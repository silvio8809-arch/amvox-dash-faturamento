#!/usr/bin/env python3
"""
CONFERÊNCIA do cache do Dashboard TV contra a origem (Protheus) — SOMENTE LEITURA.

Passo 3 da rotina `refresh-dash-faturamento`: detecta quebra silenciosa comparando
NF a NF o que está em `dash_nf_saida` com o que está na SF2010.

POR QUE O CORTE POR HORA (decisão Silvio 21/09/2026)
----------------------------------------------------
Rodando em horário comercial, sempre há nota emitida ENTRE o fim da extração e a
conferência. Sem corte, toda rodada acusava um delta que não era erro (em 21/09:
5 NF, R$ 155.992,20, todas emitidas às 14:36–14:52 contra extração que terminou
14:16). O corte usa `started_at` do último refresh ok e separa o que é ruído do
que é quebra de verdade, para o veredito virar sim-ou-não limpo.

COMO O VEREDITO É FORMADO
-------------------------
  SOBRA no cache ................ SEMPRE pendência (nota no cache que não existe
                                  na origem — ex.: cancelada/deletada depois).
  DIVERGÊNCIA DE VALOR .......... SEMPRE pendência (deve bater ao centavo).
  FALTA emitida ANTES do corte .. pendência (deveria estar no retrato).
  FALTA emitida APÓS o corte .... esperado, só informa (a próxima rodada pega).

⚠️ Uma nota lançada com hora retroativa (emissão antes do corte, gravada no banco
depois da extração) cai em "falta antes do corte" e dispara pendência. É falso
positivo, mas é o erro seguro: melhor conferir à mão do que deixar passar quebra.

Uso:  python3 etl/confere_dash.py            # corte = started_at do último refresh ok
      python3 etl/confere_dash.py --corte "2026-09-21 14:14"   # corte manual (local)
      python3 etl/confere_dash.py --dias 120
Saída: 0 = bateu · 1 = pendência · 2 = não deu para conferir (VPN/conexão/log ausente).
Queda de conexão no meio da conferência também sai 2 — não é pendência (Silvio 23/09/2026).
"""
import re
import argparse, datetime as dt, json, socket, sys, urllib.request
from pathlib import Path

# mesma régua de "falha de conexão" do ETL — uma só, para as duas não divergirem
from refresh_dash import falha_de_conexao, segura_mac_acordado

RAIZ    = Path(__file__).resolve().parent.parent
ENVFILE = RAIZ / ".env"
TOL     = 0.005          # tolerância de valor: meio centavo (ruído de float)
SKEW_MAX = 120           # segundos de diferença tolerada entre Mac e servidor


def carrega_env():
    import os
    cfg = {}
    if ENVFILE.exists():
        for linha in ENVFILE.read_text(encoding="utf-8").splitlines():
            linha = linha.strip()
            if linha and not linha.startswith("#") and "=" in linha:
                k, v = linha.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    cfg.update({k: v for k, v in os.environ.items()
                if k.startswith(("PROTHEUS_", "SUPABASE_")) and v})
    faltando = [k for k in ("PROTHEUS_SERVER", "PROTHEUS_USER", "PROTHEUS_PASSWORD",
                            "PROTHEUS_DATABASE", "SUPABASE_URL", "SUPABASE_SERVICE_KEY")
                if not cfg.get(k)]
    if faltando:
        raise RuntimeError(f"Faltam credenciais em {ENVFILE}: {', '.join(faltando)}")
    return cfg


ENV = carrega_env()


def log(msg):
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", flush=True)


def vpn_ok(host="201.157.225.29", porta=1521, timeout=8):
    try:
        with socket.create_connection((host, porta), timeout=timeout):
            return True
    except OSError:
        return False


def sb(path, rng=None, prefer=None):
    """GET no PostgREST. NUNCA imprime a chave."""
    req = urllib.request.Request(f"{ENV['SUPABASE_URL'].rstrip('/')}/rest/v1/{path}")
    req.add_header("apikey", ENV["SUPABASE_SERVICE_KEY"])
    req.add_header("Authorization", f"Bearer {ENV['SUPABASE_SERVICE_KEY']}")
    if rng:
        req.add_header("Range-Unit", "items")
        req.add_header("Range", rng)
    if prefer:
        req.add_header("Prefer", prefer)
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode()), r.headers.get("Content-Range")


def sb_tudo(path, pagina=1000):
    """PostgREST pagina de 1000 em 1000 — sem isso a soma sai TRUNCADA."""
    linhas, off = [], 0
    while True:
        lote, _ = sb(path, f"{off}-{off + pagina - 1}")
        linhas += lote
        if len(lote) < pagina:
            return linhas
        off += pagina


def corte_do_log():
    """started_at (UTC) do último refresh ok → hora LOCAL, que é a do F2_HORA."""
    linhas, _ = sb("dash_refresh_log?select=started_at,finished_at,rows_nf,janela_de,janela_ate"
                   "&ok=is.true&order=started_at.desc", "0-0")
    if not linhas or not linhas[0].get("started_at"):
        return None, None
    txt = linhas[0]["started_at"].replace("Z", "+00:00")
    # o Postgres corta o zero final do microssegundo (".21007") e o fromisoformat do
    # Python 3.9 só aceita 3 ou 6 dígitos — normaliza para 6 antes de converter.
    m = re.match(r"^(.*?)\.(\d{1,6})(.*)$", txt)
    if m:
        txt = f"{m.group(1)}.{m.group(2):<06s}{m.group(3)}"
    q = dt.datetime.fromisoformat(txt)
    if q.tzinfo is None:
        q = q.replace(tzinfo=dt.timezone.utc)
    return q.astimezone(), linhas[0]


def F_dia(iso):
    return f"{iso[8:10]}/{iso[5:7]}/{iso[:4]}" if iso else "—"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dias", type=int, default=None,
                    help="janela manual; sem ela vale a janela GRAVADA no último refresh ok")
    ap.add_argument("--corte", help='corte manual, hora local "AAAA-MM-DD HH:MM"')
    args = ap.parse_args()

    if not vpn_ok():
        log("VPN OFF — não dá para conferir. O cache não foi tocado.")
        return 2

    if args.corte:
        corte, info = dt.datetime.strptime(args.corte, "%Y-%m-%d %H:%M").astimezone(), None
        log(f"corte MANUAL: {corte:%d/%m/%Y %H:%M} (local)")
    else:
        corte, info = corte_do_log()
        if corte is None:
            log("Sem refresh ok em dash_refresh_log — não há retrato para conferir.")
            return 2
        log(f"corte = início do último refresh ok: {corte:%d/%m/%Y %H:%M:%S} (local) "
            f"· {info['rows_nf']} NF gravadas")

    # JANELA = a do retrato que está no cache (janela_de do último refresh ok), e não
    # "hoje − 120". Achado em 23/09/2026: o dia que envelhece para fora da janela
    # (25/05, 46 NF, R$ 1.357.805,82) segue no cache e a conferência lia o cache
    # inteiro → acusava "sobra" que não era quebra. Agora a comparação é janela × janela
    # e o que está no cache ANTES dela sai à parte, como informação.
    hoje = dt.date.today()
    if args.dias is None and info and info.get("janela_de"):
        de  = info["janela_de"].replace("-", "")
        ate = (info.get("janela_ate") or hoje.isoformat()).replace("-", "")
        # a origem vai até o corte por hora; 'ate' do log é só o dia da extração
        ate = max(ate, hoje.strftime("%Y%m%d"))
        log(f"janela {de} a {ate} (a do último refresh ok)")
    else:
        dias = args.dias or 120
        de   = (hoje - dt.timedelta(days=dias)).strftime("%Y%m%d")
        ate  = hoje.strftime("%Y%m%d")
        log(f"janela {de} a {ate} ({dias} dias)")
    de_iso = f"{de[:4]}-{de[4:6]}-{de[6:]}"

    # ---------------------------------------------------------------- origem
    import pymssql
    conn = pymssql.connect(server=ENV["PROTHEUS_SERVER"], port=int(ENV.get("PROTHEUS_PORT", 1521)),
                           user=ENV["PROTHEUS_USER"], password=ENV["PROTHEUS_PASSWORD"],
                           database=ENV["PROTHEUS_DATABASE"], login_timeout=30, timeout=900)
    try:
        cur = conn.cursor(as_dict=True)
        cur.execute("SELECT GETDATE() AGORA")
        agora_srv = cur.fetchone()["AGORA"]
        skew = abs((agora_srv - dt.datetime.now()).total_seconds())
        if skew > SKEW_MAX:
            log(f"⚠️ relógio do servidor difere do Mac em {skew:.0f}s — o corte por hora "
                f"pode escorregar. Conferir o fuso antes de confiar no veredito.")
        # Mesmo filtro do ETL (sql/01_extracao/01_nf_saida.sql): D_E_L_E_T_, VALFAT>0, janela.
        cur.execute(f"""
            -- MESMO universo e MESMO valor do 01_nf_saida (régua da FAT PLUS, refinada 23/09/2026).
            -- Se divergir da extração, TODA rodada acusa pendência falsa.
            --   universo: F2_TIPO normal · item cuja TES gera duplicata · sem ativo imobilizado (5551/6551)
            --   valor ...: Σ D2_VALBRUT desses itens (= F2_VALFAT nas notas normais; nas 5 de título
            --              manual o cabeçalho zerou e a FAT PLUS usa o valor dos itens)
            SELECT LTRIM(RTRIM(F2.F2_FILIAL)) FIL, LTRIM(RTRIM(F2.F2_DOC)) NF,
                   LTRIM(RTRIM(F2.F2_SERIE)) SER, F2.F2_EMISSAO EMIS,
                   LTRIM(RTRIM(F2.F2_HORA)) HORA, SUM(SD2.D2_VALBRUT) VAL,
                   LTRIM(RTRIM(F2.F2_CLIENTE)) CLI
            FROM   SF2010 F2
            JOIN   SD2010 SD2 ON SD2.D_E_L_E_T_ = '' AND SD2.D2_FILIAL = F2.F2_FILIAL
                             AND SD2.D2_DOC = F2.F2_DOC AND SD2.D2_SERIE = F2.F2_SERIE
                             AND SD2.D2_CLIENTE = F2.F2_CLIENTE AND SD2.D2_LOJA = F2.F2_LOJA
                             AND RTRIM(SD2.D2_CF) NOT IN ('5551','6551')
            JOIN   SF4010 TES ON TES.F4_CODIGO = SD2.D2_TES AND TES.D_E_L_E_T_ = ''
                             AND SUBSTRING(TES.F4_FILIAL,1,4) = SUBSTRING(SD2.D2_FILIAL,1,4)
                             AND TES.F4_DUPLIC = 'S'
            WHERE  F2.D_E_L_E_T_ = ''
              AND  F2.F2_TIPO NOT IN ('D','B')
              AND  F2.F2_EMISSAO BETWEEN '{de}' AND '{ate}'
            GROUP BY F2.F2_FILIAL, F2.F2_DOC, F2.F2_SERIE, F2.F2_EMISSAO, F2.F2_HORA, F2.F2_CLIENTE""")
        origem = {(r["FIL"], r["NF"], r["SER"]): r for r in cur.fetchall()}
        cur.close()
    finally:
        conn.close()

    # ---------------------------------------------------------------- cache
    cache, fora_janela = {}, {}
    for c in sb_tudo("dash_nf_saida?select=filial,nf,serie,valor_faturado,emissao"):
        k = (c["filial"].strip(), c["nf"].strip(), c["serie"].strip())
        (cache if (c["emissao"] or "") >= de_iso else fora_janela)[k] = c

    # ------------------------------------------------------------- comparação
    # F2_HORA é 'HH:MM' 100% preenchida (conferido 21/09) → compara como texto.
    chave_corte = f"{corte:%Y%m%d}{corte:%H:%M}"
    def antes_do_corte(r):
        return f"{r['EMIS']}{r['HORA']}" <= chave_corte

    falta_antes, falta_depois, divergentes = [], [], []
    for k, r in origem.items():
        if k in cache:
            dif = float(r["VAL"]) - float(cache[k]["valor_faturado"] or 0)
            if abs(dif) > TOL:
                divergentes.append((k, float(r["VAL"]), float(cache[k]["valor_faturado"] or 0), dif))
        else:
            (falta_antes if antes_do_corte(r) else falta_depois).append(r)
    sobra = [k for k in cache if k not in origem]

    comuns = len(origem) - len(falta_antes) - len(falta_depois)
    val_origem_ate_corte = sum(float(r["VAL"]) for r in origem.values() if antes_do_corte(r))
    qtd_origem_ate_corte = sum(1 for r in origem.values() if antes_do_corte(r))
    val_cache = sum(float(c["valor_faturado"] or 0) for c in cache.values())

    print()
    print(f"  ORIGEM até o corte : {qtd_origem_ate_corte:5d} NF   R$ {val_origem_ate_corte:>16,.2f}")
    print(f"  CACHE              : {len(cache):5d} NF   R$ {val_cache:>16,.2f}")
    print(f"  Δ                  : {len(cache)-qtd_origem_ate_corte:+5d} NF   "
          f"R$ {val_cache-val_origem_ate_corte:>+16,.2f}")
    print(f"  NF comuns conferidas uma a uma: {comuns}")
    print()

    if fora_janela:
        v = sum(float(c["valor_faturado"] or 0) for c in fora_janela.values())
        dias_fora = sorted({c["emissao"] for c in fora_janela.values()})
        print(f"  ℹ️  {len(fora_janela)} NF no cache ANTES da janela (R$ {v:,.2f}; emissão "
              f"{F_dia(dias_fora[0])} a {F_dia(dias_fora[-1])}) — envelheceram para fora dos "
              f"120 dias, não são conferidas nem atualizadas. Não é quebra.")
        print()

    if falta_depois:
        v = sum(float(r["VAL"]) for r in falta_depois)
        print(f"  ℹ️  {len(falta_depois)} NF emitidas APÓS o corte "
              f"(R$ {v:,.2f}) — esperado, entram no próximo refresh:")
        for r in sorted(falta_depois, key=lambda x: (x["EMIS"], x["HORA"]))[:10]:
            print(f"        {r['EMIS'][6:8]}/{r['EMIS'][4:6]} {r['HORA']}  fil {r['FIL']} "
                  f"NF {r['NF']}/{r['SER']}  cli {r['CLI']}  R$ {float(r['VAL']):,.2f}")
        if len(falta_depois) > 10:
            print(f"        ... e mais {len(falta_depois)-10}")
        print()

    problemas = []
    if falta_antes:
        v = sum(float(r["VAL"]) for r in falta_antes)
        problemas.append(f"{len(falta_antes)} NF emitidas ANTES do corte não estão no cache "
                         f"(R$ {v:,.2f})")
        print(f"  ❌ {len(falta_antes)} NF ANTES do corte e FORA do cache (R$ {v:,.2f}):")
        for r in sorted(falta_antes, key=lambda x: (x["EMIS"], x["HORA"]))[:20]:
            print(f"        {r['EMIS'][6:8]}/{r['EMIS'][4:6]} {r['HORA']}  fil {r['FIL']} "
                  f"NF {r['NF']}/{r['SER']}  cli {r['CLI']}  R$ {float(r['VAL']):,.2f}")
        print("        (checar se é lançamento com hora retroativa antes de tratar como quebra)")
        print()
    if sobra:
        problemas.append(f"{len(sobra)} NF no cache que não existem na origem")
        print(f"  ❌ {len(sobra)} NF no CACHE e FORA da origem:")
        for k in sorted(sobra)[:20]:
            print(f"        fil {k[0]} NF {k[1]}/{k[2]}  R$ "
                  f"{float(cache[k]['valor_faturado'] or 0):,.2f}")
        print()
    if divergentes:
        problemas.append(f"{len(divergentes)} NF com valor divergente")
        print(f"  ❌ {len(divergentes)} NF com VALOR divergente:")
        for k, vo, vc, dif in sorted(divergentes, key=lambda x: -abs(x[3]))[:20]:
            print(f"        fil {k[0]} NF {k[1]}/{k[2]}  origem {vo:,.2f} × cache {vc:,.2f} "
                  f"= {dif:+,.2f}")
        print()

    if problemas:
        print("  CONFERÊNCIA: ❌ PENDÊNCIA — " + " · ".join(problemas))
        print("  Não ajustar nada por conta própria. Reportar.")
        return 1
    print("  CONFERÊNCIA: ✅ BATEU — cache idêntico à origem no instante da extração "
          "(quantidade e valor, NF a NF).")
    return 0


if __name__ == "__main__":
    segura_mac_acordado()
    try:
        sys.exit(main())
    except Exception as e:
        if not falha_de_conexao(e):
            raise
        log(f"SEM CONEXÃO ({type(e).__name__}: {str(e)[:300]}) — não deu para conferir agora. "
            f"O cache não foi tocado.")
        sys.exit(2)
