-- 022 — CIÊNCIA ACUMULADA (Silvio 04/11/2026): "caso haja mais de uma leitura do e-mail do envio do protocolo, a ciência tem
-- que ir acumulando a informação, de modo que seja possível provar não só quem leu primeiro, mas todos que leram".
-- O banco JÁ guarda cada leitura (prot_evento, imutável: CIENCIA = botão na aba · CIENCIA_EMAIL = confirmação de leitura,
-- uma por leitor); prot_protocolo.ciencia_em/ciencia_por continuam sendo a PRIMEIRA ciência. Aqui a lista passa a devolver
-- TODAS as leituras (primeira de cada pessoa, em ordem de hora), para a aba mostrar quem leu e quando.
create or replace function public.prot_lista(p_desde date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_pode_ver() then '[]'::jsonb else coalesce(jsonb_agg(x order by x->>'numero' desc), '[]'::jsonb) end
  from (
    select jsonb_build_object('numero', p.numero, 'data', p.data_protocolo, 'tipo', p.tipo, 'gerado_por', p.gerado_por,
             'enviado_em', p.enviado_em, 'destinatarios', p.destinatarios, 'pdf_path', p.pdf_path,
             'ciencia_em', p.ciencia_em, 'ciencia_por', p.ciencia_por, 'ciencia_via', coalesce(p.ciencia_via, case when p.ciencia_em is not null then 'APP' end),
             'lembrete_em', p.lembrete_em,
             'leituras', (select coalesce(jsonb_agg(jsonb_build_object('usuario', l.usuario, 'em', l.em, 'via', l.via) order by l.em), '[]'::jsonb)
                          from (select distinct on (lower(e.usuario)) e.usuario, e.em,
                                       case when e.acao = 'CIENCIA_EMAIL' then 'EMAIL' else 'APP' end as via
                                from prot_evento e
                                where e.numero = p.numero and e.acao in ('CIENCIA', 'CIENCIA_EMAIL') and coalesce(e.usuario, '') <> ''
                                order by lower(e.usuario), e.em) l),
             'nfs', count(n.doc) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)),
             'valor', coalesce(sum(n.valor) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)), 0),
             'ocultas', case when public.prot_e_emissor() then count(n.doc) filter (where not public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)) end,
             'horas_sem_ciencia', case when p.ciencia_em is null and p.enviado_em is not null
                                   then round(extract(epoch from now() - p.enviado_em) / 3600.0, 1) end) x
    from prot_protocolo p left join exped_protocolo_nf n on n.protocolo = p.numero
    where p.situacao = 'ENVIADO' and (p_desde is null or p.data_protocolo >= p_desde)
    group by p.numero) t
$$;
revoke execute on function public.prot_lista(date) from public, anon;
grant execute on function public.prot_lista(date) to authenticated;

-- conferência: a lista nova devolve as leituras; total de leitores distintos registrados
select (select count(*) from pg_proc where proname = 'prot_lista' and prosrc like '%leituras%') as lista_com_leituras,
       (select count(distinct (numero, lower(usuario))) from prot_evento where acao in ('CIENCIA', 'CIENCIA_EMAIL')) as leituras_registradas;
