-- FASE 0 · GWU_DTENT ("Dt Entrega") e GW1_DTPENT ("Data Prevista Entrega") sao os candidatos reais
SELECT name TABELA, (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id=t.object_id) COLS
FROM sys.tables t WHERE name LIKE 'GWU%' OR name LIKE 'GWF%' ORDER BY name;

-- campos da GWU (o que e a tabela e como amarra na NF)
SELECT RTRIM(X3_CAMPO) CAMPO, RTRIM(X3_TITULO) TITULO, RTRIM(X3_DESCRIC) DESCRICAO, X3_TIPO TIPO
FROM SX3010 WHERE D_E_L_E_T_='' AND X3_ARQUIVO='GWU' ORDER BY X3_CAMPO;
