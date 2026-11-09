-- =====================================================================================
-- 026 — ACEITE PARCIAL COM PENDÊNCIA DE REIMPRESSÃO (Silvio 09/11/2026). No PROT-2026-029 o Fiscal aprovou e enviou o protocolo,
-- mas não mandou todas as notas para a impressora da LOG. O aceite deixa de ser só SIM/NÃO:
--   · LOG: "Aceite com pendência" → marca as notas que NÃO chegaram impressas (motivo) → protocolo "ACEITE PARCIAL — N NF p/
--     reimpressão". Conta como aceite da LOG (o lembrete à LOG para) e a cobrança passa ao Fiscal.
--   · Fiscal/Faturamento/Controladoria: "Reimpressão enviada" nas notas → THOR à LOG (Fiscal em cópia).
--   · LOG recebeu a reimpressão: clica "Aceito s/ pendências" (o mesmo prot_dar_aceite) → o ÚLTIMO status sobrepõe o anterior.
--   · A reimpressão fica DENTRO do mesmo protocolo (sem protocolo complementar — a nota não pode estar em dois protocolos).
-- Notificações THOR (rotina do Mac, fila de 15 min): pedido → Para FISCAL, Cc LOG · enviada → Para LOG, Cc FISCAL · lembrete ao
-- Fiscal a cada CIENCIA_HORAS (3 h) em dia útil 08h–16h59 enquanto houver nota pendente.
-- Pode rodar de novo sem estragar nada.
-- =====================================================================================

-- 1) pendências de reimpressão (estado por nota; o histórico imutável continua no prot_evento)
create table if not exists public.prot_reimpressao (
  id bigint generated always as identity primary key,
  numero text not null, filial text not null, serie text not null, doc text not null,
  motivo text not null default 'NF não impressa',
  pedido_por text not null, pedido_em timestamptz not null default now(),
  enviada_por text, enviada_em timestamptz,
  resolvida_por text, resolvida_em timestamptz,            -- "Aceito s/ pendências" da LOG encerra
  notif_pedido_em timestamptz, notif_envio_em timestamptz, lembrete_em timestamptz);   -- controle da rotina (THOR)
create index if not exists ix_prot_reimp_numero on public.prot_reimpressao (numero);
create unique index if not exists ux_prot_reimp_aberta on public.prot_reimpressao (numero, filial, serie, doc) where resolvida_em is null;
alter table public.prot_reimpressao enable row level security;
revoke all on public.prot_reimpressao from anon, authenticated;

-- 2) LOG: aceite com pendência (notas que não chegaram impressas)
create or replace function public.prot_aceite_parcial(p_numero text, p_notas jsonb, p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(auth.jwt()->>'email'); v prot_protocolo; n jsonb; qtd int := 0; docs text := ''; mot text;
begin
  if not public.prot_pode_ver() then raise exception 'Sem acesso'; end if;
  if not public.prot_e_log() then raise exception 'O aceite com pendência é exclusivo do time de Logística'; end if;
  select * into v from prot_protocolo where numero = p_numero and situacao = 'ENVIADO';
  if v.numero is null then raise exception 'Protocolo % não encontrado', p_numero; end if;
  if p_notas is null or jsonb_array_length(p_notas) = 0 then raise exception 'Marque ao menos uma nota para reimpressão'; end if;
  mot := coalesce(nullif(btrim(p_motivo), ''), 'NF não impressa');
  for n in select * from jsonb_array_elements(p_notas) loop
    if not exists (select 1 from exped_protocolo_nf e where e.protocolo = p_numero and e.filial = n->>'filial'
                     and e.serie = n->>'serie' and e.doc = n->>'doc'
                     and public.prot_nota_visivel(e.filial, e.serie, e.doc, e.situacao)) then
      raise exception 'A NF % não pertence ao %', ltrim(n->>'doc', '0'), p_numero; end if;
    if not exists (select 1 from prot_reimpressao r where r.numero = p_numero and r.filial = n->>'filial' and r.serie = n->>'serie'
                     and r.doc = n->>'doc' and r.resolvida_em is null) then
      insert into prot_reimpressao (numero, filial, serie, doc, motivo, pedido_por)
      values (p_numero, n->>'filial', n->>'serie', n->>'doc', mot, v_email);
      qtd := qtd + 1; docs := docs || case when docs = '' then '' else ', ' end || ltrim(n->>'doc', '0');
    end if;
  end loop;
  if qtd > 0 then
    insert into prot_evento (numero, acao, usuario, detalhe)
    values (p_numero, 'ACEITE_PARCIAL', v_email, format('%s NF p/ reimpressão (%s): %s', qtd, mot, docs));
  end if;
  if v.ciencia_em is null then
    update prot_protocolo set ciencia_em = now(), ciencia_por = v_email, ciencia_via = 'APP', atualizado_em = now() where numero = p_numero;
  end if;
  return jsonb_build_object('numero', p_numero, 'notas', qtd);
end $$;

-- 3) Fiscal/Faturamento/Controladoria: reimpressão enviada à impressora da LOG
create or replace function public.prot_reimp_enviada(p_numero text, p_notas jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(auth.jwt()->>'email'); n jsonb; qtd int := 0; docs text := ''; k int;
begin
  if not public.prot_e_emissor() then raise exception 'Reimpressão enviada é exclusiva do Fiscal/Faturamento e da Controladoria'; end if;
  for n in select * from jsonb_array_elements(coalesce(p_notas, '[]'::jsonb)) loop
    update prot_reimpressao set enviada_por = v_email, enviada_em = now()
     where numero = p_numero and filial = n->>'filial' and serie = n->>'serie' and doc = n->>'doc'
       and resolvida_em is null and enviada_em is null;
    get diagnostics k = row_count;
    if k > 0 then qtd := qtd + 1; docs := docs || case when docs = '' then '' else ', ' end || ltrim(n->>'doc', '0'); end if;
  end loop;
  if qtd = 0 then raise exception 'Nenhuma nota pendente de reimpressão foi marcada'; end if;
  insert into prot_evento (numero, acao, usuario, detalhe) values (p_numero, 'REIMPRESSAO_ENVIADA', v_email, format('%s NF reimpressa(s): %s', qtd, docs));
  return jsonb_build_object('numero', p_numero, 'notas', qtd);
end $$;

-- 4) LOG: "Aceito s/ pendências" = prot_dar_aceite. O ÚLTIMO status sobrepõe o anterior: havendo aceite parcial depois do último
--    aceite desta pessoa, grava um novo ACEITE e encerra as pendências abertas do protocolo.
create or replace function public.prot_dar_aceite(p_numero text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(auth.jwt()->>'email'); v prot_protocolo; ja timestamptz; ult_parcial timestamptz; pend int;
begin
  if not public.prot_pode_ver() then raise exception 'Sem acesso'; end if;
  if not public.prot_e_log() then raise exception 'O aceite é exclusivo do time de Logística'; end if;
  select * into v from prot_protocolo where numero = p_numero and situacao = 'ENVIADO';
  if v.numero is null then raise exception 'Protocolo % não encontrado', p_numero; end if;
  select max(em) into ja from prot_evento where numero = p_numero and acao = 'ACEITE' and lower(usuario) = v_email;
  select max(em) into ult_parcial from prot_evento where numero = p_numero and acao = 'ACEITE_PARCIAL';
  select count(*) into pend from prot_reimpressao where numero = p_numero and resolvida_em is null;
  if ja is null or (ult_parcial is not null and ult_parcial > ja) or pend > 0 then
    insert into prot_evento (numero, acao, usuario, detalhe)
    values (p_numero, 'ACEITE', v_email, case when pend > 0 or ult_parcial is not null
            then format('aceito sem pendências no aplicativo (encerra %s pendência(s) de reimpressão)', pend) else 'aceite no aplicativo' end);
    ja := now();
    update prot_reimpressao set resolvida_por = v_email, resolvida_em = now() where numero = p_numero and resolvida_em is null;
  end if;
  if v.ciencia_em is null then
    update prot_protocolo set ciencia_em = now(), ciencia_por = v_email, ciencia_via = 'APP', atualizado_em = now() where numero = p_numero;
  end if;
  return jsonb_build_object('numero', p_numero, 'aceite_em', ja, 'aceite_por', v_email);
end $$;

-- 5) pendências de um protocolo (detalhe) — quem vê a aba vê
create or replace function public.prot_reimp_notas(p_numero text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_pode_ver() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'filial', r.filial, 'serie', r.serie, 'doc', r.doc, 'motivo', r.motivo, 'pedido_por', r.pedido_por, 'pedido_em', r.pedido_em,
           'enviada_por', r.enviada_por, 'enviada_em', r.enviada_em, 'resolvida_por', r.resolvida_por, 'resolvida_em', r.resolvida_em)
         order by r.pedido_em, r.doc), '[]'::jsonb) end
  from prot_reimpressao r where r.numero = p_numero
$$;

-- 6) lista: igual à 023 + 'aceite_status' (TOTAL | PARCIAL | null) + resumo das pendências abertas
create or replace function public.prot_lista(p_desde date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with lg as (select unnest(string_to_array(lower(replace(coalesce((select texto from prot_parametro where chave = 'DESTINO_LOG'), ''), ' ', '')), ';')) as email)
  select case when not public.prot_pode_ver() then '[]'::jsonb else coalesce(jsonb_agg(x order by x->>'numero' desc), '[]'::jsonb) end
  from (
    select jsonb_build_object('numero', p.numero, 'data', p.data_protocolo, 'tipo', p.tipo, 'gerado_por', p.gerado_por,
             'enviado_em', p.enviado_em, 'destinatarios', p.destinatarios, 'pdf_path', p.pdf_path,
             'ciencia_em', p.ciencia_em, 'ciencia_por', p.ciencia_por, 'ciencia_via', coalesce(p.ciencia_via, case when p.ciencia_em is not null then 'APP' end),
             'lembrete_em', p.lembrete_em,
             'leituras', (select coalesce(jsonb_agg(jsonb_build_object('usuario', l.usuario, 'em', l.em, 'via', l.via) order by l.em), '[]'::jsonb)
                          from (select distinct on (lower(e.usuario)) e.usuario, e.em,
                                       case when e.acao = 'CIENCIA_EMAIL' then 'EMAIL' when e.acao in ('ACEITE', 'ACEITE_PARCIAL') then 'ACEITE' else 'APP' end as via
                                from prot_evento e
                                where e.numero = p.numero and e.acao in ('CIENCIA', 'CIENCIA_EMAIL', 'ACEITE', 'ACEITE_PARCIAL') and coalesce(e.usuario, '') <> ''
                                order by lower(e.usuario), e.em) l),
             'para_log', exists (select 1 from lg where lg.email <> '' and lower(coalesce(p.destinatarios, '')) like '%' || lg.email || '%'),
             'aceites', (select coalesce(jsonb_agg(jsonb_build_object('usuario', a.usuario, 'em', a.em, 'via', a.via) order by a.em), '[]'::jsonb)
                          from (select distinct on (lower(e.usuario)) e.usuario, e.em,
                                       case when e.acao = 'CIENCIA_EMAIL' then 'EMAIL' else 'APP' end as via
                                from prot_evento e
                                where e.numero = p.numero and e.acao in ('ACEITE', 'ACEITE_PARCIAL', 'CIENCIA', 'CIENCIA_EMAIL')
                                  and lower(coalesce(e.usuario, '')) in (select email from lg where email <> '')
                                order by lower(e.usuario), e.em) a),
             -- ÚLTIMO status sobrepõe o anterior: aceite parcial mais recente que o último ACEITE (botão) = PARCIAL
             'aceite_status', (select case when max(e.em) filter (where e.acao = 'ACEITE_PARCIAL') is not null
                                             and max(e.em) filter (where e.acao = 'ACEITE_PARCIAL') > coalesce(max(e.em) filter (where e.acao = 'ACEITE'), '-infinity')
                                           then 'PARCIAL'
                                           when max(e.em) filter (where e.acao = 'ACEITE_PARCIAL') is not null then 'TOTAL_APOS_REIMPRESSAO' end
                               from prot_evento e where e.numero = p.numero and e.acao in ('ACEITE', 'ACEITE_PARCIAL')),
             'reimp', (select jsonb_build_object('pendentes', count(*), 'enviadas', count(*) filter (where r.enviada_em is not null),
                                                 'pedido_em', min(r.pedido_em), 'pedido_por', min(r.pedido_por),
                                                 'docs', string_agg(ltrim(r.doc, '0') || case when r.enviada_em is not null then ' ✓' else '' end, ', ' order by r.doc))
                       from prot_reimpressao r where r.numero = p.numero and r.resolvida_em is null),
             'nfs', count(n.doc) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)),
             'valor', coalesce(sum(n.valor) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)), 0),
             'ocultas', case when public.prot_e_emissor() then count(n.doc) filter (where not public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)) end,
             'horas_sem_ciencia', case when p.ciencia_em is null and p.enviado_em is not null
                                   then round(extract(epoch from now() - p.enviado_em) / 3600.0, 1) end) x
    from prot_protocolo p left join exped_protocolo_nf n on n.protocolo = p.numero
    where p.situacao = 'ENVIADO' and (p_desde is null or p.data_protocolo >= p_desde)
    group by p.numero) t
$$;

revoke execute on function public.prot_aceite_parcial(text, jsonb, text), public.prot_reimp_enviada(text, jsonb),
  public.prot_dar_aceite(text), public.prot_reimp_notas(text), public.prot_lista(date) from public, anon;
grant execute on function public.prot_aceite_parcial(text, jsonb, text), public.prot_reimp_enviada(text, jsonb),
  public.prot_dar_aceite(text), public.prot_reimp_notas(text), public.prot_lista(date) to authenticated;

-- conferência: tabela + funções novas e a lista com o status do aceite
select (select count(*) from pg_tables where schemaname = 'public' and tablename = 'prot_reimpressao' and rowsecurity) as tabela_reimpressao,
       (select count(*) from pg_proc where proname in ('prot_aceite_parcial', 'prot_reimp_enviada', 'prot_reimp_notas')) as funcoes_novas,
       (select count(*) from pg_proc where proname = 'prot_lista' and prosrc like '%aceite_status%') as lista_com_status,
       (select count(*) from pg_proc where proname = 'prot_dar_aceite' and prosrc like '%ult_parcial%') as aceite_sobrepoe;
