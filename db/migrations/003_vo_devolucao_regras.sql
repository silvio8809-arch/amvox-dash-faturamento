-- =====================================================================================
-- Dashboard TV — migração 003 (23/09/2026)
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor.
-- Idempotente: pode rodar de novo sem estragar nada.
--
-- O que entra (pedido do Silvio 23/09/2026):
--   1. VENDA À ORDEM: tabela das notas de REMESSA (5923/6923) e a marca de NF-mãe na nota.
--   2. SINISTRO / FUNCIONÁRIOS: coluna regra_especial ('SINISTRO' | 'FUNCIONARIO') — só MARCA
--      a nota para o quadro próprio; a data de entrega continua a real (Silvio 23/09, 2ª versão:
--      "segregamos, mas não omitimos a pendência").
--   Venda à ordem: a NF-mãe passa a ter a data da ÚLTIMA remessa entregue (dt_entrega_origem
--      'REMESSA'); na falta, a da própria mãe (Financeiro → GFE → título quitado); sem nenhuma,
--      'REMESSA_PENDENTE'. Sem coluna nova. (Rodada no SQL Editor em 23/09/2026.)
--   3. DEVOLUÇÃO EM ABERTO: NCC na devolução e o resumo por NF de venda.
-- =====================================================================================

-- ------------------------------------------------------------------ NF de saída
alter table dash_nf_saida add column if not exists venda_ordem         boolean default false;
      -- true = a nota é MÃE de venda à ordem (algum item CFOP 5118/6118/5119/6119)
alter table dash_nf_saida add column if not exists regra_especial      text;
      -- SINISTRO (cliente TRANSFARRAPOS/PATRUS) | FUNCIONARIO (grupo de vendas 000001) | null
alter table dash_nf_saida add column if not exists valor_devolvido     numeric(18,2);
      -- Σ das devoluções cuja origem (D1_NFORI) é esta nota
alter table dash_nf_saida add column if not exists devolucao_em_aberto numeric(18,2);
      -- Σ do SALDO das NCC dessas devoluções = o que o Financeiro ainda não compensou

-- ------------------------------------------------------------------ Devoluções
alter table dash_devolucao add column if not exists ncc_valor numeric(18,2);
alter table dash_devolucao add column if not exists ncc_saldo numeric(18,2);
      -- NCC = crédito que a devolução gera no contas a receber; saldo > 0 = não compensada

-- ------------------------------------------------------------------ Venda à ordem — remessas
create table if not exists dash_vo_remessa (
  filial              text not null,
  nf                  text not null,
  serie               text not null,
  emissao             date not null,
  cliente_cod         text,
  cliente_loja        text,
  cliente_nome        text,              -- DESTINATÁRIO da mercadoria (não é quem paga)
  uf                  text,
  itens               integer,
  quantidade          numeric(18,3),
  valor_mercadoria    numeric(18,2),
  transportadora      text,
  dt_entrega          date,              -- GFE (GWU_DTENT); remessa não gera título
  dt_prevista         date,
  dt_cancelamento     date,
  status              text,              -- ENTREGUE | EM_TRANSITO | CANCELADA
  -- vínculo com a NF-mãe
  filial_mae          text,
  nf_mae              text,
  serie_mae           text,
  vinculo             text,              -- XDOCREF | TEXTO | SEM
  mae_tipo            text,              -- VENDA_ORDEM | BONIFICACAO | VENDA_COMUM | (vazio se SEM)
  outras_maes         text,              -- outras NF-mãe citadas na mesma remessa (~20 desde jan/25): valor rateado
  texto_vinculo       text,              -- o texto de onde o número saiu (prova)
  updated_at          timestamptz not null default now(),
  primary key (filial, nf, serie)
);
create index if not exists ix_dash_vo_mae     on dash_vo_remessa (filial_mae, nf_mae, serie_mae);
create index if not exists ix_dash_vo_emissao on dash_vo_remessa (emissao desc);

alter table dash_vo_remessa enable row level security;
drop policy if exists "dash_vo_remessa leitura autenticada" on dash_vo_remessa;
create policy "dash_vo_remessa leitura autenticada"
  on dash_vo_remessa for select to authenticated using (true);
