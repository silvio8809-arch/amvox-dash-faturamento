-- FASE 0 (revisao 21/09) · o Silvio informou que a LOGISTICA preenche, via GFE, um campo
-- CUSTOMIZADO no cabecalho da NF (alem do campo da SE1). Existe? (o campo CT5_LP nao existe:
-- a CT5 usa CT5_LANPAD com 3 posicoes, entao "008820" e LOTE contabil, nao LP)
SELECT RTRIM(X3_CAMPO) CAMPO, RTRIM(X3_TITULO) TITULO, RTRIM(X3_DESCRIC) DESCRICAO, X3_TIPO TIPO, X3_TAMANHO TAM
FROM SX3010 WHERE D_E_L_E_T_='' AND X3_ARQUIVO='SF2' AND X3_CAMPO LIKE 'F2[_]X%'
ORDER BY X3_CAMPO;

-- colunas fisicas customizadas da SF2010 (o SX3 pode nao declarar campo criado por integracao)
SELECT c.name COLUNA, t.name TIPO, c.max_length TAM
FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id
WHERE c.object_id=OBJECT_ID('SF2010') AND c.name LIKE 'F2[_]X%' ORDER BY c.name;
