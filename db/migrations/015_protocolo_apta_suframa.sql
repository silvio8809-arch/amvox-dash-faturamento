-- =====================================================================================
-- Dashboard Fat & LOG — migração 015 (20/10/2026) · SUFRAMA gravado no próprio quadro de notas APTAS
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 014. Idempotente.
--
-- Por quê: na 014 a marca SUFRAMA das aptas vinha pelo cliente da nota no dash (dash_nf_saida); nota recém-emitida que
-- ainda não entrou no dash (ex.: 281598 DOMESTILAR/AP, 20/10) ficava sem a marca. Agora a rotina do protocolo grava a
-- inscrição (SA1.A1_SUFRAMA, lida do Protheus junto com a nota) em prot_apta.suframa; o dash fica só como reserva.
-- =====================================================================================

alter table public.prot_apta add column if not exists suframa text;

create or replace function public.prot_aptas() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_e_emissor() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'filial', a.filial, 'serie', a.serie, 'doc', a.doc, 'emissao', a.emissao, 'cliente', a.cliente, 'municipio', a.municipio,
           'uf', a.uf, 'depositos', a.depositos, 'tipo', case when a.origem = 'BON' then 'BONIF.' else 'VENDA' end, 'valor', a.valor,
           'situacao', a.situacao, 'motivo', a.motivo, 'atualizado_em', a.atualizado_em,
           'suframa', coalesce(nullif(btrim(a.suframa), ''),
                      (select nullif(btrim(c.suframa), '') from dash_nf_saida d join cli_cadastro c on c.cod = d.cliente_cod and c.loja = d.cliente_loja
                        where d.filial = a.filial and d.serie = a.serie and d.nf = a.doc limit 1)),
           'pedido', (select p.id from prot_pedido p where p.status in ('PENDENTE', 'RODANDO')
                        and p.notas @> jsonb_build_array(jsonb_build_object('filial', a.filial, 'serie', a.serie, 'doc', a.doc)) limit 1))
         order by a.emissao, a.doc), '[]'::jsonb) end
  from prot_apta a
  where not exists (select 1 from exped_protocolo_nf n where n.filial = a.filial and n.serie = a.serie and n.doc = a.doc)
$$;

-- conferência
select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'prot_apta' and column_name = 'suframa') as coluna_suframa_apta,
       (select count(*) from pg_proc where proname = 'prot_aptas' and prosrc like '%a.suframa%') as funcao_atualizada;
