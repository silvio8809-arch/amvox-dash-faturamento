# -*- coding: utf-8 -*-
"""Executor SOMENTE-LEITURA das queries da Fase 0 (SPEC.md secao 3).
Bloqueia qualquer verbo de escrita antes de enviar ao banco."""
import sys, re, pymssql

PROIBIDO = re.compile(r'\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|CREATE|ALTER|DROP|EXEC|GRANT|INTO\s+\w+\s+FROM)\b', re.I)

def _env():
    """Credenciais vêm do .env da raiz (nunca do código). Variáveis de ambiente têm precedência."""
    import os
    from pathlib import Path
    cfg, arq = {}, Path(__file__).resolve().parent.parent / '.env'
    if arq.exists():
        for l in arq.read_text(encoding='utf-8').splitlines():
            l = l.strip()
            if l and not l.startswith('#') and '=' in l:
                k, v = l.split('=', 1); cfg[k.strip()] = v.strip()
    cfg.update({k: v for k, v in os.environ.items() if k.startswith('PROTHEUS_') and v})
    falta = [k for k in ('PROTHEUS_SERVER','PROTHEUS_USER','PROTHEUS_PASSWORD','PROTHEUS_DATABASE')
             if not cfg.get(k)]
    if falta:
        raise SystemExit(f"Faltam credenciais no .env: {', '.join(falta)} (veja .env.exemplo)")
    return cfg


def conecta():
    c = _env()
    return pymssql.connect(server=c['PROTHEUS_SERVER'], port=int(c.get('PROTHEUS_PORT', 1521)),
                           user=c['PROTHEUS_USER'], password=c['PROTHEUS_PASSWORD'],
                           database=c['PROTHEUS_DATABASE'], login_timeout=30, timeout=600)

def roda(sql, titulo=None, limite=60):
    if PROIBIDO.search(sql):
        raise SystemExit('BLOQUEADO: a query contem verbo de escrita. Protheus e somente leitura.')
    conn = conecta(); cur = conn.cursor()
    cur.execute(sql)
    out = []
    while True:
        if cur.description:
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
            out.append((cols, rows))
        if not cur.nextset(): break
    conn.close()
    if titulo: print('='*100); print(titulo); print('='*100)
    for cols, rows in out:
        if not rows: print('(sem linhas)'); continue
        larg = [max(len(str(c)), *(len(str(r[i])) for r in rows[:limite])) for i, c in enumerate(cols)]
        larg = [min(w, 52) for w in larg]
        print(' | '.join(str(c)[:w].ljust(w) for c, w in zip(cols, larg)))
        print('-+-'.join('-'*w for w in larg))
        for r in rows[:limite]:
            print(' | '.join(str('' if v is None else v).strip()[:w].ljust(w) for v, w in zip(r, larg)))
        if len(rows) > limite: print(f'... ({len(rows)} linhas no total)')
        print(f'[{len(rows)} linha(s)]')
    return out

if __name__ == '__main__':
    arq = sys.argv[1]
    roda(open(arq, encoding='utf-8').read(), titulo=arq)
