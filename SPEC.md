# SPEC — Dashboard TV Faturamento & Logística (AMVOX)
**Versão 1 — 18/09/2026** · Para execução pelo Claude Code

---

## 0. Como usar este documento

Você (Claude Code) tem acesso de leitura ao banco do TOTVS Protheus e a um repositório de queries SQL já validadas. **Este documento não afirma nomes de campos como certos.** Todo item marcado com `[CONFIRMAR]` deve ser verificado no dicionário (SX3) ou por consulta real antes de virar código. Todo item marcado com `[TESTAR]` deve rodar contra a base e ter o resultado colado no relatório da fase.

Regras inegociáveis:
- Protheus é **produção**: apenas `SELECT`. Nunca `INSERT/UPDATE/DELETE`, nunca `CREATE`, nunca `SELECT INTO` no banco do ERP.
- Toda query: filtro `D_E_L_E_T_ = ''` (salvo onde a spec pedir explicitamente os deletados), datas em `CHAR(8)` formato `YYYYMMDD`, parâmetros com `DECLARE` + `SET`.
- Sufixo das tabelas: `010` (ex.: `SF2010`). `[CONFIRMAR]` se a filial usa outro sufixo ou se há mais de uma filial (`F2_FILIAL`).
- Trabalhe em fases. **Cada fase termina com um relatório e uma pergunta de aprovação.** Não avance sem "ok" do Sílvio.
- Não invente valores para preencher tela. Sem dado real, mostre estado vazio com a mensagem "sem dados no período".

---

## 1. Objetivo

Painel web em duas camadas:

1. **Home (TV)** — 1920×1080, sem interação, atualizada a cada 1 h, com 4 blocos-ícone que passam um recado em uma frase:
   - Quantas notas foram emitidas
   - Top 10 clientes
   - Notas sem data de entrega (por faixa de dias) e top clientes nessa situação
   - Devoluções emitidas (quantas, quais, motivo) e top clientes que devolvem
2. **Páginas de detalhe** — abertas quando o usuário clica em um bloco no computador dele. Padrão fixo: cabeçalho com **data/hora da última atualização**, filtros, 4 cards no topo, tabela principal ao centro, painéis laterais à direita, botão Exportar Excel.

Protótipo visual aprovado (canvas Claude): `https://claude.ai/artifact/U7phN32FQMLnXMGQsikKpW` — artboards `Main`, `Emitidas`, `TopClientes`, `SemEntrega`, `Devolucoes`. Reproduza cores, hierarquia e ícones. Os números do protótipo são ilustrativos.

Identidade: navy `#1A1F2E` (cabeçalho e texto), laranja `#F5A623` (acento), fundo `#F4F6FA`, cards `#FFFFFF` borda `#E3E7EF`, cinza-texto `#5B6478`. Semáforo: verde `#2E9E6B`, laranja `#F5A623`, vermelho `#D64545`, vermelho-escuro `#8E2A2A`. Fontes: Barlow Condensed (títulos/números) + Barlow (texto), Google Fonts.

---

## 2. Arquitetura (decidida — não reabrir)

| Camada | Escolha |
|---|---|
| Fonte | TOTVS Protheus, SQL Server, somente leitura |
| Cache/app DB | PostgreSQL (Supabase) — tabelas `dash_*` |
| ETL | Job Python (pyodbc → psycopg) a cada 1 h, via cron/APScheduler; também acionável manualmente `POST /refresh` |
| API | FastAPI |
| Frontend | React + Tremor (blocos KPI/gráficos) + Tailwind; roteamento `/` (TV), `/emitidas`, `/clientes`, `/sem-entrega`, `/devolucoes` |
| Hospedagem | Vercel (front), backend no mesmo padrão do AMVOX Finance Suite |
| TV | Chrome em modo kiosk apontando para `/`, com `<meta http-equiv="refresh">` ou polling a cada 5 min buscando `last_update` |

A TV **nunca** consulta o Protheus diretamente. Só lê o cache.

---

## 3. Fase 0 — Descoberta e confirmação (obrigatória)

Objetivo: substituir toda suposição por fato. Entregável: `FASE0_RELATORIO.md` com as queries rodadas e os resultados.

### 3.1 Dicionário de dados
```sql
-- Campos candidatos a data de entrega
SELECT X3_ARQUIVO, X3_CAMPO, X3_TITULO, X3_DESCRIC, X3_TIPO, X3_TAMANHO
FROM SX3010
WHERE D_E_L_E_T_ = ''
  AND X3_ARQUIVO IN ('SF2','SE1','SC5','SC9','SF1','SD1')
  AND (X3_CAMPO LIKE '%ENTR%' OR X3_TITULO LIKE '%ENTREG%' OR X3_DESCRIC LIKE '%ENTREG%')
ORDER BY X3_ARQUIVO, X3_CAMPO
```
`[CONFIRMAR]` Sílvio informou que a data de entrega é preenchida na **SF2 e na SE1**. Identifique o campo exato em cada tabela (provavelmente customizado, ex.: `F2_XDTENTR`, `E1_XDTENTR`). Registre nome, tipo, tamanho.

```sql
-- Campos de texto/observação no cabeçalho do pedido (motivo de devolução)
SELECT X3_CAMPO, X3_TITULO, X3_DESCRIC, X3_TIPO, X3_TAMANHO
FROM SX3010
WHERE D_E_L_E_T_ = '' AND X3_ARQUIVO = 'SC5'
  AND (X3_TIPO = 'M' OR X3_CAMPO LIKE '%OBS%' OR X3_CAMPO LIKE '%MEN%' OR X3_CAMPO LIKE '%MOT%' OR X3_TITULO LIKE '%MOTIV%')
```
`[CONFIRMAR]` Sílvio acredita que o motivo fica em campo texto do cabeçalho do pedido de venda (SC5). Candidatos padrão: `C5_MENNOTA`, `C5_MENPAD` (código SM4), `C5_OBS`; ou campo `X` customizado. Verifique também na SF1 da devolução (`F1_XMOTIVO`?) e no pedido de compra/devolução.

### 3.2 Testes de preenchimento
```sql
DECLARE @DATADE CHAR(8), @DATAATE CHAR(8)
SET @DATADE = '20260801'  SET @DATAATE = '20260918'

-- % de NF de saída com data de entrega preenchida (substituir <CAMPO_ENTREGA_SF2>)
SELECT COUNT(*) TOTAL,
       SUM(CASE WHEN <CAMPO_ENTREGA_SF2> <> '' THEN 1 ELSE 0 END) COM_ENTREGA
FROM SF2010
WHERE D_E_L_E_T_ = '' AND F2_EMISSAO BETWEEN @DATADE AND @DATAATE
```
`[TESTAR]` Repita para SE1. Decida a regra de precedência: **SF2 primeiro; se vazio, SE1; se ambos vazios = sem entrega.** Reporte a taxa de preenchimento; se < 50%, alerte antes de seguir.

```sql
-- Motivo: quantos pedidos de venda ligados a devoluções têm texto preenchido
-- (ajuste após 3.1)
SELECT COUNT(DISTINCT D1.D1_NFORI) NF_DEVOLVIDAS,
       SUM(CASE WHEN LTRIM(RTRIM(C5.<CAMPO_MOTIVO>)) <> '' THEN 1 ELSE 0 END) COM_MOTIVO
FROM SD1010 D1
JOIN SF1010 F1 ON F1.F1_FILIAL=D1.D1_FILIAL AND F1.F1_DOC=D1.D1_DOC AND F1.F1_SERIE=D1.D1_SERIE
             AND F1.F1_FORNECE=D1.D1_FORNECE AND F1.F1_LOJA=D1.D1_LOJA AND F1.D_E_L_E_T_=''
LEFT JOIN SD2010 D2 ON D2.D2_FILIAL=D1.D1_FILIAL AND D2.D2_DOC=D1.D1_NFORI AND D2.D2_SERIE=D1.D1_SERIORI
             AND D2.D2_ITEM=D1.D1_ITEMORI AND D2.D_E_L_E_T_=''
LEFT JOIN SC5010 C5 ON C5.C5_FILIAL=D2.D2_FILIAL AND C5.C5_NUM=D2.D2_PEDIDO AND C5.D_E_L_E_T_=''
WHERE D1.D_E_L_E_T_='' AND F1.F1_TIPO='D' AND F1.F1_EMISSAO BETWEEN @DATADE AND @DATAATE
```
`[TESTAR]` Se `COM_MOTIVO / NF_DEVOLVIDAS` < 70 %, ative o **Plano B (seção 7)** — classificação no dashboard + upload de planilha. Provavelmente será necessário de qualquer forma para padronizar.

### 3.3 Cancelamentos
`[CONFIRMAR]` Comportamento padrão do Protheus: ao cancelar uma NF de saída, o registro em **SF2 recebe `D_E_L_E_T_ = '*'`** e a **SF3 permanece com `F3_DTCANC` preenchido**. Teste:
```sql
SELECT TOP 20 F3_NFISCAL, F3_SERIE, F3_EMISSAO, F3_DTCANC, F3_CLIEFOR, F3_VALCONT
FROM SF3010 WHERE F3_DTCANC <> '' ORDER BY F3_DTCANC DESC
```
Confirme se `F3_DTCANC` é a "data de cancelamento" pedida no painel. Para o **número do protocolo/evento de cancelamento** da NF-e, verifique se o TSS grava em `SPED050` / `SPED052` (`[CONFIRMAR]` existência dessas tabelas e campo de protocolo). Se não existir, exiba apenas a data.

### 3.4 Devoluções
`[CONFIRMAR]` Regra: `SF1.F1_TIPO = 'D'` identifica NF de devolução de venda. Vínculo com a venda: `D1_NFORI`, `D1_SERIORI`, `D1_ITEMORI`. CFOPs esperados: 1.201/1.410/2.201/2.410 (produto acabado), 1.202/2.202 (revenda). Liste os CFOPs realmente presentes:
```sql
SELECT D1_CF, COUNT(*) QTD FROM SD1010 D1
JOIN SF1010 F1 ON F1.F1_FILIAL=D1.D1_FILIAL AND F1.F1_DOC=D1.D1_DOC AND F1.F1_SERIE=D1.D1_SERIE AND F1.F1_FORNECE=D1.D1_FORNECE AND F1.F1_LOJA=D1.D1_LOJA AND F1.D_E_L_E_T_=''
WHERE D1.D_E_L_E_T_='' AND F1.F1_TIPO='D' AND F1.F1_EMISSAO >= '20260101'
GROUP BY D1_CF ORDER BY QTD DESC
```

### 3.5 Reaproveitamento
Antes de escrever qualquer query nova, leia no repositório: `FAT_GERAL_ANALITICO.sql`, `FATURAMENTO_ANALITICO_PLUS.sql` (usa `VW_AZ_FATURAMENTO_ANALITICO_NOVO`), `LISTA_SA1_.sql`, `FINANCEIRO_AGGLIST_CONTAS_RECEBER.sql`. `[CONFIRMAR]` se a view `VW_AZ_FATURAMENTO_ANALITICO_NOVO` já entrega NF + cliente + valor + devolução. Se sim, use-a como base do ETL de emitidas e top clientes.

### 3.6 Volumetria
`[TESTAR]` Conte NF/mês nos últimos 12 meses (SF2 e SF1 tipo D). Isso dimensiona o cache e o tempo do job.

**Gate da Fase 0:** relatório com todos os `[CONFIRMAR]` resolvidos → aguardar ok.

---

## 4. Fase 1 — Modelo de cache (Supabase)

Crie apenas após a Fase 0. Nomes de colunas finais seguem o que foi confirmado.

```sql
-- Notas de saída (uma linha por NF)
CREATE TABLE dash_nf_saida (
  filial text, nf text, serie text, emissao date,
  cliente_cod text, cliente_loja text, cliente_nome text, cnpj_raiz text, uf text, canal text, -- canal: B2B/B2C (regra na Fase 0: A1_TIPO? grupo? [CONFIRMAR])
  valor_bruto numeric, valor_liquido numeric, transportadora text,
  dt_entrega date,            -- SF2 → SE1 → null
  dt_cancelamento date,       -- SF3.F3_DTCANC
  protocolo_cancel text,      -- se existir
  status text,                -- EMITIDA | EM_TRANSITO | ENTREGUE | CANCELADA | DEVOLVIDA_PARCIAL | DEVOLVIDA_TOTAL
  dias_sem_entrega int,       -- hoje - emissao quando dt_entrega is null e status in (EMITIDA, EM_TRANSITO)
  faixa_entrega text,         -- 0-2 | 3-7 | 8-15 | >15
  updated_at timestamptz,
  PRIMARY KEY (filial, nf, serie)
);

-- Devoluções (uma linha por NF de devolução × NF de origem)
CREATE TABLE dash_devolucao (
  filial text, nf_dev text, serie_dev text, emissao_dev date,
  nf_origem text, serie_origem text, emissao_origem date,
  cliente_cod text, cliente_nome text, cnpj_raiz text, uf text,
  cfop text, valor numeric, qtd_itens int,
  motivo_erp text,            -- texto bruto do campo confirmado na Fase 0 (pode ser null)
  motivo_padrao text,         -- classificação padronizada (ver seção 7)
  motivo_origem text,         -- ERP | MANUAL | PLANILHA
  updated_at timestamptz,
  PRIMARY KEY (filial, nf_dev, serie_dev, nf_origem, serie_origem)
);

-- Metadados do job
CREATE TABLE dash_refresh_log (
  id bigserial primary key, started_at timestamptz, finished_at timestamptz,
  ok boolean, rows_nf int, rows_dev int, erro text
);

-- Motivos padrão (tabela editável)
CREATE TABLE dash_motivo_padrao (
  codigo text primary key, descricao text, ativo boolean default true, ordem int
);
INSERT INTO dash_motivo_padrao VALUES
 ('AVARIA','Avaria no transporte',true,1),('RECUSA','Recusa do cliente',true,2),
 ('ERRO_PEDIDO','Erro de pedido / preço',true,3),('FISCAL','Divergência fiscal (CFOP/ST)',true,4),
 ('ARREPEND','Arrependimento (CDC / e-commerce)',true,5),('OUTRO','Outro',true,99);

-- Classificação manual / planilha (nunca sobrescrita pelo ETL)
CREATE TABLE dash_devolucao_classif (
  filial text, nf_dev text, serie_dev text,
  motivo_padrao text references dash_motivo_padrao(codigo),
  observacao text, usuario text, origem text, -- MANUAL | PLANILHA
  updated_at timestamptz default now(),
  PRIMARY KEY (filial, nf_dev, serie_dev)
);
```

Status — regra de derivação (aplicar nesta ordem):
1. `dt_cancelamento` não nulo → `CANCELADA`
2. soma das devoluções vinculadas ≥ valor_liquido → `DEVOLVIDA_TOTAL`; > 0 → `DEVOLVIDA_PARCIAL`
3. `dt_entrega` não nulo → `ENTREGUE`
4. senão → `EM_TRANSITO` (emitida sem entrega)

`[TESTAR]` Rode a derivação sobre agosto/2026 e compare totais com um relatório do Protheus fornecido pelo Sílvio.

**Gate da Fase 1:** DDL aplicado + ETL rodado 1× com totais conferidos → aguardar ok.

---

## 5. Fase 2 — ETL horário

- Janela de extração: **últimos 120 dias** (upsert), suficiente para as faixas de entrega e para comparações mês anterior. Parametrizável.
- Ordem: `dash_nf_saida` → `dash_devolucao` → recalcular `status`, `dias_sem_entrega`, `faixa_entrega` → aplicar `dash_devolucao_classif` sobre `motivo_padrao` (prioridade: PLANILHA/MANUAL > ERP) → gravar `dash_refresh_log`.
- Falha em qualquer etapa: transação abortada, log com erro, cache anterior permanece; o front mostra "última atualização" antiga e um aviso discreto.
- `[TESTAR]` Tempo total do job < 5 min. Se maior, reduzir janela ou indexar.
- Mapeamento do motivo bruto (`motivo_erp`) para `motivo_padrao`: dicionário de palavras-chave em `motivos_map.yaml` (ex.: "avaria", "quebrad" → AVARIA; "recus" → RECUSA). O que não casar fica `motivo_padrao = null` e aparece na fila "A classificar".

---

## 6. Fase 3 — API e Frontend

### 6.1 Endpoints (FastAPI)
```
GET /api/meta                      → {last_update, next_update, refresh_ok}
GET /api/home                      → payload completo da TV (4 blocos), cacheado em memória por 60 s
GET /api/emitidas?de&ate&cliente   → cards + lista paginada + série diária + por canal/UF
GET /api/clientes?de&ate&base      → ranking top 10 + concentração + detalhe do cliente selecionado
GET /api/sem-entrega?de&ate&faixa&transportadora → cards por faixa + fila + top clientes + por transportadora
GET /api/devolucoes?de&ate&motivo&cliente → cards + lista + top clientes + evolução 6 meses
POST /api/devolucoes/{filial}/{nf}/{serie}/classificar  {motivo_padrao, observacao}
POST /api/devolucoes/importar      (multipart xlsx/csv)  → ver seção 7
GET  /api/export/{pagina}.xlsx     → mesmo filtro da tela
POST /api/refresh                  → dispara ETL (protegido)
```

### 6.2 Home (TV) — conteúdo por bloco
| Bloco | Número | Frase de recado (gerada no backend) | Mini-visual |
|---|---|---|---|
| Emitidas | qtd mês | "Hoje saíram N notas — X% acima/abaixo da média diária do mês." | barras por dia útil, última = hoje, linha da média |
| Top 10 | — | "Os 3 maiores concentram X% do faturamento do mês." | 5 barras horizontais + link "posições 6–10" |
| Sem entrega | qtd total | "N notas passaram de 7 dias — atenção com [cliente A] e [cliente B]." | 4 faixas verde/laranja/vermelho/vinho |
| Devoluções | qtd mês | "Equivale a X% do faturado — meta < 3%. Principal causa: [motivo]." | donut por motivo + top 3 clientes |

Frases usam texto fixo com placeholders; nunca texto gerado por LLM.

### 6.3 Páginas de detalhe
Reproduzir os artboards do canvas. Componentes: `HeaderBar` (título, ícone, última atualização, botão Painel), `FilterBar`, `KpiCards`, `DataTable` (TanStack Table, ordenável, paginado), `SidePanel`. Ícones: reutilizar os SVGs autorais do protótipo (exportar do canvas), não biblioteca genérica.

### 6.4 Modo TV
Rota `/` sem menus; `?tv=1` esconde cursor e desativa hover; polling de `/api/meta` a cada 5 min e reload quando `last_update` mudar. Fonte mínima 16 px; números principais ≥ 96 px.

**Gate da Fase 3:** deploy em URL de homologação + checklist da seção 8 → aguardar ok.

---

## 7. Plano B — Classificação de motivo de devolução

Ativa se a Fase 0 mostrar motivo ausente/inconsistente no ERP (provável).

**7.1 Classificação individual (tela Devoluções)**
- Coluna "Motivo" vira um `select` com os itens de `dash_motivo_padrao` + campo observação.
- Salva em `dash_devolucao_classif` com usuário e `origem = MANUAL`.
- Linhas sem classificação aparecem primeiro, com badge "A classificar" (laranja). Card no topo: "N devoluções sem motivo".

**7.2 Upload de planilha**
- Botão "Importar motivos" aceita `.xlsx`/`.csv` com colunas obrigatórias: `NF_DEVOLUCAO`, `SERIE`, `MOTIVO` (código ou descrição de `dash_motivo_padrao`); opcional `OBSERVACAO`, `FILIAL` (default filial única confirmada).
- Validação antes de gravar: NF existe em `dash_devolucao`; motivo existe na tabela padrão. Retorna resumo: `importadas / ignoradas / erros` com lista de linhas rejeitadas para download.
- Grava com `origem = PLANILHA`. Regra de conflito: planilha sobrescreve MANUAL somente se o usuário marcar "sobrescrever".
- Fornecer modelo `modelo_importacao_motivos.xlsx` para download na tela.

**7.3 Precedência final do motivo exibido**
`PLANILHA` ≥ `MANUAL` > `ERP mapeado` > `null ("A classificar")`. A origem aparece como tooltip.

---

## 8. Checklist de aceite

- [ ] Relatório da Fase 0 entregue com todos os `[CONFIRMAR]` resolvidos e queries reais coladas
- [ ] Totais de NF emitidas de agosto/2026 batem com relatório do Protheus (tolerância 0)
- [ ] Totais de devolução (qtd e valor) batem com `F1_TIPO='D'` no período
- [ ] NF cancelada some de "emitidas ativas" e aparece com data de cancelamento
- [ ] NF com entrega só na SE1 (não na SF2) é reconhecida como entregue
- [ ] Job horário roda 24 h sem falha; `last_update` visível no cabeçalho de todas as páginas
- [ ] TV: home renderiza em 1920×1080 sem barra de rolagem
- [ ] Clique em cada bloco abre a página correta; "Painel" volta
- [ ] Classificação manual e importação de planilha funcionam e sobrevivem ao próximo refresh
- [ ] Exportar Excel respeita os filtros da tela
- [ ] Nenhuma query no Protheus fora de `SELECT`; nenhuma credencial no repositório (usar `.env`)

---

## 9. Entregáveis por fase

| Fase | Entregável |
|---|---|
| 0 | `FASE0_RELATORIO.md`, `sql/00_descoberta/*.sql` |
| 1 | `db/migrations/001_dash.sql`, `sql/01_extracao/*.sql` (queries finais do Protheus, parametrizadas) |
| 2 | `etl/`, `motivos_map.yaml`, `README_ETL.md` |
| 3 | `api/`, `web/`, `modelo_importacao_motivos.xlsx`, URL de homologação |

Versionar tudo em repositório GitHub privado próprio (`amvox-dash-faturamento`), separado do Finance Suite, mas com o mesmo padrão de deploy.
