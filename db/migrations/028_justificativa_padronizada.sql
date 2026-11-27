-- =====================================================================================================
-- Dashboard Fat & LOG — migração 028 (27/11/2026) · JUSTIFICATIVA PADRONIZADA + CADASTRO PELA LOGÍSTICA
--                                                 + CONFERÊNCIA "NFS NÃO ENVIADA PARA LOGÍSTICA" × PROTOCOLO ON-LINE
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor, DEPOIS da 027.
-- Idempotente: pode rodar de novo sem estragar nada (a padronização só mexe em linha que ainda está fora da lista nova).
--
-- Pedido do Silvio (27/11/2026), fila "Notas sem data de entrega":
--   1) justificativa = SÓ a lista suspensa padronizada (8 itens abaixo). O texto livre (complemento) sai do campo;
--      o conteúdo atual é SOBRESCRITO e a parte cortada (motivo antigo + complemento) fica no HISTÓRICO imutável (migração 006:
--      o gatilho grava antes × depois). Observações / responsável / prazo / anexos NÃO mudam.
--   2) novas justificativas: cadastro pela coordenadora ou gerente de Logística (botão na tela) — parâmetro JUST_CADASTRADORES
--      (+ papel ADM). Nada é apagado: justificativa sai da lista por DESATIVAR (o histórico continua lendo o nome).
--   3) "NFS NÃO ENVIADA PARA LOGÍSTICA" dispara conferência no protocolo on-line (rotina da fila, 15 min): se a NF consta em
--      protocolo enviado à LOG, comunicado THOR ao time LOG pedindo para rever a classificação. O comunicado NASCE DESLIGADO
--      (JUST_NAO_ENVIADA_COMUNICA = NAO) até a prévia ser aprovada; a conferência e a marca na tela valem desde já.
-- Nada disso volta ao Protheus (base SOMENTE LEITURA).
-- =====================================================================================================

-- 1) Auditoria da lista de motivos ------------------------------------------------------------------------------
alter table dash_justificativa_opcao add column if not exists criado_por   text;
alter table dash_justificativa_opcao add column if not exists criado_em    timestamptz default now();
alter table dash_justificativa_opcao add column if not exists alterado_por text;
alter table dash_justificativa_opcao add column if not exists alterado_em  timestamptz;

create table if not exists dash_justificativa_opcao_log (       -- quem cadastrou / desativou / reativou (append-only)
  id        bigint generated always as identity primary key,
  codigo    text not null,
  acao      text not null,                                       -- CADASTROU | DESATIVOU | REATIVOU
  descricao text,
  usuario   text,
  em        timestamptz not null default now()
);
alter table dash_justificativa_opcao_log enable row level security;
drop policy if exists "dash_just_opcao_log leitura" on dash_justificativa_opcao_log;
create policy "dash_just_opcao_log leitura" on dash_justificativa_opcao_log for select to authenticated using (true);
revoke insert, update, delete, truncate on dash_justificativa_opcao_log from anon, authenticated;
grant select on dash_justificativa_opcao_log to authenticated;

-- 2) Lista padronizada (Silvio 27/11/2026) ------------------------------------------------------------------------
insert into dash_justificativa_opcao (codigo, descricao, ordem, ativo, pede_complemento, criado_por) values
  ('AG_EXPEDICAO',        'AG.EXPEDIÇÃO',                     10, true, false, 'padronização 028 (Silvio 27/11/2026)'),
  ('AG_CANCELAMENTO',     'AG.CANCELAMENTO',                  20, true, false, 'padronização 028 (Silvio 27/11/2026)'),
  ('AG_TRAT_COMERCIAL',   'AG.TRATATIVA COMERCIAL',           30, true, false, 'padronização 028 (Silvio 27/11/2026)'),
  ('AG_TRAT_FINANCEIRA',  'AG.TRATATIVA FINANCEIRA',          40, true, false, 'padronização 028 (Silvio 27/11/2026)'),
  ('EM_ROTA_ENTREGA',     'EM ROTA DE ENTREGA',               50, true, false, 'padronização 028 (Silvio 27/11/2026)'),
  ('ENTREGA_REALIZADA',   'ENTREGA REALIZADA',                60, true, false, 'padronização 028 (Silvio 27/11/2026)'),
  ('FAT_TRANSPORTADOR',   'FATURAMENTO TRANSPORTADOR',        70, true, false, 'padronização 028 (Silvio 27/11/2026)'),
  ('NFS_NAO_ENVIADA_LOG', 'NFS NÃO ENVIADA PARA LOGÍSTICA',   80, true, false, 'padronização 028 (Silvio 27/11/2026)')
on conflict (codigo) do nothing;

-- a lista antiga sai do combo (continua na tabela: o histórico lê o nome dela)
update dash_justificativa_opcao set ativo = false, alterado_por = 'padronização 028 (Silvio 27/11/2026)', alterado_em = now()
 where ativo and codigo in ('EM_ROTA','AGENDAMENTO','ENTREGUE_BAIXA','FUNCIONARIO_BAIXA','NAO_ENVIADA_LOG','SEM_REMESSA','REFAT_CANHOTO',
                            'DEVOLVIDA','AGUARD_DEVOLUCAO','TRATATIVA_COM','SINISTRO_AVARIA','NF_CANCELADA','OUTROS');

-- 3) Padronização das justificativas já informadas -----------------------------------------------------------------
--    O gatilho da 006 grava no histórico o ANTES (motivo antigo + complemento cortado) e o DEPOIS. Quem = a padronização.
--    "Outros" vai pelo texto do complemento; o que não se encaixa fica SEM justificativa para a Logística reclassificar.
update dash_justificativa_logistica l set
  justificativa = case l.justificativa
      when 'EM_ROTA'           then 'EM_ROTA_ENTREGA'
      when 'AGENDAMENTO'       then 'AG_EXPEDICAO'
      when 'ENTREGUE_BAIXA'    then 'ENTREGA_REALIZADA'
      when 'FUNCIONARIO_BAIXA' then 'ENTREGA_REALIZADA'
      when 'REFAT_CANHOTO'     then 'ENTREGA_REALIZADA'
      when 'NAO_ENVIADA_LOG'   then 'NFS_NAO_ENVIADA_LOG'
      when 'SEM_REMESSA'       then 'AG_CANCELAMENTO'
      when 'NF_CANCELADA'      then 'AG_CANCELAMENTO'
      -- devolução: o complemento diz o que de fato aconteceu (conferido nos 32 casos de 27/11/2026)
      when 'DEVOLVIDA' then case
          when l.complemento ~* 'DATA.*LAN[ÇC]ADA'                 then 'ENTREGA_REALIZADA'
          else 'AG_TRAT_COMERCIAL' end
      when 'AGUARD_DEVOLUCAO' then case
          when l.complemento ~* 'N[ÃA]O (FOI )?ENVIADA'            then 'NFS_NAO_ENVIADA_LOG'
          when l.complemento ~* 'FINANCEIR'                        then 'AG_TRAT_FINANCEIRA'
          when l.complemento ~* 'DATA.*LAN[ÇC]ADA'                 then 'ENTREGA_REALIZADA'
          else 'AG_TRAT_COMERCIAL' end
      when 'TRATATIVA_COM'     then 'AG_TRAT_COMERCIAL'
      when 'SINISTRO_AVARIA'   then 'FAT_TRANSPORTADOR'
      when 'OUTROS' then case
          when l.complemento ~* 'AGENDA|EXPEDI|COTA'   then 'AG_EXPEDICAO'
          when l.complemento ~* 'PAGAMENTO|FINANCEIR'  then 'AG_TRAT_FINANCEIRA'
          when l.complemento ~* 'COMERCIAL'            then 'AG_TRAT_COMERCIAL'
          when l.complemento ~* 'TRANSPORTADOR'        then 'FAT_TRANSPORTADOR'
          else null end
      else l.justificativa end,
  complemento = null,
  usuario     = 'padronização da lista (Silvio 27/11/2026)'
where (l.justificativa is not null and l.justificativa not in
        ('AG_EXPEDICAO','AG_CANCELAMENTO','AG_TRAT_COMERCIAL','AG_TRAT_FINANCEIRA','EM_ROTA_ENTREGA','ENTREGA_REALIZADA',
         'FAT_TRANSPORTADOR','NFS_NAO_ENVIADA_LOG')
        and exists (select 1 from dash_justificativa_opcao o where o.codigo = l.justificativa and not o.ativo))
   or l.complemento is not null;

-- 4) Cadastro de justificativas pela Logística --------------------------------------------------------------------
insert into prot_parametro (chave, texto, descricao) values
  ('JUST_CADASTRADORES', 'coord.logistica@amvox.com.br;gerente.logistica@amvox.com.br',
   'Quem cadastra/desativa justificativa na fila "Notas sem data de entrega" (além do papel ADM) — coordenadora e gerente de Logística'),
  ('JUST_NAO_ENVIADA_COMUNICA', 'NAO',
   'SIM = comunicado THOR ao time LOG quando a NF classificada "NFS NÃO ENVIADA PARA LOGÍSTICA" consta em protocolo enviado à LOG')
on conflict (chave) do nothing;

create or replace function dash_pode_cadastrar_justificativa() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(lower(auth.jwt() ->> 'email') = any (
           select lower(btrim(x)) from unnest(string_to_array(
             coalesce((select texto from prot_parametro where chave = 'JUST_CADASTRADORES'), ''), ';')) x where btrim(x) <> ''), false)
      or exists (select 1 from profiles where id = auth.uid() and papel = 'ADM')
$$;
revoke execute on function dash_pode_cadastrar_justificativa() from public, anon;
grant execute on function dash_pode_cadastrar_justificativa() to authenticated;

-- cadastra (ou reativa, se já existir com o mesmo nome) — devolve o código
create or replace function dash_just_cadastrar(p_descricao text) returns text
language plpgsql security definer set search_path = public as $$
declare d text := upper(btrim(regexp_replace(coalesce(p_descricao, ''), '\s+', ' ', 'g')));
        c text; ex record; quem text := coalesce(auth.jwt() ->> 'email', 'sistema');
begin
  if not dash_pode_cadastrar_justificativa() then
    raise exception 'Cadastro de justificativa: só a coordenadora ou o gerente de Logística';
  end if;
  if length(d) < 3 or length(d) > 80 then raise exception 'Descrição deve ter de 3 a 80 caracteres'; end if;
  select * into ex from dash_justificativa_opcao where upper(descricao) = d limit 1;
  if found then
    if ex.ativo then raise exception 'Já existe a justificativa "%"', ex.descricao; end if;
    update dash_justificativa_opcao set ativo = true, alterado_por = quem, alterado_em = now() where codigo = ex.codigo;
    insert into dash_justificativa_opcao_log (codigo, acao, descricao, usuario) values (ex.codigo, 'REATIVOU', ex.descricao, quem);
    return ex.codigo;
  end if;
  c := left(btrim(regexp_replace(translate(d, 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'AAAAAEEEEIIIIOOOOOUUUUC'), '[^A-Z0-9]+', '_', 'g'), '_'), 40);
  if c = '' or exists (select 1 from dash_justificativa_opcao where codigo = c) then
    c := left(c, 33) || '_' || to_char(now(), 'MMDDHH24MI');
  end if;
  insert into dash_justificativa_opcao (codigo, descricao, ordem, ativo, pede_complemento, criado_por, criado_em)
  values (c, d, coalesce((select max(ordem) from dash_justificativa_opcao where ordem < 900), 0) + 10, true, false, quem, now());
  insert into dash_justificativa_opcao_log (codigo, acao, descricao, usuario) values (c, 'CADASTROU', d, quem);
  return c;
end $$;
revoke execute on function dash_just_cadastrar(text) from public, anon;
grant execute on function dash_just_cadastrar(text) to authenticated;

-- desativa / reativa (nunca apaga: notas já classificadas e o histórico continuam lendo o nome)
create or replace function dash_just_ativar(p_codigo text, p_ativo boolean) returns void
language plpgsql security definer set search_path = public as $$
declare quem text := coalesce(auth.jwt() ->> 'email', 'sistema'); ex record;
begin
  if not dash_pode_cadastrar_justificativa() then
    raise exception 'Alterar a lista de justificativas: só a coordenadora ou o gerente de Logística';
  end if;
  select * into ex from dash_justificativa_opcao where codigo = p_codigo;
  if not found then raise exception 'Justificativa % não existe', p_codigo; end if;
  if ex.ativo = p_ativo then return; end if;
  update dash_justificativa_opcao set ativo = p_ativo, alterado_por = quem, alterado_em = now() where codigo = p_codigo;
  insert into dash_justificativa_opcao_log (codigo, acao, descricao, usuario)
  values (p_codigo, case when p_ativo then 'REATIVOU' else 'DESATIVOU' end, ex.descricao, quem);
end $$;
revoke execute on function dash_just_ativar(text, boolean) from public, anon;
grant execute on function dash_just_ativar(text, boolean) to authenticated;

-- a lista continua sem escrita direta pela tela (só pelas funções acima)
revoke insert, update, delete on dash_justificativa_opcao from anon, authenticated;

-- 5) Conferência "NFS NÃO ENVIADA PARA LOGÍSTICA" × protocolo on-line (gravada pela rotina da fila) ------------------
create table if not exists dash_just_conf_protocolo (
  filial           text not null,
  nf               text not null,
  serie            text not null,
  justificativa_em timestamptz not null,       -- updated_at da classificação conferida (reclassificou = confere de novo)
  classificado_por text,
  situacao         text not null,              -- PROTOCOLADA_LOG | PROTOCOLADA_SO_FISCAL | NAO_CONSTA
  protocolo        text,
  data_protocolo   date,
  aceite_por       text,
  aceite_em        timestamptz,
  aceite_via       text,
  conferido_em     timestamptz not null default now(),
  comunicado_em    timestamptz,                -- e-mail THOR ao time LOG (só PROTOCOLADA_LOG, com o comunicado ligado)
  primary key (filial, nf, serie, justificativa_em)
);
alter table dash_just_conf_protocolo enable row level security;
drop policy if exists "dash_just_conf leitura" on dash_just_conf_protocolo;
create policy "dash_just_conf leitura" on dash_just_conf_protocolo for select to authenticated using (true);
revoke insert, update, delete, truncate on dash_just_conf_protocolo from anon, authenticated;
grant select on dash_just_conf_protocolo to authenticated;

-- 6) Conferência ---------------------------------------------------------------------------------------------------
select (select count(*) from dash_justificativa_opcao where ativo)                                       as opcoes_ativas_8,
       (select count(*) from dash_justificativa_logistica l join dash_justificativa_opcao o on o.codigo = l.justificativa
         where not o.ativo)                                                                               as fora_da_lista_0,
       (select count(*) from dash_justificativa_logistica where complemento is not null)                  as com_complemento_0,
       (select count(*) from dash_justificativa_hist where usuario = 'padronização da lista (Silvio 27/11/2026)') as linhas_no_historico,
       (select texto from prot_parametro where chave = 'JUST_CADASTRADORES')                              as cadastradores;
