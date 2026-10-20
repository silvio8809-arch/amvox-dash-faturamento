-- =====================================================================================
-- Dashboard Fat & LOG — migração 014 (20/10/2026) · PROTOCOLO ON-LINE: venda para ÁREA DE SUFRAMA em vermelho
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 013. Idempotente.
--
-- Sugestão do time de Faturamento (Silvio 20/10/2026): marcar em vermelho, na aba Protocolos, as notas de cliente da área
-- de SUFRAMA (ZFM/ALC). Critério = INSCRIÇÃO SUFRAMA no cadastro do cliente (SA1.A1_SUFRAMA preenchido), copiada para
-- cli_cadastro.suframa pela carga horária de clientes. Teste em 120 dias (6.718 NF): o cadastro cobre 100% das notas com
-- tabela 227/228/229 e das notas com desconto ZF (F2_DESCZFR) — a tabela do pedido sozinha perderia 10 de 41.
-- =====================================================================================

-- 1) inscrição SUFRAMA no cadastro copiado do Protheus (a carga só manda o campo depois que a coluna existir)
alter table public.cli_cadastro add column if not exists suframa text;

-- 2) notas aptas (emissores) — + suframa (pelo cliente da nota no dash)
create or replace function public.prot_aptas() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_e_emissor() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'filial', a.filial, 'serie', a.serie, 'doc', a.doc, 'emissao', a.emissao, 'cliente', a.cliente, 'municipio', a.municipio,
           'uf', a.uf, 'depositos', a.depositos, 'tipo', case when a.origem = 'BON' then 'BONIF.' else 'VENDA' end, 'valor', a.valor,
           'situacao', a.situacao, 'motivo', a.motivo, 'atualizado_em', a.atualizado_em,
           'suframa', (select nullif(btrim(c.suframa), '') from dash_nf_saida d join cli_cadastro c on c.cod = d.cliente_cod and c.loja = d.cliente_loja
                        where d.filial = a.filial and d.serie = a.serie and d.nf = a.doc limit 1),
           'pedido', (select p.id from prot_pedido p where p.status in ('PENDENTE', 'RODANDO')
                        and p.notas @> jsonb_build_array(jsonb_build_object('filial', a.filial, 'serie', a.serie, 'doc', a.doc)) limit 1))
         order by a.emissao, a.doc), '[]'::jsonb) end
  from prot_apta a
  where not exists (select 1 from exped_protocolo_nf n where n.filial = a.filial and n.serie = a.serie and n.doc = a.doc)
$$;

-- 3) notas de um protocolo (todos que veem a aba) — + suframa
create or replace function public.prot_notas(p_numero text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.prot_pode_ver() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'filial', n.filial, 'serie', n.serie, 'doc', n.doc, 'emissao', n.emissao,
           'cliente', coalesce(nullif(btrim(c.nome), ''), n.cliente), 'uf', n.uf, 'suframa', nullif(btrim(c.suframa), ''),
           'depositos', n.depositos, 'tipo', case when n.origem = 'BON' then 'BONIF.' else 'VENDA' end, 'valor', n.valor,
           'status', d.status, 'dt_entrega', d.dt_entrega, 'transportadora', d.transportadora)
         order by n.emissao, n.doc), '[]'::jsonb) end
  from exped_protocolo_nf n join prot_protocolo p on p.numero = n.protocolo and p.situacao = 'ENVIADO'
  left join dash_nf_saida d on d.filial = n.filial and d.serie = n.serie and d.nf = n.doc
  left join cli_cadastro c on c.cod = d.cliente_cod and c.loja = d.cliente_loja
  where n.protocolo = p_numero and public.prot_nota_visivel(n.filial, n.serie, n.doc, n.situacao)
$$;

-- conferência
select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'cli_cadastro' and column_name = 'suframa') as coluna_suframa,
       (select count(*) from pg_proc where proname in ('prot_aptas', 'prot_notas') and prosrc like '%suframa%') as funcoes_com_suframa;
