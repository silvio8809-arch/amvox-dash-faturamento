-- =====================================================================================
-- Dashboard Fat & LOG — migração 027 (23/11/2026) · VENDA RETIDA POR BONIFICAÇÃO PENDENTE
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 026. Idempotente.
--
-- Pedido do Gerente Comercial (via Silvio, 23/11/2026): o cliente só aceita receber a compra JUNTO com a bonificação.
-- NF de VENDA não vai para expedição enquanto o MESMO cliente+loja tiver pedido de BONIFICAÇÃO sem decisão.
--   · Bonificação APROVADA = o 1º que acontecer: NF emitida para o pedido BON OU C5_XAPRSTA = 'A' (app Redes/SFA → Protheus).
--   · PENDENTE = C5_XAPRSTA 'P' sem NF · REPROVADA = C5_XAPRSTA 'R' ou C5_XESTPED 'RP' · sem corte de data (vigência).
--   · A nota aparece no quadro de aptas SEM permitir vínculo a protocolo:
--       BONIF_PENDENTE  → "Venda c/ Bonf. Pendente Liberação Pedidos: X, Y, Z"
--       BONIF_REPROVADA → "Venda c/ Bonf. Reprovada — aguardando Comercial: Pedidos X"
--   · Bonificação aprovada → a rotina da fila gera protocolo AUTOMÁTICO à LOG (sem aprovação do Fiscal).
--   · Saída manual: "Liberar" com justificativa (Controladoria/Faturamento) — o(s) pedido(s) BON citados deixam de reter.
-- Quem calcula é a rotina do Mac (rotina_protocolo_expedicao.py, lê o Protheus); o banco guarda e trava.
-- =====================================================================================

-- 1) quadro de aptas: duas situações novas + detalhe dos pedidos de bonificação
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.prot_apta'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%situacao%'
  loop
    execute format('alter table public.prot_apta drop constraint %I', c);
  end loop;
end $$;
alter table public.prot_apta add constraint prot_apta_situacao_check
  check (situacao in ('APTA', 'RETIDA', 'SEGURADA', 'BONIF_PENDENTE', 'BONIF_REPROVADA'));
alter table public.prot_apta add column if not exists bonif jsonb;

-- 2) controle por NF de venda retida (log dos avisos; só a rotina grava — service_role)
create table if not exists public.prot_bonif_venda (
  filial text not null, serie text not null, doc text not null,
  cliente text, cli_cod text, cli_loja text, emissao date, valor numeric,
  pedido_venda text, gerente_cod text, gerente_nome text, gerente_email text,
  situacao text not null check (situacao in ('PENDENTE', 'REPROVADA', 'LIBERADA', 'LIBERADA_MANUAL', 'ENCERRADA')),
  pedidos jsonb not null default '[]'::jsonb,          -- [{filial, pedido, emissao, valor, status}] da última leitura
  retida_em timestamptz not null default now(),
  aviso_controladoria_em timestamptz,                  -- (a) 1º aviso: "falta você aprovar/reprovar"
  aviso_gerente_em timestamptz,                        -- (b) última posição diária ao gerente (Cc LOG)
  aviso_reprovada_em timestamptz,                      -- (d) reprovada → gerente, Cc Comercial
  liberada_em timestamptz, liberada_pedidos jsonb,     -- (c) bonificação aprovada → protocolo automático
  liberada_prot_pedido bigint, liberada_protocolo text,
  liberacao_manual_por text, liberacao_manual_em timestamptz, liberacao_manual_motivo text,
  encerrada_motivo text,
  atualizado_em timestamptz not null default now(),
  primary key (filial, serie, doc));
alter table public.prot_bonif_venda enable row level security;
revoke all on public.prot_bonif_venda from anon, authenticated;

-- 3) parâmetros (liga/desliga e destinatários) — Silvio altera aqui
--    A regra NASCE DESLIGADA: o Run não retém nada nem envia e-mail. Ligar depois de aprovar as prévias dos comunicados:
--    update public.prot_parametro set texto = 'SIM' where chave = 'BONIF_VENDA_ATIVA';
insert into public.prot_parametro (chave, texto, descricao) values
  ('BONIF_VENDA_ATIVA', 'NÃO', 'SIM = NF de venda com pedido de bonificação pendente/reprovado do mesmo cliente+loja fica fora do protocolo (Silvio 23/11/2026); NÃO = desliga a regra'),
  ('BONIF_AVISO_CONTROLADORIA', 'gerente.contabil@amvox.com.br', 'Quem recebe o 1º aviso de venda retida ("falta você aprovar/reprovar") e a posição das notas sem gerente cadastrado'),
  ('BONIF_REPROV_CC', 'vendas@amvox.com.br;comercial3@amvox.com.br;comercial@amvox.com.br', 'Cópia do aviso de bonificação REPROVADA (Afonso, Samuel, Fernanda — Silvio 23/11/2026)'),
  ('BONIF_GERENTE_IGNORAR', '000021', 'Códigos SA3 que NÃO são gerente de vendas (000021 = REISTAR/expedicaonfe@) — tratados como "sem gerente"')
on conflict (chave) do nothing;

-- 4) liberação manual (Controladoria/Faturamento) — justificativa obrigatória
create or replace function public.prot_liberar_venda_bonif(p_filial text, p_serie text, p_doc text, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.prot_e_emissor() then raise exception 'Só Controladoria e Faturamento liberam a venda retida por bonificação'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Informe a justificativa (ex.: Comercial confirmou com o cliente a entrega sem a bonificação)';
  end if;
  update prot_bonif_venda set situacao = 'LIBERADA_MANUAL', liberacao_manual_por = auth.jwt()->>'email', liberacao_manual_em = now(),
         liberacao_manual_motivo = btrim(p_motivo), atualizado_em = now()
   where filial = p_filial and serie = p_serie and doc = p_doc and situacao in ('PENDENTE', 'REPROVADA');
  if not found then raise exception 'A NF % não está retida por bonificação (atualize a tela)', ltrim(p_doc, '0'); end if;
  update prot_apta set situacao = 'APTA',
         motivo = format('Liberada por %s: %s (venda com bonificação)', split_part(coalesce(auth.jwt()->>'email', '?'), '@', 1), btrim(p_motivo))
   where filial = p_filial and serie = p_serie and doc = p_doc and situacao in ('BONIF_PENDENTE', 'BONIF_REPROVADA');
  return jsonb_build_object('liberada', p_doc);
end $$;
revoke execute on function public.prot_liberar_venda_bonif(text, text, text, text) from public, anon;
grant execute on function public.prot_liberar_venda_bonif(text, text, text, text) to authenticated;

-- 5) aprovar o rascunho do dia recusa nota retida por bonificação (o rascunho pode ter sido montado antes do pedido BON)
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
      or exists (select 1 from prot_apta a where a.filial = x.filial and a.serie = x.serie and a.doc = x.doc
                    and a.situacao in ('BONIF_PENDENTE', 'BONIF_REPROVADA'))                              -- 027
      or exists (select 1 from prot_pedido o where o.id <> p_id and o.status in ('PENDENTE', 'RODANDO')
                   and o.notas @> jsonb_build_array(jsonb_build_object('filial', x.filial, 'serie', x.serie, 'doc', x.doc)));
  if v_fora is not null then raise exception 'NF % não pode ir neste protocolo (fora do rascunho, já protocolada, retida — inclusive por bonificação pendente — ou em outro pedido) — atualize a tela', v_fora; end if;
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
-- (prot_solicitar já só aceita situacao APTA — BONIF_* fica de fora sem mudança)

-- conferência
select pg_get_constraintdef(oid) as regra_situacao from pg_constraint
 where conrelid = 'public.prot_apta'::regclass and conname = 'prot_apta_situacao_check';
select (select count(*) from information_schema.tables where table_name = 'prot_bonif_venda') as tabela_nova,
       (select count(*) from prot_parametro where chave like 'BONIF_%') as parametros_bonif,
       (select count(*) from pg_proc where proname = 'prot_liberar_venda_bonif') as funcao_liberar;
