-- =====================================================================================
-- Dashboard TV Faturamento & Logística — cache no Supabase
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep) — projeto ÚNICO, padronizado
-- por decisão do Silvio (21/09/2026). Prefixo dash_ para não colidir com as tabelas do
-- app de preços (profiles, config_links, config_parametros, usuarios).
--
-- Rodar UMA vez no SQL Editor do Supabase. Idempotente (IF NOT EXISTS).
-- =====================================================================================

-- ---------------------------------------------------------------- NF de saída (faturamento)
create table if not exists dash_nf_saida (
  filial              text not null,
  nf                  text not null,
  serie               text not null,
  emissao             date not null,
  cliente_cod         text,
  cliente_loja        text,
  cliente_nome        text,
  cnpj_raiz           text,
  uf                  text,
  a1_tipo             text,          -- F/R — candidato a canal B2C/B2B (regra a confirmar)
  transportadora      text,
  cfop                text,
  valor_faturado      numeric(18,2),
  valor_mercadoria    numeric(18,2),
  valor_ipi           numeric(18,2),
  -- entrega: Financeiro (SE1.E1_DTSAIDA) primeiro, GFE (GWU.GWU_DTENT) como fallback
  dt_entrega          date,
  dt_entrega_origem   text,          -- FIN | GFE | SEM
  dt_prevista         date,          -- GWU_DTPENT  (previsto × realizado)
  dt_prevista_orig    date,          -- GWU_DTPENO
  -- cobrança: entrega em branco = boleto não gerado = risco de caixa
  vlr_titulos         numeric(18,2),
  saldo_aberto        numeric(18,2),
  vencimento_real     date,
  dt_cancelamento     date,          -- SF3.F3_DTCANC (nunca por D_E_L_E_T_)
  status              text,          -- CANCELADA | ENTREGUE | EM_TRANSITO
                                     -- (+ DEVOLVIDA_PARCIAL / DEVOLVIDA_TOTAL no pós-processo)
  dias_sem_entrega    integer,
  faixa_entrega       text,          -- 0-2 | 3-7 | 8-15 | >15
  atraso_dias         integer,       -- dt_entrega - dt_prevista (negativo = adiantado)
  updated_at          timestamptz not null default now(),
  primary key (filial, nf, serie)
);

create index if not exists ix_dash_nf_emissao  on dash_nf_saida (emissao desc);
create index if not exists ix_dash_nf_status   on dash_nf_saida (status);
create index if not exists ix_dash_nf_faixa    on dash_nf_saida (faixa_entrega) where faixa_entrega is not null;
create index if not exists ix_dash_nf_cliente  on dash_nf_saida (cnpj_raiz);

-- ---------------------------------------------------------------- Devoluções (todas)
create table if not exists dash_devolucao (
  filial              text not null,
  nf_dev              text not null,
  serie_dev           text not null,
  emissao_dev         date not null,
  origem_nf           text,          -- AMVOX (F1_FORMUL='S') | CLIENTE — atributo, não filtro
  cliente_cod         text,
  cliente_loja        text,
  cliente_nome        text,
  cnpj_raiz           text,
  uf                  text,
  cfop                text,
  nf_origem           text,
  serie_origem        text,
  emissao_origem      date,
  qtd_itens           integer,
  valor               numeric(18,2),
  tem_motivo          boolean,
  texto_nf            text,          -- F1_MENNOTA bruto (prova)
  motivo_causa        text,          -- causa extraída do texto — SEM taxonomia fixa
                                     -- (decisão Silvio: listar o que está na base)
  updated_at          timestamptz not null default now(),
  primary key (filial, nf_dev, serie_dev)
);

create index if not exists ix_dash_dev_emissao on dash_devolucao (emissao_dev desc);
create index if not exists ix_dash_dev_origem  on dash_devolucao (origem_nf);
create index if not exists ix_dash_dev_causa   on dash_devolucao (motivo_causa);
create index if not exists ix_dash_dev_nforig  on dash_devolucao (filial, nf_origem, serie_origem);

-- ---------------------------------------------------------------- Log do refresh
create table if not exists dash_refresh_log (
  id            bigserial primary key,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  ok            boolean,
  rows_nf       integer,
  rows_dev      integer,
  janela_de     date,
  janela_ate    date,
  erro          text
);

create index if not exists ix_dash_log_started on dash_refresh_log (started_at desc);

-- ---------------------------------------------------------------- RLS
-- Mesmo padrão do app de preços: leitura só para usuário autenticado; escrita só pela
-- service key do ETL (que ignora RLS). A TV lê pelo app, que exige login.
alter table dash_nf_saida    enable row level security;
alter table dash_devolucao   enable row level security;
alter table dash_refresh_log enable row level security;

drop policy if exists le_autenticado on dash_nf_saida;
create policy le_autenticado on dash_nf_saida
  for select to authenticated using (true);

drop policy if exists le_autenticado on dash_devolucao;
create policy le_autenticado on dash_devolucao
  for select to authenticated using (true);

drop policy if exists le_autenticado on dash_refresh_log;
create policy le_autenticado on dash_refresh_log
  for select to authenticated using (true);

-- =====================================================================================
-- NÃO criado de propósito (decisão Silvio 21/09):
--   · dash_motivo_padrao        — sem taxonomia fixa; o motivo vem do ERP em ~99% dos casos
--                                 e a lista é o que está na base (motivo_causa).
--   · dash_devolucao_classif    — classificação manual/planilha do "Plano B". Com 99,4% de
--                                 cobertura na janela de 120 dias, a fila residual é de ~6 NF.
--                                 Criar só se o volume justificar.
-- =====================================================================================
