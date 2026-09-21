-- FASE 0 (revisao 21/09) · a T.I. informou que o campo de entrega do GFE e GW1_DTENTR.
-- 1) a tabela existe? com que sufixo?
SELECT name TABELA, (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id=t.object_id) COLUNAS
FROM sys.tables t WHERE name LIKE 'GW1%' ORDER BY name;

-- 2) o campo existe? (dicionario + coluna fisica)
SELECT 'SX3' ORIGEM, RTRIM(X3_ARQUIVO) ARQ, RTRIM(X3_CAMPO) CAMPO, RTRIM(X3_TITULO) TITULO,
       RTRIM(X3_DESCRIC) DESCRICAO, X3_TIPO TIPO, X3_TAMANHO TAM
FROM SX3010 WHERE D_E_L_E_T_='' AND X3_ARQUIVO='GW1'
  AND (X3_CAMPO COLLATE Latin1_General_CI_AI LIKE '%ENTR%'
    OR X3_TITULO COLLATE Latin1_General_CI_AI LIKE '%ENTREG%')
ORDER BY X3_CAMPO;

-- 3) campos-chave da GW1 para amarrar com a NF
SELECT RTRIM(X3_CAMPO) CAMPO, RTRIM(X3_TITULO) TITULO, X3_TIPO TIPO, X3_TAMANHO TAM
FROM SX3010 WHERE D_E_L_E_T_='' AND X3_ARQUIVO='GW1'
  AND (X3_CAMPO COLLATE Latin1_General_CI_AI LIKE '%DOC%'
    OR X3_CAMPO COLLATE Latin1_General_CI_AI LIKE '%SERIE%'
    OR X3_CAMPO COLLATE Latin1_General_CI_AI LIKE '%NF%'
    OR X3_CAMPO COLLATE Latin1_General_CI_AI LIKE '%EMIS%'
    OR X3_CAMPO COLLATE Latin1_General_CI_AI LIKE '%FIL%')
ORDER BY X3_CAMPO;
