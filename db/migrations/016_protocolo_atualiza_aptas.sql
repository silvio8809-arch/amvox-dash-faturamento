-- =====================================================================================
-- Dashboard Fat & LOG — migração 016 (20/10/2026) · botão "Atualizar aptas agora" (aba Protocolos)
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 015. Idempotente.
--
-- Pedido do Silvio (20/10/2026): o quadro de notas aptas é atualizado a cada carga do dash (de hora em hora); nota
-- autorizada logo depois só aparecia na carga seguinte. O botão grava um pedido aqui; a rotina do Mac (rodada da fila de
-- complementares, a cada 30 min nos dias úteis 09h–17h) atende primeiro o pedido e relê as aptas no Protheus.
-- Só Controladoria e Faturamento (prot_e_emissor) pedem e veem; um pedido pendente por vez (clicar de novo não duplica).
-- =====================================================================================

create table if not exists public.prot_aptas_pedido (
  id bigint generated always as identity primary key,
  pedido_por text, pedido_em timestamptz not null default now(),
  status text not null default 'PENDENTE' check (status in ('PENDENTE', 'RODANDO', 'OK', 'ERRO')),
  iniciado_em timestamptz, concluido_em timestamptz, mensagem text);
alter table public.prot_aptas_pedido enable row level security;
revoke all on public.prot_aptas_pedido from anon, authenticated;

-- pedir (emissores): devolve o pedido pendente se já houver um
create or replace function public.prot_pedir_aptas() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb; v_id bigint;
begin
  if not public.prot_e_emissor() then raise exception 'Só Controladoria e Faturamento atualizam as notas aptas'; end if;
  select to_jsonb(p) into v from prot_aptas_pedido p where p.status in ('PENDENTE', 'RODANDO') order by p.id limit 1;
  if v is not null then return v || jsonb_build_object('ja_havia', true); end if;
  insert into prot_aptas_pedido (pedido_por) values (auth.jwt()->>'email') returning id into v_id;
  select to_jsonb(p) into v from prot_aptas_pedido p where p.id = v_id;
  return v || jsonb_build_object('ja_havia', false);
end $$;

-- situação do último pedido (emissores)
create or replace function public.prot_aptas_situacao() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_e_emissor() then null else
         (select to_jsonb(p) from prot_aptas_pedido p order by p.id desc limit 1) end
$$;

revoke execute on function public.prot_pedir_aptas(), public.prot_aptas_situacao() from public, anon;
grant execute on function public.prot_pedir_aptas(), public.prot_aptas_situacao() to authenticated;

-- conferência
select (select count(*) from pg_tables where schemaname = 'public' and tablename = 'prot_aptas_pedido' and rowsecurity) as tabela,
       (select count(*) from pg_proc where proname in ('prot_pedir_aptas', 'prot_aptas_situacao')) as funcoes;
