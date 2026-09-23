-- =====================================================================================
-- FASE 1 · EXTRAÇÃO 01 — NF DE SAÍDA (uma linha por nota) → cache dash_nf_saida
-- Regras confirmadas na Fase 0 (skill dash-tv-faturamento). SOMENTE LEITURA.
--
--  universo ...... FATURAMENTO (receita) na régua da FAT PLUS: F2_VALFAT > 0 E a nota tem
--                  item que gera duplicata (F4_DUPLIC='S'). Remessa/retorno fora.
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
      -- PERFORMANCE (23/09/2026): antes agregava o contas a receber INTEIRO, de todos os anos.
      -- Título de NF nasce com a NF, então E1_EMISSAO >= início da janela não perde nada.
      AND   E1_EMISSAO >= @DATADE
      -- só título de NF: NCC/RA com mesmo número+prefixo somariam no saldo da nota
      -- (0 casos desde 2025 — conferido 23/09 —, mas a porta fica fechada)
      AND   E1_TIPO = 'NF'
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
      -- PERFORMANCE (23/09/2026): só os trechos das NF da janela. Igualdade direta porque
      -- nem GWU_NRDC nem F2_DOC têm espaço à esquerda (conferido: 0 em 144.118 e 219.937 linhas);
      -- espaço à direita o SQL Server já ignora no "=".
      AND   EXISTS (SELECT 1 FROM SF2010 W
                    WHERE W.D_E_L_E_T_ = '' AND W.F2_FILIAL = GW.GWU_FILIAL AND W.F2_DOC = GW.GWU_NRDC
                      AND W.F2_EMISSAO BETWEEN @DATADE AND @DATAATE)
    GROUP BY GW.GWU_FILIAL, LTRIM(RTRIM(GW.GWU_NRDC))
),
-- Cancelamento. ⚠️ EXCEÇÃO CONSCIENTE à regra do D_E_L_E_T_: o evento de cancelamento
-- precisa ser visto mesmo quando a linha foi excluída (SPEC 3.3). Só notas de SAÍDA:
-- discriminador = CFOP 5xxx/6xxx (F3_ENTRADA é data contábil, sempre preenchida).
CANC AS (
    SELECT  F3_FILIAL                      FIL,
            F3_NFISCAL                     NF,
            F3_SERIE                       SER,
            MAX(NULLIF(F3_DTCANC,''))      DT_CANCELAMENTO
    FROM    SF3010
    WHERE   LEFT(F3_CFO,1) IN ('5','6')
      AND   F3_EMISSAO BETWEEN @DATADE AND @DATAATE      -- PERFORMANCE (23/09/2026)
    GROUP BY F3_FILIAL, F3_NFISCAL, F3_SERIE
    -- ⚠️ CANCELADA = cancelada na SF3 E SEM nenhum registro VIVO da mesma nota (corrigido 23/09/2026).
    -- Antes bastava um F3_DTCANC. Mas 28 NF desde jan/25 têm um registro cancelado E outro vivo na
    -- SF3 (numeração reaproveitada) — e as que têm valor estão com o título PAGO pelo cliente (ex.:
    -- KAIO DISTRIBUIDORA, NF 000249850, R$ 144.982,32, paga no dia). São vendas válidas; a FAT PLUS
    -- as conta. A conclusão da Fase 0 ("12 canceladas ativas entrariam como faturamento válido")
    -- estava errada: elas SÃO faturamento válido.
    HAVING  MAX(F3_DTCANC) <> ''
       AND  SUM(CASE WHEN F3_DTCANC = '' AND D_E_L_E_T_ = '' THEN 1 ELSE 0 END) = 0
),
-- CFOP predominante da nota (para auditar o universo de receita)
CFOP AS (
    SELECT  D2_FILIAL FIL, D2_DOC DOC, D2_SERIE SER, MIN(D2_CF) CFOP, SUM(D2_QUANT) QTD_ITENS,
            -- VALOR FATURADO = Σ dos itens que geram duplicata, sem ativo imobilizado. Nas notas
            -- normais é exatamente o F2_VALFAT (conferido nas 20.730 NF desde jan/25); nas 5 notas
            -- de título manual, onde o cabeçalho zerou, é o valor que a FAT PLUS mostra.
            SUM(CASE WHEN T.F4_DUPLIC = 'S' AND RTRIM(D2_CF) NOT IN ('5551','6551') THEN D2_VALBRUT ELSE 0 END) VAL_FAT,
            SUM(CASE WHEN T.F4_DUPLIC = 'S' AND RTRIM(D2_CF) NOT IN ('5551','6551') THEN D2_TOTAL   ELSE 0 END) VAL_MERC,
            -- NF-MÃE de venda à ordem: gera o financeiro; a entrega sai nas remessas 5923/6923
            MAX(CASE WHEN RTRIM(D2_CF) IN ('5118','6118','5119','6119') THEN 1 ELSE 0 END) VENDA_ORDEM
    FROM    SD2010
    LEFT JOIN SF4010 T ON T.F4_CODIGO = D2_TES AND T.D_E_L_E_T_ = ''
                      AND SUBSTRING(T.F4_FILIAL,1,4) = SUBSTRING(D2_FILIAL,1,4)
    WHERE   SD2010.D_E_L_E_T_ = ''
      AND   D2_EMISSAO BETWEEN @DATADE AND @DATAATE      -- PERFORMANCE (23/09/2026)
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
        CAST(C.VAL_FAT  AS DECIMAL(18,2))                          VALOR_FATURADO,   -- ver CFOP.VAL_FAT
        CAST(C.VAL_MERC AS DECIMAL(18,2))                          VALOR_MERCADORIA,
        CAST(F2.F2_VALIPI  AS DECIMAL(18,2))                       VALOR_IPI,
        ISNULL(C.CFOP,'')                                          CFOP,
        ISNULL(C.VENDA_ORDEM,0)                                    VENDA_ORDEM,
        -- ---------- data de entrega: Financeiro primeiro, GFE como fallback ----------
        ENT.DT                                                     DT_ENTREGA,
        ENT.ORIGEM                                                 DT_ENTREGA_ORIGEM,
        RG.REGRA                                                   REGRA_ESPECIAL,   -- SINISTRO | FUNCIONARIO | NULL
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
            WHEN ENT.DT IS NOT NULL                                            THEN 'ENTREGUE'
            ELSE 'EM_TRANSITO'
        END                                                        STATUS_BASE,
        -- ---------- dias e faixa (só quando ainda não há entrega) ----------
        CASE WHEN CANC.DT_CANCELAMENTO IS NULL
              AND ENT.DT IS NULL
             THEN DATEDIFF(DAY, CONVERT(DATE, F2.F2_EMISSAO, 112), GETDATE()) END  DIAS_SEM_ENTREGA,
        CASE WHEN CANC.DT_CANCELAMENTO IS NULL
              AND ENT.DT IS NULL
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
-- ---------- grupo especial: só MARCA, não mexe na data (Silvio 23/09/2026, 2ª versão) ----------
-- Revenda a transportadora que causou SINISTRO e venda a FUNCIONÁRIO ficam num quadro próprio da
-- tela "Sem entrega", mas a data de entrega mostra a REALIDADE: tem data, mostra; não tem, está
-- pendente ("segregamos, mas não omitimos a pendência"). A 1ª versão (emissão = entrega) foi desfeita.
--   sinistro ... nome do cliente contém TRANSFARRAPOS ou PATRUS
--   funcionário  grupo de vendas 000001 = FUNCIONARIOS (A1_GRPVEN → ACY010)
CROSS APPLY (SELECT
    CASE
      WHEN A1.A1_NOME   COLLATE Latin1_General_CI_AI LIKE '%TRANSFARRAPOS%'
        OR A1.A1_NREDUZ COLLATE Latin1_General_CI_AI LIKE '%TRANSFARRAPOS%'
        OR A1.A1_NOME   COLLATE Latin1_General_CI_AI LIKE '%PATRUS%'
        OR A1.A1_NREDUZ COLLATE Latin1_General_CI_AI LIKE '%PATRUS%'        THEN 'SINISTRO'
      WHEN RTRIM(ISNULL(A1.A1_GRPVEN,'')) = '000001'                         THEN 'FUNCIONARIO'
    END AS REGRA) RG
-- ---------- data de entrega: UMA expressão, e status/dias/faixa derivam dela ----------
-- Coerência por construção entre as telas (pedido do Silvio 23/09/2026): "Notas emitidas" e
-- "Sem entrega" leem a mesma conta. NF-mãe de venda à ordem: o ETL troca esta data pela da
-- ÚLTIMA remessa entregue e recalcula status/dias/faixa com a mesma regra (refresh_dash.py).
CROSS APPLY (SELECT
    COALESCE(FIN.DT_ENTREGA_FIN, G.DT_ENTREGA_GFE,
             CASE WHEN ISNULL(FIN.SALDO_ABERTO,-1) = 0 THEN FIN.DT_BAIXA END) AS DT,
    CASE WHEN FIN.DT_ENTREGA_FIN IS NOT NULL                                  THEN 'FIN'
         WHEN G.DT_ENTREGA_GFE   IS NOT NULL                                  THEN 'GFE'
         WHEN ISNULL(FIN.SALDO_ABERTO,-1) = 0 AND FIN.DT_BAIXA IS NOT NULL    THEN 'BAIXA'
         ELSE 'SEM' END AS ORIGEM) ENT
WHERE       F2.D_E_L_E_T_ = ''
  AND       F2.F2_EMISSAO BETWEEN @DATADE AND @DATAATE
  -- UNIVERSO = régua da FAT PLUS (refinada 23/09/2026 ao estender o cache a jan/2025):
  --   · F2_TIPO normal — fora 'D' (devolução de compra a fornecedor: 22 NF 5553/5556/6556/5206
  --     desde jan/25) e 'B' (beneficiamento);
  --   · ao menos um item cuja TES gera duplicata e que NÃO é venda de ativo imobilizado
  --     (CFOP 5551/6551: 5 NF, R$ 132.295,94 — sucata, equipamentos; a FAT PLUS não conta).
  --   O antigo "F2_VALFAT > 0" saiu: 5 vendas normais 5101/6101 têm F2_VALFAT = 0 porque o título
  --   foi lançado à parte (condição manual) — a FAT PLUS as conta (R$ 105.561,88).
  --   Resultado conferido NF a NF desde jan/25: igual à FAT PLUS, fora 1 NF que a view conta
  --   estando APAGADA na SF2 (000278810, R$ 5.249,73 — vazamento conhecido da view).
  AND       F2.F2_TIPO NOT IN ('D','B')
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
                      AND  DUP.D2_FILIAL  = F2.F2_FILIAL  AND DUP.D2_DOC   = F2.F2_DOC
                      AND  DUP.D2_SERIE   = F2.F2_SERIE   AND DUP.D2_CLIENTE = F2.F2_CLIENTE
                      AND  DUP.D2_LOJA    = F2.F2_LOJA
                      AND  TES.F4_DUPLIC  = 'S'
                      AND  RTRIM(DUP.D2_CF) NOT IN ('5551','6551'))
ORDER BY    F2.F2_EMISSAO DESC, F2.F2_DOC;
