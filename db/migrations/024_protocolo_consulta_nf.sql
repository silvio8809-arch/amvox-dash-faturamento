-- =====================================================================================
-- 024 — CONSULTA POR NOTA na aba Protocolos (Silvio 06/11/2026, caso NF 282773: "por que essa nota não aparece em nenhum
-- protocolo? deve existir um campo para consultar por nota — os quadros são filtrados e é possível saber em que protocolo
-- a nota está, e demais informações").
-- prot_consulta_nf(p_nf) devolve, para cada nota com esse número (qualquer filial/série):
--   · dados da nota (Dash: dash_nf_saida; remessa de venda à ordem: dash_vo_remessa; ou o próprio protocolo/aptas)
--   · protocolos em que entrou (com situação; quem não é emissor só vê os visíveis — mesma regra da aba)
--   · venda à ordem: NF-mãe ⇄ remessas (a mãe não expede; quem expede é a remessa)
--   · SÓ EMISSORES (Controladoria/Faturamento): situação no quadro de aptas (APTA/RETIDA/SEGURADA + motivo), retenção
--     manual ativa e pedido de protocolo pendente — a Logística só vê o que foi liberado (regra de 20/10/2026)
-- Só leitura. Pode rodar de novo sem estragar nada.
-- =====================================================================================

create or replace function public.prot_consulta_nf(p_nf text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d text := lpad(regexp_replace(coalesce(p_nf, ''), '\D', '', 'g'), 9, '0'); emi boolean; r jsonb;
begin
  if not public.prot_pode_ver() then return '[]'::jsonb; end if;
  if d = '000000000' or length(d) > 9 then return '[]'::jsonb; end if;
  emi := public.prot_e_emissor();
  with chaves as (
    select filial, serie, nf as doc from dash_nf_saida where nf = d
    union select filial, serie, nf from dash_vo_remessa where nf = d
    union select filial, serie, doc from exped_protocolo_nf where doc = d
    union select filial, serie, doc from prot_apta where doc = d and emi)
  select coalesce(jsonb_agg(jsonb_build_object(
      'filial', k.filial, 'serie', k.serie, 'doc', k.doc,
      'emissao', coalesce(n.emissao::text, v.emissao::text, (select max(e.emissao)::text from exped_protocolo_nf e where e.filial = k.filial and e.serie = k.serie and e.doc = k.doc)),
      'cliente', coalesce(n.cliente_nome, v.cliente_nome, (select max(e.cliente) from exped_protocolo_nf e where e.filial = k.filial and e.serie = k.serie and e.doc = k.doc)),
      'uf', coalesce(n.uf, v.uf), 'cfop', n.cfop,
      'valor', coalesce(n.valor_faturado, v.valor_mercadoria),
      'status', coalesce(n.status, v.status), 'dt_entrega', coalesce(n.dt_entrega, v.dt_entrega),
      'transportadora', coalesce(n.transportadora, v.transportadora), 'romaneio', n.romaneio,
      'tipo', case when v.nf is not null then 'REMESSA_ORDEM' when coalesce(n.venda_ordem, false) then 'VENDA_ORDEM_MAE' else 'NORMAL' end,
      'nf_mae', v.nf_mae,
      'remessas', (select coalesce(jsonb_agg(jsonb_build_object('doc', x.nf, 'emissao', x.emissao, 'status', x.status,
                          'protocolos', (select coalesce(jsonb_agg(e.protocolo order by e.protocolo), '[]'::jsonb) from exped_protocolo_nf e
                                          where e.filial = x.filial and e.serie = x.serie and e.doc = x.nf
                                            and (emi or public.prot_nota_visivel(e.filial, e.serie, e.doc, e.situacao))))
                          order by x.nf), '[]'::jsonb)
                   from dash_vo_remessa x where x.filial_mae = k.filial and x.nf_mae = k.doc and x.serie_mae = k.serie),
      'protocolos', (select coalesce(jsonb_agg(jsonb_build_object('numero', e.protocolo, 'data', e.data_protocolo, 'situacao', e.situacao,
                          'visivel', public.prot_nota_visivel(e.filial, e.serie, e.doc, e.situacao)) order by e.protocolo), '[]'::jsonb)
                     from exped_protocolo_nf e where e.filial = k.filial and e.serie = k.serie and e.doc = k.doc
                       and (emi or public.prot_nota_visivel(e.filial, e.serie, e.doc, e.situacao))),
      'apta', case when emi then (select jsonb_build_object('situacao', a.situacao, 'motivo', a.motivo, 'atualizado_em', a.atualizado_em)
                                  from prot_apta a where a.filial = k.filial and a.serie = k.serie and a.doc = k.doc) end,
      'retencao', case when emi then (select jsonb_build_object('motivo', t.motivo, 'por', t.retido_por, 'em', t.retido_em)
                                      from prot_retencao t where t.filial = k.filial and t.serie = k.serie and t.doc = k.doc and t.liberado_em is null
                                      order by t.retido_em desc limit 1) end,
      'pedido', case when emi then (select jsonb_build_object('id', p.id, 'status', p.status, 'agendado_para', p.agendado_para)
                                    from prot_pedido p where p.status in ('PENDENTE', 'RODANDO', 'AGUARDANDO_APROVACAO')
                                      and p.notas @> jsonb_build_array(jsonb_build_object('filial', k.filial, 'serie', k.serie, 'doc', k.doc))
                                    order by p.id desc limit 1) end
    ) order by k.filial, k.serie), '[]'::jsonb) into r
  from chaves k
  left join dash_nf_saida n on n.filial = k.filial and n.serie = k.serie and n.nf = k.doc
  left join dash_vo_remessa v on v.filial = k.filial and v.serie = k.serie and v.nf = k.doc;
  return r;
end $$;

revoke execute on function public.prot_consulta_nf(text) from public, anon;
grant execute on function public.prot_consulta_nf(text) to authenticated;

-- conferência: função criada (o resultado da consulta depende do usuário logado — no editor, sem usuário, volta vazio)
select (select count(*) from pg_proc where proname = 'prot_consulta_nf') as funcao_criada;
