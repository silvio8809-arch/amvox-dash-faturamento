-- =====================================================================================
-- FASE 1 · EXTRAÇÃO 04 — VENDA À ORDEM: NOTAS DE REMESSA → cache dash_vo_remessa
-- Uma linha por NF de REMESSA (CFOP 5923/6923). SOMENTE LEITURA.
--
--  a operação ..... a NF-MÃE (5118/6118, ou 5119/6119 quando a mercadoria é de terceiros) gera
--                   o financeiro e serve para cobrar; a ENTREGA física sai nas REMESSAS
--                   (5923/6923). Σ mercadoria das remessas deve igualar a mercadoria da mãe.
--                   Regra do Silvio, 23/09/2026: a entrega é controlada pelas REMESSAS.
--  data de entrega  só pode vir do GFE (GWU_DTENT): a remessa não gera título, então não há
--                   E1_DTSAIDA. Cobertura medida em 23/09: 626 de 645 remessas desde jan/25 (97,1%).
--  vínculo c/ mãe . D2_NFORI NUNCA vem preenchido na remessa (0 de 1.324 itens) e o pedido é
--                   outro. O vínculo está em:
--                     1º F2_XDOCREF/F2_XSERREF/F2_XFILREF (campo custom — só nas recentes: 46/645)
--                     2º texto livre do pedido (C5_MENNOTA) ou da nota (F2_MENNOTA), em vários
--                        formatos: "REF A NF 222423", "REF NF 000222742-", "NF (247809)",
--                        "NF'S 000232243/000232251", "Origem NF 000278795 Venda Ordem".
--                   O parser fica no ETL (Python). Cobertura: 96,1% (620/645).
--  cancelamento ... SF3 (exceção consciente à regra do D_E_L_E_T_), como nas outras extrações.
-- =====================================================================================
DECLARE @DATADE CHAR(8), @DATAATE CHAR(8);
SET @DATADE  = CONVERT(CHAR(8), DATEADD(DAY,-120,GETDATE()), 112);   -- janela do ETL
SET @DATAATE = CONVERT(CHAR(8), GETDATE(), 112);

WITH
REM AS (   -- notas que têm item de remessa por conta e ordem
    SELECT  D2_FILIAL FIL, D2_DOC DOC, D2_SERIE SER,
            MAX(D2_PEDIDO) PEDIDO, COUNT(*) ITENS, SUM(D2_QUANT) QTD
    FROM    SD2010
    WHERE   D_E_L_E_T_ = '' AND D2_EMISSAO BETWEEN @DATADE AND @DATAATE
      AND   RTRIM(D2_CF) IN ('5923','6923')
    GROUP BY D2_FILIAL, D2_DOC, D2_SERIE
),
GFE AS (
    SELECT  GW.GWU_FILIAL FIL, LTRIM(RTRIM(GW.GWU_NRDC)) NRDC,
            MAX(NULLIF(GW.GWU_DTENT,''))  DT_ENTREGA_GFE,
            MAX(NULLIF(GW.GWU_DTPENT,'')) DT_PREVISTA,
            MAX(NULLIF(RTRIM(U3.GU3_NMFAN),'')) TRANSP_NOME_GFE
    FROM    GWU010 GW
    LEFT JOIN GU3010 U3 ON U3.D_E_L_E_T_ = ''
                       AND LTRIM(RTRIM(U3.GU3_CDEMIT)) = LTRIM(RTRIM(GW.GWU_CDTRP))
    WHERE   GW.D_E_L_E_T_ = ''
      AND   EXISTS (SELECT 1 FROM REM WHERE REM.FIL = GW.GWU_FILIAL AND REM.DOC = GW.GWU_NRDC)
    GROUP BY GW.GWU_FILIAL, LTRIM(RTRIM(GW.GWU_NRDC))
),
CANC AS (
    SELECT  F3_FILIAL FIL, F3_NFISCAL NF, F3_SERIE SER, MAX(NULLIF(F3_DTCANC,'')) DT_CANCELAMENTO
    FROM    SF3010
    WHERE   LEFT(F3_CFO,1) IN ('5','6')
      AND   F3_EMISSAO BETWEEN @DATADE AND @DATAATE
    GROUP BY F3_FILIAL, F3_NFISCAL, F3_SERIE
    -- cancelada = sem nenhum registro vivo na SF3 (mesma regra do 01_nf_saida, 23/09/2026)
    HAVING  MAX(F3_DTCANC) <> ''
       AND  SUM(CASE WHEN F3_DTCANC = '' AND D_E_L_E_T_ = '' THEN 1 ELSE 0 END) = 0
)
SELECT
        RTRIM(F2.F2_FILIAL)                                  FILIAL,
        RTRIM(F2.F2_DOC)                                     NF,
        RTRIM(F2.F2_SERIE)                                   SERIE,
        F2.F2_EMISSAO                                        EMISSAO,
        RTRIM(F2.F2_CLIENTE)                                 CLIENTE_COD,
        RTRIM(F2.F2_LOJA)                                    CLIENTE_LOJA,
        RTRIM(ISNULL(A1.A1_NREDUZ,''))                       CLIENTE_NOME,      -- destinatário da mercadoria
        RTRIM(ISNULL(A1.A1_EST,''))                          UF,
        REM.ITENS                                            ITENS,
        CAST(REM.QTD AS DECIMAL(18,3))                       QUANTIDADE,
        CAST(F2.F2_VALMERC AS DECIMAL(18,2))                 VALOR_MERCADORIA,
        RTRIM(ISNULL(G.TRANSP_NOME_GFE,''))                  TRANSPORTADORA,
        G.DT_ENTREGA_GFE                                     DT_ENTREGA,
        G.DT_PREVISTA                                        DT_PREVISTA,
        CANC.DT_CANCELAMENTO                                 DT_CANCELAMENTO,
        -- vínculo com a NF-mãe: os três campos custom + os dois textos (o ETL decide)
        RTRIM(ISNULL(F2.F2_XDOCREF,''))                      XDOCREF,
        RTRIM(ISNULL(F2.F2_XSERREF,''))                      XSERREF,
        RTRIM(ISNULL(F2.F2_XFILREF,''))                      XFILREF,
        RTRIM(ISNULL(SC5.C5_MENNOTA,''))                     TEXTO_PEDIDO,
        RTRIM(ISNULL(F2.F2_MENNOTA,''))                      TEXTO_NOTA,
        -- checagem complementar (Silvio 23/09/2026, só notas desde 01/08/2026): campos de usuário
        -- do PEDIDO da remessa que apontam a NF-mãe (SX3: Filial Ref / Serie Ref / Doc Ref)
        RTRIM(REM.PEDIDO)                                    PEDIDO,
        RTRIM(ISNULL(SC5.C5_XFILREF,''))                     PED_XFILREF,
        RTRIM(ISNULL(SC5.C5_XSERREF,''))                     PED_XSERREF,
        RTRIM(ISNULL(SC5.C5_XDOCREF,''))                     PED_XDOCREF,
        RTRIM(ISNULL(A1.A1_CGC,''))                          CNPJ_DESTINO       -- quem recebeu a remessa
FROM        REM
INNER JOIN  SF2010 F2  ON F2.D_E_L_E_T_ = '' AND F2.F2_FILIAL = REM.FIL
                      AND F2.F2_DOC = REM.DOC AND F2.F2_SERIE = REM.SER
LEFT JOIN   SA1010 A1  ON A1.D_E_L_E_T_ = '' AND A1.A1_COD = F2.F2_CLIENTE AND A1.A1_LOJA = F2.F2_LOJA
LEFT JOIN   SC5010 SC5 ON SC5.D_E_L_E_T_ = '' AND SC5.C5_FILIAL = REM.FIL AND SC5.C5_NUM = REM.PEDIDO
LEFT JOIN   GFE G      ON G.FIL = F2.F2_FILIAL AND G.NRDC = LTRIM(RTRIM(F2.F2_DOC))
LEFT JOIN   CANC       ON CANC.FIL = F2.F2_FILIAL AND CANC.NF = F2.F2_DOC AND CANC.SER = F2.F2_SERIE
ORDER BY    F2.F2_EMISSAO DESC, F2.F2_DOC;
