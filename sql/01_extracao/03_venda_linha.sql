-- =====================================================================================
-- FASE 1 · EXTRAÇÃO 03 — VENDA POR REGIÃO × LINHA → cache dash_venda_linha
-- Uma linha por NF × LINHA DE PRODUTO. SOMENTE LEITURA.
--
--  por que tabela nova: dash_nf_saida tem grão de NOTA e a linha de produto é do ITEM
--                       (SD2 → SB1.B1_GRUPO → SBM.BM_DESC). Uma NF pode ter AUDIO e LAR
--                       na mesma nota, então a linha não cabe como coluna da nota.
--  universo ...... idêntico ao 01_nf_saida: FATURAMENTO na régua da FAT PLUS
--                  (F2_VALFAT > 0 E nota com item que gera duplicata), todas as filiais.
--  valor ......... SUM(D2_VALBRUT dos itens que GERAM DUPLICATA) = F2_VALFAT AO CENTAVO
--                  (desde 23/09/2026 — ver o filtro TIT abaixo; antes somava todos os itens e
--                  quebrava em nota mista venda + bonificação). Conferido 22/09/2026 na janela
--                  de 120 dias: 46.696.390,19 dos dois lados). SUM(D2_TOTAL) = F2_VALMERC,
--                  também ao centavo — é a mercadoria SEM IPI.
--                  Logo: VALOR_FATURADO soma com IPI, VALOR_MERCADORIA sem.
--  UF ............ A1_EST (cadastro do cliente), o MESMO campo do 01_nf_saida, para as duas
--                  telas cruzarem. Conferido: A1_EST = F2_EST em 1.876/1.876 NF (100%).
--  região ........ derivada da UF pelo agrupamento do IBGE (as 27 UFs estão cobertas).
--  cancelamento .. herda a marca da SF3 (LEFT JOIN, nunca por D_E_L_E_T_) — a tela exclui
--                  CANCELADA, mas o dado fica para conferência.
--  linhas na base  0005 AUDIO · 0002 LAR · 0003 CLIMA · 0004 INFORMATICA · 0001 VIDEO ·
--                  0012 MATERIAS REMESSAS. Sem taxonomia inventada: sai o que está na SBM.
-- =====================================================================================
DECLARE @DATADE CHAR(8), @DATAATE CHAR(8);
SET @DATADE  = CONVERT(CHAR(8), DATEADD(DAY,-120,GETDATE()), 112);   -- janela do ETL
SET @DATAATE = CONVERT(CHAR(8), GETDATE(), 112);

WITH
-- cancelamento: a SF3 é a EXCEÇÃO CONSCIENTE à regra do D_E_L_E_T_ — precisamos enxergar o
-- evento de cancelamento, inclusive das notas que seguem ativas na SF2 (12 casos em 12 meses).
CANC AS (
    SELECT  F3_FILIAL FIL, F3_NFISCAL NF, F3_SERIE SER,
            MAX(NULLIF(F3_DTCANC,'')) DT_CANC
    FROM    SF3010
    WHERE   LEFT(F3_CFO,1) IN ('5','6')        -- discriminador de SAÍDA (F3_ENTRADA não serve)
      AND   F3_EMISSAO BETWEEN @DATADE AND @DATAATE
    GROUP BY F3_FILIAL, F3_NFISCAL, F3_SERIE
    -- ⚠️ CANCELADA = cancelada na SF3 E SEM nenhum registro VIVO da mesma nota (corrigido 23/09/2026).
    -- Antes bastava um F3_DTCANC. Mas 28 NF desde jan/25 têm um registro cancelado E outro vivo na
    -- SF3 (numeração reaproveitada) — e as que têm valor estão com o título PAGO pelo cliente (ex.:
    -- KAIO DISTRIBUIDORA, NF 000249850, R$ 144.982,32, paga no dia). São vendas válidas; a FAT PLUS
    -- as conta. A conclusão da Fase 0 ("12 canceladas ativas entrariam como faturamento válido")
    -- estava errada: elas SÃO faturamento válido.
    HAVING  MAX(F3_DTCANC) <> ''
       AND  SUM(CASE WHEN F3_DTCANC = '' AND D_E_L_E_T_ = '' THEN 1 ELSE 0 END) = 0
)
SELECT
        RTRIM(SD2.D2_FILIAL)                                        FILIAL,
        RTRIM(SD2.D2_DOC)                                           NF,
        RTRIM(SD2.D2_SERIE)                                         SERIE,
        RTRIM(ISNULL(SBM.BM_DESC, '(SEM LINHA)'))                   LINHA,
        RTRIM(ISNULL(SB1.B1_GRUPO, ''))                             GRUPO,
        SF2.F2_EMISSAO                                              EMISSAO,
        RTRIM(SF2.F2_CLIENTE)                                       CLIENTE_COD,
        RTRIM(SF2.F2_LOJA)                                          CLIENTE_LOJA,
        RTRIM(ISNULL(A1.A1_NREDUZ,''))                              CLIENTE_NOME,
        LEFT(RTRIM(ISNULL(A1.A1_CGC,'')),8)                         CNPJ_RAIZ,
        RTRIM(ISNULL(A1.A1_EST,''))                                 UF,
        -- agrupamento do IBGE; o ELSE só existe para não perder linha se entrar UF estranha
        CASE RTRIM(ISNULL(A1.A1_EST,''))
            WHEN 'AC' THEN 'NORTE'        WHEN 'AP' THEN 'NORTE'
            WHEN 'AM' THEN 'NORTE'        WHEN 'PA' THEN 'NORTE'
            WHEN 'RO' THEN 'NORTE'        WHEN 'RR' THEN 'NORTE'
            WHEN 'TO' THEN 'NORTE'
            WHEN 'AL' THEN 'NORDESTE'     WHEN 'BA' THEN 'NORDESTE'
            WHEN 'CE' THEN 'NORDESTE'     WHEN 'MA' THEN 'NORDESTE'
            WHEN 'PB' THEN 'NORDESTE'     WHEN 'PE' THEN 'NORDESTE'
            WHEN 'PI' THEN 'NORDESTE'     WHEN 'RN' THEN 'NORDESTE'
            WHEN 'SE' THEN 'NORDESTE'
            WHEN 'DF' THEN 'CENTRO-OESTE' WHEN 'GO' THEN 'CENTRO-OESTE'
            WHEN 'MT' THEN 'CENTRO-OESTE' WHEN 'MS' THEN 'CENTRO-OESTE'
            WHEN 'ES' THEN 'SUDESTE'      WHEN 'MG' THEN 'SUDESTE'
            WHEN 'RJ' THEN 'SUDESTE'      WHEN 'SP' THEN 'SUDESTE'
            WHEN 'PR' THEN 'SUL'          WHEN 'RS' THEN 'SUL'
            WHEN 'SC' THEN 'SUL'
            ELSE '(SEM REGIÃO)'
        END                                                         REGIAO,
        COUNT(*)                                                    ITENS,
        CAST(SUM(SD2.D2_QUANT)    AS DECIMAL(18,3))                 QUANTIDADE,
        CAST(SUM(SD2.D2_VALBRUT)  AS DECIMAL(18,2))                 VALOR_FATURADO,    -- = F2_VALFAT
        CAST(SUM(SD2.D2_TOTAL)    AS DECIMAL(18,2))                 VALOR_MERCADORIA,  -- = F2_VALMERC
        CASE WHEN CANC.DT_CANC IS NOT NULL THEN 'CANCELADA' ELSE 'ATIVA' END  STATUS
FROM        SD2010 SD2
INNER JOIN  SF2010 SF2 ON  SF2.F2_FILIAL  = SD2.D2_FILIAL
                       AND SF2.F2_DOC     = SD2.D2_DOC
                       AND SF2.F2_SERIE   = SD2.D2_SERIE
                       AND SF2.F2_CLIENTE = SD2.D2_CLIENTE
                       AND SF2.F2_LOJA    = SD2.D2_LOJA
                       AND SF2.D_E_L_E_T_ = ''
LEFT JOIN   SA1010  A1 ON  A1.A1_COD = SF2.F2_CLIENTE AND A1.A1_LOJA = SF2.F2_LOJA
                       AND A1.D_E_L_E_T_ = ''
LEFT JOIN   SB1010 SB1 ON  SB1.B1_COD = SD2.D2_COD AND SB1.D_E_L_E_T_ = ''
-- BONIFICAÇÃO NÃO É FATURAMENTO — também no nível do ITEM (achado 23/09/2026).
-- Nota MISTA: a 000223128 (23/01/2025) tem 12 itens de venda 6101 e 2 de bonificação 6910
-- (TES 628, não gera duplicata) na MESMA nota. F2_VALFAT já exclui a bonificação; somando todos
-- os itens a região × linha ficava R$ 769,90 acima. Com o filtro por item, Σ itens = F2_VALFAT
-- de novo — e bate com a FAT PLUS, que separa esses itens em ORIGEM='BON'.
INNER JOIN  SF4010 TIT ON  TIT.F4_CODIGO = SD2.D2_TES AND TIT.D_E_L_E_T_ = ''
                       AND SUBSTRING(TIT.F4_FILIAL,1,4) = SUBSTRING(SD2.D2_FILIAL,1,4)
                       AND TIT.F4_DUPLIC = 'S'
                       AND RTRIM(SD2.D2_CF) NOT IN ('5551','6551')   -- venda de ativo imobilizado fora
LEFT JOIN   SBM010 SBM ON  SBM.BM_GRUPO = SB1.B1_GRUPO AND SBM.D_E_L_E_T_ = ''
LEFT JOIN   CANC       ON  CANC.FIL = SF2.F2_FILIAL AND CANC.NF = SF2.F2_DOC
                       AND CANC.SER = SF2.F2_SERIE
WHERE       SD2.D_E_L_E_T_ = ''
  AND       SF2.F2_EMISSAO BETWEEN @DATADE AND @DATAATE
  AND       SF2.F2_TIPO NOT IN ('D','B')   -- mesmo universo do 01_nf_saida (ver lá)
  -- ALINHAMENTO COM A FAT PLUS (regra Silvio 22/09/2026): faturamento = o que a
  -- VW_AZ_FATURAMENTO_ANALITICO_NOVO conta como ORIGEM='FAT'. Só `F2_VALFAT > 0` não bastava:
  -- deixava entrar "outras saídas" com TES que NÃO gera duplicata (NF 000276398, CFOP 5949,
  -- TES 555, R$ 400 — a view exclui, o dash incluía). Exigir que a nota tenha ao menos um item
  -- com F4_DUPLIC='S' fecha com a view AO CENTAVO: 1.870 NF · R$ 46.661.024,64 nos dois lados.
  -- (Filtro no nível da NOTA, não do item — assim SUM(D2_VALBRUT) continua = F2_VALFAT.)
  AND       EXISTS (SELECT 1
                    FROM   SD2010 DUP
                    JOIN   SF4010 TES ON DUP.D2_TES = TES.F4_CODIGO
                                     AND SUBSTRING(TES.F4_FILIAL,1,4) = SUBSTRING(DUP.D2_FILIAL,1,4)
                                     AND TES.D_E_L_E_T_ = ''
                    WHERE  DUP.D_E_L_E_T_ = ''
                      AND  DUP.D2_FILIAL  = SF2.F2_FILIAL  AND DUP.D2_DOC   = SF2.F2_DOC
                      AND  DUP.D2_SERIE   = SF2.F2_SERIE   AND DUP.D2_CLIENTE = SF2.F2_CLIENTE
                      AND  DUP.D2_LOJA    = SF2.F2_LOJA
                      AND  TES.F4_DUPLIC  = 'S'
                      AND  RTRIM(DUP.D2_CF) NOT IN ('5551','6551'))
GROUP BY    SD2.D2_FILIAL, SD2.D2_DOC, SD2.D2_SERIE,
            SBM.BM_DESC, SB1.B1_GRUPO, SF2.F2_EMISSAO,
            SF2.F2_CLIENTE, SF2.F2_LOJA, A1.A1_NREDUZ, A1.A1_CGC, A1.A1_EST,
            CANC.DT_CANC
ORDER BY    SF2.F2_EMISSAO DESC, NF, LINHA;
