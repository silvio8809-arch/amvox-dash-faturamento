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
Saída: 0 = bateu · 1 = pendência · 2 = não deu para conferir (VPN/log ausente).
"""
import re
import argparse, datetime as dt, json, socket, sys, urllib.request
from pathlib import Path

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
    linhas, _ = sb("dash_refresh_log?select=started_at,finished_at,rows_nf"
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dias", type=int, default=120)
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

    hoje = dt.date.today()
    de   = (hoje - dt.timedelta(days=args.dias)).strftime("%Y%m%d")
    ate  = hoje.strftime("%Y%m%d")
    log(f"janela {de} a {ate} ({args.dias} dias)")

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
            SELECT LTRIM(RTRIM(F2_FILIAL)) FIL, LTRIM(RTRIM(F2_DOC)) NF,
                   LTRIM(RTRIM(F2_SERIE)) SER, F2_EMISSAO EMIS,
                   LTRIM(RTRIM(F2_HORA)) HORA, F2_VALFAT VAL,
                   LTRIM(RTRIM(F2_CLIENTE)) CLI
            FROM   SF2010
            WHERE  D_E_L_E_T_ = ''
              AND  F2_VALFAT  > 0
              AND  F2_EMISSAO BETWEEN '{de}' AND '{ate}'""")
        origem = {(r["FIL"], r["NF"], r["SER"]): r for r in cur.fetchall()}
        cur.close()
    finally:
        conn.close()

    # ---------------------------------------------------------------- cache
    cache = {}
    for c in sb_tudo("dash_nf_saida?select=filial,nf,serie,valor_faturado,emissao"):
        cache[(c["filial"].strip(), c["nf"].strip(), c["serie"].strip())] = c

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
    sys.exit(main())
