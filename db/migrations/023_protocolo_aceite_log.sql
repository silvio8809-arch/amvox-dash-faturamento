-- =====================================================================================
-- 023 — ACEITE DA LOGÍSTICA NO APP (Silvio 06/11/2026): o e-mail do protocolo diz à LOG que ela precisa dar o aceite pela
-- confirmação de leitura do e-mail OU no aplicativo. Faltava o campo no app — só o time LOG (lista DESTINO_LOG) pode dar.
--   · prot_e_log()        = usuário logado está na lista DESTINO_LOG
--   · prot_dar_aceite()   = SÓ LOG; grava evento ACEITE (histórico imutável, um por pessoa) e, se o protocolo ainda não tinha
--                           ciência, registra a 1ª ciência (encerra os lembretes de 2 em 2 h, como a confirmação do e-mail)
--   · prot_lista()        = + 'para_log' (o protocolo foi enviado à LOG) e 'aceites' (aceites da LOG: botão no app OU
--                           confirmação de leitura do e-mail por alguém da lista DESTINO_LOG), 1º de cada pessoa, em ordem
-- Pode rodar de novo sem estragar nada.
-- =====================================================================================

create or replace function public.prot_e_log() returns boolean
language sql stable security definer set search_path = public as $$
  select lower(coalesce(auth.jwt()->>'email', '')) <> '' and lower(coalesce(auth.jwt()->>'email', '')) = any (
    string_to_array(lower(replace(coalesce((select texto from prot_parametro where chave = 'DESTINO_LOG'), ''), ' ', '')), ';'))
$$;

create or replace function public.prot_dar_aceite(p_numero text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(auth.jwt()->>'email'); v prot_protocolo; ja timestamptz;
begin
  if not public.prot_pode_ver() then raise exception 'Sem acesso'; end if;
  if not public.prot_e_log() then raise exception 'O aceite é exclusivo do time de Logística'; end if;
  select * into v from prot_protocolo where numero = p_numero and situacao = 'ENVIADO';
  if v.numero is null then raise exception 'Protocolo % não encontrado', p_numero; end if;
  select min(em) into ja from prot_evento where numero = p_numero and acao = 'ACEITE' and lower(usuario) = v_email;
  if ja is null then
    insert into prot_evento (numero, acao, usuario, detalhe) values (p_numero, 'ACEITE', v_email, 'aceite no aplicativo');
    ja := now();
  end if;
  if v.ciencia_em is null then
    update prot_protocolo set ciencia_em = now(), ciencia_por = v_email, ciencia_via = 'APP', atualizado_em = now()
     where numero = p_numero;
  end if;
  return jsonb_build_object('numero', p_numero, 'aceite_em', ja, 'aceite_por', v_email);
end $$;

-- lista: igual à 022 + para_log + aceites (+ ACEITE também conta como leitura na lista "quem leu")
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
                                       case when e.acao = 'CIENCIA_EMAIL' then 'EMAIL' when e.acao = 'ACEITE' then 'ACEITE' else 'APP' end as via
                                from prot_evento e
                                where e.numero = p.numero and e.acao in ('CIENCIA', 'CIENCIA_EMAIL', 'ACEITE') and coalesce(e.usuario, '') <> ''
                                order by lower(e.usuario), e.em) l),
             'para_log', exists (select 1 from lg where lg.email <> '' and lower(coalesce(p.destinatarios, '')) like '%' || lg.email || '%'),
             'aceites', (select coalesce(jsonb_agg(jsonb_build_object('usuario', a.usuario, 'em', a.em, 'via', a.via) order by a.em), '[]'::jsonb)
                          from (select distinct on (lower(e.usuario)) e.usuario, e.em,
                                       case when e.acao = 'CIENCIA_EMAIL' then 'EMAIL' else 'APP' end as via
                                from prot_evento e
                                where e.numero = p.numero and e.acao in ('ACEITE', 'CIENCIA', 'CIENCIA_EMAIL')
                                  and lower(coalesce(e.usuario, '')) in (select email from lg where email <> '')
                                order by lower(e.usuario), e.em) a),
             'nfs', count(n.doc) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)),
             'valor', coalesce(sum(n.valor) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)), 0),
             'ocultas', case when public.prot_e_emissor() then count(n.doc) filter (where not public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)) end,
             'horas_sem_ciencia', case when p.ciencia_em is null and p.enviado_em is not null
                                   then round(extract(epoch from now() - p.enviado_em) / 3600.0, 1) end) x
    from prot_protocolo p left join exped_protocolo_nf n on n.protocolo = p.numero
    where p.situacao = 'ENVIADO' and (p_desde is null or p.data_protocolo >= p_desde)
    group by p.numero) t
$$;

revoke execute on function public.prot_e_log(), public.prot_dar_aceite(text), public.prot_lista(date) from public, anon;
grant execute on function public.prot_e_log(), public.prot_dar_aceite(text), public.prot_lista(date) to authenticated;

-- conferência: funções novas, protocolos enviados à LOG e aceites/leituras da LOG já registrados
select (select count(*) from pg_proc where proname in ('prot_e_log', 'prot_dar_aceite')) as funcoes_novas,
       (select count(*) from pg_proc where proname = 'prot_lista' and prosrc like '%aceites%') as lista_com_aceite,
       (select count(*) from prot_protocolo p where p.situacao = 'ENVIADO' and lower(coalesce(p.destinatarios, '')) like '%logistica%') as protocolos_para_log,
       (select count(*) from prot_evento e where e.acao in ('ACEITE', 'CIENCIA', 'CIENCIA_EMAIL')
          and lower(e.usuario) = any (string_to_array(lower(replace((select texto from prot_parametro where chave = 'DESTINO_LOG'), ' ', '')), ';'))) as leituras_da_log;
