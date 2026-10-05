-- =====================================================================================
-- Dashboard TV — migração 009 (05/10/2026) · PLANO DE AÇÃO: RESPONSÁVEL PADRÃO = INGRIDE SOARES
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor,
-- DEPOIS da 005–008. Idempotente: pode rodar de novo sem estragar nada.
--
-- Pedido do Silvio (05/10/2026): "cada linha com o campo responsável VAZIO deve ser preenchida com a
-- Ingride — ela é a responsável geral, podendo delegar para outros". Então:
--   1) função dash_plano_resp_padrao() = o nome padrão, num lugar só (a tela usa o mesmo valor);
--   2) default da coluna responsavel = o padrão;
--   3) carimbo (BEFORE): responsável vazio vira o padrão — salvar sem responsável grava a Ingride;
--      delegar = trocar o nome;
--   4) preenche os planos que hoje estão sem responsável. O gatilho de histórico registra cada um como
--      ALTEROU (antes vazio → depois Ingride), com autoria explícita da Controladoria.
-- =====================================================================================

create or replace function dash_plano_resp_padrao() returns text
language sql immutable as $$ select 'Ingride Soares'::text $$;

alter table dash_justificativa_logistica alter column responsavel set default dash_plano_resp_padrao();

-- Carimbo (BEFORE) — igual ao da 008, com o responsável padrão
create or replace function dash_justificativa_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.complemento := nullif(btrim(coalesce(new.complemento, '')), '');
  new.observacoes := nullif(btrim(coalesce(new.observacoes, '')), '');
  new.responsavel := coalesce(nullif(btrim(coalesce(new.responsavel, '')), ''), dash_plano_resp_padrao());
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

-- Preenche os vazios (autoria explícita: no SQL Editor não há usuário logado no JWT)
update dash_justificativa_logistica
   set responsavel = dash_plano_resp_padrao(),
       usuario     = 'gerente.contabil@amvox.com.br'
 where responsavel is null or btrim(responsavel) = '';

-- Conferência: nenhum plano sem responsável; quantos foram preenchidos agora (histórico)
select (select count(*) from dash_justificativa_logistica where responsavel is null or btrim(responsavel) = '') as sem_responsavel_restantes,
       (select count(*) from dash_justificativa_logistica where responsavel = dash_plano_resp_padrao())             as planos_da_ingride,
       (select count(*) from dash_justificativa_hist
         where acao = 'ALTEROU' and responsavel = dash_plano_resp_padrao()
           and coalesce(responsavel_anterior, '') = '' and em > now() - interval '10 minutes')                      as preenchidos_agora;
