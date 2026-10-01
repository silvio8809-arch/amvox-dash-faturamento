-- =====================================================================================
-- Dashboard TV — migração 007 (01/10/2026) · PLANO DE AÇÃO (Justificativa + Observações + Anexos)
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor,
-- DEPOIS da 005 e da 006. Idempotente: pode rodar de novo sem estragar nada.
--
-- Pedido do Silvio (01/10/2026): na fila "Notas sem data de entrega", a seção PLANO DE AÇÃO reúne
--   · Justificativa (combo + complemento — já existia, migração 005);
--   · Observações (texto livre — NOVO);
--   · Anexos / evidências (arquivos — NOVO).
-- Tudo entra no MESMO histórico imutável da 006 (antes × depois, quem, quando).
--
-- Desenho dos anexos:
--   · arquivo no Storage do Supabase, pasta PRIVADA `dash-anexos` (só usuário logado lê; 10 MB por arquivo);
--   · cada arquivo tem uma linha em `dash_plano_anexo` (quem anexou e quando — gravado pelo banco);
--   · "remover" é só marcar como removido (quem/quando): o arquivo e a linha FICAM guardados como
--     evidência. Ninguém apaga nem substitui arquivo — não há política de exclusão/atualização no Storage.
-- Nada disso volta para o Protheus (base SOMENTE LEITURA). O ETL não conhece estas tabelas.
-- =====================================================================================

-- 1) Observações na justificativa vigente; justificativa deixa de ser obrigatória
--    (dá para registrar só uma observação ou só anexos, antes de escolher o motivo).
alter table dash_justificativa_logistica add column if not exists observacoes text;
alter table dash_justificativa_logistica alter column justificativa drop not null;

-- 2) Histórico ganha observações (antes/depois) e o nome do anexo
alter table dash_justificativa_hist add column if not exists observacoes          text;
alter table dash_justificativa_hist add column if not exists observacoes_anterior text;
alter table dash_justificativa_hist add column if not exists anexo                text;

-- 3) Carimbo (BEFORE) e histórico (AFTER) passam a considerar as observações
create or replace function dash_justificativa_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.complemento := nullif(btrim(coalesce(new.complemento, '')), '');
  new.observacoes := nullif(btrim(coalesce(new.observacoes, '')), '');
  if tg_op = 'UPDATE'
     and new.justificativa is not distinct from old.justificativa
     and new.complemento   is not distinct from old.complemento
     and new.observacoes   is not distinct from old.observacoes then
    new.usuario    := old.usuario;
    new.updated_at := old.updated_at;
    return new;
  end if;
  new.usuario    := coalesce(auth.jwt() ->> 'email', new.usuario);
  new.updated_at := now();
  return new;
end $$;

create or replace function dash_justificativa_historico() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento, observacoes,
                                         justificativa_anterior, complemento_anterior, observacoes_anterior, usuario)
    values (new.filial, new.nf, new.serie, 'INCLUIU', new.justificativa, new.complemento, new.observacoes,
            null, null, null, new.usuario);
    return new;
  elsif tg_op = 'UPDATE' then
    if new.justificativa is not distinct from old.justificativa
       and new.complemento is not distinct from old.complemento
       and new.observacoes is not distinct from old.observacoes then
      return new;                                   -- salvou sem mudar nada: não registra
    end if;
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento, observacoes,
                                         justificativa_anterior, complemento_anterior, observacoes_anterior, usuario)
    values (new.filial, new.nf, new.serie, 'ALTEROU', new.justificativa, new.complemento, new.observacoes,
            old.justificativa, old.complemento, old.observacoes, new.usuario);
    return new;
  else
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento, observacoes,
                                         justificativa_anterior, complemento_anterior, observacoes_anterior, usuario)
    values (old.filial, old.nf, old.serie, 'EXCLUIU', null, null, null,
            old.justificativa, old.complemento, old.observacoes,
            coalesce(auth.jwt() ->> 'email', old.usuario));
    return old;
  end if;
end $$;
-- (os gatilhos da 006 já apontam para estas duas funções — não precisam ser recriados)

-- 4) Anexos: uma linha por arquivo
create table if not exists dash_plano_anexo (
  id           bigint generated always as identity primary key,
  filial       text not null,
  nf           text not null,
  serie        text not null,
  caminho      text not null unique,        -- caminho no Storage (bucket dash-anexos)
  nome         text not null,               -- nome original do arquivo
  tamanho      bigint,
  tipo         text,
  usuario      text,                        -- quem anexou (gravado pelo banco)
  criado_em    timestamptz not null default now(),
  removido_em  timestamptz,                 -- "remover" = marcar; o arquivo fica guardado
  removido_por text
);
create index if not exists ix_dash_plano_anexo_nf on dash_plano_anexo (filial, nf, serie);

-- carimbo do anexo: quem/quando pelo banco; a única mudança permitida é marcar como removido, uma vez
create or replace function dash_plano_anexo_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.usuario := coalesce(auth.jwt() ->> 'email', new.usuario);
    new.criado_em := now();
    new.removido_em := null; new.removido_por := null;
    return new;
  end if;
  if old.removido_em is not null then
    raise exception 'anexo já removido — não pode ser alterado';
  end if;
  if (new.filial, new.nf, new.serie, new.caminho, new.nome, new.tamanho, new.tipo, new.usuario, new.criado_em)
     is distinct from (old.filial, old.nf, old.serie, old.caminho, old.nome, old.tamanho, old.tipo, old.usuario, old.criado_em) then
    raise exception 'anexo não pode ser alterado — só marcado como removido';
  end if;
  if new.removido_em is null then
    return old;                                     -- nada a fazer
  end if;
  new.removido_em  := now();
  new.removido_por := coalesce(auth.jwt() ->> 'email', new.removido_por);
  return new;
end $$;

drop trigger if exists trg_dash_plano_anexo_carimbo on dash_plano_anexo;
create trigger trg_dash_plano_anexo_carimbo
  before insert or update on dash_plano_anexo
  for each row execute function dash_plano_anexo_carimbo();

-- anexo entra no MESMO histórico da justificativa
create or replace function dash_plano_anexo_historico() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into dash_justificativa_hist (filial, nf, serie, acao, anexo, usuario)
    values (new.filial, new.nf, new.serie, 'ANEXOU', new.nome, new.usuario);
  elsif old.removido_em is null and new.removido_em is not null then
    insert into dash_justificativa_hist (filial, nf, serie, acao, anexo, usuario)
    values (new.filial, new.nf, new.serie, 'REMOVEU ANEXO', new.nome, new.removido_por);
  end if;
  return new;
end $$;

drop trigger if exists trg_dash_plano_anexo_historico on dash_plano_anexo;
create trigger trg_dash_plano_anexo_historico
  after insert or update on dash_plano_anexo
  for each row execute function dash_plano_anexo_historico();

-- ninguém apaga linha de anexo (nem o acesso administrativo)
create or replace function dash_plano_anexo_sem_exclusao() returns trigger
language plpgsql as $$
begin
  raise exception 'dash_plano_anexo: anexo não pode ser apagado — use "remover" (fica registrado)';
end $$;

drop trigger if exists trg_dash_plano_anexo_sem_delete on dash_plano_anexo;
create trigger trg_dash_plano_anexo_sem_delete
  before delete on dash_plano_anexo
  for each row execute function dash_plano_anexo_sem_exclusao();

drop trigger if exists trg_dash_plano_anexo_sem_truncate on dash_plano_anexo;
create trigger trg_dash_plano_anexo_sem_truncate
  before truncate on dash_plano_anexo
  for each statement execute function dash_plano_anexo_sem_exclusao();

alter table dash_plano_anexo enable row level security;
drop policy if exists "dash_anexo leitura" on dash_plano_anexo;
drop policy if exists "dash_anexo inclui"  on dash_plano_anexo;
drop policy if exists "dash_anexo remove"  on dash_plano_anexo;
create policy "dash_anexo leitura" on dash_plano_anexo for select to authenticated using (true);
create policy "dash_anexo inclui"  on dash_plano_anexo for insert to authenticated with check (true);
create policy "dash_anexo remove"  on dash_plano_anexo for update to authenticated using (removido_em is null) with check (true);

revoke all on dash_plano_anexo from anon;
grant select, insert on dash_plano_anexo to authenticated;
grant update (removido_em) on dash_plano_anexo to authenticated;
revoke delete, truncate on dash_plano_anexo from authenticated, service_role;

-- 5) Pasta PRIVADA de arquivos (Storage). 10 MB por arquivo; tipos de documento e imagem.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dash-anexos', 'dash-anexos', false, 10485760, array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/gif',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/msword',
  'text/plain', 'text/csv', 'message/rfc822', 'application/vnd.ms-outlook'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- usuário logado lê e envia; NÃO há política de update/delete → ninguém substitui nem apaga arquivo pela tela
drop policy if exists "dash_anexos leitura" on storage.objects;
drop policy if exists "dash_anexos envio"   on storage.objects;
create policy "dash_anexos leitura" on storage.objects for select to authenticated using (bucket_id = 'dash-anexos');
create policy "dash_anexos envio"   on storage.objects for insert to authenticated with check (bucket_id = 'dash-anexos');
