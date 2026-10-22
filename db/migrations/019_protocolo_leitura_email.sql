-- =====================================================================================
-- Dashboard Fat & LOG — migração 019 (22/10/2026) · CONFIRMAÇÃO DE LEITURA = CIÊNCIA + LEMBRETE + MODO TESTE de e-mail
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 018. Idempotente.
--
-- Pedido do Silvio (22/10/2026):
--   · "pedir confirmação de leitura = regra universal, todos os e-mails de notificação" (a rotina marca a opção no Outlook);
--   · a confirmação de leitura vira CIÊNCIA na central: "Ciência pelo e-mail de notificação — dd/mm hh:mm, Fulano";
--   · "só envia e-mail de notificação [lembrete] caso o protocolo não tenha NENHUMA confirmação de leitura; se um ler e
--     confirmar, não enviar notificação adicional nem para a pessoa nem para ninguém" → UM lembrete por protocolo, depois de
--     CIENCIA_HORAS sem nenhuma ciência (e-mail ou botão), só para protocolos enviados a partir de LEITURA_DESDE;
--   · TESTES: todo e-mail do protocolo (alerta, protocolo, lembrete) vai só para EMAIL_TESTE, mostrando para quem seria.
--     Para voltar ao envio real: update prot_parametro set texto = '' where chave = 'EMAIL_TESTE';
-- =====================================================================================

insert into public.prot_parametro (chave, texto, descricao) values
  ('EMAIL_TESTE', 'gerente.contabil@amvox.com.br', 'MODO TESTE (Silvio 22/10/2026): preenchido = todo e-mail do protocolo (alerta, protocolo, lembrete) vai SÓ para este e-mail, com a lista de quem receberia; vazio = envio real'),
  ('LEITURA_DESDE', to_char(now() at time zone 'America/Bahia', 'YYYY-MM-DD HH24:MI'), 'Protocolos enviados a partir desta data/hora pedem confirmação de leitura e recebem lembrete se ninguém confirmar em CIENCIA_HORAS')
on conflict (chave) do nothing;

alter table public.prot_protocolo add column if not exists ciencia_via text;        -- APP (botão) | EMAIL (confirmação de leitura)
alter table public.prot_protocolo add column if not exists lembrete_em timestamptz;   -- lembrete enviado (um por protocolo)

create or replace function public.prot_lista(p_desde date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_pode_ver() then '[]'::jsonb else coalesce(jsonb_agg(x order by x->>'numero' desc), '[]'::jsonb) end
  from (
    select jsonb_build_object('numero', p.numero, 'data', p.data_protocolo, 'tipo', p.tipo, 'gerado_por', p.gerado_por,
             'enviado_em', p.enviado_em, 'destinatarios', p.destinatarios, 'pdf_path', p.pdf_path,
             'ciencia_em', p.ciencia_em, 'ciencia_por', p.ciencia_por, 'ciencia_via', coalesce(p.ciencia_via, case when p.ciencia_em is not null then 'APP' end),
             'lembrete_em', p.lembrete_em,
             'nfs', count(n.doc) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)),
             'valor', coalesce(sum(n.valor) filter (where public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)), 0),
             'ocultas', case when public.prot_e_emissor() then count(n.doc) filter (where not public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)) end,
             'horas_sem_ciencia', case when p.ciencia_em is null and p.enviado_em is not null
                                   then round(extract(epoch from now() - p.enviado_em) / 3600.0, 1) end) x
    from prot_protocolo p left join exped_protocolo_nf n on n.protocolo = p.numero
    where p.situacao = 'ENVIADO' and (p_desde is null or p.data_protocolo >= p_desde)
    group by p.numero) t
$$;

-- conferência
select (select texto from prot_parametro where chave = 'EMAIL_TESTE') as email_teste,
       (select texto from prot_parametro where chave = 'LEITURA_DESDE') as leitura_desde,
       (select count(*) from information_schema.columns where table_name = 'prot_protocolo' and column_name in ('ciencia_via', 'lembrete_em')) as colunas,
       (select count(*) from pg_proc where proname = 'prot_lista' and prosrc like '%ciencia_via%') as lista_ok;
