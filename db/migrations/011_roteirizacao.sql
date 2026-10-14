-- =====================================================================================
-- Dashboard TV — migração 011 (14/10/2026) · STATUS ROTEIRIZAÇÃO NO PLANO DE AÇÃO
-- Projeto: precificacao-app-2026 (ref dzxekwdpktvishdsmiep). Rodar UMA vez no SQL Editor.
-- Idempotente: pode rodar de novo sem estragar nada.
--
-- Pedido da Logística, via Silvio (14/10/2026): na fila "Notas pendentes de entrega", coluna inicial
-- do plano de ação com o status da roteirização — o romaneio do GFE atrelado à nota:
--   "Roteirizado com previsão de entrega dd/mm/aaaa" · "Roteirizado SEM previsão de entrega" ·
--   "Não roteirizado" (nota sem romaneio).
-- Fonte (Protheus, só leitura): GW1010 (documento de carga, GW1_NRROM) → GWN010 (romaneio:
-- GWN_SIT, GWN_DTSAI/HRSAI) + GWU_DTPENT (previsão). NF-mãe de venda à ordem herda o romaneio
-- da remessa (romaneio_origem = 'remessa <nf>'). O ETL grava; a tela só lê.
-- =====================================================================================

alter table dash_nf_saida add column if not exists romaneio text;
alter table dash_nf_saida add column if not exists romaneio_situacao text;    -- Digitado | Emitido | Liberado | Encerrado
alter table dash_nf_saida add column if not exists romaneio_saida timestamp;  -- saída do romaneio (hora local)
alter table dash_nf_saida add column if not exists romaneio_prevista date;    -- previsão de entrega usada no status
alter table dash_nf_saida add column if not exists romaneio_origem text;      -- null = da própria NF · 'remessa <nf>'

notify pgrst, 'reload schema';

select count(*) filter (where column_name like 'romaneio%') as colunas_romaneio
from information_schema.columns where table_schema = 'public' and table_name = 'dash_nf_saida';
