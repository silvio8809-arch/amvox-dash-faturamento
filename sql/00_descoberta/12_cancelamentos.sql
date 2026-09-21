-- FASE 0 · 3.3 · regra de cancelamento
-- NOTA (excecao consciente a regra do D_E_L_E_T_): as consultas a SF3010 abaixo NAO filtram
-- D_E_L_E_T_ de proposito — o evento de cancelamento precisa ser visto mesmo quando a linha
-- correspondente foi excluida. E exatamente o que a SPEC 3.3 pede. A SF2 e consultada com o
-- D_E_L_E_T_ EXPOSTO como coluna (DEL), para medir o comportamento, nunca como filtro oculto.
DECLARE @DE12 CHAR(8); SET @DE12 = CONVERT(CHAR(8), DATEADD(MONTH,-12,GETDATE()), 112);

-- (a) amostra do SPEC
SELECT TOP 10 F3_NFISCAL, F3_SERIE, F3_EMISSAO, F3_DTCANC, F3_CLIEFOR, F3_VALCONT
FROM SF3010 WHERE F3_DTCANC <> '' ORDER BY F3_DTCANC DESC;

-- (b) volume de cancelamentos por mes (SF3, sem filtro de D_E_L_E_T_ para nao perder o evento)
SELECT LEFT(F3_DTCANC,6) ANOMES_CANC, COUNT(DISTINCT F3_NFISCAL+'|'+F3_SERIE) NF_CANCELADAS
FROM SF3010 WHERE F3_DTCANC >= @DE12 GROUP BY LEFT(F3_DTCANC,6) ORDER BY ANOMES_CANC;

-- (c) TESTE DA REGRA: a NF cancelada esta deletada na SF2? (D_E_L_E_T_='*')
SELECT 'NF com F3_DTCANC nos 12m' TESTE,
       COUNT(*) TOTAL_NF_CANC,
       SUM(CASE WHEN F2.F2_DOC IS NULL THEN 1 ELSE 0 END) SEM_LINHA_NA_SF2,
       SUM(CASE WHEN F2.DEL = '*' THEN 1 ELSE 0 END) NA_SF2_DELETADA,
       SUM(CASE WHEN F2.DEL = ''  THEN 1 ELSE 0 END) NA_SF2_ATIVA
FROM (SELECT DISTINCT F3_FILIAL FIL, F3_NFISCAL NF, F3_SERIE SER
      FROM SF3010 WHERE F3_DTCANC >= @DE12) C
LEFT JOIN (SELECT F2_FILIAL FIL, F2_DOC, F2_SERIE, D_E_L_E_T_ DEL FROM SF2010) F2
       ON F2.FIL=C.FIL AND F2.F2_DOC=C.NF AND F2.F2_SERIE=C.SER;

-- (d) existe tabela de protocolo NF-e (TSS)?
SELECT name TABELA FROM sys.tables
WHERE name LIKE 'SPED%' OR name LIKE 'CTE%' OR name LIKE '%NFE%' ORDER BY name;
