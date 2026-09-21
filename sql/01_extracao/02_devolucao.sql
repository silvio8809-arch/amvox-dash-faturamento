-- =====================================================================================
-- FASE 1 · EXTRAÇÃO 02 — DEVOLUÇÕES (uma linha por NF de devolução) → dash_devolucao
-- Regras confirmadas na Fase 0 (skill dash-tv-faturamento). SOMENTE LEITURA.
--
--  universo ...... TODAS as devoluções: SF1.F1_TIPO='D', todas as filiais
--  origem ........ F1_FORMUL: 'S' = emitida pela AMVOX · '' = emitida pelo cliente
--                  (ATRIBUTO, nunca filtro — decisão Silvio 21/09)
--  vínculo ....... SD1.D1_NFORI/D1_SERIORI (preenchido em 99,8%)
--  CFOP .......... mantém 1201/2201/1202/2202/2203/1410/2410;
--                  EXCLUI 2914/2949/2208 (retorno de remessa, não é devolução de venda)
--  motivo ........ F1_MENNOTA, DUAS convenções ("MOTIVO DEV:" e "... MOT.:").
--                  Busca com COLLATE (banco é Latin1_General_BIN, case-sensitive).
--                  Sem taxonomia fixa: guarda o texto bruto + a causa extraída.
-- =====================================================================================
DECLARE @DATADE CHAR(8), @DATAATE CHAR(8);
SET @DATADE  = CONVERT(CHAR(8), DATEADD(DAY,-120,GETDATE()), 112);
SET @DATAATE = CONVERT(CHAR(8), GETDATE(), 112);

WITH ITENS AS (
    SELECT  D1.D1_FILIAL FIL, D1.D1_DOC DOC, D1.D1_SERIE SER,
            D1.D1_FORNECE FORN, D1.D1_LOJA LOJA,
            MIN(D1.D1_CF)                       CFOP,
            MAX(LTRIM(RTRIM(D1.D1_NFORI)))      NF_ORIGEM,
            MAX(LTRIM(RTRIM(D1.D1_SERIORI)))    SERIE_ORIGEM,
            COUNT(*)                            QTD_ITENS,
            SUM(D1.D1_TOTAL)                    VALOR_ITENS
    FROM    SD1010 D1
    WHERE   D1.D_E_L_E_T_ = ''
    GROUP BY D1.D1_FILIAL, D1.D1_DOC, D1.D1_SERIE, D1.D1_FORNECE, D1.D1_LOJA
),
DEV AS (
    SELECT  F1.F1_FILIAL, F1.F1_DOC, F1.F1_SERIE, F1.F1_FORNECE, F1.F1_LOJA,
            F1.F1_EMISSAO, F1.F1_VALBRUT, F1.F1_FORMUL, F1.F1_MENNOTA,
            -- o texto tem motivo? (padrão validado: 970/970, zero falso positivo)
            CASE WHEN F1.F1_MENNOTA COLLATE Latin1_General_CI_AI LIKE '%MOT%'
                 THEN 1 ELSE 0 END  TEM_MOTIVO,
            -- corta o texto DEPOIS do marcador; "MOTIVO" tem 6 letras, "MOT" tem 3
            -- ...e limpa os restos do marcador: "DEV.:", "DEV:", ".:" e pontuação da borda
            CASE WHEN F1.F1_MENNOTA COLLATE Latin1_General_CI_AI LIKE '%MOT%'
                 THEN TRIM(' .:-/' FROM
                        REPLACE(REPLACE(REPLACE(
                          SUBSTRING(F1.F1_MENNOTA,
                            PATINDEX('%MOT%', F1.F1_MENNOTA COLLATE Latin1_General_CI_AI)
                            + CASE WHEN F1.F1_MENNOTA COLLATE Latin1_General_CI_AI LIKE '%MOTIVO%'
                                   THEN 6 ELSE 3 END, 70)
                        ,'DEV.:',''),'DEV:',''),'DEV',''))
                 END  MOTIVO_BRUTO
    FROM    SF1010 F1
    WHERE   F1.D_E_L_E_T_ = '' AND F1.F1_TIPO = 'D'
      AND   F1.F1_EMISSAO BETWEEN @DATADE AND @DATAATE
)
SELECT
        RTRIM(D.F1_FILIAL)                                  FILIAL,
        RTRIM(D.F1_DOC)                                     NF_DEV,
        RTRIM(D.F1_SERIE)                                   SERIE_DEV,
        D.F1_EMISSAO                                        EMISSAO_DEV,
        CASE WHEN D.F1_FORMUL = 'S' THEN 'AMVOX' ELSE 'CLIENTE' END  ORIGEM_NF,
        RTRIM(D.F1_FORNECE)                                 CLIENTE_COD,
        RTRIM(D.F1_LOJA)                                    CLIENTE_LOJA,
        RTRIM(ISNULL(A1.A1_NREDUZ,''))                      CLIENTE_NOME,
        LEFT(RTRIM(ISNULL(A1.A1_CGC,'')),8)                 CNPJ_RAIZ,
        RTRIM(ISNULL(A1.A1_EST,''))                         UF,
        ISNULL(I.CFOP,'')                                   CFOP,
        ISNULL(I.NF_ORIGEM,'')                              NF_ORIGEM,
        ISNULL(I.SERIE_ORIGEM,'')                           SERIE_ORIGEM,
        F2.F2_EMISSAO                                       EMISSAO_ORIGEM,
        ISNULL(I.QTD_ITENS,0)                               QTD_ITENS,
        CAST(D.F1_VALBRUT AS DECIMAL(18,2))                 VALOR,
        D.TEM_MOTIVO                                        TEM_MOTIVO,
        LTRIM(RTRIM(ISNULL(D.F1_MENNOTA,'')))               TEXTO_NF,
        -- causa sem o sufixo de OS/CHAMADO, para agrupar no painel
        TRIM(' .:-/' FROM CASE
            WHEN CHARINDEX('OS', D.MOTIVO_BRUTO COLLATE Latin1_General_CI_AI) > 1
                 THEN LEFT(D.MOTIVO_BRUTO, CHARINDEX('OS', D.MOTIVO_BRUTO COLLATE Latin1_General_CI_AI)-1)
            WHEN CHARINDEX('CH', D.MOTIVO_BRUTO COLLATE Latin1_General_CI_AI) > 1
                 THEN LEFT(D.MOTIVO_BRUTO, CHARINDEX('CH', D.MOTIVO_BRUTO COLLATE Latin1_General_CI_AI)-1)
            WHEN CHARINDEX('-',  D.MOTIVO_BRUTO) > 1
                 THEN LEFT(D.MOTIVO_BRUTO, CHARINDEX('-', D.MOTIVO_BRUTO)-1)
            ELSE D.MOTIVO_BRUTO END)                        MOTIVO_CAUSA
FROM        DEV D
LEFT JOIN   ITENS I   ON I.FIL=D.F1_FILIAL AND I.DOC=D.F1_DOC AND I.SER=D.F1_SERIE
                     AND I.FORN=D.F1_FORNECE AND I.LOJA=D.F1_LOJA
LEFT JOIN   SA1010 A1 ON A1.D_E_L_E_T_='' AND A1.A1_COD=D.F1_FORNECE AND A1.A1_LOJA=D.F1_LOJA
LEFT JOIN   SF2010 F2 ON F2.D_E_L_E_T_='' AND F2.F2_FILIAL=D.F1_FILIAL
                     AND F2.F2_DOC=I.NF_ORIGEM AND F2.F2_SERIE=I.SERIE_ORIGEM
WHERE       ISNULL(I.CFOP,'') NOT IN ('2914','2949','2208')   -- retorno de remessa fora
ORDER BY    D.F1_EMISSAO DESC, D.F1_DOC;
