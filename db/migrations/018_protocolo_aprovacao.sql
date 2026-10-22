-- =====================================================================================
-- Dashboard Fat & LOG — migração 018 (22/10/2026) · APROVAÇÃO do protocolo automático + RETENÇÃO MANUAL com motivo
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 017. Idempotente.
--
-- Pedido do Silvio (22/10/2026): "o sistema monta, mas só envia as notificações previstas se o protocolo montado
-- automaticamente for aprovado [por FAT ou CTRL], podendo inclusive ser editado antes do envio. Existem casos onde a nota foi
-- faturada, mas existe um motivo (ex.: Comercial solicitou reter) para que a nota ainda não esteja liberada para expedição."
--   1) às 09h a rotina monta o protocolo do dia como RASCUNHO (prot_pedido origem AUTOMATICO, status AGUARDANDO_APROVACAO);
--      o ALERTA de canceladas/devolvidas continua saindo na hora (é aviso de segurança, não é liberação);
--   2) Controladoria/Faturamento (prot_e_emissor) aprovam na aba — podem tirar notas e reter com motivo; "Aprovar e enviar"
--      = o pedido vira PENDENTE e a rodada da fila (a cada 15 min) gera o PDF e envia o e-mail no padrão de sempre;
--   3) RETENÇÃO MANUAL (prot_retencao): nota faturada que NÃO pode ser liberada (motivo obrigatório) fica fora de qualquer
--      protocolo — automático, complementar ou aprovação — até "Liberar retenção". Histórico guardado (quem reteve/liberou).
--   4) parâmetro APROVACAO_AUTOMATICO = SIM (NÃO = volta ao envio direto, como antes).
-- =====================================================================================

insert into public.prot_parametro (chave, texto, descricao) values
  ('APROVACAO_AUTOMATICO', 'SIM', 'SIM = o protocolo automático das 09h vira RASCUNHO e só é enviado depois de aprovado por Controladoria/Faturamento na aba (Silvio 22/10/2026); NÃO = envio direto')
on conflict (chave) do nothing;

-- 1) fila ganha o rascunho do automático
alter table public.prot_pedido add column if not exists origem text not null default 'MANUAL';
alter table public.prot_pedido add column if not exists aprovado_por text;
alter table public.prot_pedido add column if not exists aprovado_em timestamptz;
alter table public.prot_pedido add column if not exists notas_originais jsonb;
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.prot_pedido'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%status%'
  loop
    execute format('alter table public.prot_pedido drop constraint %I', c);
  end loop;
end $$;
alter table public.prot_pedido add constraint prot_pedido_status_check
  check (status in ('AGUARDANDO_APROVACAO', 'PENDENTE', 'RODANDO', 'ENVIADO', 'ERRO', 'CANCELADO'));

-- 2) retenção manual com motivo
create table if not exists public.prot_retencao (
  id bigint generated always as identity primary key,
  filial text not null, serie text not null, doc text not null,
  motivo text not null, retido_por text, retido_em timestamptz not null default now(),
  liberado_por text, liberado_em timestamptz, liberacao_motivo text);
create unique index if not exists prot_retencao_ativa on public.prot_retencao (filial, serie, doc) where liberado_em is null;
alter table public.prot_retencao enable row level security;
revoke all on public.prot_retencao from anon, authenticated;

create or replace function public.prot_reter(p_notas jsonb, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not public.prot_e_emissor() then raise exception 'Só Controladoria e Faturamento retêm notas'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo da retenção (ex.: Comercial solicitou reter)'; end if;
  insert into prot_retencao (filial, serie, doc, motivo, retido_por)
  select x.filial, x.serie, x.doc, btrim(p_motivo), auth.jwt()->>'email'
    from jsonb_to_recordset(p_notas) as x(filial text, serie text, doc text)
   where not exists (select 1 from prot_retencao r where r.filial = x.filial and r.serie = x.serie and r.doc = x.doc and r.liberado_em is null)
     and not exists (select 1 from exped_protocolo_nf n where n.filial = x.filial and n.serie = x.serie and n.doc = x.doc);
  get diagnostics v_n = row_count;
  return jsonb_build_object('retidas', v_n);
end $$;

create or replace function public.prot_liberar_retencao(p_filial text, p_serie text, p_doc text, p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.prot_e_emissor() then raise exception 'Só Controladoria e Faturamento liberam retenção'; end if;
  update prot_retencao set liberado_por = auth.jwt()->>'email', liberado_em = now(), liberacao_motivo = nullif(btrim(coalesce(p_motivo, '')), '')
   where filial = p_filial and serie = p_serie and doc = p_doc and liberado_em is null;
  if not found then raise exception 'A NF % não está retida', p_doc; end if;
  return jsonb_build_object('liberada', p_doc);
end $$;

-- 3) aptas: retenção manual vale na hora (antes da próxima carga) e nota no rascunho do dia aparece como tal
create or replace function public.prot_aptas() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_e_emissor() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'filial', a.filial, 'serie', a.serie, 'doc', a.doc, 'emissao', a.emissao, 'cliente', a.cliente, 'municipio', a.municipio,
           'uf', a.uf, 'depositos', a.depositos, 'tipo', case when a.origem = 'BON' then 'BONIF.' else 'VENDA' end, 'valor', a.valor,
           'situacao', case when r.id is not null then 'RETIDA' else a.situacao end,
           'motivo', case when r.id is not null then format('Retida por %s em %s: %s', split_part(coalesce(r.retido_por, '?'), '@', 1),
                                                              to_char(r.retido_em at time zone 'America/Bahia', 'DD/MM HH24:MI'), r.motivo)
                          else a.motivo end,
           'retencao', case when r.id is not null then jsonb_build_object('motivo', r.motivo, 'por', r.retido_por, 'em', r.retido_em) end,
           'atualizado_em', a.atualizado_em,
           'suframa', coalesce(nullif(btrim(a.suframa), ''),
                      (select nullif(btrim(c.suframa), '') from dash_nf_saida d join cli_cadastro c on c.cod = d.cliente_cod and c.loja = d.cliente_loja
                        where d.filial = a.filial and d.serie = a.serie and d.nf = a.doc limit 1)),
           'pedido', (select p.id from prot_pedido p where p.status in ('PENDENTE', 'RODANDO', 'AGUARDANDO_APROVACAO')
                        and p.notas @> jsonb_build_array(jsonb_build_object('filial', a.filial, 'serie', a.serie, 'doc', a.doc)) limit 1),
           'pedido_status', (select p.status from prot_pedido p where p.status in ('PENDENTE', 'RODANDO', 'AGUARDANDO_APROVACAO')
                        and p.notas @> jsonb_build_array(jsonb_build_object('filial', a.filial, 'serie', a.serie, 'doc', a.doc)) limit 1))
         order by a.emissao, a.doc), '[]'::jsonb) end
  from prot_apta a
  left join prot_retencao r on r.filial = a.filial and r.serie = a.serie and r.doc = a.doc and r.liberado_em is null
  where not exists (select 1 from exped_protocolo_nf n where n.filial = a.filial and n.serie = a.serie and n.doc = a.doc)
$$;

-- 4) complementar: não aceita nota retida nem nota que já está no rascunho do dia
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
   where not exists (select 1 from exped_protocolo_nf n where n.filial = x.filial and n.serie = x.serie and n.doc = x.doc)
     and not exists (select 1 from prot_retencao r where r.filial = x.filial and r.serie = x.serie and r.doc = x.doc and r.liberado_em is null);
  if v_ok <> v_n then raise exception 'Há nota que não está apta (já protocolada, retida ou fora da lista atual) — atualize a tela'; end if;
  select count(*) into v_dup from jsonb_to_recordset(p_notas) as x(filial text, serie text, doc text)
   where exists (select 1 from prot_pedido p where p.status in ('PENDENTE', 'RODANDO', 'AGUARDANDO_APROVACAO')
                   and p.notas @> jsonb_build_array(jsonb_build_object('filial', x.filial, 'serie', x.serie, 'doc', x.doc)));
  if v_dup > 0 then raise exception 'Há nota que já está em outro pedido na fila ou no rascunho do protocolo do dia (aprove o rascunho)'; end if;
  insert into prot_pedido (criado_por, notas, agendado_para) values (auth.jwt()->>'email',
    (select jsonb_agg(jsonb_build_object('filial', x.filial, 'serie', x.serie, 'doc', x.doc)) from jsonb_to_recordset(p_notas) as x(filial text, serie text, doc text)),
    p_agendar) returning id into v_id;
  return jsonb_build_object('id', v_id, 'notas', v_n, 'agendado_para', p_agendar);
end $$;

-- 5) aprovar o rascunho (pode tirar notas) e descartar
create or replace function public.prot_aprovar(p_id bigint, p_notas jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_p prot_pedido; v_sel jsonb; v_n int; v_fora text;
begin
  if not public.prot_e_emissor() then raise exception 'Só Controladoria e Faturamento aprovam o protocolo'; end if;
  select * into v_p from prot_pedido where id = p_id for update;
  if v_p.id is null or v_p.status <> 'AGUARDANDO_APROVACAO' then raise exception 'O rascunho % não está aguardando aprovação (atualize a tela)', p_id; end if;
  if coalesce(jsonb_array_length(p_notas), 0) = 0 then raise exception 'Marque ao menos uma nota — ou use "Não enviar hoje"'; end if;
  select string_agg(ltrim(x.doc, '0'), ', ') into v_fora from jsonb_to_recordset(p_notas) as x(filial text, serie text, doc text)
   where not (v_p.notas @> jsonb_build_array(jsonb_build_object('filial', x.filial, 'serie', x.serie, 'doc', x.doc)))
      or exists (select 1 from exped_protocolo_nf n where n.filial = x.filial and n.serie = x.serie and n.doc = x.doc)
      or exists (select 1 from prot_retencao r where r.filial = x.filial and r.serie = x.serie and r.doc = x.doc and r.liberado_em is null)
      or exists (select 1 from prot_pedido o where o.id <> p_id and o.status in ('PENDENTE', 'RODANDO')
                   and o.notas @> jsonb_build_array(jsonb_build_object('filial', x.filial, 'serie', x.serie, 'doc', x.doc)));
  if v_fora is not null then raise exception 'NF % não pode ir neste protocolo (fora do rascunho, já protocolada, retida ou em outro pedido) — atualize a tela', v_fora; end if;
  select jsonb_agg(e) into v_sel from jsonb_array_elements(v_p.notas) e
   where exists (select 1 from jsonb_to_recordset(p_notas) as x(filial text, serie text, doc text)
                  where x.filial = e->>'filial' and x.serie = e->>'serie' and x.doc = e->>'doc');
  v_n := jsonb_array_length(v_sel);
  update prot_pedido set notas_originais = coalesce(notas_originais, notas), notas = v_sel, status = 'PENDENTE',
         aprovado_por = auth.jwt()->>'email', aprovado_em = now(), agendado_para = null,
         mensagem = format('aprovado por %s — %s de %s nota(s) do rascunho', split_part(coalesce(auth.jwt()->>'email', '?'), '@', 1),
                           v_n, jsonb_array_length(v_p.notas))
   where id = p_id;
  return jsonb_build_object('id', p_id, 'notas', v_n, 'do_rascunho', jsonb_array_length(v_p.notas));
end $$;

create or replace function public.prot_descartar_rascunho(p_id bigint, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.prot_e_emissor() then raise exception 'Sem acesso'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo de não enviar o protocolo hoje'; end if;
  update prot_pedido set status = 'CANCELADO', processado_em = now(),
         mensagem = format('não enviado — %s: %s', split_part(coalesce(auth.jwt()->>'email', '?'), '@', 1), btrim(p_motivo))
   where id = p_id and status = 'AGUARDANDO_APROVACAO';
  if not found then raise exception 'O rascunho % não está aguardando aprovação', p_id; end if;
  return jsonb_build_object('id', p_id, 'status', 'CANCELADO');
end $$;

revoke execute on function public.prot_reter(jsonb, text), public.prot_liberar_retencao(text, text, text, text),
  public.prot_aprovar(bigint, jsonb), public.prot_descartar_rascunho(bigint, text) from public, anon;
grant execute on function public.prot_reter(jsonb, text), public.prot_liberar_retencao(text, text, text, text),
  public.prot_aprovar(bigint, jsonb), public.prot_descartar_rascunho(bigint, text) to authenticated;

-- conferência
select (select texto from prot_parametro where chave = 'APROVACAO_AUTOMATICO') as aprovacao,
       (select pg_get_constraintdef(oid) from pg_constraint where conname = 'prot_pedido_status_check') as status_fila,
       (select count(*) from pg_tables where schemaname = 'public' and tablename = 'prot_retencao' and rowsecurity) as tabela_retencao,
       (select count(*) from pg_proc where proname in ('prot_reter', 'prot_liberar_retencao', 'prot_aprovar', 'prot_descartar_rascunho')) as funcoes_novas;
