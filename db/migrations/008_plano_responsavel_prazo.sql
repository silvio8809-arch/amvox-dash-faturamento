-- =====================================================================================
-- Dashboard TV — migração 008 (01/10/2026) · PLANO DE AÇÃO: RESPONSÁVEL + PRAZO
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor,
-- DEPOIS da 005, 006 e 007. Idempotente: pode rodar de novo sem estragar nada.
--
-- Pedido do Silvio (01/10/2026): na fila "Notas sem data de entrega", o plano de ação ganha
--   · RESPONSÁVEL — nome da pessoa que a Logística indica para realizar a ação (texto livre);
--   · PRAZO — data até a qual essa pessoa deve realizar a ação.
-- Os dois entram no MESMO histórico imutável (antes × depois, quem, quando).
-- =====================================================================================

alter table dash_justificativa_logistica add column if not exists responsavel text;
alter table dash_justificativa_logistica add column if not exists prazo       date;

alter table dash_justificativa_hist add column if not exists responsavel          text;
alter table dash_justificativa_hist add column if not exists responsavel_anterior text;
alter table dash_justificativa_hist add column if not exists prazo                date;
alter table dash_justificativa_hist add column if not exists prazo_anterior       date;

-- Carimbo (BEFORE): quem/quando pelo banco; textos vazios viram nulo; salvar sem mudança mantém o carimbo
create or replace function dash_justificativa_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.complemento := nullif(btrim(coalesce(new.complemento, '')), '');
  new.observacoes := nullif(btrim(coalesce(new.observacoes, '')), '');
  new.responsavel := nullif(btrim(coalesce(new.responsavel, '')), '');
  if tg_op = 'UPDATE'
     and new.justificativa is not distinct from old.justificativa
     and new.complemento   is not distinct from old.complemento
     and new.observacoes   is not distinct from old.observacoes
     and new.responsavel   is not distinct from old.responsavel
     and new.prazo         is not distinct from old.prazo then
    new.usuario    := old.usuario;
    new.updated_at := old.updated_at;
    return new;
  end if;
  new.usuario    := coalesce(auth.jwt() ->> 'email', new.usuario);
  new.updated_at := now();
  return new;
end $$;

-- Histórico (AFTER): uma linha por mudança real, com ANTES e DEPOIS de todos os campos do plano
create or replace function dash_justificativa_historico() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento, observacoes, responsavel, prazo,
                                         justificativa_anterior, complemento_anterior, observacoes_anterior,
                                         responsavel_anterior, prazo_anterior, usuario)
    values (new.filial, new.nf, new.serie, 'INCLUIU', new.justificativa, new.complemento, new.observacoes, new.responsavel, new.prazo,
            null, null, null, null, null, new.usuario);
    return new;
  elsif tg_op = 'UPDATE' then
    if new.justificativa is not distinct from old.justificativa
       and new.complemento is not distinct from old.complemento
       and new.observacoes is not distinct from old.observacoes
       and new.responsavel is not distinct from old.responsavel
       and new.prazo       is not distinct from old.prazo then
      return new;                                   -- salvou sem mudar nada: não registra
    end if;
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento, observacoes, responsavel, prazo,
                                         justificativa_anterior, complemento_anterior, observacoes_anterior,
                                         responsavel_anterior, prazo_anterior, usuario)
    values (new.filial, new.nf, new.serie, 'ALTEROU', new.justificativa, new.complemento, new.observacoes, new.responsavel, new.prazo,
            old.justificativa, old.complemento, old.observacoes, old.responsavel, old.prazo, new.usuario);
    return new;
  else
    insert into dash_justificativa_hist (filial, nf, serie, acao, justificativa, complemento, observacoes, responsavel, prazo,
                                         justificativa_anterior, complemento_anterior, observacoes_anterior,
                                         responsavel_anterior, prazo_anterior, usuario)
    values (old.filial, old.nf, old.serie, 'EXCLUIU', null, null, null, null, null,
            old.justificativa, old.complemento, old.observacoes, old.responsavel, old.prazo,
            coalesce(auth.jwt() ->> 'email', old.usuario));
    return old;
  end if;
end $$;
-- (os gatilhos da 006 já apontam para estas duas funções — não precisam ser recriados)
