-- FASE 0 · GW1_DTENTR nao apareceu no SX3 por "entrega". Levantar TODOS os candidatos.
-- (a) GW1_DTENTR existe FISICAMENTE?
SELECT 'GW1_DTENTR existe fisicamente?' TESTE,
       (SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID('GW1010') AND name='GW1_DTENTR') ACHOU;

-- (b) TODOS os campos de data da GW1 no dicionario
SELECT 'SX3 datas GW1' BLOCO, RTRIM(X3_CAMPO) CAMPO, RTRIM(X3_TITULO) TITULO,
       RTRIM(X3_DESCRIC) DESCRICAO, X3_TIPO TIPO
FROM SX3010 WHERE D_E_L_E_T_='' AND X3_ARQUIVO='GW1' AND X3_TIPO='D' ORDER BY X3_CAMPO;

-- (c) TODAS as colunas fisicas da GW1010 com cara de data
SELECT 'colunas fisicas' BLOCO, c.name COLUNA, t.name TIPO, c.max_length TAM
FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id
WHERE c.object_id=OBJECT_ID('GW1010')
  AND (c.name LIKE '%DT%' OR c.name LIKE '%DAT%' OR c.name LIKE '%ENTR%')
ORDER BY c.name;

-- (d) outras tabelas GFE (GWx) que tenham campo de entrega
SELECT 'outras tabelas GFE' BLOCO, RTRIM(X3_ARQUIVO) ARQ, RTRIM(X3_CAMPO) CAMPO,
       RTRIM(X3_TITULO) TITULO, X3_TIPO TIPO
FROM SX3010 WHERE D_E_L_E_T_='' AND X3_ARQUIVO LIKE 'GW%'
  AND X3_TIPO='D'
  AND (X3_CAMPO COLLATE Latin1_General_CI_AI LIKE '%ENTR%'
    OR X3_TITULO COLLATE Latin1_General_CI_AI LIKE '%ENTREG%'
    OR X3_DESCRIC COLLATE Latin1_General_CI_AI LIKE '%ENTREG%')
ORDER BY X3_ARQUIVO, X3_CAMPO;
