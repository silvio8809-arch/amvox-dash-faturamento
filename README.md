# amvox-dash-faturamento

Dashboard TV de Faturamento & Logística (AMVOX).

- `web/` — painel: TV (`index.html`, 1920×1080) + 4 telas de detalhe
- `etl/` — carga do Protheus para o cache Supabase
- `sql/00_descoberta/` — as queries da Fase 0 (como cada campo foi confirmado)
- `sql/01_extracao/` — queries finais, parametrizadas
- `db/migrations/` — DDL do cache

Dados no Supabase, atrás de login. **Nenhuma credencial neste repositório** — o publicador
aborta o push se encontrar alguma.
