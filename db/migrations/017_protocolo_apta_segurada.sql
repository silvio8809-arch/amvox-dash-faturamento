-- =====================================================================================
-- Dashboard Fat & LOG — migração 017 (22/10/2026) · nota SEGURADA (erro de emissão) visível no quadro de aptas
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 016. Idempotente.
--
-- Pedido do Silvio (22/10/2026), caso NF 281598 DOMESTILAR: nota de bonificação marcada "ERRO DE EMISSÃO" no app Redes
-- fica fora de qualquer protocolo, mas não aparecia em lugar nenhum da aba — parecia ter sumido. Agora entra no quadro de
-- aptas como SEGURADA (só Controladoria e Faturamento veem; não pode ser selecionada para protocolo — prot_solicitar só
-- aceita APTA). Sai do quadro quando for cancelada no TOTVS.
-- =====================================================================================

do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.prot_apta'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%situacao%'
  loop
    execute format('alter table public.prot_apta drop constraint %I', c);
  end loop;
end $$;
alter table public.prot_apta add constraint prot_apta_situacao_check check (situacao in ('APTA', 'RETIDA', 'SEGURADA'));

-- conferência
select pg_get_constraintdef(oid) as regra_situacao from pg_constraint
 where conrelid = 'public.prot_apta'::regclass and conname = 'prot_apta_situacao_check';
