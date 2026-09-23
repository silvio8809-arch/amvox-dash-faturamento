-- =====================================================================================
-- FASE 1 · EXTRAÇÃO 06 — VENDA À ORDEM: ITENS DA NF-MÃE E DAS REMESSAS (auditoria)
-- Não vai para o cache como está: o ETL compara produto a produto e grava só as OCORRÊNCIAS
-- em dash_auditoria. SOMENTE LEITURA.
--
--  pedido do Silvio, 23/09/2026 — "não posso entregar mais produtos (R$) do que foi registrado
--  na nota mãe, muito menos produtos DISTINTOS da nota mãe". Por isso o grão é ITEM:
--    MAE ...... itens 5118/6118/5119/6119 (a mercadoria vendida e cobrada)
--    REMESSA .. itens 5923/6923 (a mercadoria que saiu fisicamente)
--  valores .. VALOR_TOTAL = D2_VALBRUT (com IPI). A remessa leva o valor cheio da mãe (medido em
--             23/09: Σ remessas ÷ valor da mãe = 1,000 na mediana), então a comparação em R$ é
--             valor bruto × valor bruto. Quantidade compara sem ambiguidade.
--  retorno .. não há NF de entrada referenciando remessa (0 desde jan/25, medido 23/09): a
--             devolução volta contra a MÃE (2201/1201) — não abate remessa.
--  janela ... a mãe entra desde 180 dias ANTES da janela (a remessa pode citar mãe anterior).
-- =====================================================================================
DECLARE @DATADE CHAR(8), @DATAATE CHAR(8);
SET @DATADE  = CONVERT(CHAR(8), DATEADD(DAY,-120,GETDATE()), 112);   -- janela do ETL
SET @DATAATE = CONVERT(CHAR(8), GETDATE(), 112);

SELECT  CASE WHEN RTRIM(SD2.D2_CF) IN ('5923','6923') THEN 'REMESSA' ELSE 'MAE' END  TIPO,
        RTRIM(SD2.D2_FILIAL)                          FILIAL,
        RTRIM(SD2.D2_DOC)                             NF,
        RTRIM(SD2.D2_SERIE)                           SERIE,
        RTRIM(SD2.D2_COD)                             PRODUTO,
        RTRIM(ISNULL(MAX(B1.B1_DESC),''))             DESCRICAO,
        CAST(SUM(SD2.D2_QUANT)   AS DECIMAL(18,3))    QUANTIDADE,
        CAST(SUM(SD2.D2_VALBRUT) AS DECIMAL(18,2))    VALOR_TOTAL
FROM    SD2010 SD2
-- descrição por OUTER APPLY TOP 1: se a SB1 for exclusiva por filial, um JOIN direto duplicaria o item
OUTER APPLY (SELECT TOP 1 B.B1_DESC FROM SB1010 B WHERE B.D_E_L_E_T_ = '' AND B.B1_COD = SD2.D2_COD) B1
WHERE   SD2.D_E_L_E_T_ = ''
  AND   SD2.D2_EMISSAO BETWEEN CONVERT(CHAR(8), DATEADD(DAY,-180, CONVERT(DATE,@DATADE,112)), 112) AND @DATAATE
  AND   RTRIM(SD2.D2_CF) IN ('5118','6118','5119','6119','5923','6923')
GROUP BY SD2.D2_FILIAL, SD2.D2_DOC, SD2.D2_SERIE, SD2.D2_COD,
         CASE WHEN RTRIM(SD2.D2_CF) IN ('5923','6923') THEN 'REMESSA' ELSE 'MAE' END;
