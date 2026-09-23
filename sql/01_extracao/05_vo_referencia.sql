-- =====================================================================================
-- FASE 1 · EXTRAÇÃO 05 — VENDA À ORDEM: ÍNDICE DAS NF QUE UMA REMESSA PODE CITAR
-- Não vai para o cache: serve só para o ETL resolver o texto "REF A NF 222423" e dizer
-- QUE nota é essa. SOMENTE LEITURA.
--
--  por que um índice amplo, e não só as mães 5118/6118:
--    medido em 23/09/2026, as remessas citam também
--      · 5119/6119 — venda à ordem de mercadoria de terceiros → é MÃE legítima;
--      · 5910/6910 — BONIFICAÇÃO "à ordem" → não é faturamento, vira sinalização;
--      · 5101/6101/6109 — venda comum → o vínculo existe mas a mãe não é de venda à ordem.
--    Para saber qual é qual, o índice traz qualquer NF de saída do período, com o CFOP.
--  janela ......... começa 180 dias ANTES da janela da remessa: a mãe é sempre anterior.
-- =====================================================================================
DECLARE @DATADE CHAR(8), @DATAATE CHAR(8);
SET @DATADE  = CONVERT(CHAR(8), DATEADD(DAY,-120,GETDATE()), 112);   -- janela do ETL
SET @DATAATE = CONVERT(CHAR(8), GETDATE(), 112);

WITH NFS AS (
SELECT  RTRIM(SD2.D2_FILIAL)                 FILIAL,
        RTRIM(SD2.D2_DOC)                    NF,
        RTRIM(SD2.D2_SERIE)                  SERIE,
        MIN(SD2.D2_EMISSAO)                  EMISSAO,
        -- mãe de venda à ordem = algum item com CFOP 5118/6118/5119/6119
        MAX(CASE WHEN RTRIM(SD2.D2_CF) IN ('5118','6118','5119','6119') THEN 1 ELSE 0 END) EH_MAE_VO,
        MAX(CASE WHEN RTRIM(SD2.D2_CF) IN ('5910','6910') THEN 1 ELSE 0 END)               EH_BONIFICACAO,
        MIN(RTRIM(SD2.D2_CF))                CFOP,
        MAX(SD2.D2_PEDIDO)                   PEDIDO,
        CAST(SUM(SD2.D2_TOTAL) AS DECIMAL(18,2)) VALOR_MERCADORIA
FROM    SD2010 SD2
WHERE   SD2.D_E_L_E_T_ = ''
  AND   SD2.D2_EMISSAO BETWEEN CONVERT(CHAR(8), DATEADD(DAY,-180, CONVERT(DATE,@DATADE,112)), 112) AND @DATAATE
  AND   LEFT(SD2.D2_CF,1) IN ('5','6')
  AND   RTRIM(SD2.D2_CF) NOT IN ('5923','6923')          -- a própria remessa não é mãe de ninguém
GROUP BY SD2.D2_FILIAL, SD2.D2_DOC, SD2.D2_SERIE
)
SELECT  NFS.FILIAL, NFS.NF, NFS.SERIE, NFS.EMISSAO, NFS.EH_MAE_VO, NFS.EH_BONIFICACAO, NFS.CFOP,
        NFS.VALOR_MERCADORIA,
        -- checagem complementar (Silvio 23/09/2026, só notas desde 01/08/2026): campo de usuário do
        -- PEDIDO da NF-mãe "Venda Ordem" (C5_XVENDAO) = CNPJ de quem vai receber as remessas
        CASE WHEN NFS.EH_MAE_VO = 1 THEN RTRIM(ISNULL(SC5.C5_XVENDAO,'')) ELSE '' END  PED_XVENDAO
FROM    NFS
LEFT JOIN SC5010 SC5 ON SC5.D_E_L_E_T_ = '' AND NFS.EH_MAE_VO = 1
                    AND SC5.C5_FILIAL = NFS.FILIAL AND SC5.C5_NUM = NFS.PEDIDO;
