-- =====================================================================================
-- Dashboard Fat & LOG — migração 012 (20/10/2026) · PROTOCOLO ON-LINE (etapa 1: central + ciência)
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor. Idempotente.
--
-- Pedido do Silvio (20/10/2026): aba "Protocolos" no dash = central on-line dos protocolos de notas
-- LIBERADAS PARA EXPEDIÇÃO, com a ciência da Logística. Regras:
--   · a LOG só vê notas JÁ APROVADAS para expedição (protocolo enviado) — nada do que ainda não foi liberado;
--   · nota CANCELADA ou DEVOLVIDA depois NÃO aparece (evita erro de interpretação);
--   · gerar/reenviar protocolo = Controladoria (ADM) e Faturamento (lista PROT_EMISSORES);
--   · ciência registrada por usuário/hora; histórico imutável (prot_evento).
-- A LEITURA é só por funções (security definer) que aplicam as regras — as tabelas não têm política de
-- leitura direta. Quem grava os protocolos é a rotina do Mac (chave de serviço). Nada volta ao Protheus.
-- =====================================================================================

-- 1) parâmetros (texto; listas separadas por ';')
create table if not exists public.prot_parametro (
  chave text primary key, texto text, descricao text, atualizado_em timestamptz not null default now());
insert into public.prot_parametro (chave, texto, descricao) values
  ('PROT_EMISSORES', 'gerente.contabil@amvox.com.br;fiscal@amvox.com.br;fiscal4@amvox.com.br',
   'Quem gera/reenvia protocolo (além do papel ADM): Controladoria e Faturamento'),
  ('DESTINO_MODO', 'HOMOLOGACAO', 'HOMOLOGACAO = só o time FISCAL recebe; LOGISTICA = fiscal + time LOG (só por ordem do Silvio, após 03/11/2026)'),
  ('DESTINO_FISCAL', 'fiscal@amvox.com.br;fiscal4@amvox.com.br', 'Destinatários na homologação'),
  ('DESTINO_LOG', 'coord.logistica@amvox.com.br;logistica.suporte@amvox.com.br;analistadelogistica@amvox.com.br;gerente.logistica@amvox.com.br;logistica4@amvox.com.br',
   'Time de Logística — DESLIGADO até a apresentação do Silvio (gestão da mudança)'),
  ('ABA_ACESSO', 'EMISSORES', 'Quem vê a aba Protocolos: EMISSORES (homologação, até a apresentação à LOG) ou TODOS (todo usuário do Dash)'),
  ('CIENCIA_HORAS', '2', 'Alerta de protocolo sem ciência após N horas do envio'),
  ('HORA_AUTOMATICO', '09:00', 'Protocolo automático: 1 por dia útil; complementares só sob demanda')
on conflict (chave) do nothing;

-- 2) protocolos (cabeçalho) — gravado pela rotina
create table if not exists public.prot_protocolo (
  numero text primary key,                       -- PROT-AAAA-NNN
  data_protocolo date not null,
  gerado_em timestamptz,
  tipo text not null default 'AUTOMATICO' check (tipo in ('AUTOMATICO', 'MANUAL')),
  gerado_por text,
  nfs int not null default 0, valor numeric not null default 0,   -- como saiu no PDF
  situacao text not null default 'ENVIADO' check (situacao in ('NA_FILA', 'GERADO', 'ENVIADO', 'ERRO')),
  enviado_em timestamptz, destinatarios text,
  pdf_path text,                                 -- objeto no bucket prot-pdf
  ciencia_em timestamptz, ciencia_por text,
  atualizado_em timestamptz not null default now());

-- 3) notas do protocolo: a tabela espelho que já existe (021) ganha UF, depósitos e a situação depois da liberação
alter table public.exped_protocolo_nf add column if not exists uf text;
alter table public.exped_protocolo_nf add column if not exists depositos text;
alter table public.exped_protocolo_nf add column if not exists situacao text not null default 'LIBERADA';
alter table public.exped_protocolo_nf add column if not exists situacao_em date;

-- 4) histórico imutável (ciência, envio, reenvio…)
create table if not exists public.prot_evento (
  id bigint generated always as identity primary key,
  numero text not null, acao text not null, usuario text, em timestamptz not null default now(), detalhe text);
create or replace function public.prot_evento_imutavel() returns trigger language plpgsql as $$
begin raise exception 'Histórico de protocolos é imutável'; end $$;
drop trigger if exists prot_evento_imutavel on public.prot_evento;
create trigger prot_evento_imutavel before update or delete on public.prot_evento
  for each row execute function public.prot_evento_imutavel();

alter table public.prot_parametro enable row level security;
alter table public.prot_protocolo enable row level security;
alter table public.prot_evento    enable row level security;
revoke all on public.prot_parametro, public.prot_protocolo, public.prot_evento from anon, authenticated;

-- 5) quem é emissor (Controladoria/Faturamento)
create or replace function public.prot_e_emissor() returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_app('dash') and (
    exists (select 1 from profiles where id = auth.uid() and papel = 'ADM')
    or lower(coalesce(auth.jwt()->>'email', '')) = any (string_to_array(lower(coalesce((select texto from prot_parametro where chave = 'PROT_EMISSORES'), '')), ';')))
$$;

-- quem vê a aba: na homologação só os emissores; depois (ABA_ACESSO = TODOS) todo usuário do Dash
create or replace function public.prot_pode_ver() returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_app('dash') and (public.prot_e_emissor()
    or coalesce((select texto from prot_parametro where chave = 'ABA_ACESSO'), 'EMISSORES') = 'TODOS')
$$;

-- nota visível = protocolo ENVIADO, situação LIBERADA e, no dash, nem cancelada nem devolvida (total ou parcial)
create or replace function public.prot_nota_visivel(p_filial text, p_serie text, p_doc text, p_sit text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p_sit, 'LIBERADA') = 'LIBERADA' and not exists (
    select 1 from dash_nf_saida d where d.filial = p_filial and d.serie = p_serie and d.nf = p_doc
       and d.status in ('CANCELADA', 'DEVOLVIDA_TOTAL', 'DEVOLVIDA_PARCIAL'))
$$;

-- 6) LISTA de protocolos (todos os usuários do Dash) — contagem e valor só das notas visíveis
create or replace function public.prot_lista(p_desde date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_pode_ver() then '[]'::jsonb else coalesce(jsonb_agg(x order by x->>'numero' desc), '[]'::jsonb) end
  from (
    select jsonb_build_object('numero', p.numero, 'data', p.data_protocolo, 'tipo', p.tipo, 'gerado_por', p.gerado_por,
             'enviado_em', p.enviado_em, 'destinatarios', p.destinatarios, 'pdf_path', p.pdf_path,
             'ciencia_em', p.ciencia_em, 'ciencia_por', p.ciencia_por,
             'nfs', count(n.doc) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)),
             'valor', coalesce(sum(n.valor) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)), 0),
             'ocultas', case when public.prot_e_emissor() then count(n.doc) filter (where not public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)) end,
             'horas_sem_ciencia', case when p.ciencia_em is null and p.enviado_em is not null
                                   then round(extract(epoch from now() - p.enviado_em) / 3600.0, 1) end) x
    from prot_protocolo p left join exped_protocolo_nf n on n.protocolo = p.numero
    where p.situacao = 'ENVIADO' and (p_desde is null or p.data_protocolo >= p_desde)
    group by p.numero) t
$$;

-- 7) NOTAS de um protocolo (só as visíveis) + situação logística atual vinda do próprio dash
create or replace function public.prot_notas(p_numero text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_pode_ver() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'filial', n.filial, 'serie', n.serie, 'doc', n.doc, 'emissao', n.emissao, 'cliente', n.cliente, 'uf', n.uf,
           'depositos', n.depositos, 'tipo', case when n.origem = 'BON' then 'BONIF.' else 'VENDA' end, 'valor', n.valor,
           'status', d.status, 'dt_entrega', d.dt_entrega, 'transportadora', d.transportadora)
         order by n.emissao, n.doc), '[]'::jsonb) end
  from exped_protocolo_nf n join prot_protocolo p on p.numero = n.protocolo and p.situacao = 'ENVIADO'
  left join dash_nf_saida d on d.filial = n.filial and d.serie = n.serie and d.nf = n.doc
  where n.protocolo = p_numero and public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)
$$;

-- 8) CIÊNCIA (quem vê a aba; vale a 1ª; todas ficam no histórico)
create or replace function public.prot_dar_ciencia(p_numero text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := auth.jwt()->>'email'; v prot_protocolo;
begin
  if not public.prot_pode_ver() then raise exception 'Sem acesso'; end if;
  select * into v from prot_protocolo where numero = p_numero and situacao = 'ENVIADO';
  if v.numero is null then raise exception 'Protocolo % não encontrado', p_numero; end if;
  insert into prot_evento (numero, acao, usuario) values (p_numero, 'CIENCIA', v_email);
  if v.ciencia_em is null then
    update prot_protocolo set ciencia_em = now(), ciencia_por = v_email, atualizado_em = now() where numero = p_numero;
  end if;
  return jsonb_build_object('numero', p_numero, 'ciencia_em', coalesce(v.ciencia_em, now()), 'ciencia_por', coalesce(v.ciencia_por, v_email));
end $$;

-- 9) histórico de um protocolo (todos do Dash)
create or replace function public.prot_historico(p_numero text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_pode_ver() then '[]'::jsonb else
    coalesce(jsonb_agg(jsonb_build_object('acao', acao, 'usuario', usuario, 'em', em, 'detalhe', detalhe) order by em), '[]'::jsonb) end
  from prot_evento where numero = p_numero
$$;

revoke execute on function public.prot_pode_ver() from public, anon;
grant execute on function public.prot_pode_ver() to authenticated;
revoke execute on function public.prot_e_emissor(), public.prot_nota_visivel(text, text, text, text), public.prot_lista(date),
  public.prot_notas(text), public.prot_dar_ciencia(text), public.prot_historico(text) from public, anon;
grant execute on function public.prot_e_emissor(), public.prot_lista(date), public.prot_notas(text),
  public.prot_dar_ciencia(text), public.prot_historico(text) to authenticated;

-- 10) PDFs dos protocolos: pasta PRIVADA prot-pdf; só quem tem o Dash lê; só a rotina (chave de serviço) grava
insert into storage.buckets (id, name, public, file_size_limit) values ('prot-pdf', 'prot-pdf', false, 10485760)
on conflict (id) do nothing;
drop policy if exists "prot_pdf leitura" on storage.objects;
create policy "prot_pdf leitura" on storage.objects for select to authenticated
  using (bucket_id = 'prot-pdf' and (select public.prot_pode_ver()));

-- conferência
select (select count(*) from prot_parametro) as parametros,
       (select count(*) from pg_proc where proname like 'prot\_%') as funcoes,
       (select count(*) from information_schema.columns where table_name = 'exped_protocolo_nf' and column_name in ('uf','depositos','situacao','situacao_em')) as colunas_novas,
       (select count(*) from storage.buckets where id = 'prot-pdf') as bucket;
