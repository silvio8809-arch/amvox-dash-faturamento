-- =====================================================================================
-- Dashboard TV — migração 004 (23/09/2026) · AUDITORIA
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor.
-- Idempotente: pode rodar de novo sem estragar nada.
--
-- Pedido do Silvio 23/09/2026: card de auditoria com dois subgrupos — AUDITORIA LOG e
-- AUDITORIA FAT — para, no futuro, controlar o acesso por perfil. Esta é a 1ª auditoria
-- (venda à ordem: remessa × NF-mãe); outras virão e usam a MESMA tabela.
--
-- Uma linha = uma OCORRÊNCIA de um teste. O ETL grava o retrato inteiro a cada rodada
-- (coluna `rodada`) e apaga o que não reapareceu — ocorrência resolvida some sozinha.
-- =====================================================================================

create table if not exists dash_auditoria (
  grupo           text not null,          -- LOG | FAT  (perfil de acesso futuro)
  auditoria       text not null,          -- ex.: VO_REMESSA_X_MAE
  teste           text not null,          -- ex.: VALOR_MAIOR | PRODUTO_DISTINTO | QTD_MAIOR
  chave           text not null,          -- identifica a ocorrência (ex.: filial|NF-mãe(s))
  severidade      text,                   -- ALTA | MEDIA | BAIXA
  filial          text,
  documento       text,                   -- documento principal (ex.: NF-mãe; várias = "a, b")
  documentos_ref  text,                   -- documentos relacionados (ex.: remessas)
  emissao         date,                   -- emissão do documento principal
  cliente_nome    text,
  uf              text,
  valor_base      numeric(18,2),          -- o que deveria ser (ex.: Σ NF-mãe, com IPI)
  valor_comparado numeric(18,2),          -- o que aconteceu (ex.: Σ remessas)
  diferenca       numeric(18,2),          -- comparado − base
  descricao       text,                   -- a frase que a tela mostra
  detalhe         jsonb,                  -- a prova (ex.: produto a produto)
  rodada          timestamptz not null,   -- início da carga que gravou a linha
  updated_at      timestamptz not null default now(),
  primary key (auditoria, teste, chave)
);
create index if not exists ix_dash_aud_grupo on dash_auditoria (grupo, auditoria, teste);

alter table dash_auditoria enable row level security;
-- Hoje todo usuário autenticado lê os dois grupos (perfis iguais — decisão Silvio 22/09/2026).
-- Quando houver perfis, trocar esta política por uma que filtre `grupo` pelo perfil do usuário.
drop policy if exists "dash_auditoria leitura autenticada" on dash_auditoria;
create policy "dash_auditoria leitura autenticada"
  on dash_auditoria for select to authenticated using (true);
