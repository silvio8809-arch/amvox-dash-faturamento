-- =====================================================================================
-- 010 — REGISTRO DE ACESSO AO DASH (Silvio 13/10/2026 — informe de gestão de uso pela Logística)
-- O login (auth.users.last_sign_in_at) não mede uso: a sessão fica aberta por dias. Cada tela do Dash grava um
-- acesso quando abre (ou recarrega) VISÍVEL, no máximo 1 registro a cada 30 min por pessoa e origem.
-- origem 'painel' = telas de trabalho (sem-entrega, emitidas, devoluções, clientes, região, auditoria);
-- origem 'tv' = tela inicial (index.html, que roda na TV com o login da Logística) — o informe NÃO conta a TV.
-- Leitura: só Controladoria e gerentes (rede_ve_tudo). Ninguém altera nem apaga registro.
-- =====================================================================================

create table if not exists public.dash_acesso (
  id bigserial primary key,
  user_id uuid not null default auth.uid(),
  usuario text not null default (auth.jwt()->>'email'),
  origem text not null check (origem in ('painel', 'tv')),
  pagina text,
  em timestamptz not null default now()
);
create index if not exists dash_acesso_usuario_em on public.dash_acesso (usuario, em desc);
alter table public.dash_acesso enable row level security;
drop policy if exists dacesso_le on public.dash_acesso;
create policy dacesso_le on public.dash_acesso for select to authenticated using ((select public.rede_ve_tudo()));
revoke all on public.dash_acesso from anon, authenticated;
grant select on public.dash_acesso to authenticated;

create or replace function public.dash_registra_acesso(p_origem text, p_pagina text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_email text := auth.jwt()->>'email';
begin
  if auth.uid() is null or coalesce(p_origem, '') not in ('painel', 'tv') then return false; end if;
  if exists (select 1 from dash_acesso a where a.user_id = auth.uid() and a.origem = p_origem
               and a.em > now() - interval '30 minutes') then
    return false;                                   -- já registrado nos últimos 30 min
  end if;
  insert into dash_acesso (user_id, usuario, origem, pagina) values (auth.uid(), v_email, p_origem, left(p_pagina, 120));
  return true;
end $$;
revoke execute on function public.dash_registra_acesso(text, text) from public, anon;
grant execute on function public.dash_registra_acesso(text, text) to authenticated;

select (select relrowsecurity from pg_class where relname = 'dash_acesso') as rls_acesso,
       (select count(*) from pg_proc where proname = 'dash_registra_acesso') as funcao;
