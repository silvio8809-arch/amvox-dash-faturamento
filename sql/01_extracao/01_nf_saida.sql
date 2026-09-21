-- =====================================================================================
-- FASE 1 · EXTRAÇÃO 01 — NF DE SAÍDA (uma linha por nota) → cache dash_nf_saida
-- Regras confirmadas na Fase 0 (skill dash-tv-faturamento). SOMENTE LEITURA.
--
--  universo ...... só FATURAMENTO (receita): F2_VALFAT > 0. Remessa/retorno fora.
--  filiais ....... TODAS
--  entrega ....... COALESCE( SE1.E1_DTSAIDA , GWU010.GWU_DTENT )   [decisão Silvio 21/09]
--                  NUNCA F2_DTENTR (diverge em 98,8% e tem data anterior à emissão).
--  previsão ...... GWU_DTPENT (para previsto × realizado)
--  cancelamento .. SF3.F3_DTCANC — LEFT JOIN, nunca por D_E_L_E_T_ (12 NF canceladas
--                  seguem ATIVAS na SF2 e entrariam como faturamento válido).
--  cobrança ...... E1_SALDO > 0 = título em aberto; entrega em branco = boleto travado.
-- =====================================================================================
DECLARE @DATADE CHAR(8), @DATAATE CHAR(8);
SET @DATADE  = CONVERT(CHAR(8), DATEADD(DAY,-120,GETDATE()), 112);   -- janela do ETL
SET @DATAATE = CONVERT(CHAR(8), GETDATE(), 112);

WITH
-- título(s) da NF no contas a receber: data de entrega do Financeiro + posição de cobrança
FIN AS (
    SELECT  E1_FILIAL                      FIL,
            E1_NUM                         NUM,
            E1_PREFIXO                     PRE,
            MAX(NULLIF(E1_DTSAIDA,''))     DT_ENTREGA_FIN,
            SUM(E1_VALOR)                  VLR_TITULOS,
            SUM(E1_SALDO)                  SALDO_ABERTO,
            MAX(NULLIF(E1_VENCREA,''))     VENC_REAL,
            MIN(NULLIF(E1_BAIXA,''))       DT_BAIXA,      -- 1ª baixa = prova mais antiga de recebimento
            COUNT(*)                       QTD_PARCELAS
    FROM    SE1010
    WHERE   D_E_L_E_T_ = ''
    GROUP BY E1_FILIAL, E1_NUM, E1_PREFIXO
),
-- GFE: entrega realizada (fallback) e previsão. Uma linha por trecho → agregar.
GFE AS (
    SELECT  GW.GWU_FILIAL                  FIL,
            LTRIM(RTRIM(GW.GWU_NRDC))      NRDC,
            MAX(NULLIF(GW.GWU_DTENT,''))   DT_ENTREGA_GFE,
            MAX(NULLIF(GW.GWU_DTPENT,''))  DT_PREVISTA,
            MAX(NULLIF(GW.GWU_DTPENO,''))  DT_PREVISTA_ORIG,
            MAX(NULLIF(GW.GWU_CDTRP,''))   TRANSPORTADOR_GFE, -- GWU_NMTRP existe no SX3 mas NAO na tabela fisica
            -- nome real da transportadora: GU3010 e o cadastro de emitentes do GFE.
            -- GWU_NMTRP nao existe fisicamente, por isso o join pelo codigo.
            MAX(NULLIF(RTRIM(U3.GU3_NMFAN),'')) TRANSP_NOME_GFE
    FROM    GWU010 GW
    LEFT JOIN GU3010 U3 ON U3.D_E_L_E_T_ = ''
                       AND LTRIM(RTRIM(U3.GU3_CDEMIT)) = LTRIM(RTRIM(GW.GWU_CDTRP))
    WHERE   GW.D_E_L_E_T_ = ''
    GROUP BY GW.GWU_FILIAL, LTRIM(RTRIM(GW.GWU_NRDC))
),
-- Cancelamento. ⚠️ EXCEÇÃO CONSCIENTE à regra do D_E_L_E_T_: o evento de cancelamento
-- precisa ser visto mesmo quando a linha foi excluída (SPEC 3.3). Só notas de SAÍDA:
-- discriminador = CFOP 5xxx/6xxx (F3_ENTRADA é data contábil, sempre preenchida).
CANC AS (
    SELECT  F3_FILIAL                      FIL,
            F3_NFISCAL                     NF,
            F3_SERIE                       SER,
            MAX(F3_DTCANC)                 DT_CANCELAMENTO
    FROM    SF3010
    WHERE   F3_DTCANC <> '' AND LEFT(F3_CFO,1) IN ('5','6')
    GROUP BY F3_FILIAL, F3_NFISCAL, F3_SERIE
),
-- CFOP predominante da nota (para auditar o universo de receita)
CFOP AS (
    SELECT  D2_FILIAL FIL, D2_DOC DOC, D2_SERIE SER, MIN(D2_CF) CFOP, SUM(D2_QUANT) QTD_ITENS
    FROM    SD2010 WHERE D_E_L_E_T_ = ''
    GROUP BY D2_FILIAL, D2_DOC, D2_SERIE
)
SELECT
        RTRIM(F2.F2_FILIAL)                                        FILIAL,
        RTRIM(F2.F2_DOC)                                           NF,
        RTRIM(F2.F2_SERIE)                                         SERIE,
        F2.F2_EMISSAO                                              EMISSAO,
        RTRIM(F2.F2_CLIENTE)                                       CLIENTE_COD,
        RTRIM(F2.F2_LOJA)                                          CLIENTE_LOJA,
        RTRIM(ISNULL(A1.A1_NREDUZ,''))                             CLIENTE_NOME,
        LEFT(RTRIM(ISNULL(A1.A1_CGC,'')),8)                        CNPJ_RAIZ,
        RTRIM(ISNULL(A1.A1_EST,''))                                UF,
        RTRIM(ISNULL(A1.A1_TIPO,''))                               A1_TIPO,        -- canal: F/R [confirmar regra]
        -- TRANSPORTADORA (decisao Silvio 21/09): o GFE manda. O cadastro SA4 e generico
        -- (1.640 de 1.849 NF apontam para o codigo 0169 = 'TERCEIROS'), entao A4_NREDUZ
        -- so entra como fallback quando o GFE nao tem o nome.
        RTRIM(ISNULL(G.TRANSP_NOME_GFE,
              ISNULL(A4.A4_NREDUZ, ISNULL(G.TRANSPORTADOR_GFE,'')))) TRANSPORTADORA,
        CAST(F2.F2_VALFAT  AS DECIMAL(18,2))                       VALOR_FATURADO,
        CAST(F2.F2_VALMERC AS DECIMAL(18,2))                       VALOR_MERCADORIA,
        CAST(F2.F2_VALIPI  AS DECIMAL(18,2))                       VALOR_IPI,
        ISNULL(C.CFOP,'')                                          CFOP,
        -- ---------- data de entrega: Financeiro primeiro, GFE como fallback ----------
        COALESCE(FIN.DT_ENTREGA_FIN, G.DT_ENTREGA_GFE,
                 CASE WHEN ISNULL(FIN.SALDO_ABERTO,-1) = 0 THEN FIN.DT_BAIXA END) DT_ENTREGA,
        CASE WHEN FIN.DT_ENTREGA_FIN IS NOT NULL THEN 'FIN'
             WHEN G.DT_ENTREGA_GFE   IS NOT NULL THEN 'GFE'
             WHEN ISNULL(FIN.SALDO_ABERTO,-1) = 0 AND FIN.DT_BAIXA IS NOT NULL THEN 'BAIXA'
             ELSE 'SEM' END                                        DT_ENTREGA_ORIGEM,
        G.DT_PREVISTA                                              DT_PREVISTA,
        G.DT_PREVISTA_ORIG                                         DT_PREVISTA_ORIG,
        -- ---------- cobrança ----------
        CAST(ISNULL(FIN.VLR_TITULOS,0)  AS DECIMAL(18,2))          VLR_TITULOS,
        CAST(ISNULL(FIN.SALDO_ABERTO,0) AS DECIMAL(18,2))          SALDO_ABERTO,
        FIN.VENC_REAL                                              VENCIMENTO_REAL,
        -- ---------- cancelamento ----------
        CANC.DT_CANCELAMENTO                                       DT_CANCELAMENTO,
        -- ---------- status derivado (ordem da SPEC seção 4) ----------
        CASE
            WHEN CANC.DT_CANCELAMENTO IS NOT NULL                          THEN 'CANCELADA'
            WHEN COALESCE(FIN.DT_ENTREGA_FIN, G.DT_ENTREGA_GFE,
                      CASE WHEN ISNULL(FIN.SALDO_ABERTO,-1) = 0 THEN FIN.DT_BAIXA END) IS NOT NULL THEN 'ENTREGUE'
            ELSE 'EM_TRANSITO'
        END                                                        STATUS_BASE,
        -- ---------- dias e faixa (só quando ainda não há entrega) ----------
        CASE WHEN CANC.DT_CANCELAMENTO IS NULL
              AND COALESCE(FIN.DT_ENTREGA_FIN, G.DT_ENTREGA_GFE,
                     CASE WHEN ISNULL(FIN.SALDO_ABERTO,-1) = 0 THEN FIN.DT_BAIXA END) IS NULL
             THEN DATEDIFF(DAY, CONVERT(DATE, F2.F2_EMISSAO, 112), GETDATE()) END  DIAS_SEM_ENTREGA,
        CASE WHEN CANC.DT_CANCELAMENTO IS NULL
              AND COALESCE(FIN.DT_ENTREGA_FIN, G.DT_ENTREGA_GFE,
                     CASE WHEN ISNULL(FIN.SALDO_ABERTO,-1) = 0 THEN FIN.DT_BAIXA END) IS NULL
             THEN CASE
                    WHEN DATEDIFF(DAY, CONVERT(DATE,F2.F2_EMISSAO,112), GETDATE()) <= 2  THEN '0-2'
                    WHEN DATEDIFF(DAY, CONVERT(DATE,F2.F2_EMISSAO,112), GETDATE()) <= 7  THEN '3-7'
                    WHEN DATEDIFF(DAY, CONVERT(DATE,F2.F2_EMISSAO,112), GETDATE()) <= 15 THEN '8-15'
                    ELSE '>15' END END                             FAIXA_ENTREGA
FROM        SF2010 F2
LEFT JOIN   SA1010 A1   ON A1.D_E_L_E_T_=''  AND A1.A1_COD = F2.F2_CLIENTE AND A1.A1_LOJA = F2.F2_LOJA
LEFT JOIN   SA4010 A4   ON A4.D_E_L_E_T_=''  AND A4.A4_COD = F2.F2_TRANSP
LEFT JOIN   FIN         ON FIN.FIL = F2.F2_FILIAL AND FIN.NUM = F2.F2_DOC AND FIN.PRE = F2.F2_SERIE
LEFT JOIN   GFE G       ON G.FIL   = F2.F2_FILIAL AND G.NRDC = LTRIM(RTRIM(F2.F2_DOC))
LEFT JOIN   CANC        ON CANC.FIL = F2.F2_FILIAL AND CANC.NF = F2.F2_DOC AND CANC.SER = F2.F2_SERIE
LEFT JOIN   CFOP C      ON C.FIL   = F2.F2_FILIAL AND C.DOC = F2.F2_DOC AND C.SER = F2.F2_SERIE
WHERE       F2.D_E_L_E_T_ = ''
  AND       F2.F2_EMISSAO BETWEEN @DATADE AND @DATAATE
  AND       F2.F2_VALFAT > 0            -- só faturamento (receita); remessa fora
ORDER BY    F2.F2_EMISSAO DESC, F2.F2_DOC;
