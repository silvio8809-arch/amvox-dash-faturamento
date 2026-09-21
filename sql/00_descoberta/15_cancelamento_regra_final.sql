-- FASE 0 · 3.3 (FINAL) · regra de cancelamento validada
-- NOTA (excecao consciente a regra do D_E_L_E_T_): as consultas a SF3010 abaixo NAO filtram
-- D_E_L_E_T_ de proposito — o evento de cancelamento precisa ser visto mesmo quando a linha
-- correspondente foi excluida. E exatamente o que a SPEC 3.3 pede. A SF2 e consultada com o
-- D_E_L_E_T_ EXPOSTO como coluna (DEL), para medir o comportamento, nunca como filtro oculto.
-- Discriminador de SAIDA = F3_CFO iniciando em 5 ou 6 (F3_ENTRADA e data contabil, sempre preenchida)
DECLARE @DE12 CHAR(8); SET @DE12 = CONVERT(CHAR(8), DATEADD(MONTH,-12,GETDATE()), 112);

SELECT 'NF de SAIDA canceladas 12m' TESTE, COUNT(*) TOTAL,
       SUM(CASE WHEN F2.F2_DOC IS NULL THEN 1 ELSE 0 END) SEM_LINHA_SF2,
       SUM(CASE WHEN F2.DEL='*' THEN 1 ELSE 0 END) SF2_DELETADA,
       SUM(CASE WHEN F2.DEL='' THEN 1 ELSE 0 END) SF2_AINDA_ATIVA
FROM (SELECT DISTINCT F3_FILIAL FIL, F3_NFISCAL NF, F3_SERIE SER
      FROM SF3010 WHERE F3_DTCANC >= @DE12 AND LEFT(F3_CFO,1) IN ('5','6')) C
LEFT JOIN (SELECT F2_FILIAL FIL, F2_DOC, F2_SERIE, D_E_L_E_T_ DEL FROM SF2010) F2
       ON F2.FIL=C.FIL AND F2.F2_DOC=C.NF AND F2.F2_SERIE=C.SER;

-- as que continuam ATIVAS na SF2 (risco de contar como emitida): amostra
SELECT TOP 15 C.NF, C.SER, C.DTCANC, F2.F2_EMISSAO, CAST(F2.F2_VALFAT AS DECIMAL(18,2)) VALOR
FROM (SELECT DISTINCT F3_FILIAL FIL, F3_NFISCAL NF, F3_SERIE SER, F3_DTCANC DTCANC
      FROM SF3010 WHERE F3_DTCANC >= @DE12 AND LEFT(F3_CFO,1) IN ('5','6')) C
JOIN SF2010 F2 ON F2.F2_FILIAL=C.FIL AND F2.F2_DOC=C.NF AND F2.F2_SERIE=C.SER AND F2.D_E_L_E_T_=''
ORDER BY C.DTCANC DESC;
