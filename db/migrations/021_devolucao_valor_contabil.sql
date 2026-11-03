-- =====================================================================================
-- 021 · DEVOLUÇÃO — data de digitação e valor contábil (Silvio 03/11/2026)
-- Card "Notas emitidas" da TV passa a mostrar Faturamento BRUTO (3110101) e LÍQUIDO
-- (3110101 − 3110102). A conta 3110102 registra a devolução:
--   · no mês da DIGITAÇÃO da nota de entrada (F1_DTDIGIT), não da emissão do cliente;
--   · pelo valor dos itens com TES que gera duplicata (D1_TOTAL + D1_VALIPI − D1_VALDESC),
--     sem o ICMS-ST (CFOP 1410/2410) e sem retorno de remessa (1949/2949 = 0).
-- Conferido contra o razão 3110102 jan–out/2026 (out/26: 277 NF · R$ 2.127.487,05).
-- Só acrescenta colunas; nada é apagado. Preenchidas pela carga seguinte do ETL.
-- =====================================================================================
alter table dash_devolucao add column if not exists dt_digitacao date;
alter table dash_devolucao add column if not exists valor_contabil numeric(18,2);

-- conferência: as duas linhas devem aparecer
select column_name, data_type from information_schema.columns
 where table_name = 'dash_devolucao' and column_name in ('dt_digitacao', 'valor_contabil');
