# Especificação — Dashboard TV Faturamento & Logística (AMVOX)

**Versão 1.6** · 25/09/2026 · Dono das definições: Silvio Amaral (Controladoria) · Mantido por: Claude

> Documento de consulta e de validação. Descreve **o que cada número do painel significa e como é
> calculado**. Toda definição nova aprovada pelo Silvio gera uma nova versão deste documento, com a
> mudança registrada no **Histórico** (última seção). O código do painel declara a versão que
> implementa; se os dois divergirem, a atualização automática avisa no resumo.

## 1. Para que serve

Painel em duas camadas, alimentado pelo Protheus (TOTVS):

| Tela | Pergunta que responde |
|---|---|
| **TV (início)** | Como está o mês: notas emitidas, maiores clientes, notas sem entrega, devoluções |
| **Notas emitidas** | Quais notas saíram, de quanto, e em que situação cada uma está |
| **Top clientes** | Quem concentra o faturamento |
| **Sem data de entrega** | Quais notas ainda não têm entrega registrada — a fila de ação |
| **Devoluções** | O que voltou, de quem e por quê |
| **Região × linha** | Onde e o que se vende (Nordeste, Sudeste… × Áudio, Lar…) |
| **Auditoria** | Desvios encontrados por controles automáticos (subgrupos LOG e FAT) |

Todas as telas de detalhe têm filtros, filtro cruzado (clicar em qualquer barra, linha ou célula
filtra a tela inteira) e exportação para Excel.

**Consulta pelo número da NF** — campo *NF* em todas as telas de detalhe. Aceita o número com ou sem
zeros à esquerda e também o começo dele ("279825", "000279825" ou "2798"). Com a NF digitada, a
competência deixa de filtrar: a nota é encontrada em qualquer mês. O que o campo procura em cada tela:

| Tela | Procura na |
|---|---|
| Notas emitidas · Top clientes · Região × linha | NF de venda |
| Sem data de entrega | NF da fila; no quadro de venda à ordem, a NF-mãe **ou** qualquer remessa dela (mostra também as concluídas) |
| Devoluções | NF de devolução **ou** a NF de venda de origem |
| Auditoria | NF-mãe **ou** remessa da ocorrência |

## 2. Princípios que valem para tudo

- **Base somente leitura.** O painel só lê o Protheus; nunca grava nada no ERP.
- **Faturamento = número oficial da FAT PLUS.** Todo valor de faturamento bate com a consulta
  *Faturamento Analítico Plus* (visão `VW_AZ_FATURAMENTO_ANALITICO_NOVO`, origem FAT). A conferência é
  nota a nota. Única diferença conhecida: a NF 000278810 (R$ 5.249,73), que a visão conta estando
  excluída — nesse ponto o painel está certo.
- **Bonificação não é faturamento.** Fica fora de todos os totais.
- **Leitura da AMVOX = faturamento líquido:** bruto − devoluções (e descontos incondicionais) do mesmo
  mês. A visão já vem líquida do desconto incondicional.
- **Valor sempre acompanhado da participação (%).** Todo quadro-resumo mostra o R$ e quanto ele
  representa do total da dimensão inteira (não só dos itens visíveis).
- **Divergência sem explicação vira pendência.** Nada é ajustado ou arredondado para "fechar".
- **Período dos dados:** desde **01/01/2025**, até o momento da última atualização.

## 3. O que é uma nota emitida (faturamento)

Entra no painel a nota de saída que é **venda** — a régua é a mesma da FAT PLUS:

1. Nota de saída normal — ficam fora as notas de **devolução de compra** ao fornecedor e as de
   **beneficiamento** (tipos D e B).
2. Ao menos um item cuja operação (TES) **gera duplicata**, e que **não** seja venda de ativo
   imobilizado (CFOP 5551/6551 — sucata, equipamentos).
3. **Valor da nota** = soma desses itens, com IPI. Itens de bonificação na mesma nota não entram.

Remessas, bonificações, demonstrações e outras saídas sem cobrança ficam fora.

## 4. Nota cancelada

Uma nota está **cancelada** quando o livro fiscal (SF3) registra o cancelamento **e não resta nenhum
registro vivo** dela. Nota com registro vivo e título pago é venda válida, mesmo que tenha passado
por um cancelamento parcial no livro. Nota excluída do Protheus depois de uma atualização sai do
painel na atualização seguinte.

## 5. Data de entrega

A data de entrega de uma nota é a **primeira** disponível nesta ordem:

| Ordem | Fonte | Observação |
|---|---|---|
| 1º | **Financeiro** — data de entrega do título (`E1_DTSAIDA`) | É a referência oficial |
| 2º | **GFE** — entrega registrada pela logística (`GWU_DTENT`) | Quando o Financeiro está vazio |
| 3º | **Título quitado** — data da 1ª baixa | Se o cliente pagou tudo, recebeu a mercadoria |

A data de entrega da nota fiscal (`F2_DTENTR`) **não é usada**: diverge das outras fontes em quase
todas as notas. Exceção a esta ordem: **NF-mãe de venda à ordem** (seção 8).

## 6. Situação (status) da nota

| Status | Quando |
|---|---|
| **Entregue** | Tem data de entrega |
| **Em trânsito** | Não tem data de entrega — é o mesmo que "sem entrega" |
| **Devolvida total / parcial** | Foi entregue e teve devolução (total ou parte do valor) |
| **Cancelada** | Seção 4 |

**Coerência garantida:** a mesma nota diz a mesma coisa em todas as telas. Toda nota "em trânsito"
em *Notas emitidas* está na fila de *Sem data de entrega*, e vice-versa. A atualização automática
confere isso nota a nota e **não grava** se encontrar uma única divergência. Nota devolvida sem
data de entrega continua "em trânsito"; a devolução aparece na coluna *Devolução em aberto*.

## 7. Fila de notas sem data de entrega

- **O que entra:** toda nota não cancelada sem data de entrega, **desde jan/2025, sem corte de
  dias** — mostra a realidade, e a fila diminui à medida que as áreas resolvem.
- **Faixas por dias desde a emissão:** 0–2 (normal) · 3–7 (acompanhar) · 8–15 (cobrar transportadora)
  · acima de 15 (risco).
- **Valor principal:** saldo em aberto dos títulos, em R$, com a participação de cada faixa.
- **Devolução em aberto:** para cada nota, o valor devolvido pelo cliente cujo crédito (NCC) o
  Financeiro ainda não compensou, com a marca *total*, *parcial* ou *compensada*. Mostra que a nota
  não tem entrega porque voltou, e que só falta o Financeiro compensar o saldo.
- **Marcas na fila:** notas de *venda à ordem*, *sinistro* e *funcionário* aparecem na fila com
  etiqueta — os grupos têm quadros próprios, mas a pendência nunca é omitida.
- A TV mostra a fila inteira e o recado das notas com mais de 7 dias.

### 7.1 Justificativa logística

- Na fila, cada nota tem o campo **Justificativa logística**: uma lista com os principais motivos
  (em rota, agendamento confirmado, entregue com baixa disponível no TOTVS, funcionário com baixa
  disponível, NF não enviada para a Logística, faturada sem a nota de remessa, refaturamento aguardando
  canhoto, devolvida, aguardando devolução, tratativa comercial, faturamento contra o transportador
  (sinistro/avaria), NF cancelada e outros) e um **complemento** em texto livre.
- Alguns motivos **pedem complemento** (agendamento, refaturamento, devolvida, tratativa comercial,
  outros): a tela avisa quando ele falta, mas não impede a gravação.
- **Quem informou e quando** é gravado pelo próprio banco, a partir do usuário logado — a tela não
  consegue registrar em nome de outra pessoa. Toda inclusão, troca ou exclusão fica no **histórico**.
- Quadro **Justificativa logística** ao lado da fila: saldo em aberto por motivo, com a participação no
  saldo da fila; filtro por motivo, *sem justificativa* e *com justificativa*. O Excel da fila leva a
  justificativa, o complemento, quem informou e quando.
- A justificativa é **escrita pelas pessoas, não pela carga automática**: a atualização de hora em hora
  nunca a apaga. Quando a nota ganha data de entrega, ela sai da fila e a justificativa fica guardada.
  Nada disso volta para o Protheus. Motivo novo entra na lista sem publicar tela.
- **Datas no Excel** de todas as telas saem como data de verdade no padrão brasileiro (dd/mm/aaaa).

## 8. Venda à ordem

**A operação.** A **NF-mãe** (CFOP 5118/6118, ou 5119/6119 para mercadoria de terceiros) gera o
financeiro e serve para cobrar. A mercadoria sai depois, em **notas de remessa** (CFOP 5923/6923).
A soma das remessas deve igualar o valor da NF-mãe, e a entrega é controlada pelas remessas.

**Qual remessa é de qual mãe.** O Protheus não liga as duas notas num campo padrão. O vínculo é lido,
nesta ordem: (1) campo de referência da nota de remessa (`F2_XDOCREF`); (2) texto da **nota** de
remessa ("REF A NF 222423"); (3) texto do **pedido**. O texto da nota vem antes do pedido porque um
pedido gera várias remessas e cita só uma das mães. Remessa que cita várias mães ("REF AS NF'S
254954 E 254946") tem o valor **rateado** entre elas, proporcional ao valor de cada mãe.

**Checagem complementar pelo pedido — só para notas a partir de 01/08/2026** (definição do Silvio,
23/09/2026). O pedido de venda ganhou campos próprios de rastreio da venda à ordem, que se somam ao
CFOP e ao cliente para confirmar o cenário:

| Pedido de | Campo (tela do pedido) | O que guarda |
|---|---|---|
| Remessa | Filial Ref · Série Ref · Doc Ref (`C5_XFILREF`, `C5_XSERREF`, `C5_XDOCREF`) | A NF-mãe da remessa ("Origem NF 000235741 Venda Ordem") |
| NF-mãe | Venda Ordem (`C5_XVENDAO`) | CNPJ de quem vai receber a mercadoria (o destinatário das remessas) |

Preenchimento medido em 23/09/2026: Doc Ref em 100% das remessas de ago–set/26; Venda Ordem em 8 de
10 NF-mães de ago/26. Antes de agosto a checagem não se aplica (campos novos). Uso: confirmar que a
NF-mãe citada no pedido da remessa é a mesma do vínculo lido pela nota, e que o destinatário da
remessa é o CNPJ informado no pedido da mãe. Quando nenhuma outra fonte achou a mãe, o Doc Ref do
pedido vira a 4ª fonte do vínculo. Os testes estão na Auditoria (seção 13.2).

**Base de comparação:** valor **total** da NF-mãe, **com IPI** — a remessa leva o valor cheio.
Tolerância de arredondamento: R$ 1 ou 0,5% do valor da mãe, o que for maior.

**Data de entrega da NF-mãe** (substitui a seção 5 para estas notas):

| Ordem | Regra |
|---|---|
| 1º | **Data da última remessa entregue**, quando as remessas cobrem o valor da mãe e **todas** têm data de entrega |
| 2º | Na falta disso, a data da própria mãe: **Financeiro → GFE → título quitado**. Mãe paga está OK: o cliente não quita sem ter recebido |
| 3º | Sem nenhuma das duas: **pendente** (entra na fila) |

O disparo de boleto não é objeto do painel — o Financeiro tem controle próprio e automático.

**Quadro "Venda à ordem"** (tela *Sem data de entrega*): uma linha por NF-mãe com valor, Σ remessas,
a remeter, entregue, % entregue, **saldo a receber**, data de entrega da mãe (e de onde veio) e situação.
O filtro padrão *"Com pendência e saldo a receber"* mostra só a mãe com situação em aberto **e** saldo a
receber no título; *"Todas"* mostra o quadro inteiro. Mãe sem saldo não é pendência (seção 9.1):

| Situação | Significado |
|---|---|
| Concluída | Remessas cobrem a mãe e todas entregues |
| A remeter | Falta remessar parte do valor |
| Remessa sem entrega | Há remessa sem data de entrega no GFE |
| Sem remessa | Nenhuma remessa encontrada para a mãe |
| Remessado a maior | Remessas acima do valor da mãe (ver Auditoria) |

Clicar na NF-mãe abre a cascata das remessas com a entrega de cada uma. Um segundo quadro lista as
**remessas sem mãe identificável** (texto não cita a NF, ou cita bonificação ou venda comum).

## 9. Sinistro e funcionários

- **Quem é:** venda a transportadora que causou **sinistro** (nome do cliente contém TRANSFARRAPOS ou
  PATRUS) e venda a **funcionário** (cliente do grupo de vendas 000001 — FUNCIONÁRIOS, no cadastro).
- **Regra:** o grupo é só **marcado**. A data de entrega é a real (seção 5): tem data, mostra; não
  tem, está pendente. *Segrega-se, mas não se omite a pendência.*
- **Onde aparece:** quadro próprio e destacado na tela *Sem data de entrega* (total, sinistro,
  funcionários, entrega pendente com saldo), e as pendentes também na fila com etiqueta. O filtro padrão
  do quadro é *"Com saldo a receber"*; *"Todas"* mostra também as notas já quitadas.

### 9.1 Só é pendência a entrega que tem saldo a receber

Definição do Silvio (24/09/2026): *o que se controla é a entrega que ainda tem saldo a receber.* Sem
saldo em aberto no título, a falta de data de entrega **não é pendência** — a nota aparece com a
etiqueta *sem saldo*, nunca como *pendente*. Vale para os quadros de sinistro, funcionários e venda à
ordem. A fila principal (seção 7) não muda: por construção ela não tem nota sem saldo, porque título
quitado já dá a data de entrega (seção 5).

## 10. Devoluções

- **Universo:** todas as notas de entrada de devolução (tipo D), de todas as filiais, desde jan/2025.
- **Origem:** separada entre **emitida pela AMVOX** (formulário próprio) e **emitida pelo cliente**.
- **Devolução de venda:** CFOP 1201/2201 (99% do volume), 1202/2202/2203/1410/2410. Retornos de
  remessa (2914/2949/2208) não são devolução de venda.
- **Vínculo com a venda:** pela nota de origem informada no item da devolução.
- **Motivo:** lido do texto da própria nota de devolução ("MOTIVO DEV: …" ou "… MOT.: …"). Sem
  taxonomia fixa até se definir um campo próprio — a tela lista as causas como estão na base.
- **Crédito do cliente (NCC):** cada devolução gera um crédito no contas a receber; saldo maior que
  zero = ainda não compensado (alimenta a *Devolução em aberto*, seção 7).

## 11. Região × linha

- **Grão:** nota × linha de produto (uma nota com Áudio e Lar vira duas linhas). A soma da tela é
  igual, ao centavo, ao faturamento de *Notas emitidas* — a atualização não grava se não for.
- **UF:** do cadastro do cliente. **Região:** agrupamento do IBGE (Norte, Nordeste, Centro-Oeste,
  Sudeste, Sul).
- **Linha:** grupo do produto no cadastro (Áudio, Lar, Clima, Informática, Vídeo…).
- **Matriz:** cada célula mostra o R$ e, logo abaixo, a participação no total geral; a coluna Total
  soma as linhas para conferência com a FAT PLUS.

## 12. Top clientes

Clientes agrupados pela **raiz do CNPJ** (8 primeiros dígitos) — lojas e filiais do mesmo grupo somam
juntas. Concentração mostrada em R$ e em % do faturamento do período.

## 13. Auditoria

Controles automáticos que **apontam** desvios; não alteram nenhum outro número do painel. São dois
subgrupos, pensados para, no futuro, dar acesso por perfil. **Cada auditoria pertence a um único
grupo**, definido quando ela é aprovada:

| Subgrupo | Escopo | Auditorias ativas |
|---|---|---|
| **Auditoria FAT** | Faturamento | Venda à ordem — remessa × NF-mãe (13.1) · Venda à ordem — conferência pelo pedido (13.2) |
| **Auditoria LOG** | Expedição e entrega física | Nenhuma ainda |

A cada atualização a auditoria é refeita inteira: ocorrência corrigida no Protheus some sozinha.

### 13.1 FAT · Venda à ordem — remessa × NF-mãe

*Não se pode entregar mais mercadoria (R$) do que a NF-mãe registrou, nem produto diferente do
dela.* Compara, **produto a produto**, a NF-mãe com as remessas vinculadas (seção 8). Quando uma
remessa cita mais de uma mãe, a comparação é feita no grupo das mães citadas.

| Teste | Dispara quando | Severidade |
|---|---|---|
| **Valor maior** | Σ remessas (valor bruto) > valor da NF-mãe + tolerância | Alta se o excesso passa de R$ 1.000 e de 10% da mãe; senão Média |
| **Produto distinto** | Remessa com produto que não está na NF-mãe | Alta |
| **Quantidade maior** | Produto remessado em quantidade maior que a da NF-mãe | Alta |

Clicar numa ocorrência abre a comparação produto a produto (quantidade e valor, mãe × remessas).
Não há retorno de remessa registrado na base — nada é abatido.

### 13.2 FAT · Venda à ordem — conferência pelo pedido (notas desde 01/08/2026)

Usa os campos do pedido da seção 8, só para notas emitidas a partir de 01/08/2026.

| Teste | Dispara quando | Severidade |
|---|---|---|
| **Pedido aponta outra NF-mãe** | O Doc Ref do pedido da remessa não é a NF-mãe lida na nota, nem a mãe de nenhuma outra remessa do mesmo pedido | Alta |
| **Destinatário divergente** | O CNPJ de quem recebeu a remessa é diferente do CNPJ do campo Venda Ordem do pedido da NF-mãe | Alta |
| **NF-mãe sem destinatário no pedido** | NF-mãe de venda à ordem sem o campo Venda Ordem preenchido | Média |

**Pedido agrupador:** um pedido pode gerar várias remessas para mães diferentes, mas o campo Doc Ref
guarda uma só (caso de ago/26: 1 pedido, 8 remessas, 8 mães). Por isso a divergência considera todas
as mães das remessas daquele pedido.

## 14. Atualização automática

- **Quando:** de hora em hora das 09h às 16h e uma rodada final às 16h30, em dias úteis. Fora disso a
  TV mostra o último retrato, sempre com a data e a hora dele.
- **Falha de conexão** (VPN, servidor, Mac em repouso) não é erro: a rotina tenta de novo sozinha
  (até 3 vezes, 5 min entre elas; a das 16h30 insiste até as 18h). Sem conexão, nada é gravado e o
  painel segue com o retrato anterior.
- **Travas — se qualquer uma falhar, nada é gravado:**
  1. região × linha soma exatamente o faturamento das notas;
  2. coerência status × fila, nota a nota (seção 6);
  3. **estrutura do banco:** antes de gravar, o código compara as colunas que vai mandar com as que
     existem no banco do painel. Faltou algo, ele diz **qual arquivo de migração rodar**. Tabela
     essencial faltando = não grava nada; tabela nova ainda não criada = pula só ela e avisa;
  4. nota que sumiu do Protheus sai do painel, mas só se a sobra for menor que 5% (proteção contra
     extração incompleta).
- **Conferência** após cada carga: o painel é comparado nota a nota com o Protheus, cortando pela
  hora da extração. Diferença vira pendência no resumo.
- **Sempre a última versão do código:** a rotina agendada só executa os programas do projeto; o que
  gravar e como está no próprio código (manifesto das tabelas). Tabela ou regra nova passa a valer na
  primeira rodada depois de publicada, e o resumo de cada rodada é gerado pelo código.

## 15. Acesso

Login individual por e-mail (mesmo cadastro do app de preços). Hoje todos os usuários têm o mesmo
perfil e veem todas as telas, inclusive os dois subgrupos da Auditoria. A segregação por perfil
(ex.: LOG × FAT) está prevista e ainda não definida.

## 16. Em aberto — aguardando definição

| Assunto | Situação |
|---|---|
| Canal B2B × B2C | Campo candidato no cadastro do cliente; falta confirmação de negócio |
| Perfis de acesso por tela / subgrupo de auditoria | Previsto, não definido (inclui quem pode informar a justificativa logística — hoje todo usuário logado) |
| Próximas auditorias (LOG e FAT) | A listar |
| Mães sem remessa, remessadas a maior e remessas sem mãe | Casos para correção no Protheus (quadros da seção 8 e Auditoria) |

## Histórico de versões

| Versão | Data | O que mudou | Aprovado por |
|---|---|---|---|
| 1.0 | 23/09/2026 | Primeira versão consolidada: universo = FAT PLUS; regra de cancelamento corrigida; data de entrega FIN → GFE → título quitado; venda à ordem (vínculo pela nota, rateio, base com IPI, data da mãe pela última remessa com retaguarda FIN/GFE/pago); sinistro e funcionários só marcados; devolução em aberto (NCC); fila sem corte de 120 dias; dados desde jan/2025; Auditoria LOG/FAT com o 1º controle (remessa × NF-mãe); atualização guiada pelo código com checagem de estrutura | Silvio Amaral (definições de 21 a 23/09/2026) |
| 1.1 | 23/09/2026 | Venda à ordem: registrada a checagem complementar pelos campos do pedido (Filial/Série/Doc Ref no pedido da remessa; Venda Ordem = CNPJ do destinatário no pedido da mãe), só para notas a partir de 01/08/2026 | Silvio Amaral |
| 1.2 | 23/09/2026 | Aprovada a forma de uso dos campos do pedido: 3 testes na Auditoria (seção 13.2) e Doc Ref do pedido como 4ª fonte do vínculo; regra do pedido agrupador | Silvio Amaral |
| 1.3 | 23/09/2026 | Cada auditoria pertence a um único grupo; as duas auditorias de venda à ordem passam para a Auditoria FAT (LOG fica sem auditoria ativa) | Silvio Amaral |
| 1.4 | 23/09/2026 | Consulta pelo número da NF em todas as telas de detalhe (seção 1) | Silvio Amaral |
| 1.5 | 24/09/2026 | Só é pendência a entrega com saldo a receber: quadros de sinistro, funcionários e venda à ordem abrem filtrados pelo saldo; nota sem saldo leva a etiqueta *sem saldo* (seções 8 e 9.1) | Silvio Amaral |
| 1.6 | 25/09/2026 | Justificativa logística na fila de notas sem data de entrega (lista de motivos + complemento, quem/quando gravado pelo banco, histórico, quadro e filtro por motivo); datas do Excel em dd/mm/aaaa (seção 7.1) | Silvio Amaral (pedido da Logística) |
