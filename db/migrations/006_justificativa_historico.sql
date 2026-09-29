-- =====================================================================================
-- Dashboard TV — migração 006 (29/09/2026) · HISTÓRICO DA JUSTIFICATIVA LOGÍSTICA
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor,
-- DEPOIS da 005. Idempotente: pode rodar de novo sem estragar nada.
--
-- Aprovado pelo Silvio em 29/09/2026 ("aprovado, rode"): log de alteração com ANTES e DEPOIS.
--   1) cada linha do histórico passa a trazer o conteúdo ANTERIOR ao lado do NOVO;
--   2) salvar sem mudar nada NÃO gera linha (nem muda quem/quando da justificativa vigente);
--   3) o histórico fica IMUTÁVEL — ninguém altera nem apaga, nem pelo acesso administrativo.
--
-- ⚠️ Correção de um defeito da 005: a tela grava por UPSERT (insert ... on conflict do update).
-- No Postgres, o gatilho BEFORE INSERT dispara mesmo quando o insert vira update — então cada
-- troca de justificativa gravaria um "INCLUIU" falso antes do "ALTEROU". Aqui o histórico passa
-- para gatilhos AFTER, que só disparam para o que de fato aconteceu. O BEFORE fica só com o
-- carimbo (quem/quando). Em 29/09 o histórico tinha 1 linha (INCLUIU), sem nenhum registro falso.
-- =====================================================================================

-- 1) Colunas do ANTES
alter table dash_justificativa_hist add column if not exists justificativa_anterior text;
alter table dash_justificativa_hist add column if not exists complemento_anterior   text;

-- 2) Carimbo (BEFORE): quem/quando = usuário logado (JWT); complemento vazio vira nulo.
--    Salvar sem mudança mantém o carimbo anterior (não "rouba" a autoria).
create or replace function dash_justificativa_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.complemento := nullif(btrim(coalesce(new.complemento, '')), '');
  if tg_op = 'UPDATE'
     and new.justificativa is not distinct from old.justificativa
     and new.complemento   is not distinct from old.complemento then
    new.usuario    := old.usuario;
    new.updated_at := old.updated_at;
    return new;
  end if;
  new.usuario    := coalesce(auth.jwt() ->> 'email', new.usuario);
  new.updated_at := now();
  return new;
end $$;

-- 3) Histórico (AFTER): uma linha por mudança real, com ANTES e DEPOIS.
create or replace function dash_justificativa_historico() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento,
                                         justificativa_anterior, complemento_anterior, usuario)
    values (new.filial, new.nf, new.serie, 'INCLUIU', new.justificativa, new.complemento, null, null, new.usuario);
    return new;
  elsif tg_op = 'UPDATE' then
    if new.justificativa is not distinct from old.justificativa
       and new.complemento is not distinct from old.complemento then
      return new;                                   -- salvou sem mudar nada: não registra
    end if;
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento,
                                         justificativa_anterior, complemento_anterior, usuario)
    values (new.filial, new.nf, new.serie, 'ALTEROU', new.justificativa, new.complemento,
            old.justificativa, old.complemento, new.usuario);
    return new;
  else
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento,
                                         justificativa_anterior, complemento_anterior, usuario)
    values (old.filial, old.nf, old.serie, 'EXCLUIU', null, null, old.justificativa, old.complemento,
            coalesce(auth.jwt() ->> 'email', old.usuario));
    return old;
  end if;
end $$;

drop trigger if exists trg_dash_justificativa_carimbo on dash_justificativa_logistica;
create trigger trg_dash_justificativa_carimbo
  before insert or update on dash_justificativa_logistica
  for each row execute function dash_justificativa_carimbo();

drop trigger if exists trg_dash_justificativa_historico on dash_justificativa_logistica;
create trigger trg_dash_justificativa_historico
  after insert or update or delete on dash_justificativa_logistica
  for each row execute function dash_justificativa_historico();

-- 4) Histórico IMUTÁVEL: bloqueia alteração, exclusão e truncate para qualquer papel
--    (gatilho vale também para o acesso administrativo / service_role).
create or replace function dash_justificativa_hist_imutavel() returns trigger
language plpgsql as $$
begin
  raise exception 'dash_justificativa_hist é somente-inclusão: histórico não pode ser alterado nem apagado';
end $$;

drop trigger if exists trg_dash_just_hist_imutavel on dash_justificativa_hist;
create trigger trg_dash_just_hist_imutavel
  before update or delete on dash_justificativa_hist
  for each row execute function dash_justificativa_hist_imutavel();

drop trigger if exists trg_dash_just_hist_sem_truncate on dash_justificativa_hist;
create trigger trg_dash_just_hist_sem_truncate
  before truncate on dash_justificativa_hist
  for each statement execute function dash_justificativa_hist_imutavel();

revoke update, delete, truncate on dash_justificativa_hist from anon, authenticated, service_role;
