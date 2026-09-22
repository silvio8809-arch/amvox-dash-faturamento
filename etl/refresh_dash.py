# -*- coding: utf-8 -*-
"""
ETL do Dashboard TV Faturamento & Logística (AMVOX).

Protheus (somente leitura) -> pós-processamento -> cache Supabase (tabelas dash_*).
Regras em .claude/skills/dash-tv-faturamento. Padrão operacional herdado da tarefa
`refresh-app-precos`: VPN primeiro; qualquer falha => NÃO grava nada e mantém o retrato
anterior; fecha com resumo.

Uso:
    python3 etl/refresh_dash.py              # janela padrão (120 dias)
    python3 etl/refresh_dash.py --dias 30
    python3 etl/refresh_dash.py --dry-run    # roda tudo, não grava no Supabase
"""
import argparse, json, os, socket, sys, datetime as dt
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
SQL_NF  = RAIZ / "sql/01_extracao/01_nf_saida.sql"
SQL_DEV = RAIZ / "sql/01_extracao/02_devolucao.sql"
SQL_VL  = RAIZ / "sql/01_extracao/03_venda_linha.sql"   # venda por região x linha
ENVFILE = RAIZ / ".env"


def carrega_env():
    """Credenciais SEMPRE de fora do código (.env local, nunca versionado).
    Variáveis de ambiente têm precedência, para rodar em outra máquina/CI."""
    cfg = {}
    if ENVFILE.exists():
        for linha in ENVFILE.read_text(encoding="utf-8").splitlines():
            linha = linha.strip()
            if linha and not linha.startswith("#") and "=" in linha:
                k, v = linha.split("=", 1)
                cfg[k.strip()] = v.strip()
    cfg.update({k: v for k, v in os.environ.items() if k.startswith(("PROTHEUS_", "SUPABASE_")) and v})
    faltando = [k for k in ("PROTHEUS_SERVER", "PROTHEUS_USER", "PROTHEUS_PASSWORD",
                            "PROTHEUS_DATABASE", "SUPABASE_URL") if not cfg.get(k)]
    if faltando:
        raise RuntimeError(f"Faltam credenciais em {ENVFILE}: {', '.join(faltando)} "
                           f"(veja .env.exemplo)")
    return cfg


ENV = carrega_env()
PROTHEUS = dict(server=ENV["PROTHEUS_SERVER"], port=int(ENV.get("PROTHEUS_PORT", 1521)),
                user=ENV["PROTHEUS_USER"], password=ENV["PROTHEUS_PASSWORD"],
                database=ENV["PROTHEUS_DATABASE"], login_timeout=30, timeout=900)
SUPABASE_URL = ENV["SUPABASE_URL"]


# ------------------------------------------------------------------ utilidades
def log(msg):
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", flush=True)


def vpn_ok(host="201.157.225.29", porta=1521, timeout=8):
    try:
        with socket.create_connection((host, porta), timeout=timeout):
            return True
    except OSError:
        return False


def d(v):
    """CHAR(8) YYYYMMDD -> 'YYYY-MM-DD' (ou None)."""
    if not v:
        return None
    v = str(v).strip()
    return f"{v[0:4]}-{v[4:6]}-{v[6:8]}" if len(v) == 8 and v.isdigit() else None


def num(v):
    return float(v) if v is not None else None


def janela(dias):
    hoje = dt.date.today()
    return (hoje - dt.timedelta(days=dias)).strftime("%Y%m%d"), hoje.strftime("%Y%m%d")


def sql_com_janela(caminho, de, ate):
    """Troca o DECLARE/SET da janela pelas datas do run (mantém o arquivo como fonte única)."""
    txt = caminho.read_text(encoding="utf-8")
    alvo_de  = "SET @DATADE  = CONVERT(CHAR(8), DATEADD(DAY,-120,GETDATE()), 112);"
    alvo_ate = "SET @DATAATE = CONVERT(CHAR(8), GETDATE(), 112);"
    if alvo_de not in txt or alvo_ate not in txt:
        raise RuntimeError(f"{caminho.name}: não achei as linhas SET da janela — o arquivo mudou?")
    return (txt.replace(alvo_de, f"SET @DATADE  = '{de}';")
               .replace(alvo_ate, f"SET @DATAATE = '{ate}';"))


# ------------------------------------------------------------------ extração
def extrai(conn, sql):
    cur = conn.cursor(as_dict=True)
    cur.execute(sql)
    linhas = cur.fetchall()
    cur.close()
    return [{k: (v.strip() if isinstance(v, str) else v) for k, v in r.items()} for r in linhas]


def monta_nf(reg):
    return dict(
        filial=reg["FILIAL"], nf=reg["NF"], serie=reg["SERIE"], emissao=d(reg["EMISSAO"]),
        cliente_cod=reg["CLIENTE_COD"], cliente_loja=reg["CLIENTE_LOJA"],
        cliente_nome=reg["CLIENTE_NOME"] or None, cnpj_raiz=reg["CNPJ_RAIZ"] or None,
        uf=reg["UF"] or None, a1_tipo=reg["A1_TIPO"] or None,
        transportadora=reg["TRANSPORTADORA"] or None, cfop=reg["CFOP"] or None,
        valor_faturado=num(reg["VALOR_FATURADO"]), valor_mercadoria=num(reg["VALOR_MERCADORIA"]),
        valor_ipi=num(reg["VALOR_IPI"]),
        dt_entrega=d(reg["DT_ENTREGA"]), dt_entrega_origem=reg["DT_ENTREGA_ORIGEM"],
        dt_prevista=d(reg["DT_PREVISTA"]), dt_prevista_orig=d(reg["DT_PREVISTA_ORIG"]),
        vlr_titulos=num(reg["VLR_TITULOS"]), saldo_aberto=num(reg["SALDO_ABERTO"]),
        vencimento_real=d(reg["VENCIMENTO_REAL"]), dt_cancelamento=d(reg["DT_CANCELAMENTO"]),
        status=reg["STATUS_BASE"], dias_sem_entrega=reg["DIAS_SEM_ENTREGA"],
        faixa_entrega=reg["FAIXA_ENTREGA"], atraso_dias=None,
        updated_at=dt.datetime.now(dt.timezone.utc).isoformat(),
    )


def monta_dev(reg):
    return dict(
        filial=reg["FILIAL"], nf_dev=reg["NF_DEV"], serie_dev=reg["SERIE_DEV"],
        emissao_dev=d(reg["EMISSAO_DEV"]), origem_nf=reg["ORIGEM_NF"],
        cliente_cod=reg["CLIENTE_COD"], cliente_loja=reg["CLIENTE_LOJA"],
        cliente_nome=reg["CLIENTE_NOME"] or None, cnpj_raiz=reg["CNPJ_RAIZ"] or None,
        uf=reg["UF"] or None, cfop=reg["CFOP"] or None,
        nf_origem=reg["NF_ORIGEM"] or None, serie_origem=reg["SERIE_ORIGEM"] or None,
        emissao_origem=d(reg["EMISSAO_ORIGEM"]), qtd_itens=reg["QTD_ITENS"],
        valor=num(reg["VALOR"]), tem_motivo=bool(reg["TEM_MOTIVO"]),
        devolucao_venda=bool(reg["DEVOLUCAO_VENDA"]),
        texto_nf=reg["TEXTO_NF"] or None, motivo_causa=(reg["MOTIVO_CAUSA"] or None),
        updated_at=dt.datetime.now(dt.timezone.utc).isoformat(),
    )


def monta_vl(reg):
    """Uma linha por NF x LINHA de produto. Grão diferente do dash_nf_saida — ver 002_venda_linha.sql."""
    return dict(
        filial=reg["FILIAL"], nf=reg["NF"], serie=reg["SERIE"],
        linha=reg["LINHA"], grupo=reg["GRUPO"] or None,
        emissao=d(reg["EMISSAO"]),
        cliente_cod=reg["CLIENTE_COD"], cliente_loja=reg["CLIENTE_LOJA"],
        cliente_nome=reg["CLIENTE_NOME"] or None, cnpj_raiz=reg["CNPJ_RAIZ"] or None,
        uf=reg["UF"] or None, regiao=reg["REGIAO"],
        itens=reg["ITENS"], quantidade=num(reg["QUANTIDADE"]),
        valor_faturado=num(reg["VALOR_FATURADO"]),
        valor_mercadoria=num(reg["VALOR_MERCADORIA"]),
        status=reg["STATUS"],
        updated_at=dt.datetime.now(dt.timezone.utc).isoformat(),
    )


def confere_venda_linha(nfs, vls):
    """A soma por linha de produto TEM de dar o mesmo faturamento da soma por nota.
    SUM(D2_VALBRUT) = F2_VALFAT ao centavo (conferido 22/09/2026). Divergência aqui
    significa item órfão ou nota fora do universo — não publicar sem entender."""
    a = round(sum(n["valor_faturado"] or 0 for n in nfs), 2)
    b = round(sum(v["valor_faturado"] or 0 for v in vls), 2)
    nf_a = {(n["filial"], n["nf"], n["serie"]) for n in nfs}
    nf_b = {(v["filial"], v["nf"], v["serie"]) for v in vls}
    return dict(valor_nf=a, valor_linha=b, delta=round(b - a, 2),
                nf_sem_linha=sorted(nf_a - nf_b)[:5], n_sem_linha=len(nf_a - nf_b),
                linha_sem_nf=sorted(nf_b - nf_a)[:5], n_sem_nf=len(nf_b - nf_a))


# ------------------------------------------------------------------ pós-processo
def aplica_devolucao_e_atraso(nfs, devs):
    """Status final (ordem da SPEC) + dias de atraso contra a previsão do GFE."""
    devolvido = {}
    for v in devs:
        if v["nf_origem"]:
            k = (v["filial"], v["nf_origem"], v["serie_origem"] or "")
            devolvido[k] = devolvido.get(k, 0.0) + (v["valor"] or 0.0)

    marcadas = {"DEVOLVIDA_TOTAL": 0, "DEVOLVIDA_PARCIAL": 0}
    for n in nfs:
        # atraso: realizado - previsto (só quando há as duas datas)
        if n["dt_entrega"] and n["dt_prevista"]:
            a = dt.date.fromisoformat(n["dt_entrega"])
            p = dt.date.fromisoformat(n["dt_prevista"])
            n["atraso_dias"] = (a - p).days

        if n["status"] == "CANCELADA":
            continue
        val_dev = devolvido.get((n["filial"], n["nf"], n["serie"]), 0.0)
        if val_dev > 0:
            base = n["valor_faturado"] or 0.0
            n["status"] = "DEVOLVIDA_TOTAL" if val_dev >= base - 0.01 else "DEVOLVIDA_PARCIAL"
            marcadas[n["status"]] += 1
    return marcadas


# ------------------------------------------------------------------ carga
def chave_service():
    chave = ENV.get("SUPABASE_SERVICE_KEY", "").strip()
    if not chave:
        raise RuntimeError(
            "Falta SUPABASE_SERVICE_KEY no .env.\n"
            "    Supabase → Project Settings → API Keys → service_role → Reveal → copiar.\n"
            "    O ETL precisa dela para GRAVAR: a chave publishable é barrada pelo RLS.")
    return chave


def remove_orfas(tabela, linhas, chave_svc, campos_chave, campo_data, de, ate, teto=0.05):
    """Apaga do cache as linhas que sumiram da ORIGEM dentro da janela extraída.

    Por que existe (achado em 22/09/2026, ao carregar a tabela região x linha):
    o ETL só fazia upsert. Nota CANCELADA some da SF2 (D_E_L_E_T_='*') e a linha
    ficava no cache PARA SEMPRE, contando como faturamento válido. Foi o caso das
    6 NF de 21/09 canceladas em 22/09 — R$ 41.513,65 fantasma em dash_nf_saida.

    Trava: se a sobra passar de `teto` (5%) das linhas da janela, NÃO apaga e devolve
    o aviso. Extração parcial não pode esvaziar o painel.
    """
    import urllib.request, urllib.parse, json as _json
    cab = {"apikey": chave_svc, "Authorization": f"Bearer {chave_svc}"}
    sel = ",".join(campos_chave)
    # o que está hoje no cache DENTRO da janela
    existentes, off = [], 0
    while True:
        url = (f"{SUPABASE_URL}/rest/v1/{tabela}?select={sel}"
               f"&{campo_data}=gte.{d(de)}&{campo_data}=lte.{d(ate)}")
        req = urllib.request.Request(url, headers={**cab, "Range": f"{off}-{off+999}"})
        pag = _json.load(urllib.request.urlopen(req, timeout=60))
        existentes += pag; off += 1000
        if len(pag) < 1000:
            break
    k = lambda r: tuple(str(r[c]) for c in campos_chave)
    vivas = {k(r) for r in linhas}
    orfas = [r for r in existentes if k(r) not in vivas]
    if not orfas:
        return 0, None
    if existentes and len(orfas) / len(existentes) > teto:
        return 0, (f"{tabela}: {len(orfas)} de {len(existentes)} linhas da janela sumiram da origem "
                   f"({100*len(orfas)/len(existentes):.1f}% > teto de {100*teto:.0f}%) — "
                   f"NÃO apaguei nada. Conferir a extração antes.")
    # trilha: DELETE não deixa rastro no cache, então o que sai fica registrado aqui
    log(f"  {tabela}: removendo {len(orfas)} linha(s) que sumiram da origem — "
        + "; ".join("/".join(str(r[c]) for c in campos_chave) for r in orfas[:20])
        + (" ..." if len(orfas) > 20 else ""))
    for r in orfas:
        q = "&".join(f"{c}=eq." + urllib.parse.quote(str(r[c]), safe="") for c in campos_chave)
        req = urllib.request.Request(f"{SUPABASE_URL}/rest/v1/{tabela}?{q}",
                                     headers={**cab, "Prefer": "return=minimal"}, method="DELETE")
        urllib.request.urlopen(req, timeout=60)
    return len(orfas), None


def upsert(tabela, linhas, chave, conflito, lote=500):
    import urllib.request
    if not linhas:
        return 0
    enviados = 0
    for i in range(0, len(linhas), lote):
        parte = linhas[i:i + lote]
        req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/{tabela}?on_conflict={conflito}",
            data=json.dumps(parte, default=str).encode("utf-8"),
            method="POST",
            headers={"apikey": chave, "Authorization": f"Bearer {chave}",
                     "Content-Type": "application/json",
                     "Prefer": "resolution=merge-duplicates,return=minimal"})
        with urllib.request.urlopen(req, timeout=120) as r:
            if r.status not in (200, 201, 204):
                raise RuntimeError(f"{tabela}: HTTP {r.status}")
        enviados += len(parte)
        log(f"    {tabela}: {enviados}/{len(linhas)}")
    return enviados


def grava_log(chave, **campos):
    import urllib.request
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/dash_refresh_log",
        data=json.dumps([campos], default=str).encode("utf-8"), method="POST",
        headers={"apikey": chave, "Authorization": f"Bearer {chave}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"})
    try:
        urllib.request.urlopen(req, timeout=30)
    except Exception as e:
        log(f"  (aviso: não consegui gravar o log do refresh: {e})")


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dias", type=int, default=120)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    inicio = dt.datetime.now(dt.timezone.utc)
    de, ate = janela(args.dias)
    log(f"janela {de} a {ate} ({args.dias} dias)")

    # 1. VPN — sem ela, não faz nada (o painel segue com o retrato anterior)
    if not vpn_ok():
        log("VPN OFF — nada extraído, nada gravado. O painel segue com o retrato anterior.")
        return 2

    chave = None if args.dry_run else chave_service()

    # 2. Extração (somente leitura)
    try:
        import pymssql
        conn = pymssql.connect(**PROTHEUS)
    except Exception as e:
        log(f"ERRO ao conectar no Protheus: {e}")
        return 1
    try:
        log("extraindo NF de saída...")
        nfs = [monta_nf(r) for r in extrai(conn, sql_com_janela(SQL_NF, de, ate))]
        log(f"  {len(nfs)} NF de faturamento")
        log("extraindo devoluções...")
        devs = [monta_dev(r) for r in extrai(conn, sql_com_janela(SQL_DEV, de, ate))]
        log(f"  {len(devs)} devoluções")
        log("extraindo venda por região x linha...")
        vls = [monta_vl(r) for r in extrai(conn, sql_com_janela(SQL_VL, de, ate))]
        log(f"  {len(vls)} linhas de NF x linha de produto")
    except Exception as e:
        log(f"ERRO na extração: {e} — nada gravado.")
        return 1
    finally:
        conn.close()

    # 3. Pós-processo
    marcadas = aplica_devolucao_e_atraso(nfs, devs)
    log(f"status por devolução: {marcadas['DEVOLVIDA_TOTAL']} totais, "
        f"{marcadas['DEVOLVIDA_PARCIAL']} parciais")

    # trava: venda por linha tem de reconciliar com a venda por nota
    rec = confere_venda_linha(nfs, vls)
    if rec["delta"] != 0 or rec["n_sem_linha"] or rec["n_sem_nf"]:
        log(f"ERRO de reconciliação região x linha: nota R$ {rec['valor_nf']:,.2f} x "
            f"linha R$ {rec['valor_linha']:,.2f} (delta {rec['delta']:,.2f}); "
            f"{rec['n_sem_linha']} NF sem linha {rec['nf_sem_linha']}; "
            f"{rec['n_sem_nf']} linha sem NF {rec['linha_sem_nf']} — nada gravado.")
        return 1
    log(f"reconciliação região x linha: OK (R$ {rec['valor_linha']:,.2f} nos dois grãos)")

    sem_entrega = [n for n in nfs if n["faixa_entrega"]]
    saldo = sum(n["saldo_aberto"] or 0 for n in sem_entrega)
    log(f"fila de cobrança: {len(sem_entrega)} NF sem entrega, R$ {saldo:,.2f} em aberto")

    if args.dry_run:
        log("DRY-RUN — nada gravado no Supabase.")
        return 0

    # 4. Carga (só aqui escreve; falhou antes = não chega aqui)
    try:
        log("gravando no Supabase...")
        n1 = upsert("dash_nf_saida", nfs, chave, "filial,nf,serie")
        n2 = upsert("dash_devolucao", devs, chave, "filial,nf_dev,serie_dev,cliente_cod,cliente_loja")
        n3 = upsert("dash_venda_linha", vls, chave, "filial,nf,serie,linha")
        # varredura de órfãs: o que sumiu da origem (nota cancelada) tem de sair do cache
        for tab, dados, cps, cdata in [
                ("dash_nf_saida",    nfs, ["filial","nf","serie"],                                      "emissao"),
                ("dash_devolucao",   devs,["filial","nf_dev","serie_dev","cliente_cod","cliente_loja"], "emissao_dev"),
                ("dash_venda_linha", vls, ["filial","nf","serie","linha"],                              "emissao")]:
            qtd, aviso = remove_orfas(tab, dados, chave, cps, cdata, de, ate)
            if aviso:
                log("ATENÇÃO — " + aviso)
            elif qtd:
                log(f"  {tab}: {qtd} linha(s) removida(s) — sumiram da origem (cancelamento/exclusão)")
    except Exception as e:
        log(f"ERRO na carga: {e}")
        grava_log(chave, started_at=inicio.isoformat(),
                  finished_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                  ok=False, rows_nf=0, rows_dev=0,
                  janela_de=d(de), janela_ate=d(ate), erro=str(e)[:500])
        return 1

    grava_log(chave, started_at=inicio.isoformat(),
              finished_at=dt.datetime.now(dt.timezone.utc).isoformat(),
              ok=True, rows_nf=n1, rows_dev=n2, janela_de=d(de), janela_ate=d(ate))
    seg = (dt.datetime.now(dt.timezone.utc) - inicio).total_seconds()
    log(f"OK — {n1} NF, {n2} devoluções e {n3} linhas região x linha em {seg:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
