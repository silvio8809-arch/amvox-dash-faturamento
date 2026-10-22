-- =====================================================================================
-- Dashboard Fat & LOG — migração 020 (22/10/2026) · fim do MODO TESTE + exceção REPROTOCOLAR + "Liberar" na hora
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 019. Idempotente.
--
-- Silvio (22/10/2026), depois do teste controlado (tudo funcionou):
--   1) "modo de teste pode ser desligado" → EMAIL_TESTE vazio: e-mails voltam aos destinatários reais;
--   2) "como exceção, as notas do PROT-2026-014 (teste, só foi ao meu e-mail) devem entrar no protocolo de amanhã às 09h
--      normalmente — duplicidade aceita em exceção" → parâmetro REPROTOCOLAR (lista filial|serie|doc): a nota volta a ser
--      apta mesmo já constando em protocolo; a rotina consome a lista quando o protocolo real sair;
--   3) "cliquei em Liberar e a nota continua Retida, com o histórico anterior — apagar da tela, manter só no log" →
--      liberar limpa o quadro de aptas NA HORA (o motivo antigo some da tela; o histórico fica em prot_retencao).
-- =====================================================================================

update public.prot_parametro set texto = '' where chave = 'EMAIL_TESTE';

insert into public.prot_parametro (chave, texto, descricao) values
  ('REPROTOCOLAR', '010102|1|000281775;010102|1|000281778',
   'EXCEÇÃO (Silvio 22/10/2026): notas que voltam a ser aptas mesmo já constando em protocolo (ex.: PROT-2026-014 de teste, só foi ao e-mail do Silvio). A rotina tira cada nota daqui quando ela sair no protocolo real.')
on conflict (chave) do update set texto = excluded.texto, descricao = excluded.descricao;

create or replace function public.prot_reprotocolar(p_filial text, p_serie text, p_doc text) returns boolean
language sql stable security definer set search_path = public as $$
  select (p_filial || '|' || p_serie || '|' || p_doc) = any (string_to_array(coalesce((select texto from prot_parametro where chave = 'REPROTOCOLAR'), ''), ';'))
$$;

-- "já protocolada" — exceto as notas da lista REPROTOCOLAR
create or replace function public.prot_ja_protocolada(p_filial text, p_serie text, p_doc text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from exped_protocolo_nf n where n.filial = p_filial and n.serie = p_serie and n.doc = p_doc)
     and not public.prot_reprotocolar(p_filial, p_serie, p_doc)
$$;

-- liberar = vale na hora no quadro de aptas (o motivo antigo some da tela; o histórico fica em prot_retencao)
create or replace function public.prot_liberar_retencao(p_filial text, p_serie text, p_doc text, p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.prot_e_emissor() then raise exception 'Só Controladoria e Faturamento liberam retenção'; end if;
  update prot_retencao set liberado_por = auth.jwt()->>'email', liberado_em = now(), liberacao_motivo = nullif(btrim(coalesce(p_motivo, '')), '')
   where filial = p_filial and serie = p_serie and doc = p_doc and liberado_em is null;
  if not found then raise exception 'A NF % não está retida', p_doc; end if;
  update prot_apta set situacao = 'APTA', motivo = null
   where filial = p_filial and serie = p_serie and doc = p_doc and situacao = 'RETIDA' and motivo like 'Retida por %';
  return jsonb_build_object('liberada', p_doc);
end $$;
-- limpeza de linhas antigas do quadro com retenção manual já liberada
update public.prot_apta a set situacao = 'APTA', motivo = null
 where a.situacao = 'RETIDA' and a.motivo like 'Retida por %'
   and not exists (select 1 from prot_retencao r where r.filial = a.filial and r.serie = a.serie and r.doc = a.doc and r.liberado_em is null);

create or replace function public.prot_aptas() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_e_emissor() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'filial', a.filial, 'serie', a.serie, 'doc', a.doc, 'emissao', a.emissao, 'cliente', a.cliente, 'municipio', a.municipio,
           'uf', a.uf, 'depositos', a.depositos, 'tipo', case when a.origem = 'BON' then 'BONIF.' else 'VENDA' end, 'valor', a.valor,
           'situacao', case when r.id is not null then 'RETIDA'
                            when a.situacao = 'RETIDA' and a.motivo like 'Retida por %' then 'APTA'   -- retenção manual já liberada
                            else a.situacao end,
           'motivo', case when r.id is not null then format('Retida por %s em %s: %s', split_part(coalesce(r.retido_por, '?'), '@', 1),
                                                              to_char(r.retido_em at time zone 'America/Bahia', 'DD/MM HH24:MI'), r.motivo)
                          when a.situacao = 'RETIDA' and a.motivo like 'Retida por %' then null
                          else a.motivo end,
           'retencao', case when r.id is not null then jsonb_build_object('motivo', r.motivo, 'por', r.retido_por, 'em', r.retido_em) end,
           'reprotocolar', public.prot_reprotocolar(a.filial, a.serie, a.doc),
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
  where not public.prot_ja_protocolada(a.filial, a.serie, a.doc)
$$;

create or replace function public.prot_solicitar(p_notas jsonb, p_agendar timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int; v_ok int; v_id bigint; v_dup int;
begin
  if not public.prot_e_emissor() then raise exception 'Só Controladoria e Faturamento geram protocolo'; end if;
  v_n := coalesce(jsonb_array_length(p_notas), 0);
  if v_n = 0 then raise exception 'Selecione ao menos uma nota'; end if;
  if p_agendar is not null and p_agendar < now() - interval '5 minutes' then raise exception 'O horário agendado já passou'; end if;
  select count(*) into v_ok from jsonb_to_recordset(p_notas) as x(filial text, serie text, doc text)
    join prot_apta a on a.filial = x.filial and a.serie = x.serie and a.doc = x.doc
                    and (a.situacao = 'APTA' or (a.situacao = 'RETIDA' and a.motivo like 'Retida por %'))
   where not public.prot_ja_protocolada(x.filial, x.serie, x.doc)
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
      or public.prot_ja_protocolada(x.filial, x.serie, x.doc)
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

revoke execute on function public.prot_reprotocolar(text, text, text), public.prot_ja_protocolada(text, text, text) from public, anon;
grant execute on function public.prot_reprotocolar(text, text, text), public.prot_ja_protocolada(text, text, text) to authenticated;

-- conferência
select (select texto from prot_parametro where chave = 'EMAIL_TESTE') as email_teste_vazio,
       (select texto from prot_parametro where chave = 'REPROTOCOLAR') as reprotocolar,
       (select count(*) from pg_proc where proname in ('prot_reprotocolar', 'prot_ja_protocolada')) as funcoes_novas,
       (select count(*) from prot_apta where situacao = 'RETIDA' and motivo like 'Retida por %') as retidas_manuais_no_quadro;
