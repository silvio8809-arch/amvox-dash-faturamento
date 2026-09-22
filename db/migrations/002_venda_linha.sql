-- =====================================================================================
-- Dashboard TV — VENDA POR REGIÃO × LINHA (migração 002, 22/09/2026)
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep) — projeto ÚNICO.
-- Rodar UMA vez no SQL Editor do Supabase. Idempotente (IF NOT EXISTS).
--
-- ⚠️ Grão: UMA LINHA POR NF × LINHA DE PRODUTO — não por nota.
--    dash_nf_saida tem grão de NOTA; a linha de produto vem do ITEM. Das 1.876 NF da
--    janela de 120 dias, 424 têm mais de uma linha na mesma nota. Somar esta tabela
--    por NF DUPLICA nota — para contar notas use COUNT(DISTINCT filial||nf||serie),
--    e para faturamento total use dash_nf_saida.
--
-- Reconciliação (conferida 22/09/2026, janela de 120 dias):
--    SUM(valor_faturado)   = SUM(dash_nf_saida.valor_faturado) = R$ 46.696.390,19  ✓
--    valor_faturado   COM IPI (= D2_VALBRUT = F2_VALFAT)
--    valor_mercadoria SEM IPI (= D2_TOTAL   = F2_VALMERC)
-- =====================================================================================

create table if not exists dash_venda_linha (
  filial              text not null,
  nf                  text not null,
  serie               text not null,
  linha               text not null,      -- AUDIO | LAR | CLIMA | INFORMATICA | VIDEO | ...
                                          -- vem da SBM (BM_DESC); sem taxonomia inventada
  grupo               text,               -- B1_GRUPO (0005 AUDIO, 0002 LAR, 0003 CLIMA...)
  emissao             date not null,
  cliente_cod         text,
  cliente_loja        text,
  cliente_nome        text,
  cnpj_raiz           text,
  uf                  text,
  regiao              text,               -- NORTE | NORDESTE | CENTRO-OESTE | SUDESTE | SUL
                                          -- derivada da UF (IBGE); UF = A1_EST, o mesmo
                                          -- campo do dash_nf_saida (batem em 100% das NF)
  itens               integer,
  quantidade          numeric(18,3),
  valor_faturado      numeric(18,2),      -- com IPI
  valor_mercadoria    numeric(18,2),      -- sem IPI
  status              text,               -- ATIVA | CANCELADA (SF3.F3_DTCANC)
  updated_at          timestamptz not null default now(),
  primary key (filial, nf, serie, linha)
);

create index if not exists ix_dash_vl_emissao on dash_venda_linha (emissao desc);
create index if not exists ix_dash_vl_regiao  on dash_venda_linha (regiao);
create index if not exists ix_dash_vl_linha   on dash_venda_linha (linha);
create index if not exists ix_dash_vl_cliente on dash_venda_linha (cnpj_raiz);

-- ---------------------------------------------------------------- RLS
alter table dash_venda_linha enable row level security;

drop policy if exists "dash_venda_linha leitura autenticada" on dash_venda_linha;
create policy "dash_venda_linha leitura autenticada"
  on dash_venda_linha for select to authenticated using (true);
