-- =====================================================================================================
-- Dashboard Fat & LOG — migração 029 (27/11/2026) · AJUSTE DO DE-PARA DA PADRONIZAÇÃO (028)
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez, DEPOIS da 028. Idempotente.
--
-- A 028 rodada no banco usou o de-para v1: "Aguardando devolução" e "Devolvida" foram TODAS para AG.TRATATIVA COMERCIAL.
-- O de-para refinado (o que está no arquivo da 028 publicado) lê o complemento antigo dessas notas:
--   "NF não (foi) enviada…"        → NFS NÃO ENVIADA PARA LOGÍSTICA
--   "… financeira"                 → AG.TRATATIVA FINANCEIRA
--   "Romaneio … data … lançada…"   → ENTREGA REALIZADA
-- O complemento antigo vem do HISTÓRICO da padronização (complemento_anterior). Só mexe na nota que continua como a
-- padronização deixou (ninguém da LOG alterou depois). Simulação de 27/11/2026: 8 notas — 258221 e 251662 (NFS NÃO ENVIADA),
-- 263153 (AG.TRAT. FINANCEIRA), 258781, 258768, 258715, 258764 e 258218 (ENTREGA REALIZADA). O gatilho registra no histórico.
-- =====================================================================================================

with ult as (
  select distinct on (h.filial, h.nf, h.serie) h.filial, h.nf, h.serie,
         h.justificativa_anterior as ja, coalesce(h.complemento_anterior, '') as ca
    from dash_justificativa_hist h
   where h.usuario = 'padronização da lista (Silvio 27/11/2026)' and h.acao = 'ALTEROU'
   order by h.filial, h.nf, h.serie, h.id desc
), alvo as (
  select u.filial, u.nf, u.serie,
         case when u.ja = 'AGUARD_DEVOLUCAO' and u.ca ~* 'N[ÃA]O (FOI )?ENVIADA' then 'NFS_NAO_ENVIADA_LOG'
              when u.ja = 'AGUARD_DEVOLUCAO' and u.ca ~* 'FINANCEIR'             then 'AG_TRAT_FINANCEIRA'
              when u.ca ~* 'DATA.*LAN[ÇC]ADA'                                     then 'ENTREGA_REALIZADA' end as novo
    from ult u
   where u.ja in ('AGUARD_DEVOLUCAO', 'DEVOLVIDA')
)
update dash_justificativa_logistica l
   set justificativa = a.novo,
       usuario       = 'padronização da lista — ajuste do de-para (Silvio 27/11/2026)'
  from alvo a
 where a.novo is not null
   and l.filial = a.filial and l.nf = a.nf and l.serie = a.serie
   and l.justificativa = 'AG_TRAT_COMERCIAL'
   and l.usuario = 'padronização da lista (Silvio 27/11/2026)';   -- intocada desde a padronização

-- Conferência: esperado 8 notas ajustadas · NFS NÃO ENVIADA = 14 · AG.TRAT. COMERCIAL = 30
select (select count(*) from dash_justificativa_logistica
         where usuario = 'padronização da lista — ajuste do de-para (Silvio 27/11/2026)')        as ajustadas_8,
       (select count(*) from dash_justificativa_logistica where justificativa = 'NFS_NAO_ENVIADA_LOG') as nfs_nao_enviada_14,
       (select count(*) from dash_justificativa_logistica where justificativa = 'AG_TRAT_COMERCIAL')   as ag_trat_comercial_30;
