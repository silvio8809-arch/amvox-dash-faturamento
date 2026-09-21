-- FASE 0 · ambiente: sufixo de tabela e filiais (SPEC 0 / 3)
-- Somente leitura.
SELECT 'sufixo 010 existe' CHECAGEM,
       (SELECT COUNT(*) FROM sys.tables WHERE name = 'SF2010') SF2010,
       (SELECT COUNT(*) FROM sys.tables WHERE name = 'SF1010') SF1010,
       (SELECT COUNT(*) FROM sys.tables WHERE name = 'SE1010') SE1010,
       (SELECT COUNT(*) FROM sys.tables WHERE name = 'SC5010') SC5010,
       (SELECT COUNT(*) FROM sys.tables WHERE name = 'SF3010') SF3010,
       (SELECT COUNT(*) FROM sys.tables WHERE name = 'SX3010') SX3010;

-- outros sufixos das mesmas tabelas (indica mais de uma empresa no banco)
SELECT name TABELA FROM sys.tables
WHERE name LIKE 'SF2[0-9][0-9][0-9]' OR name LIKE 'SF1[0-9][0-9][0-9]'
   OR name LIKE 'SE1[0-9][0-9][0-9]' OR name LIKE 'SC5[0-9][0-9][0-9]'
ORDER BY name;

-- filiais realmente presentes na SF2 (ultimos 12 meses)
DECLARE @DE CHAR(8); SET @DE = CONVERT(CHAR(8), DATEADD(MONTH,-12,GETDATE()), 112);
SELECT F2_FILIAL FILIAL, COUNT(*) QTD_NF, MIN(F2_EMISSAO) PRIMEIRA, MAX(F2_EMISSAO) ULTIMA
FROM SF2010 WHERE D_E_L_E_T_ = '' AND F2_EMISSAO >= @DE
GROUP BY F2_FILIAL ORDER BY QTD_NF DESC;
