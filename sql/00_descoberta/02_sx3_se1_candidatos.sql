-- FASE 0 · 3.1 · SE1: NAO houve match para "ENTREGA". Levantar TODOS os candidatos:
--   (a) todo campo de DATA da SE1
--   (b) todo campo customizado (E1_X*) da SE1
--   (c) colunas fisicas da SE1010 (o SX3 pode declarar campo inexistente e vice-versa)
SELECT 'a) datas na SE1 (SX3)' BLOCO, RTRIM(X3_CAMPO) CAMPO, RTRIM(X3_TITULO) TITULO,
       RTRIM(X3_DESCRIC) DESCRICAO, X3_TIPO TIPO, X3_TAMANHO TAM
FROM SX3010 WHERE D_E_L_E_T_='' AND X3_ARQUIVO='SE1' AND X3_TIPO='D'
ORDER BY X3_CAMPO;

SELECT 'b) customizados E1_X*' BLOCO, RTRIM(X3_CAMPO) CAMPO, RTRIM(X3_TITULO) TITULO,
       RTRIM(X3_DESCRIC) DESCRICAO, X3_TIPO TIPO, X3_TAMANHO TAM
FROM SX3010 WHERE D_E_L_E_T_='' AND X3_ARQUIVO='SE1' AND X3_CAMPO LIKE 'E1[_]X%'
ORDER BY X3_CAMPO;

SELECT 'c) colunas fisicas SE1010 tipo data/char8' BLOCO, c.name COLUNA, t.name TIPO, c.max_length TAM
FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id
WHERE c.object_id = OBJECT_ID('SE1010')
  AND (c.name LIKE '%DT%' OR c.name LIKE '%DATA%' OR c.name LIKE '%ENTR%' OR c.name LIKE 'E1[_]X%')
ORDER BY c.name;
