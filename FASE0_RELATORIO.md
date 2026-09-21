# FASE 0 — Descoberta e confirmação
**Dashboard TV Faturamento & Logística (AMVOX)** · execução em 21/09/2026
Base: TOTVS Protheus `CAN49P_170475_PR_PD` (SQL Server, somente leitura) · 33 queries em `sql/00_descoberta/`

> Todas as queries rodaram apenas `SELECT`, com `D_E_L_E_T_ = ''` (exceto onde o teste exigia ver a
> linha excluída, sempre rotulado), datas `CHAR(8) YYYYMMDD` e parâmetros por `DECLARE`/`SET`.
> O executor `sql/_runner.py` **bloqueia** qualquer verbo de escrita antes de enviar ao banco.

---

## REVISÃO 21/09 — validação contra o relatório TOTVS + decisões do Sílvio

Base: `Cancelamento P_Entrada 2026.xlsx` (506 itens · **304 NF de devolução** · 14/01 a 17/09/2026)
Queries: `21` a `25` em `sql/00_descoberta/`.

### Teste de cobertura: nossa regra pega todas as notas do relatório?

**Sim — 304 de 304 (100%).** Nenhuma faltou, nenhuma estava deletada, nenhuma com `F1_TIPO` diferente.
No mesmo período nossa regra devolve **2.512 NF**, ou seja **2.208 a mais** que o relatório.

A diferença **não é erro** — são dois universos distintos, e o discriminador é exato:

| `F1_FORMUL` | Significado | No relatório | Fora do relatório |
|---|---|---|---|
| **`'S'`** | Nota de entrada **emitida pela AMVOX** (formulário próprio, série 1) | **304 (100%)** | 0 |
| `''` | Devolução **emitida pelo cliente** (numeração e série do cliente) | 0 | 2.223 (100%) |

O relatório que você mandou é só o primeiro grupo. `F1_FORMUL = 'S'` separa os dois com 100% de
precisão — é a coluna "Form. Prop." do próprio relatório.

> **Decisão necessária:** o bloco "Devoluções" da TV mostra **todas** as devoluções (2.512 no período,
> visão comercial completa) ou **só as emitidas pela AMVOX** (304, visão do seu relatório)? Recomendo
> mostrar todas com quebra por origem — o cliente que devolve por nota própria devolve do mesmo jeito.

### Correção importante: a cobertura do motivo era maior do que reportei

Meu primeiro teste procurou `LIKE '%MOTIVO%'` e **perdeu uma segunda convenção** presente no seu
relatório: `"ENTR REF NF <n> MOT.: <causa>"`. Com o padrão correto:

| Janela | Origem | NF | Com motivo | % |
|---|---|---|---|---|
| **120 dias (ETL)** | AMVOX (`F1_FORMUL='S'`) | 147 | 147 | **100,0%** |
| **120 dias (ETL)** | Cliente | 830 | 823 | **99,2%** |
| 12 meses | AMVOX | 565 | 545 | 96,5% |
| 12 meses | Cliente | 3.804 | 2.156 | 56,7% |

Precisão do padrão verificada: **970 de 970** casos são marcador real de motivo — zero falsos
positivos (nenhum "MOTOR"/"REMOTO"). **A cobertura na janela do ETL é ~99,3%, não 84,6%.**

Vocabulário adicional que só aparece nas notas emitidas pela AMVOX: CNPJ INCORRETO, EMISSÃO
INCORRETA, DESTINATÁRIO INCORRETO, CLIENTE NÃO ACEITA DESCONTO, ENTREGA DEMORADA, SEM AGENDAMENTO,
PEDIDO CANCELADO, DESISTÊNCIA CLIENTE.

### Decisões que você tomou (incorporadas)

1. **Remessa fora do dash.** Confirmado nos dados: o corte `F2_VALFAT > 0` separa exatamente as duas
   naturezas em agosto/2026 — receita nos CFOPs **5101, 5102, 6101, 6107, 6109, 6118** (434 NF) e
   remessa/retorno nos CFOPs **5916, 6916, 5949, 6949, 5910, 6910, 5901, 5554, 5927, 6151, 6923**
   (1.454 NF, todas com valor faturado zero). Nenhum CFOP aparece nos dois lados.
2. **Data de entrega = campo do Financeiro (`SE1.E1_DTSAIDA`).** Passa a ser a fonte primária,
   **invertendo a precedência do SPEC** (que mandava SF2 primeiro). A divergência de 98,8% relatada
   na seção 2 fica explicada pela sua informação: a logística preenche via GFE um campo do cabeçalho
   da NF e, em paralelo, o campo da SE1 — são dois apontamentos distintos, e o do Financeiro é o
   correto para o painel.
3. **Todas as filiais**, restrito a operações de faturamento.
4. **Critério de receita = lote contábil 008820 (Vendas).** Confirmado: em agosto o lote 008820
   credita a conta de receita **3110101003** (R$ 15.853.313,21, valor com impostos). A chave contábil
   (`CT2_KEY`) embute filial + número da NF, mas é frágil para join horário — recomendo filtrar pelo
   **CFOP de receita** (lista acima) e reconciliar mensalmente contra a conta 3110101003.

### A escolha do campo do Financeiro se confirma nos dados — com uma ressalva séria

Medi a cobertura no universo **já decidido** (todas as filiais, só faturamento, remessa fora) —
`sql/00_descoberta/26_cobertura_entrega_universo_final.sql`:

| Mês | NF de faturamento | **SE1 (Financeiro)** | SF2 (Logística/GFE) |
|---|---|---|---|
| 202602 | 803 | **89,7%** | 86,2% |
| 202603 | 877 | **91,9%** | 98,4% |
| 202604 | 1.096 | **92,6%** | 97,4% |
| 202605 | 625 | **79,4%** | 96,0% |
| 202606 | 466 | **90,6%** | 52,8% |
| 202607 | 367 | **88,8%** | **1,4%** |
| 202608 | 434 | **61,3%** | 85,0% |
| 202609 (parcial) | 255 | **12,9%** | 85,5% |

Três conclusões:
1. **A cobertura da SE1 era muito melhor do que eu reportei** (50,5%). Aquele número estava diluído
   por títulos que não são NF de venda. **Excluindo remessa, fica em 79–93%** de fev a jul.
2. **O buraco de julho deixa de existir.** Era um problema do campo da logística (1,4%); o campo do
   Financeiro tem 88,8% em julho. A sua escolha resolve a pendência nº 4 do relatório original.
3. ⚠️ **O campo do Financeiro tem atraso de apontamento**: 61,3% em agosto e **12,9% em setembro**
   (mês corrente), contra 85% da logística. Isso é esperado — a baixa financeira vem depois —
   **mas afeta diretamente o bloco "Notas sem entrega" da TV**: as notas recentes vão aparecer como
   não entregues por falta de baixa, não por atraso logístico. Sugestões, você decide:
   *(a)* começar a contagem de "dias sem entrega" só após N dias da emissão (carência),
   *(b)* usar o campo do Financeiro e exibir o da logística como coluna auxiliar na página de
   detalhe, ou *(c)* manter como está e aceitar que o mês corrente fica inflado.

### Campo customizado do GFE — não existe
`sql/00_descoberta/23_gfe_campo_customizado.sql`

Procurei campos `F2_X*` no dicionário e nas colunas físicas da SF2010. Existem apenas
`F2_XDOCREF`, `F2_XFILREF`, `F2_XSERREF` (referência de remessa), `F2_XMPTRAN` e `F2_X_EXPO` —
**nenhum de data**. Ou seja: o GFE grava no campo **padrão `F2_DTENTR`**, não num customizado.
Isso fecha a explicação da divergência: dois processos, dois campos padrão, apontamentos distintos.

### DECISÕES FINAIS DO SÍLVIO (21/09) — gate da Fase 0 fechado

**1. Universo de devoluções = TODAS.** O relatório enviado serviu de apoio ao racional, mas não
contempla as devoluções emitidas pelos clientes. O dash considera os dois grupos; `F1_FORMUL`
vira apenas **atributo de origem** (AMVOX / CLIENTE), não filtro.

**2. Data de entrega = campo do Financeiro (`E1_DTSAIDA`) — e o indicador muda de natureza.**
Motivo dado pelo Sílvio: **é com base nesse campo que se geram os boletos de cobrança**. Portanto,
campo em branco não é falha de apontamento logístico — é **risco de caixa**. A data pode até estar
com folga (funcionando como previsão); **o que não pode é estar em branco.**

> Isso responde e **derruba** a sugestão de carência que eu havia feito. Quantifiquei
> (`sql/00_descoberta/27_risco_caixa_campo_em_branco.sql`, títulos de NF de faturamento desde fev/26):

| Situação | Títulos | Valor emitido | **Saldo em aberto** | Títulos em aberto | Idade média |
|---|---|---|---|---|---|
| Com data | 11.213 | R$ 78.179.347,99 | R$ 23.808.145,47 | 2.949 | 147 dias |
| **SEM data** | **1.571** | **R$ 27.326.277,11** | **R$ 9.391.903,41** | 952 | 63 dias |

Por faixa de idade, os sem data:

| Faixa | Títulos | Valor | Saldo em aberto |
|---|---|---|---|
| 0–2 dias | 72 | R$ 207.082,29 | R$ 207.082,29 |
| 3–7 dias | 257 | R$ 1.719.813,73 | R$ 1.714.564,00 |
| 8–15 dias | 89 | R$ 624.941,88 | R$ 615.001,00 |
| **mais de 15 dias** | **1.153** | **R$ 24.774.439,21** | **R$ 6.855.256,12** |

**Conclusão: carência não se justifica.** Só 72 títulos (R$ 207 mil) estão na janela de 0–2 dias
que eu temia ser ruído. O grosso — **1.153 títulos, R$ 6,86 milhões ainda em aberto** — já passou
de 15 dias. O bloco "sem entrega" da TV é, na prática, uma **fila de cobrança travada**, e sugiro
renomeá-lo para deixar isso explícito (ex.: "Notas sem data de entrega — cobrança pendente"), com
o card principal mostrando **o saldo em aberto em R$**, não só a contagem.

**3. Motivos = listar o que está na base**, até se definir um lugar mais apropriado. Sem taxonomia
fixa. Lista completa entregue em
`analises-claude/CLAUDE_MOTIVOS_DEVOLUCAO_BASE_2026-09-21.csv` — **116 grafias**, 2.704 NF
(`sql/00_descoberta/28_motivos_lista_da_base.sql`).

Achado relevante: **os dois universos quase não compartilham vocabulário** — 76 causas aparecem só
nas notas emitidas pela AMVOX, 32 só nas emitidas pelo cliente, e apenas 8 nas duas. São fenômenos
diferentes:

| Origem | Causas dominantes |
|---|---|
| **Cliente** (pós-venda) | CONSERTO (984), ACORDO COMERCIAL (808), DEFEITO FUNCIONAL (97), REGIÃO NORTE (85), LOGÍSTICO (41), AVARIA/EMBALAGEM |
| **AMVOX** (falha de entrega/fiscal) | CLIENTE NÃO AGENDOU (196), CUBAGEM INCORRETA (29), CLIENTE NÃO ACEITA DESCONTO (28), DESISTÊNCIA (25), PROD. NÃO EXPEDIDO (18), SOLICITAÇÃO DA DIRETORIA (16), PEDIDO INCORRETO/DIVERGENTE, BLOQUEIO ANATEL (10), ENTREGA DEMORADA (10) |

Recomendo que o donut da TV **quebre por origem** — misturar "conserto de garantia" com "cliente não
agendou" num único gráfico esconde as duas histórias.

### O campo do GFE (informação da T.I., 21/09) — `GW1_DTENTR` não existe; o campo real é `GWU_DTENT`

`sql/00_descoberta/29` a `33`.

A T.I. indicou `GW1_DTENTR`. **Esse campo não existe** — nem no dicionário (SX3) nem como coluna
física da `GW1010` (que existe, com 65 colunas). Os campos de data da GW1 são: `GW1_DTALT`,
`GW1_DTCAN`, `GW1_DTEMIS`, `GW1_DTFRE`, `GW1_DTIMPL`, `GW1_DTLIB`, **`GW1_DTPENT`** (Data *Prevista*
de Entrega), `GW1_DTPSAI`, `GW1_DTSAI`.

Procurando em todo o módulo GFE, o campo de entrega **efetiva** está em outra tabela:

| Tabela | Campo | Título | O que é |
|---|---|---|---|
| **`GWU010`** | **`GWU_DTENT`** | Dt Entrega | **data da entrega realizada** |
| GWU010 | `GWU_DTPENT` / `GWU_DTPENO` | Dt Prev Entr / Orig | data prevista (e a original) |
| GWU010 | `GWU_HRENT` | Hora Entrega | hora da entrega |
| GWU010 | `GWU_FLGENT` / `GWU_EVENTR` | Comp. Entrega / Evid. | comprovante e evidência |
| GWU010 | `GWU_XMOTAT` / `GWU_XOBS` | Mot. atraso / Obs | motivo do atraso (customizado) |

`GWU010` tem **143.923 linhas**, **92.785 com data de entrega real**, histórico de 03/07/2021 a
18/09/2026. O campo de motivo de atraso existe mas está praticamente vazio (**43 registros**).

### As três fontes, comparadas no universo decidido

| Mês | NF fat. | **SE1 (Financeiro)** | **GWU (GFE)** | SF2 | GWU previsão | SE1 **ou** GWU |
|---|---|---|---|---|---|---|
| 202602 | 803 | 89,7% | **92,9%** | 86,2% | 37,1% | **94,0%** |
| 202603 | 877 | 91,9% | 90,8% | 98,4% | 64,4% | **94,3%** |
| 202604 | 1.096 | 92,6% | **94,8%** | 97,4% | 76,6% | **96,5%** |
| 202605 | 625 | 79,4% | **85,6%** | 96,0% | 74,6% | **90,9%** |
| 202606 | 466 | 90,6% | 88,6% | 52,8% | 79,6% | **97,6%** |
| 202607 | 367 | 88,8% | **89,4%** | 1,4% | 73,6% | **91,6%** |
| 202608 | 434 | 61,3% | **67,7%** | 85,0% | 71,7% | 71,2% |
| 202609 | 277 | 12,3% | 14,1% | 85,9% | 48,7% | 18,1% |

**E o mais importante: as duas concordam.** Nas 3.917 NFs que têm as duas datas, **96,5% são
idênticas** e a diferença média é de **0 dias**. Ou seja, `GWU_DTENT` e `E1_DTSAIDA` são a mesma
informação — a entrega real. Quem destoa é a `F2_DTENTR` da SF2 (aquela divergência de 98,8% da
seção 2), que não deve ser usada.

**Duas correções ao que eu havia concluído:**
1. A divergência não era "Financeiro × Logística". **O Financeiro e o GFE contam a mesma história**;
   o campo fora de linha é o da SF2.
2. O atraso do mês corrente **não é demora do Financeiro em lançar**: o GFE tem a mesma baixa
   cobertura em setembro (14,1% × 12,3%). Isso significa que as notas recentes **ainda não foram
   entregues/confirmadas** — não que a baixa financeira esteja emperrada. O problema de caixa que
   você apontou continua real e está nos **1.153 títulos com mais de 15 dias**, não no mês corrente.

**Sugestão (sua decisão, não mudei nada):** manter `E1_DTSAIDA` como norte, conforme você definiu, e
usar a GWU de três formas complementares:
- **fallback** quando a SE1 estiver vazia → cobertura sobe de ~90% para **94–97%**;
- **`GWU_DTPENT` como a "data prevista"** que você mencionou (a de folga) → permite mostrar
  *previsto × realizado* e medir atraso de verdade, que é o que uma TV de logística pede;
- **`GWU_FLGENT`/`GWU_EVENTR`** como prova de entrega na página de detalhe.

### DECISÃO FINAL da data de entrega (Silvio, 21/09)

```
dt_entrega = COALESCE( NULLIF(SE1.E1_DTSAIDA,'') ,  NULLIF(GWU010.GWU_DTENT,'') )
```

**Financeiro como norte; GFE só quando o Financeiro estiver vazio.** `SF2.F2_DTENTR` fica fora.
Cobertura resultante: **94–97%** (fev–jul/26), contra ~90% só com o Financeiro.
Join da GWU: `GWU_FILIAL = F2_FILIAL` e `LTRIM(RTRIM(GWU_NRDC)) = LTRIM(RTRIM(F2_DOC))`,
agregando por `MAX(NULLIF(GWU_DTENT,''))` (a GWU tem uma linha por trecho).

### Consequência para o Plano B

Com cobertura real de **~99%** na janela do ETL, o Plano B deixa de ter qualquer função de
preenchimento de lacuna. Ele fica **só como normalização** (93 grafias → ~10 causas) mais uma fila
residual de 7 notas em 120 dias. Ver seção 8 revisada.

---

## Resumo executivo — o que muda no projeto

| # | Achado | Impacto |
|---|---|---|
| 1 | **O banco é `Latin1_General_BIN` (case-sensitive).** Os `LIKE '%ENTREG%'` do SPEC falham em silêncio | Toda query de dicionário precisa de `COLLATE`. Foi o que escondeu o campo da SE1 na primeira tentativa |
| 2 | **Há 3 filiais**, não uma: `010102` (22.700 NF/12m), `010103` (3.858), `010101` (2) | Filial entra em toda chave e em todo filtro. Confirmar com você se a TV mostra as 3 ou só a 010102 |
| 3 | **"Notas emitidas" é ambíguo**: 1.888 NF em ago/26, mas só **434 têm faturamento**; 1.454 são remessa/retorno (CFOP 5916/6916/5949/6949) | Decisão sua: o número da TV é 434 ou 1.888? Muda o painel inteiro |
| 4 | **As duas datas de entrega divergem em 98,8%** das NFs que têm ambas (SE1 em média 11 dias antes da SF2) | A precedência "SF2 → SE1" do SPEC **não é segura**. Pendência aberta |
| 5 | **Motivo de devolução não está na SC5** (a hipótese do SPEC), e sim na `F1_MENNOTA` da própria devolução, no padrão `"MOTIVO DEV: <causa>"`, com **84,6% de cobertura** na janela de 120 dias | Plano B **parcial** (ver seção 7) |
| 6 | **12 NFs canceladas continuam ativas na SF2** (uma de R$ 144.982,32) | O ETL não pode confiar só em `D_E_L_E_T_`; tem de cruzar a SF3 |

---

## 1. Ambiente · `[CONFIRMAR]` sufixo e filiais
`sql/00_descoberta/00_ambiente_filiais.sql`

Sufixo **`010` confirmado** para SF2/SF1/SE1/SC5/SF3/SX3. Existem também os sufixos `020` e `990`
(SC5020, SE1020, SF1020, SF2020, SF1990, SF2990, SC5990) — outras empresas/ambientes no mesmo banco.
**Usar sempre `010`.**

Filiais com NF de saída nos últimos 12 meses:

| Filial | NF | Primeira | Última |
|---|---|---|---|
| 010102 | 22.700 | 20250922 | 20260921 |
| 010103 | 3.858 | 20250922 | 20260917 |
| 010101 | 2 | 20260528 | 20260529 |

> ⚠️ O SPEC assume filial única (`FILIAL` default na importação de planilha, seção 7.2). **Pendência
> de decisão:** o painel consolida as 3 filiais, mostra só a 010102, ou tem filtro de filial?

---

## 2. `[CONFIRMAR]` Data de entrega — SF2 e SE1

`sql/00_descoberta/01_sx3_data_entrega.sql` · `02_sx3_se1_candidatos.sql` · `03_sx3_entrega_case_insensitive.sql`

A query do SPEC (3.1) encontrou **só a SF2**. Não achei nada na SE1 com aquele filtro — e, seguindo
sua instrução de não assumir, fui atrás dos candidatos: listei todos os campos de data da SE1, todos
os `E1_X*` e as colunas físicas da SE1010. O campo apareceu ali, e a causa do silêncio é a
**collation binária**: o título é `Dt. Entrega` e o filtro procurava `%ENTREG%` em maiúsculas.

### Campos confirmados

| Tabela | Campo | Título (SX3) | Tipo | Tam | Coluna física |
|---|---|---|---|---|---|
| SF2 | **`F2_DTENTR`** | Data Entrega | D | 8 | `varchar(8)` ✓ |
| SE1 | **`E1_DTSAIDA`** | Dt. Entrega | D | 8 | `varchar(8)` ✓ |

Nenhum dos dois é campo customizado (`X`) — são campos padrão do Protheus. Não existem
`F2_XDTENTR` nem `E1_XDTENTR` (os únicos `E1_X*` são `E1_XMPTRAN`, `E1_XPORPRO`, `E1_X_EXPO`).

Também presentes, **não** usados como entrega efetiva: `SC5.C5_FECENT` (data de entrega do pedido),
`SC5.C5_SUGENT` (sugerida), `SC9.C9_DATENT` (liberação).

### `[TESTAR]` Percentual de preenchimento
`sql/00_descoberta/04_preenchimento_entrega.sql` · `05_volumetria_12m_e_evolucao.sql`

| Recorte | Total | Com data | % |
|---|---|---|---|
| SF2 · 01/08 a 18/09/2026 (janela do SPEC) | 2.839 | 2.517 | **88,7%** |
| SE1 · 01/08 a 18/09/2026 | 2.341 | 1.183 | 50,5% |
| **Combinado por NF (SF2 → SE1)** | 2.839 | 2.575 | **90,7%** |
| SF2 · 12 meses · filial 010102 | 22.700 | 10.168 | 44,8% |
| SF2 · 12 meses · filial 010103 | 3.858 | 1.494 | 38,7% |

A diferença entre 88,7% e 44,8% tem explicação: **o preenchimento começou em fev/2026.**

| Mês | NF saída | % com data de entrega |
|---|---|---|
| 202509 – 202601 | 1.494 – 2.187 | **0% a 0,1%** |
| 202602 | 2.162 | 71,6% |
| 202603 | 2.743 | 86,0% |
| 202604 | 2.361 | 94,3% |
| 202605 | 2.171 | 87,2% |
| 202606 | 1.542 | 67,1% |
| **202607** | 1.927 | **1,5%** ⚠️ |
| 202608 | 1.888 | 88,8% |
| 202609 (parcial) | 1.006 | 88,9% |

> ⚠️ **Julho/2026 é um buraco**: 28 de 1.927 notas com data (1,5%). Com a janela de 120 dias do
> SPEC, julho entra no painel e vai produzir ~1.900 notas classificadas como "sem entrega" que na
> verdade são falta de apontamento. **Pendência:** foi parada de processo, migração, ou as notas de
> julho realmente não foram baixadas? Não ajustei nada — só reporto.

### ⚠️ Pendência crítica: as duas fontes não concordam
`sql/00_descoberta/19_divergencia_datas_entrega.sql` · `20_semantica_e1_dtsaida.sql`

O SPEC (3.2) manda usar **SF2 primeiro; se vazio, SE1**. Testei se as duas dizem a mesma coisa nas
NFs que têm as duas (fev–set/2026):

| | |
|---|---|
| NF com as duas datas | 3.400 |
| Iguais | **41 (1,2%)** |
| Divergentes | **3.359 (98,8%)** |
| Diferença média | SE1 **11 dias antes** da SF2 |

Distribuição: SE1 mais de 7 dias antes → 2.231 · SE1 1-7 dias antes → 480 · SE1 mais de 7 dias
depois → 410 · SE1 1-7 dias depois → 238 · iguais → 41.

Testei a hipótese de que `E1_DTSAIDA` fosse data de *saída* (o nome do campo sugere isso, apesar do
título "Dt. Entrega"): **não é** — só 4,8% coincidem com a emissão, e a média é 17 dias após a
emissão. Já a `F2_DTENTR` fica em média 29 dias após a emissão e tem **99 casos com data anterior à
emissão da própria nota** (impossível para uma entrega).

Conclusão: os dois campos são alimentados por processos diferentes e nenhum dos dois é
obviamente "a" data de entrega. **Não escolhi por conta própria.** Preciso que você diga qual
processo alimenta cada um (quem preenche a SF2? o financeiro preenche a SE1 na baixa?), porque a
regra de precedência muda o indicador "notas sem entrega" — o principal bloco da TV.

---

## 3. `[CONFIRMAR]` Motivo de devolução

`sql/00_descoberta/06_sx3_motivo_devolucao.sql` · `07`, `08`, `09`, `10`, `11`

### A hipótese do SPEC está errada — o motivo não vem da SC5

Campos estruturados na NF de devolução, medidos sobre as **4.368 devoluções de 12 meses**:

| Campo | Descrição (SX3) | Preenchido |
|---|---|---|
| `F1_MOTRET` | Cod. Motivo do Retorno | **0** |
| `F1_MOTIVO` | Motivo Devol (Aprov/Rej AFIP) | **0** |
| `F1_HISTRET` | Histórico do Retorno (memo) | **0** |
| `F1_DEVMERC` | Devol. merc. não recebida | **0** |
| `F1_MENPAD` | Mensagem padrão | 563 |
| **`F1_MENNOTA`** | **Mensagem para Nota Fiscal** | **2.726 (62,4%)** |

Do lado da SC5 (caminho proposto pelo SPEC, via `SD1 → SD2 → SC5`): `C5_MENNOTA` está preenchido em
98% dos itens, **mas não é motivo** — é texto logístico do pedido original. Amostra real:
`"CD 1500 - OC 4803806 - AGENDA 22/11 - SENHA 81878"`, `"PEDIDO MASTER SALES: 616340"`,
`"LOCAL: CENTRO DE CONVENCOES E FEIRAS DA AMAZONIA..."`. **Descartado.**

### Onde o motivo realmente está

Na **`F1_MENNOTA` da própria NF de devolução**, numa convenção informal mas consistente:
`"MOTIVO DEV: <causa>"`, muitas vezes com número de OS/chamado. Exemplos reais:

```
MOTIVO DEV: LOGISTICO
MOTIVO DEV: DEFEITO FUNCIONAL - OS 2975215-1
MOTIVO DEV.: ACORDO COMERCIAL/ OS: 3030833-1
MOTIVO DEV.: CONSERTO/ OS: 3044900-1/SP
MOTIVO DEV: CLIENTE NAO AGENDOU ENTREGA
MOTIVO DEV: CUBAGEM INCORRETA CLIENTE RECUSOU
```

### `[TESTAR]` Cobertura

| Janela | NF devolução | Com "MOTIVO" | % |
|---|---|---|---|
| **120 dias (janela do ETL)** | 976 | 826 | **84,6%** |
| 12 meses | 4.368 | 2.303 | 52,7% |

Por mês, mostra a mesma adoção recente da data de entrega:

| Mês | 202509 | 202510 | 202511 | 202512 | 202601 | 202602 | 202603 | 202604 | 202605 | 202606 | 202607 | 202608 | 202609 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| % com motivo | 0 | 14,2 | 2,9 | 15,6 | 43,2 | 86,4 | 86,6 | 95,4 | 91,6 | 74,6 | 97,4 | 82,3 | 67,0 |

### Taxonomia real (≠ a proposta no SPEC)

Há **93 grafias distintas** para ~10 causas. Normalizando por palavra-chave (12 meses, 2.303 NF):

| Causa normalizada | Qtd | % |
|---|---|---|
| CONSERTO | 995 | 43,2% |
| ACORDO_COMERCIAL | 823 | 35,7% |
| LOGISTICO | 163 | 7,1% |
| NAO_AGENDOU | 98 | 4,3% |
| DEFEITO_FUNCIONAL | 97 | 4,2% |
| AVARIA | 64 | 2,8% |
| RECUSA_CLIENTE | 34 | 1,5% |
| NAO_CLASSIFICADO | 12 | 0,5% |
| ERRO_PEDIDO | 10 | 0,4% |
| RETORNO_EVENTO | 7 | 0,3% |

> A lista do SPEC (seção 4: AVARIA, RECUSA, ERRO_PEDIDO, FISCAL, ARREPEND, OUTRO) **não reflete a
> operação**: as duas maiores causas reais (CONSERTO 43% e ACORDO COMERCIAL 36%) não existem nela, e
> FISCAL/ARREPEND não aparecem nos dados. Sugiro substituir a tabela `dash_motivo_padrao` pela
> taxonomia acima — decisão sua, na Fase 1.

---

## 4. `[CONFIRMAR]` Cancelamento

`sql/00_descoberta/12_cancelamentos.sql` · `14_sf3_estrutura.sql` · `15_cancelamento_regra_final.sql`

**`F3_DTCANC` é a data de cancelamento** — confirmado (campo SX3 "Dt. Cancel. / Data do
Cancelamento", D/8). Amostra real de 21/09/2026: NF 000279582 série 1, emitida 20260919, cancelada
20260921, R$ 6.387,34.

Para separar saída de entrada na SF3, **`F3_ENTRADA` não serve** (é "Data de Entrada Contábil",
sempre preenchida — minha primeira tentativa retornou zero por causa disso). O discriminador correto
é o **CFOP (`F3_CFO` iniciando em 5 ou 6)**.

### Regra validada — 834 NF de saída canceladas em 12 meses

| Situação na SF2 | Qtd | % |
|---|---|---|
| `D_E_L_E_T_ = '*'` (excluída) | 822 | 98,6% |
| **`D_E_L_E_T_ = ''` (ainda ATIVA)** | **12** | **1,4%** |
| Sem linha na SF2 | 0 | 0% |

A premissa do SPEC está certa em 98,6% dos casos, **mas não é absoluta**. As 12 exceções apareceriam
como notas emitidas válidas. Entre elas, a NF **000249850 de 25/09/2025, R$ 144.982,32**, e outras
com valor zerado (0,00) mas ainda ativas.

> **Regra para o ETL:** marcar `CANCELADA` por `LEFT JOIN SF3 WHERE F3_DTCANC <> ''`, **não** por
> `D_E_L_E_T_`. Caso contrário, 12 notas (R$ ~156 mil) entram como faturamento válido.
> As 12 divergências ficam como **linha de pendência** para conferência — não ajustei nada.

Volume mensal de cancelamentos (12m): 28 a 113 por mês, total 1.027 (incluindo entradas).

### Protocolo de cancelamento NF-e
`sql/00_descoberta/12_cancelamentos.sql` (bloco d)

**Não existem** as tabelas `SPED050`/`SPED052` neste banco. As únicas tabelas do gênero são `CTE010`
e `CTE020` (Conhecimento de Transporte). Conforme o próprio SPEC 3.3 — **exibir apenas a data de
cancelamento**, sem número de protocolo.

---

## 5. `[CONFIRMAR]` Devoluções e CFOPs reais

`sql/00_descoberta/13_cancel_refinado_e_cfop.sql`

`SF1.F1_TIPO = 'D'` identifica a devolução — confirmado (4.368 NF em 12 meses).
O vínculo com a venda (`D1_NFORI`) está preenchido em **99,8%** dos 6.256 itens — o join é confiável.

CFOPs realmente presentes (12 meses):

| CFOP | Itens | NF | Valor (R$) | Comentário |
|---|---|---|---|---|
| 1201 | 3.048 | 2.209 | 20.675.115,52 | devolução de venda, dentro do estado |
| 2201 | 3.044 | 2.056 | 11.945.707,36 | devolução de venda, fora do estado |
| 1202 | 51 | 35 | 54.172,40 | revenda |
| 2203 | 44 | 37 | 241.167,34 | **não previsto no SPEC** |
| 2202 | 36 | 31 | 28.046,25 | revenda |
| 2914 | 12 | 1 | 6.593,31 | **retorno de remessa — não é devolução de venda** |
| 2208 | 9 | 1 | 5.812,93 | **não previsto** |
| 2410 | 6 | 2 | 471.678,66 | previsto |
| 1410 | 4 | 4 | 13.356,30 | previsto |
| 2949 | 2 | 2 | 519,71 | **outras saídas/entradas — não é devolução** |

Os CFOPs esperados pelo SPEC se confirmam e concentram 99,4% do volume (1201+2201). Sugiro **filtrar
por CFOP** na Fase 1 (`1201, 2201, 1202, 2202, 2203, 1410, 2410`) para não contaminar o indicador com
2914/2949/2208, que são retorno de remessa.

---

## 6. `[CONFIRMAR]` Reaproveitamento — view `VW_AZ_FATURAMENTO_ANALITICO_NOVO`

`sql/00_descoberta/16_view_reaproveitamento_e_canal.sql` · `17_view_crosscheck.sql` · `18_divergencias_view.sql`

A view **existe** (42 colunas) e entrega NF, cliente, CNPJ, UF, transportadora, valor, CMV, LB,
grupo de vendas, vendedor, e separa `ORIGEM` em **FAT / DEV / BON**. Também traz `DT SAI` e
`1 RECEBIMENTO`.

Cruzamento de agosto/2026:

| Fonte | NF | Valor (R$) |
|---|---|---|
| SF2010 direto | 1.888 | 13.337.597,23 |
| View `ORIGEM='FAT'` | 434 | **13.337.597,23** ✓ |
| SF1 tipo D | 158 | 1.894.380,94 |
| View `ORIGEM='DEV'` | 239 | −2.062.268,01 ✗ |

**Veredito:**
- **Faturamento: usar a view.** O valor bate ao centavo. A diferença de contagem está explicada:
  das 1.888 notas da SF2, **1.454 têm `F2_VALFAT = 0`** e são remessa/retorno (CFOP 6949 em 538 NF,
  6916 em 478, 5916 em 240, 5949 em 149). A view corretamente considera as 434 com faturamento.
- **Devolução: NÃO usar a view.** Diverge de SF1 em quantidade (239 × 158) e em critério de valor.
  Extrair devolução direto de `SF1`/`SD1`, como nas queries desta fase.
- ⚠️ A view é **analítica por item** (PRODUTO/CODPRO/QTD) — para contagem de NF exige
  `COUNT(DISTINCT NF)`, e o campo `NF` vem no formato `'1  -000276100'` (série + `-` + número).
- ⚠️ `DT SAI` da view **não segue** a regra do SPEC: na NF 000276123, a view traz 18/08, a
  `F2_DTENTR` traz 30/07 e a `E1_DTSAIDA` traz 04/09. Três fontes, três datas. Reforça a pendência
  da seção 2.

### Canal B2B/B2C (`[CONFIRMAR]` citado na seção 4 do SPEC)
Candidato: `SA1.A1_TIPO` → **F = 46.450 · R = 12.931 · X = 12 · L = 1**. No padrão Protheus,
F = consumidor final, R = revendedor, X = exportação, L = produtor rural. É o candidato viável, mas
**precisa da sua confirmação** de que "F" equivale a B2C na prática da AMVOX — há clientes pessoa
jurídica classificados como F. Alternativa: `A1_GRPVEN` (grupo de vendas), mas 34.279 clientes estão
com o campo em branco, o que o inviabiliza sozinho.

`F2_TRANSP` está preenchido (0219 em 2.742 NF, 0169 em 1.195, 324 em 0006), com **770 NF sem
transportadora** no trimestre — o filtro por transportadora da tela "Sem entrega" precisa tratar o
branco.

---

## 7. `[TESTAR]` Volumetria — 12 meses

`sql/00_descoberta/05_volumetria_12m_e_evolucao.sql`

| Mês | NF saída | Valor saída (R$) | NF devolução | Valor devolução (R$) |
|---|---|---|---|---|
| 202509 | 1.494 | 32.385.133,23 | 258 | 2.425.424,62 |
| 202510 | 3.077 | 33.230.501,45 | 660 | 6.599.989,59 |
| 202511 | 1.998 | 16.210.920,57 | 346 | 703.258,58 |
| 202512 | 2.004 | 22.739.043,28 | 495 | 7.201.941,18 |
| 202601 | 2.187 | 20.585.153,42 | 366 | 1.481.228,90 |
| 202602 | 2.162 | 15.317.337,76 | 280 | 1.373.664,53 |
| 202603 | 2.743 | 17.586.029,53 | 411 | 3.423.405,98 |
| 202604 | 2.361 | 20.622.668,88 | 347 | 1.683.506,22 |
| 202605 | 2.171 | 15.891.045,46 | 310 | 2.255.615,06 |
| 202606 | 1.542 | 7.343.324,74 | 284 | 1.974.280,56 |
| 202607 | 1.927 | 8.792.535,03 | 347 | 1.055.543,28 |
| 202608 | 1.888 | 13.337.597,23 | 158 | 1.894.380,94 |
| 202609 (parcial) | 1.006 | 6.562.726,19 | 106 | 3.907.427,74 |
| **Total** | **26.560** | — | **4.368** | — |

**Dimensionamento:** ~26,6 mil NF de saída e 4,4 mil devoluções em 12 meses. Na janela de 120 dias
do ETL são ~6 mil NF e ~1 mil devoluções. É volume pequeno: o cache cabe folgado e o job de 1 h não
tem risco de estourar os 5 minutos do SPEC. Nenhuma preocupação de performance.

---

## 8. Recomendação objetiva — Plano B

> ⚠️ **REVISADO em 21/09** — a medição original subestimava a cobertura (padrão `%MOTIVO%`
> perdia a convenção `MOT.:`). Ver a seção de revisão no topo. Recomendação atualizada abaixo.

**Plano B: ATIVO apenas como NORMALIZAÇÃO — não como fonte de motivo.**

Com a medição corrigida, a cobertura na janela do ETL é **~99,3%** (100% nas notas emitidas
pela AMVOX, 99,2% nas emitidas pelo cliente). O ERP **é** a fonte do motivo. O que resta:
- **Dicionário de palavras-chave obrigatório** (`motivos_map.yaml`): 93 grafias para ~10 causas,
  em duas convenções (`MOTIVO DEV:` e `ENTR REF NF … MOT.:`). Sem isso o donut da TV é ilegível.
- **Fila "A classificar" residual**: ~7 notas em 120 dias. Tela de classificação individual (7.1)
  resolve; **upload de planilha (7.2) não se justifica** — sugiro cortar do escopo.

<details><summary>Recomendação original de 21/09 (antes da correção) — mantida para histórico</summary>

**Plano B: ATIVO, porém em modo complementar (não como fonte principal).**

Justificativa em números:
- O gatilho do SPEC (3.2) é `COM_MOTIVO / NF_DEVOLVIDAS < 70%`. Na janela real do ETL (120 dias) a
  cobertura é **84,6% — acima do gatilho**. Pelo critério literal, o Plano B não seria obrigatório.
- Mas ele é necessário por dois outros motivos, e por isso recomendo ativar:
  1. **Padronização.** São **93 grafias distintas** (`"MOTIVO DEV:"`, `"MOTIVO DEV.:"`,
     `"MOTIVO DEV.:  "`, com e sem OS, com sufixo de UF). Sem o dicionário de palavras-chave
     (`motivos_map.yaml`) e a fila "A classificar", o donut da TV fica ilegível. O mapeamento que
     testei já resolve **99,5%** do texto existente — é barato e funciona.
  2. **A lacuna de 15,4%** (150 NF nos 120 dias) precisa de algum caminho de classificação manual,
     senão vira uma fatia "sem motivo" permanente no painel.
- **Não** recomendo a classificação individual e o upload de planilha como esforço prioritário: com
  84,6% vindo do ERP, a fila manual é pequena. Sugiro entregar primeiro o mapeamento automático e a
  tela de classificação individual (7.1), e deixar o upload de planilha (7.2) para depois, se a fila
  justificar.

</details>

---

## 9. Pendências que precisam de decisão sua (bloqueiam a Fase 1)

1. ~~**Filial**~~ ✅ **RESOLVIDO 21/09: todas as filiais**, restrito a operações de faturamento.
2. ~~**Definição de "nota emitida"**~~ ✅ **RESOLVIDO 21/09: só faturamento (receita, lote 008820)** —
   remessa fica fora. Em ago/26 são **434 NF**, não 1.888.
3. ~~**Data de entrega**~~ ✅ **RESOLVIDO 21/09: usar `SE1.E1_DTSAIDA` (campo do Financeiro)** como
   fonte primária — inverte a precedência do SPEC. A logística preenche o campo do cabeçalho via GFE;
   o do Financeiro é o considerado correto. ✅ Efeito colateral **esclarecido e aceito**: o campo
   alimenta a cobrança, então branco = risco de caixa, e a fila deve aparecer mesmo. Sem carência
   (só 72 títulos/R$ 207 mil estão na faixa 0–2 dias; 1.153 títulos já passaram de 15 dias).
4. **Julho/2026** — o vazio de 98,5% em data de entrega é real ou falha de apontamento? Ele entra na
   janela de 120 dias do painel.
5. ~~**Taxonomia de motivos**~~ ✅ **RESOLVIDO 21/09: listar o que está na base**, sem taxonomia
   fixa, até se definir um lugar apropriado para o campo. Lista das 116 grafias entregue em
   `analises-claude/CLAUDE_MOTIVOS_DEVOLUCAO_BASE_2026-09-21.csv`.
5b. ~~**Universo de devoluções**~~ ✅ **RESOLVIDO 21/09: TODAS** — `F1_FORMUL` vira atributo de
   origem (AMVOX/CLIENTE), não filtro.
6. **Canal B2B/B2C** — `A1_TIPO` (F/R) serve como regra?
7. **12 NFs canceladas ativas na SF2** — conferir com o fiscal (uma de R$ 144.982,32).
8. **`.env`** — o SPEC pede credenciais em `.env` e ele não existe. Hoje as credenciais estão nos
   scripts de `.claude/scripts/`, por decisão sua registrada. Para o repositório novo
   (`amvox-dash-faturamento`), crio o `.env` + `.gitignore` na Fase 1 — confirme.

---

## 10. Arquivos entregues

```
FASE0_RELATORIO.md            este documento
sql/_runner.py                executor somente-leitura (bloqueia verbos de escrita)
sql/00_descoberta/
  00_ambiente_filiais.sql            sufixo de tabela, outros ambientes, filiais ativas
  01_sx3_data_entrega.sql            query do SPEC 3.1 (achou só a SF2)
  02_sx3_se1_candidatos.sql          busca ampla na SE1 (datas, E1_X*, colunas físicas)
  03_sx3_entrega_case_insensitive.sql  refeita com COLLATE — achou E1_DTSAIDA
  04_preenchimento_entrega.sql       % SF2, % SE1 e combinado com precedência
  05_volumetria_12m_e_evolucao.sql   volumetria 12m + evolução do preenchimento
  06_sx3_motivo_devolucao.sql        candidatos a motivo (SC5, SF1, SD1)
  07_existencia_fisica_campos.sql    conferência SX3 × colunas físicas
  08_motivo_preenchimento.sql        preenchimento de cada candidato + vínculo D1_NFORI
  09_motivo_amostra_texto.sql        conteúdo real dos textos livres
  10_motivo_taxonomia_real.sql       cobertura mensal + 93 grafias
  11_motivo_normalizado_120d.sql     taxonomia normalizada + cobertura na janela do ETL
  12_cancelamentos.sql               amostra do SPEC, volume mensal, tabelas SPED
  13_cancel_refinado_e_cfop.sql      1ª tentativa do filtro de saída + CFOPs reais
  14_sf3_estrutura.sql               por que F3_ENTRADA não serve de discriminador
  15_cancelamento_regra_final.sql    regra validada + as 12 exceções
  16_view_reaproveitamento_e_canal.sql  colunas da view, ORIGEM, canal, transportadora
  17_view_crosscheck.sql             view × SF2 e view × SF1
  18_divergencias_view.sql           explicação das 1.454 notas de valor zero
  19_divergencia_datas_entrega.sql   SF2 × SE1: 98,8% divergentes
  20_semantica_e1_dtsaida.sql        teste da hipótese "E1_DTSAIDA = data de saída"
  -- revisão 21/09, após o relatório Cancelamento P_Entrada 2026 --
  21_motivo_revisado_e_formul.sql    F1_FORMUL como discriminador + motivo com padrão amplo
  22_precisao_padrao_motivo.sql      precisão do padrão (970/970, zero falso positivo)
  23_gfe_lp008820_remessa.sql        campos F2_X* (GFE), CT5, CFOPs de remessa
  24_lote008820_receita.sql          lote 008820 → conta de receita 3110101003
  25_criterio_receita_cfop.sql       CFOP de receita × CFOP de remessa (corte VALFAT>0)
  26_cobertura_entrega_universo_final.sql  cobertura SE1 × SF2 no universo decidido
  27_risco_caixa_campo_em_branco.sql  títulos sem data: valor e saldo em aberto por faixa
  28_motivos_lista_da_base.sql       lista das causas reais, por origem
  29_gfe_gw1_dtentr.sql              GW1_DTENTR (indicado pela T.I.) — não existe
  30_gw1_candidatos_data.sql         todos os campos de data do GFE
  31_gwu_entrega_real.sql            estrutura da GWU (entrega efetiva)
  32_gwu_volume_e_amarracao.sql      volume da GWU e amarração com a NF
  33_tres_fontes_comparadas.sql      SE1 × GWU × SF2 mês a mês + concordância
```

Também em `analises-claude/`:
`CLAUDE_MOTIVOS_DEVOLUCAO_BASE_2026-09-21.csv` — as 116 grafias de motivo da base, por origem.

**Gate da Fase 0: ENCERRADA em 21/09** — todas as decisões bloqueantes tomadas e o aprendizado
persistido na skill `dash-tv-faturamento` e na memória `project_dash_tv_faturamento`. Restam apenas itens não
bloqueantes (nº 4 julho, nº 6 canal B2B/B2C, nº 7 as 12 NFs canceladas, nº 8 `.env`).
Aguardando seu "ok" para iniciar a Fase 1.
Nada foi criado no Protheus, nenhuma tabela foi criada no Supabase, nenhum ETL ou frontend iniciado.
