# -*- coding: utf-8 -*-
"""
ETL do Dashboard TV Faturamento & Logística (AMVOX).

Protheus (somente leitura) -> pós-processamento -> cache Supabase (tabelas dash_*).
Regras em .claude/skills/dash-tv-faturamento. Padrão operacional herdado da tarefa
`refresh-app-precos`: VPN primeiro; qualquer falha => NÃO grava nada e mantém o retrato
anterior; fecha com resumo.

Falha de CONEXÃO não é erro (decisão Silvio 23/09/2026): o próprio ETL espera e tenta de
novo — até 3 vezes, 5 min entre elas; com --ate, insiste até o horário dado. Erro de DADO
continua parando na hora.

Uso:
    python3 etl/refresh_dash.py              # janela padrão (120 dias), até 3 tentativas
    python3 etl/refresh_dash.py --dias 30
    python3 etl/refresh_dash.py --dry-run    # roda tudo, não grava no Supabase
    python3 etl/refresh_dash.py --ate 18:00  # rodada final do dia: insiste até 18h00

Saída: 0 = gravou · 1 = erro de DADO (reportar) · 2 = sem conexão depois das tentativas
(ignorar: o painel segue com o retrato anterior e a próxima rodada tenta de novo).
"""
import argparse
import re, json, os, re, socket, subprocess, sys, tempfile, time, datetime as dt
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
SQL_NF  = RAIZ / "sql/01_extracao/01_nf_saida.sql"
SQL_DEV = RAIZ / "sql/01_extracao/02_devolucao.sql"
SQL_VL  = RAIZ / "sql/01_extracao/03_venda_linha.sql"   # venda por região x linha
SQL_VO  = RAIZ / "sql/01_extracao/04_vo_remessa.sql"    # venda à ordem: notas de remessa
SQL_VOR = RAIZ / "sql/01_extracao/05_vo_referencia.sql" # índice p/ resolver a NF-mãe citada
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


# Desde 23/09/2026 o cache guarda o FATURAMENTO desde JAN/2025 (pedido do Silvio: "Incluir dados
# de faturamento também de 2025"). Antes eram 120 dias móveis — e o dia que saía da janela ficava
# congelado no cache (achado 23/09). Com início FIXO a varredura de órfãs cobre o cache inteiro.
# Custo: a extração caiu de 8 min (120 dias) para ~20 s (desde jan/25) depois que os blocos do
# Financeiro/GFE/SF3/SD2/SD1 passaram a olhar só a janela (23/09/2026).
DESDE_PADRAO = "20250101"

def janela(dias=None, desde=None):
    hoje = dt.date.today()
    if desde:
        return desde, hoje.strftime("%Y%m%d")
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


# ------------------------------------------------------------------ tentativas
# Cai como falha de CONEXÃO: VPN fora, conexão derrubada, réplica sem resposta, Mac que
# dormiu no meio. Erro de DADO (SQL, reconciliação, carga recusada) para na hora (exit 1).
#
# Por que a extração roda num processo filho vigiado pelo RELÓGIO DE PAREDE: em 22/09 a
# tampa do Mac fechou às 16h47 no meio da extração e o processo ficou 6h44 parado. O
# timeout do pymssql/FreeTDS só conta o tempo em que o Mac está acordado — estourou de
# madrugada, somando os minutos de "DarkWake". Passou do limite, o filho é morto e a
# tentativa conta como falha de conexão. Nada é gravado antes de a extração terminar.
ERROS_REDE = {20002, 20003, 20004, 20006, 20009, 20017, 20047}   # DB-Lib: conexão/timeout/processo morto
DEADLOCK   = 1205                                               # vítima de deadlock: transitório
TRAVA      = Path(tempfile.gettempdir()) / "amvox_refresh_dash.lock"


def falha_de_conexao(e):
    """True = queda de conexão (tenta de novo) · False = erro de verdade (para e reporta)."""
    import urllib.error
    if isinstance(e, urllib.error.HTTPError):
        return False                        # o servidor respondeu e recusou: não é rede
    if isinstance(e, (urllib.error.URLError, ConnectionError, TimeoutError,
                      socket.timeout, socket.gaierror)):
        return True
    try:
        import pymssql
    except ImportError:
        return False
    if isinstance(e, pymssql.InterfaceError):
        return True
    if isinstance(e, pymssql.OperationalError):
        a = e.args[0] if e.args else None
        n = a[0] if isinstance(a, tuple) and a else a
        if not isinstance(n, int):
            m = re.search(r"DB-Lib error message (\d+)", str(e))
            n = int(m.group(1)) if m else None
        return n in ERROS_REDE or n == DEADLOCK
    return False


def _extrai_no_filho(de, ate, saida):
    """Processo filho: conecta, roda as 3 extrações e deixa o resultado bruto em `saida`."""
    import pickle
    try:
        import pymssql
        conn = pymssql.connect(**PROTHEUS)
        try:
            log("extraindo NF de saída...")
            nf = extrai(conn, sql_com_janela(SQL_NF, de, ate))
            log(f"  {len(nf)} NF de faturamento")
            log("extraindo devoluções...")
            dev = extrai(conn, sql_com_janela(SQL_DEV, de, ate))
            log(f"  {len(dev)} devoluções")
            log("extraindo venda por região x linha...")
            vl = extrai(conn, sql_com_janela(SQL_VL, de, ate))
            log(f"  {len(vl)} linhas de NF x linha de produto")
            log("extraindo venda à ordem (remessas + índice das NF citadas)...")
            vo = extrai(conn, sql_com_janela(SQL_VO, de, ate))
            vor = extrai(conn, sql_com_janela(SQL_VOR, de, ate))
            log(f"  {len(vo)} remessas · índice com {len(vor)} NF")
        finally:
            conn.close()
        res = ("ok", (nf, dev, vl, vo, vor))
    except Exception as e:
        res = ("conexao" if falha_de_conexao(e) else "erro", f"{type(e).__name__}: {str(e)[:300]}")
    with open(saida, "wb") as f:
        pickle.dump(res, f)


def tentativa_extracao(de, ate, limite_seg):
    """Uma tentativa em processo filho, com teto no relógio de parede.
    Devolve ('ok', (nf, dev, vl)) | ('conexao', motivo) | ('erro', motivo)."""
    import multiprocessing as mp, pickle
    fd, saida = tempfile.mkstemp(prefix="amvox_dash_", suffix=".pkl")
    os.close(fd)
    try:
        filho = mp.get_context("spawn").Process(target=_extrai_no_filho,
                                                args=(de, ate, saida), daemon=True)
        filho.start()
        prazo = time.time() + limite_seg
        while filho.is_alive() and time.time() < prazo:
            filho.join(5)                   # acorda a cada 5 s para olhar o relógio de parede
        if filho.is_alive():
            filho.kill()
            filho.join(10)
            return "conexao", (f"extração passou de {limite_seg / 60:g} min no relógio "
                               f"(réplica travada ou Mac em repouso) — processo encerrado")
        if os.path.getsize(saida) == 0:
            return "erro", f"o processo de extração terminou sem resultado (código {filho.exitcode})"
        with open(saida, "rb") as f:
            return pickle.load(f)
    finally:
        try:
            os.remove(saida)
        except OSError:
            pass


def espera_ate(instante):
    """Dorme até `instante` (epoch) pelo relógio de parede: se o Mac dormir no meio, ao
    acordar a espera já venceu e segue na hora."""
    while time.time() < instante:
        time.sleep(min(30, max(0.0, instante - time.time())))


def trava_execucao(prazo):
    """Uma carga por vez: a rodada das 16h pode ainda estar tentando quando a das 16h30
    chega. Espera a outra terminar até `prazo` (epoch). Devolve o arquivo travado (manter
    aberto — a trava some quando o processo termina) ou None se não deu."""
    try:
        import fcntl
    except ImportError:                     # Windows: sem trava (a rotina agendada roda no Mac)
        return open(os.devnull, "w")
    f = open(TRAVA, "w")
    avisou = False
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return f
        except OSError:
            if time.time() >= prazo:
                f.close()
                return None
            if not avisou:
                log("outra carga do painel em andamento — aguardando ela terminar...")
                avisou = True
            time.sleep(30)


def segura_mac_acordado():
    """Impede o repouso POR INATIVIDADE enquanto o ETL roda (tampa fechada não tem como)."""
    try:
        subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass                                # fora do Mac não existe caffeinate


def ultimo_retrato_ok(chave):
    """'dd/mm HH:MM' (local) do último refresh ok — para o aviso de qual retrato a TV mostra."""
    import urllib.request
    try:
        req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/dash_refresh_log?select=started_at&ok=is.true"
            f"&order=started_at.desc&limit=1",
            headers={"apikey": chave, "Authorization": f"Bearer {chave}"})
        txt = json.load(urllib.request.urlopen(req, timeout=30))[0]["started_at"]
        q = dt.datetime.fromisoformat(txt[:19]).replace(tzinfo=dt.timezone.utc).astimezone()
        return f"{q:%d/%m %H:%M}"
    except Exception:
        return None


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
        venda_ordem=bool(reg.get("VENDA_ORDEM")),
        regra_especial=reg.get("REGRA_ESPECIAL") or None,   # SINISTRO | FUNCIONARIO — só marca
        valor_devolvido=None, devolucao_em_aberto=None,     # preenchidos no pós-processo
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
        ncc_valor=num(reg.get("NCC_VALOR")), ncc_saldo=num(reg.get("NCC_SALDO")),
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


# ------------------------------------------------------------------ venda à ordem
# O vínculo remessa -> NF-mãe NÃO vem em campo padrão (D2_NFORI vazio em 1.324/1.324 itens).
# Ordem de busca (medido em 23/09/2026 sobre 645 remessas desde jan/25):
#   1º F2_XDOCREF (campo custom, só nas mais novas) ............ 46  (7,1%)
#   2º número depois de "NF" no texto da NOTA, depois do PEDIDO  574 (89,0%)
#   sem vínculo .................................................  25 (3,9%)
# Formatos vistos: "REF A NF 222423" · "REF NF 000222742-" · "NF (247809)" ·
# "NF'S 000232243/000232251" · "Origem NF 000278795 Venda Ordem". Quando o texto cita também a
# NF do distribuidor ("... AMVOX E NF (3947) DISTRIBUIDORA"), vale a PRIMEIRA que existe na base.
# "FN" = erro de digitação visto na 000230437 ("REF A FN 230019"); o número ainda tem de existir no índice.
_PAT_NF = re.compile(r"(?:N\.?\s*F|F\s*N)[^0-9]{0,14}?(\d{5,9})((?:\s*[/,e]\s*\d{5,9})*)", re.I)

def _numeros_citados(txt):
    out = []
    for m in _PAT_NF.finditer(txt or ""):
        out.append(m.group(1))
        out += re.findall(r"\d{5,9}", m.group(2) or "")    # "000232243/000232251"
    return out


def indice_referencia(vor):
    """NF de saída que uma remessa pode citar, com o tipo (mãe de venda à ordem, bonificação...)."""
    idx = {}
    for r in vor:
        tipo = ("VENDA_ORDEM" if r["EH_MAE_VO"] else "BONIFICACAO" if r["EH_BONIFICACAO"] else "VENDA_COMUM")
        idx[(r["FILIAL"], r["NF"].zfill(9))] = (r["SERIE"], tipo)
    return idx


def monta_vo(reg, idx):
    fil = reg["FILIAL"]
    vinc, achadas, texto = "SEM", [], ""
    if reg["XDOCREF"]:
        k = (reg["XFILREF"] or fil, reg["XDOCREF"].zfill(9))
        if k in idx:
            vinc, achadas, texto = "XDOCREF", [k], f"F2_XDOCREF={reg['XDOCREF']}"
    if not achadas:
        # ⚠️ ORDEM (corrigida 23/09/2026): texto da NOTA antes do texto do PEDIDO. Um pedido só
        # (C5) gera várias remessas, e o C5_MENNOTA cita UMA das mães (ex.: pedido A51182 cita a
        # 258550 nas 11 remessas); o F2_MENNOTA de cada remessa cita a mãe DELA (258544, 258545…).
        # Com o pedido primeiro, 87 mães ficavam "sem remessa" e outras "remessadas a maior".
        # Entre os números citados, vale o primeiro que é NF-mãe de venda à ordem; só na falta
        # dela fica o primeiro que existe (bonificação/venda comum — vai para "órfãs" na tela).
        for campo in ("TEXTO_NOTA", "TEXTO_PEDIDO"):
            vistos = []
            for n in _numeros_citados(reg[campo]):
                k = (fil, n.zfill(9))
                if k in idx and k not in vistos:
                    vistos.append(k)
            vo_ = [k for k in vistos if idx[k][1] == "VENDA_ORDEM"]
            if vo_:
                vinc, achadas, texto = "TEXTO", vo_ + [k for k in vistos if k not in vo_], reg[campo]
                break
            if vistos and not achadas:
                vinc, achadas, texto = "TEXTO", vistos, reg[campo]     # guarda e tenta o próximo texto
    if not texto:
        texto = reg["TEXTO_NOTA"] or reg["TEXTO_PEDIDO"] or ""
    mae = achadas[0] if achadas else None
    serie_mae, tipo = idx[mae] if mae else (None, None)
    status = ("CANCELADA" if reg["DT_CANCELAMENTO"] else
              "ENTREGUE" if reg["DT_ENTREGA"] else "EM_TRANSITO")
    return dict(
        filial=fil, nf=reg["NF"], serie=reg["SERIE"], emissao=d(reg["EMISSAO"]),
        cliente_cod=reg["CLIENTE_COD"], cliente_loja=reg["CLIENTE_LOJA"],
        cliente_nome=reg["CLIENTE_NOME"] or None, uf=reg["UF"] or None,
        itens=reg["ITENS"], quantidade=num(reg["QUANTIDADE"]),
        valor_mercadoria=num(reg["VALOR_MERCADORIA"]),
        transportadora=reg["TRANSPORTADORA"] or None,
        dt_entrega=d(reg["DT_ENTREGA"]), dt_prevista=d(reg["DT_PREVISTA"]),
        dt_cancelamento=d(reg["DT_CANCELAMENTO"]), status=status,
        filial_mae=mae[0] if mae else None, nf_mae=mae[1] if mae else None, serie_mae=serie_mae,
        vinculo=vinc, mae_tipo=tipo,
        # outras NF-mãe citadas na MESMA remessa ("REF AS NF'S 254954 E 254946"): a remessa atende
        # todas e o valor é rateado entre elas (aplica_entrega_venda_ordem e a tela fazem igual)
        outras_maes=",".join(k[1] for k in achadas[1:]
                             if tipo != "VENDA_ORDEM" or idx[k][1] == "VENDA_ORDEM") or None,
        texto_vinculo=(texto or "")[:250] or None,
        updated_at=dt.datetime.now(dt.timezone.utc).isoformat(),
    )


def faixa_de(dias):
    """Mesma régua do 01_nf_saida.sql (FAIXA_ENTREGA)."""
    return "0-2" if dias <= 2 else "3-7" if dias <= 7 else "8-15" if dias <= 15 else ">15"


def remessas_por_mae(nfs, vos):
    """{(filial, nf, série) da mãe: [remessas]}; cada remessa leva `_valor` = a parte dela que
    cabe àquela mãe. Remessa que cita VÁRIAS mães de venda à ordem (vínculo N:1, ~20 casos desde
    jan/25) é rateada pelo valor faturado de cada mãe — sem isso a 1ª ficava "remessada a maior"
    e as outras "sem remessa". Mesma conta da tela (montaVo em sem-entrega.html)."""
    vf = {(n["filial"], n["nf"]): (n["serie"], n["valor_faturado"] or 0.0)
          for n in nfs if n["venda_ordem"] and n["status"] != "CANCELADA"}
    out = {}
    for v in vos:
        if v["status"] == "CANCELADA" or v["vinculo"] == "SEM" or v["mae_tipo"] != "VENDA_ORDEM":
            continue
        cit = [v["nf_mae"]] + [x for x in (v["outras_maes"] or "").split(",") if x]
        maes = [(v["filial_mae"], x) for x in dict.fromkeys(cit) if (v["filial_mae"], x) in vf]
        if not maes:
            continue
        soma = sum(vf[k][1] for k in maes)
        for k in maes:
            parte = (v["valor_mercadoria"] or 0.0) * (vf[k][1] / soma if soma else 1.0 / len(maes))
            out.setdefault((k[0], k[1], vf[k][0]), []).append({**v, "_valor": parte})
    return out


def aplica_entrega_venda_ordem(nfs, vos, hoje=None):
    """NF-mãe de venda à ordem — ordem da data de entrega (regra do Silvio, 23/09/2026):
      1º REMESSAS: Σ das remessas (não canceladas, vinculadas a ela; rateadas quando a remessa
         cita várias mães) cobre o valor TOTAL da mãe (com IPI), tolerância max(R$ 1; 0,5%), e
         TODAS têm data no GFE → a mãe fica com a data da ÚLTIMA remessa (origem 'REMESSA').
      2º na falta disso, a data que a query já trouxe para a própria mãe, na ordem de sempre:
         Financeiro (E1_DTSAIDA) → GFE → título QUITADO (1ª baixa). "Se o FIN marcou data, usamos
         como última opção" e "se a mãe já foi paga, está OK — não faz sentido o cliente pagar
         sem ter recebido as remessas". A origem continua FIN/GFE/BAIXA.
      3º sem nada disso → pendente (origem 'REMESSA_PENDENTE'), com dias/faixa pela mesma régua
         da query — "Notas emitidas" e "Sem entrega" continuam dizendo a mesma coisa.
    O boleto não entra aqui: o Financeiro tem controle próprio."""
    hoje = hoje or dt.date.today()
    rem = remessas_por_mae(nfs, vos)
    cont = {"remessa": 0, "fin_gfe_baixa": 0, "pendente": 0}
    for n in nfs:
        if not n["venda_ordem"] or n["status"] == "CANCELADA":
            continue
        rs = rem.get((n["filial"], n["nf"], n["serie"]), [])
        base = n["valor_faturado"] or 0.0
        tot = sum(r["_valor"] for r in rs)
        completa = bool(rs) and tot >= base - max(1.0, base * 0.005)
        if completa and all(r["dt_entrega"] for r in rs):
            n["dt_entrega"] = max(r["dt_entrega"] for r in rs)
            n["dt_entrega_origem"] = "REMESSA"
            n["status"], n["dias_sem_entrega"], n["faixa_entrega"] = "ENTREGUE", None, None
            cont["remessa"] += 1
        elif n["dt_entrega"]:
            cont["fin_gfe_baixa"] += 1              # mantém a data e a origem da query
        else:
            dias = (hoje - dt.date.fromisoformat(n["emissao"])).days
            n["dt_entrega_origem"] = "REMESSA_PENDENTE"
            n["status"], n["dias_sem_entrega"], n["faixa_entrega"] = "EM_TRANSITO", dias, faixa_de(dias)
            cont["pendente"] += 1
    return cont


def confere_coerencia(nfs):
    """As telas "Notas emitidas" e "Sem entrega" TÊM de chegar à mesma conclusão sobre cada nota
    (pedido do Silvio, 23/09/2026). Por construção, na query, status/faixa/dias derivam da MESMA
    data de entrega; aqui se garante que o pós-processo não quebrou isso.
    Regra: fora as canceladas, 'não entregue' <=> sem data <=> tem faixa <=> está na fila."""
    quebras = []
    for n in nfs:
        if n["status"] == "CANCELADA":
            continue
        sem_data = n["dt_entrega"] is None
        na_fila = n["faixa_entrega"] is not None
        nao_entregue = n["status"] == "EM_TRANSITO"
        if not (sem_data == na_fila == nao_entregue):
            quebras.append((n["filial"], n["nf"], n["serie"], n["status"], n["dt_entrega"], n["faixa_entrega"]))
    return quebras


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
    devolvido, ncc_aberta = {}, {}
    for v in devs:
        if v["nf_origem"]:
            k = (v["filial"], v["nf_origem"], v["serie_origem"] or "")
            devolvido[k] = devolvido.get(k, 0.0) + (v["valor"] or 0.0)
            # saldo da NCC = o que o Financeiro ainda não compensou contra o título da venda
            ncc_aberta[k] = ncc_aberta.get(k, 0.0) + max(v.get("ncc_saldo") or 0.0, 0.0)

    marcadas = {"DEVOLVIDA_TOTAL": 0, "DEVOLVIDA_PARCIAL": 0}
    for n in nfs:
        # atraso: realizado - previsto (só quando há as duas datas)
        if n["dt_entrega"] and n["dt_prevista"]:
            a = dt.date.fromisoformat(n["dt_entrega"])
            p = dt.date.fromisoformat(n["dt_prevista"])
            n["atraso_dias"] = (a - p).days

        chave = (n["filial"], n["nf"], n["serie"])
        val_dev = devolvido.get(chave, 0.0)
        n["valor_devolvido"] = round(val_dev, 2) if val_dev else None
        n["devolucao_em_aberto"] = round(ncc_aberta.get(chave, 0.0), 2) if val_dev else None
        if n["status"] == "CANCELADA":
            continue
        # ⚠️ COERÊNCIA (23/09/2026): só vira DEVOLVIDA a nota que foi ENTREGUE. Nota sem data de
        # entrega continua EM_TRANSITO — senão "Notas emitidas" diria "Devolvida" e "Sem entrega"
        # diria "pendente" para a mesma nota. A devolução dela aparece na coluna "Devolução em
        # aberto" da fila, que é onde o Silvio quer ver.
        if val_dev > 0 and n["dt_entrega"]:
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
    ap.add_argument("--desde", default=DESDE_PADRAO, help="início fixo da janela AAAAMMDD (padrão 20250101)")
    ap.add_argument("--dias", type=int, help="alternativa: janela móvel de N dias (substitui --desde)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--tentativas", type=int, default=3,
                    help="máximo de tentativas quando a conexão falha (padrão 3)")
    ap.add_argument("--espera-min", type=float, default=5,
                    help="minutos entre uma tentativa e a próxima (padrão 5)")
    ap.add_argument("--limite-min", type=float, default=10,
                    help="teto de cada tentativa de extração, no relógio de parede (padrão 10)")
    ap.add_argument("--ate", metavar="HH:MM",
                    help="insiste até este horário de hoje, sem teto de tentativas (rodada final)")
    args = ap.parse_args()

    inicio_rodada = time.time()
    de, ate = janela(args.dias, None if args.dias else args.desde)
    log(f"janela {de} a {ate}" + (f" ({args.dias} dias)" if args.dias else " (início fixo)"))
    prazo_final = None
    if args.ate:
        h, m = map(int, args.ate.split(":"))
        prazo_final = dt.datetime.now().replace(hour=h, minute=m, second=0, microsecond=0).timestamp()

    segura_mac_acordado()
    chave = None if args.dry_run else chave_service()
    if not args.dry_run:
        trava = trava_execucao(prazo_final or time.time() + 15 * 60)   # aberta até o fim do main
        if trava is None:
            log("outra carga do painel ainda em andamento — esta rodada não faz nada.")
            return 2

    # 1+2. VPN e extração (somente leitura). Sem conexão → espera e tenta de novo; o painel
    # segue com o retrato anterior enquanto isso.
    n = 0
    while True:
        n += 1
        inicio = dt.datetime.now(dt.timezone.utc)      # started_at = início da tentativa que valeu
        if vpn_ok():
            situacao, info = tentativa_extracao(de, ate, int(args.limite_min * 60))
        else:
            situacao, info = "conexao", "VPN OFF"
        if situacao == "ok":
            break
        if situacao == "erro":
            log(f"ERRO na extração: {info} — nada gravado.")
            return 1
        proxima = time.time() + args.espera_min * 60
        insiste = proxima <= prazo_final if prazo_final else n < args.tentativas
        if not insiste:
            retrato = ultimo_retrato_ok(chave) if chave else None
            log(f"SEM CONEXÃO ({info}) — {n} tentativa(s); nada extraído, nada gravado. "
                f"O painel segue com o retrato anterior" + (f" ({retrato})" if retrato else "")
                + "; a próxima rodada tenta de novo.")
            return 2
        log(f"sem conexão ({info}) — tentativa {n}; nova tentativa às "
            f"{dt.datetime.fromtimestamp(proxima):%H:%M}")
        espera_ate(proxima)
    if n > 1:
        log(f"extração ok na tentativa {n}")

    try:
        nf_bruto, dev_bruto, vl_bruto, vo_bruto, vor_bruto = info
        nfs  = [monta_nf(r) for r in nf_bruto]
        devs = [monta_dev(r) for r in dev_bruto]
        vls  = [monta_vl(r) for r in vl_bruto]
        idx  = indice_referencia(vor_bruto)
        vos  = [monta_vo(r, idx) for r in vo_bruto]
    except Exception as e:
        log(f"ERRO na extração: {e} — nada gravado.")
        return 1

    # 3. Pós-processo — venda à ordem ANTES da devolução (DEVOLVIDA depende de haver entrega)
    cvo = aplica_entrega_venda_ordem(nfs, vos)
    log(f"venda à ordem — data da NF-mãe: {cvo['remessa']} pela última remessa, "
        f"{cvo['fin_gfe_baixa']} pelo Financeiro/GFE/título quitado, {cvo['pendente']} pendentes")
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

    # trava: "Notas emitidas" e "Sem entrega" têm de chegar à MESMA conclusão sobre cada nota
    quebras = confere_coerencia(nfs)
    if quebras:
        log(f"ERRO de coerência status × fila: {len(quebras)} NF com status e faixa discordando "
            f"(ex.: {quebras[:3]}) — nada gravado.")
        return 1
    log("coerência status × fila: OK (não entregue ⇔ sem data ⇔ na fila, nota a nota)")

    from collections import Counter as _C
    cv = _C(v["vinculo"] for v in vos if v["status"] != "CANCELADA")
    log(f"venda à ordem: {len(vos)} remessas · vínculo XDOCREF {cv['XDOCREF']} · texto {cv['TEXTO']} · "
        f"sem vínculo {cv['SEM']} · {sum(1 for v in vos if not v['dt_entrega'])} sem data de entrega")

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
        n4 = upsert("dash_vo_remessa", vos, chave, "filial,nf,serie")
        # varredura de órfãs: o que sumiu da origem (nota cancelada) tem de sair do cache
        for tab, dados, cps, cdata in [
                ("dash_nf_saida",    nfs, ["filial","nf","serie"],                                      "emissao"),
                ("dash_devolucao",   devs,["filial","nf_dev","serie_dev","cliente_cod","cliente_loja"], "emissao_dev"),
                ("dash_venda_linha", vls, ["filial","nf","serie","linha"],                              "emissao"),
                ("dash_vo_remessa",  vos, ["filial","nf","serie"],                                      "emissao")]:
            qtd, aviso = remove_orfas(tab, dados, chave, cps, cdata, de, ate)
            if aviso:
                log("ATENÇÃO — " + aviso)
            elif qtd:
                log(f"  {tab}: {qtd} linha(s) removida(s) — sumiram da origem (cancelamento/exclusão)")
    except Exception as e:
        conexao = falha_de_conexao(e)
        log((f"SEM CONEXÃO com o Supabase na carga: {e} — pode ter gravado parte; "
             f"a próxima rodada completa.") if conexao else f"ERRO na carga: {e}")
        grava_log(chave, started_at=inicio.isoformat(),
                  finished_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                  ok=False, rows_nf=0, rows_dev=0,
                  janela_de=d(de), janela_ate=d(ate), erro=str(e)[:500])
        return 2 if conexao else 1

    grava_log(chave, started_at=inicio.isoformat(),
              finished_at=dt.datetime.now(dt.timezone.utc).isoformat(),
              ok=True, rows_nf=n1, rows_dev=n2, janela_de=d(de), janela_ate=d(ate))
    seg = (dt.datetime.now(dt.timezone.utc) - inicio).total_seconds()
    log(f"OK — {n1} NF, {n2} devoluções, {n3} linhas região x linha e {n4} remessas em {seg:.1f}s"
        + (f" (tentativa {n}; {(time.time() - inicio_rodada) / 60:.0f} min desde o início "
           f"da rodada)" if n > 1 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
