-- =====================================================================================
-- Dashboard Fat & LOG — migração 013 (20/10/2026) · PROTOCOLO ON-LINE (etapas 2 e 3)
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 012. Idempotente.
--
-- Decisões do Silvio (20/10/2026):
--   · a aba Protocolos abre para TODO usuário do Dash AUTOMATICAMENTE a partir de 03/11/2026 (ABA_LIBERA_EM);
--     o ENVIO de e-mail ao time LOG continua desligado (DESTINO_MODO = HOMOLOGACAO) até ordem dele;
--   · Controladoria e Faturamento veem as NOTAS APTAS (autorizadas e ainda sem protocolo) e geram protocolo
--     COMPLEMENTAR sob demanda — selecionam as notas, podem agendar o horário; a rotina do Mac processa a fila e
--     envia (mesmo padrão de e-mail + PDF). Automático continua UM por dia (09h);
--   · bonificação SEM FATURAMENTO do grupo (regra do app Redes: venda do grupo ±prazo) fica RETIDA — não entra em
--     protocolo nenhum enquanto não houver venda, JUSTIFICATIVA ou "PODE LIBERAR" enviado.
-- Nada disto é visível para a LOG: aptas, retidas e fila são só de quem gera protocolo.
-- =====================================================================================

-- 1) liberação automática da aba
insert into public.prot_parametro (chave, texto, descricao) values
  ('ABA_LIBERA_EM', '2026-11-03', 'A partir desta data a aba Protocolos abre para todo usuário do Dash (decisão do Silvio 20/10/2026)')
on conflict (chave) do nothing;
-- envio AUTOMÁTICO ao time LOG a partir de 03/11/2026 (Silvio 20/10/2026): protocolos liberados pelo Faturamento passam a ir
-- para fiscal + LOG; antes disso, só fiscal (a rotina lê DESTINO_LIBERA_EM; DESTINO_MODO = LOGISTICA antecipa)
insert into public.prot_parametro (chave, texto, descricao) values
  ('DESTINO_LIBERA_EM', '2026-11-03', 'A partir desta data os protocolos vão também para o time LOG (DESTINO_LOG) — decisão do Silvio 20/10/2026')
on conflict (chave) do nothing;
update public.prot_parametro set descricao = 'HOMOLOGACAO = só o time FISCAL até DESTINO_LIBERA_EM; LOGISTICA = fiscal + time LOG já' where chave = 'DESTINO_MODO';
update public.prot_parametro set descricao = 'Time de Logística — recebe os protocolos a partir de DESTINO_LIBERA_EM (03/11/2026)' where chave = 'DESTINO_LOG';
create or replace function public.prot_pode_ver() returns boolean language sql stable security definer set search_path = public as $$
  select public.tem_app('dash') and (public.prot_e_emissor()
    or coalesce((select texto from prot_parametro where chave = 'ABA_ACESSO'), 'EMISSORES') = 'TODOS'
    or (now() at time zone 'America/Bahia')::date >= coalesce((select texto::date from prot_parametro where chave = 'ABA_LIBERA_EM'), '2999-12-31'))
$$;

-- 2) notas aptas a liberar (gravadas pela rotina a cada carga do dash; só emissores leem)
create table if not exists public.prot_apta (
  filial text not null, serie text not null, doc text not null,
  emissao date, cliente text, municipio text, uf text, depositos text, origem text, valor numeric,
  situacao text not null default 'APTA' check (situacao in ('APTA', 'RETIDA')), motivo text,
  atualizado_em timestamptz not null default now(),
  primary key (filial, serie, doc));
alter table public.prot_apta enable row level security;
revoke all on public.prot_apta from anon, authenticated;

-- 3) fila de protocolos complementares
create table if not exists public.prot_pedido (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(), criado_por text,
  notas jsonb not null,                                     -- [{"filial","serie","doc"}]
  agendado_para timestamptz,                                -- null = na próxima rodada
  status text not null default 'PENDENTE' check (status in ('PENDENTE', 'RODANDO', 'ENVIADO', 'ERRO', 'CANCELADO')),
  protocolo text, mensagem text, processado_em timestamptz);
alter table public.prot_pedido enable row level security;
revoke all on public.prot_pedido from anon, authenticated;

-- 4) bonificação RETIDA (mesma regra do painel de notas de bonificação do app Redes, para a rotina — chave de serviço)
create or replace function public.prot_bonif_retidas() returns table (filial text, serie text, doc text, motivo text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_ini date; v_prazo int;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.prot_e_emissor()) then raise exception 'Sem acesso'; end if;
  select rp.texto::date into v_ini from rede_parametro rp where rp.chave = 'CAMP_INICIO';
  select rp.valor::int into v_prazo from rede_parametro rp where rp.chave = 'BONIF_PRAZO_DIAS';
  return query
  with b as (select n.*, c.grupo, c.cnpj cnpj_cad from cli_nota_bonif n left join cli_cadastro c on c.cod = n.cliente and c.loja = n.loja
              where n.emissao >= v_ini and coalesce(n.valor_devolvido, 0) < n.valor - 0.01)
  select b.filial, b.serie, b.doc,
         format('Bonificação sem faturamento do grupo (nenhuma venda entre %s e %s) — reter até haver venda, justificativa ou "pode liberar" no app Redes',
                to_char(b.emissao - v_prazo, 'DD/MM'), to_char(b.emissao + v_prazo, 'DD/MM'))
    from b
   where not exists (select 1 from bonif_nf_vinculo v where v.filial = b.filial and v.doc = b.doc and v.serie = b.serie and v.cliente = b.cliente and v.loja = b.loja)
     and not exists (select 1 from bonif_nf_justif j where j.filial = b.filial and j.doc = b.doc and j.serie = b.serie and j.cliente = b.cliente and j.loja = b.loja)
     and not exists (select 1 from bonif_nf_aviso a where a.filial = b.filial and a.doc = b.doc and a.serie = b.serie and a.cliente = b.cliente
                        and a.loja = b.loja and a.tipo = 'LIBERAR' and a.enviado_em is not null)
     and not exists (select 1 from cli_nota nv join cli_cadastro cv on cv.cod = nv.cliente and cv.loja = nv.loja
                      where nv.emissao between b.emissao - v_prazo and b.emissao + v_prazo
                        and ((b.grupo is not null and cv.grupo = b.grupo)
                             or (length(coalesce(cv.cnpj, '')) = 14 and left(cv.cnpj, 8) = left(coalesce(b.cnpj_cad, b.cnpj, ''), 8))
                             or cv.cnpj = coalesce(b.cnpj_cad, b.cnpj)));
end $$;

-- 5) leitura das aptas (emissores) — marca as que já estão num pedido pendente
create or replace function public.prot_aptas() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_e_emissor() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'filial', a.filial, 'serie', a.serie, 'doc', a.doc, 'emissao', a.emissao, 'cliente', a.cliente, 'municipio', a.municipio,
           'uf', a.uf, 'depositos', a.depositos, 'tipo', case when a.origem = 'BON' then 'BONIF.' else 'VENDA' end, 'valor', a.valor,
           'situacao', a.situacao, 'motivo', a.motivo, 'atualizado_em', a.atualizado_em,
           'pedido', (select p.id from prot_pedido p where p.status in ('PENDENTE', 'RODANDO')
                        and p.notas @> jsonb_build_array(jsonb_build_object('filial', a.filial, 'serie', a.serie, 'doc', a.doc)) limit 1))
         order by a.emissao, a.doc), '[]'::jsonb) end
  from prot_apta a
  where not exists (select 1 from exped_protocolo_nf n where n.filial = a.filial and n.serie = a.serie and n.doc = a.doc)
$$;

-- 6) pedir protocolo complementar (emissores): só notas APTAS, fora de outro pedido em andamento
create or replace function public.prot_solicitar(p_notas jsonb, p_agendar timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int; v_ok int; v_id bigint; v_dup int;
begin
  if not public.prot_e_emissor() then raise exception 'Só Controladoria e Faturamento geram protocolo'; end if;
  v_n := coalesce(jsonb_array_length(p_notas), 0);
  if v_n = 0 then raise exception 'Selecione ao menos uma nota'; end if;
  if p_agendar is not null and p_agendar < now() - interval '5 minutes' then raise exception 'O horário agendado já passou'; end if;
  select count(*) into v_ok from jsonb_to_recordset(p_notas) as x(filial text, serie text, doc text)
    join prot_apta a on a.filial = x.filial and a.serie = x.serie and a.doc = x.doc and a.situacao = 'APTA'
   where not exists (select 1 from exped_protocolo_nf n where n.filial = x.filial and n.serie = x.serie and n.doc = x.doc);
  if v_ok <> v_n then raise exception 'Há nota que não está apta (já protocolada, retida ou fora da lista atual) — atualize a tela'; end if;
  select count(*) into v_dup from jsonb_to_recordset(p_notas) as x(filial text, serie text, doc text)
   where exists (select 1 from prot_pedido p where p.status in ('PENDENTE', 'RODANDO')
                   and p.notas @> jsonb_build_array(jsonb_build_object('filial', x.filial, 'serie', x.serie, 'doc', x.doc)));
  if v_dup > 0 then raise exception 'Há nota que já está em outro pedido na fila'; end if;
  insert into prot_pedido (criado_por, notas, agendado_para) values (auth.jwt()->>'email',
    (select jsonb_agg(jsonb_build_object('filial', x.filial, 'serie', x.serie, 'doc', x.doc)) from jsonb_to_recordset(p_notas) as x(filial text, serie text, doc text)),
    p_agendar) returning id into v_id;
  return jsonb_build_object('id', v_id, 'notas', v_n, 'agendado_para', p_agendar);
end $$;

-- 7) fila (emissores) e cancelamento de pedido ainda pendente
create or replace function public.prot_pedidos() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_e_emissor() then '[]'::jsonb else coalesce(jsonb_agg(to_jsonb(p) order by p.id desc), '[]'::jsonb) end
  from prot_pedido p where p.criado_em >= now() - interval '30 days'
$$;
create or replace function public.prot_cancelar_pedido(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.prot_e_emissor() then raise exception 'Sem acesso'; end if;
  update prot_pedido set status = 'CANCELADO', mensagem = 'cancelado por ' || coalesce(auth.jwt()->>'email', '?'), processado_em = now()
   where id = p_id and status = 'PENDENTE';
  if not found then raise exception 'Pedido % não está pendente (já saiu ou foi cancelado)', p_id; end if;
  return jsonb_build_object('id', p_id, 'status', 'CANCELADO');
end $$;

revoke execute on function public.prot_bonif_retidas(), public.prot_aptas(), public.prot_solicitar(jsonb, timestamptz),
  public.prot_pedidos(), public.prot_cancelar_pedido(bigint) from public, anon;
grant execute on function public.prot_bonif_retidas(), public.prot_aptas(), public.prot_solicitar(jsonb, timestamptz),
  public.prot_pedidos(), public.prot_cancelar_pedido(bigint) to authenticated;

-- 8) cliente pela RAZÃO SOCIAL (Silvio 20/10/2026) — também nos protocolos antigos, que gravaram o nome reduzido:
--    vem do cadastro (cli_cadastro.nome = A1_NOME) pelo código/loja da nota no dash
create or replace function public.prot_notas(p_numero text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_pode_ver() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'filial', n.filial, 'serie', n.serie, 'doc', n.doc, 'emissao', n.emissao,
           'cliente', coalesce(nullif(btrim(c.nome), ''), n.cliente), 'uf', n.uf,
           'depositos', n.depositos, 'tipo', case when n.origem = 'BON' then 'BONIF.' else 'VENDA' end, 'valor', n.valor,
           'status', d.status, 'dt_entrega', d.dt_entrega, 'transportadora', d.transportadora)
         order by n.emissao, n.doc), '[]'::jsonb) end
  from exped_protocolo_nf n join prot_protocolo p on p.numero = n.protocolo and p.situacao = 'ENVIADO'
  left join dash_nf_saida d on d.filial = n.filial and d.serie = n.serie and d.nf = n.doc
  left join cli_cadastro c on c.cod = d.cliente_cod and c.loja = d.cliente_loja
  where n.protocolo = p_numero and public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)
$$;

-- conferência
select (select texto from prot_parametro where chave = 'ABA_LIBERA_EM') as libera_em,
       (select texto from prot_parametro where chave = 'DESTINO_LIBERA_EM') as envio_log_em,
       (select count(*) from pg_tables where schemaname = 'public' and tablename in ('prot_apta', 'prot_pedido') and rowsecurity) as tabelas,
       (select count(*) from pg_proc where proname in ('prot_bonif_retidas', 'prot_aptas', 'prot_solicitar', 'prot_pedidos', 'prot_cancelar_pedido')) as funcoes_novas;
