-- FASE 0 · conferir se os campos candidatos existem FISICAMENTE (SX3 pode declarar campo ausente)
SELECT 'SF1010' TABELA, c.name COLUNA, t.name TIPO, c.max_length TAM
FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id
WHERE c.object_id=OBJECT_ID('SF1010')
  AND c.name IN ('F1_MOTIVO','F1_MOTRET','F1_HISTRET','F1_MENNOTA','F1_MENPAD','F1_DEVMERC','F1_TIPO','F1_ESPECIE')
UNION ALL
SELECT 'SC5010', c.name, t.name, c.max_length
FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id
WHERE c.object_id=OBJECT_ID('SC5010')
  AND c.name IN ('C5_MENNOTA','C5_OBS','C5_COMENT','C5_MENPAD','C5_XMPOBS')
UNION ALL
SELECT 'SF2010', c.name, t.name, c.max_length
FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id
WHERE c.object_id=OBJECT_ID('SF2010') AND c.name IN ('F2_DTENTR','F2_VALFAT','F2_DOC','F2_SERIE')
ORDER BY TABELA, COLUNA;
