-- =====================================================================================
-- Dashboard TV — migração 005 (25/09/2026) · JUSTIFICATIVA LOGÍSTICA
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor.
-- Idempotente: pode rodar de novo sem estragar nada (a lista de motivos é atualizada).
--
-- Pedido da Logística (Silvio 25/09/2026): na fila "Notas sem data de entrega", um campo
-- JUSTIFICATIVA LOGÍSTICA com uma lista (combo) dos principais motivos, para o time informar
-- por que aquela NF ainda está sem data de entrega.
--
-- ⚠️ DIFERENTE do resto do dash: estas tabelas são ESCRITAS PELAS PESSOAS na tela, não pelo
-- ETL. O ETL não as conhece (não estão no MANIFESTO), então a carga horária e a varredura de
-- órfãs NUNCA apagam uma justificativa. A justificativa fica guardada mesmo depois que a nota
-- ganha data de entrega — só deixa de aparecer, porque a nota sai da fila.
-- Nada disso volta para o Protheus (base SOMENTE LEITURA).
-- =====================================================================================

-- 1) Lista de motivos (o combo). Motivo novo = linha nova aqui, sem publicar tela.
create table if not exists dash_justificativa_opcao (
  codigo     text primary key,
  descricao  text not null,
  ordem      int  not null default 100,
  ativo      boolean not null default true,
  pede_complemento boolean not null default false   -- a tela avisa que falta data / nº de chamado / NF
);

insert into dash_justificativa_opcao (codigo, descricao, ordem, pede_complemento) values
  ('EM_ROTA',          'Em rota de entrega para o cliente',                               10, false),
  ('AGENDAMENTO',      'Agendamento confirmado',                                          20, true),
  ('ENTREGUE_BAIXA',   'Entregue — baixa disponível no TOTVS',                            30, false),
  ('FUNCIONARIO_BAIXA','Funcionário — baixa disponível no TOTVS',                         40, false),
  ('NAO_ENVIADA_LOG',  'NF não enviada para a Logística',                                 50, false),
  ('SEM_REMESSA',      'Faturada sem a nota de remessa (aguardando faturamento correto)', 60, false),
  ('REFAT_CANHOTO',    'Refaturamento — aguardando assinatura de canhoto',                70, true),
  ('DEVOLVIDA',        'Devolvida (informar data e nº do chamado)',                       80, true),
  ('AGUARD_DEVOLUCAO', 'Aguardando devolução (Comercial)',                                90, false),
  ('TRATATIVA_COM',    'Tratativa comercial',                                            100, true),
  ('SINISTRO_AVARIA',  'Faturamento contra o transportador (sinistro / avaria)',         110, false),
  ('NF_CANCELADA',     'NF cancelada',                                                   120, false),
  ('OUTROS',           'Outros (descrever no complemento)',                              999, true)
on conflict (codigo) do update
  set descricao = excluded.descricao, ordem = excluded.ordem, pede_complemento = excluded.pede_complemento;

-- 2) A justificativa vigente de cada NF (uma por nota).
create table if not exists dash_justificativa_logistica (
  filial        text not null,
  nf            text not null,
  serie         text not null,
  justificativa text not null references dash_justificativa_opcao (codigo),
  complemento   text,                    -- texto livre: data, nº do chamado, NF de refaturamento…
  usuario       text,                    -- e-mail de quem informou (gravado pelo banco, não pela tela)
  updated_at    timestamptz not null default now(),
  primary key (filial, nf, serie)
);

-- 3) Histórico append-only: toda inclusão, troca ou exclusão fica registrada com quem e quando.
create table if not exists dash_justificativa_hist (
  id            bigint generated always as identity primary key,
  filial        text not null,
  nf            text not null,
  serie         text not null,
  acao          text not null,           -- INCLUIU | ALTEROU | EXCLUIU
  justificativa text,
  complemento   text,
  usuario       text,
  em            timestamptz not null default now()
);
create index if not exists ix_dash_just_hist_nf on dash_justificativa_hist (filial, nf, serie, em);

-- Quem informou = o usuário logado (JWT). A tela não consegue se passar por outra pessoa.
create or replace function dash_justificativa_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento, usuario)
    values (old.filial, old.nf, old.serie, 'EXCLUIU', old.justificativa, old.complemento,
            coalesce(auth.jwt() ->> 'email', old.usuario));
    return old;
  end if;
  new.usuario    := coalesce(auth.jwt() ->> 'email', new.usuario);
  new.updated_at := now();
  insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento, usuario)
  values (new.filial, new.nf, new.serie, case when tg_op = 'INSERT' then 'INCLUIU' else 'ALTEROU' end,
          new.justificativa, new.complemento, new.usuario);
  return new;
end $$;

drop trigger if exists trg_dash_justificativa_carimbo on dash_justificativa_logistica;
create trigger trg_dash_justificativa_carimbo
  before insert or update or delete on dash_justificativa_logistica
  for each row execute function dash_justificativa_carimbo();

-- 4) Acesso. Hoje todo usuário autenticado lê e informa (perfis iguais — decisão Silvio 22/09/2026).
--    Quando houver perfil LOGÍSTICA, trocar as políticas de escrita por uma que filtre o perfil.
alter table dash_justificativa_opcao     enable row level security;
alter table dash_justificativa_logistica enable row level security;
alter table dash_justificativa_hist      enable row level security;

drop policy if exists "dash_just_opcao leitura" on dash_justificativa_opcao;
create policy "dash_just_opcao leitura" on dash_justificativa_opcao for select to authenticated using (true);

drop policy if exists "dash_just leitura"  on dash_justificativa_logistica;
drop policy if exists "dash_just inclui"   on dash_justificativa_logistica;
drop policy if exists "dash_just altera"   on dash_justificativa_logistica;
drop policy if exists "dash_just exclui"   on dash_justificativa_logistica;
create policy "dash_just leitura" on dash_justificativa_logistica for select to authenticated using (true);
create policy "dash_just inclui"  on dash_justificativa_logistica for insert to authenticated with check (true);
create policy "dash_just altera"  on dash_justificativa_logistica for update to authenticated using (true) with check (true);
create policy "dash_just exclui"  on dash_justificativa_logistica for delete to authenticated using (true);

-- histórico: só leitura pela tela; quem escreve é o trigger (security definer)
drop policy if exists "dash_just_hist leitura" on dash_justificativa_hist;
create policy "dash_just_hist leitura" on dash_justificativa_hist for select to authenticated using (true);

grant select on dash_justificativa_opcao to authenticated;
grant select, insert, update, delete on dash_justificativa_logistica to authenticated;
grant select on dash_justificativa_hist to authenticated;
