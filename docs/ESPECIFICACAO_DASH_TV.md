# Especificação — Dashboard TV Faturamento & Logística (AMVOX)

**Versão 1.32** · 28/10/2026 · Dono das definições: Silvio Amaral (Controladoria) · Mantido por: Claude

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
- **Faixas por dias desde a emissão** (9 faixas, Silvio 01/10/2026 — o antigo "acima de 15 dias" foi
  aberto): 0–2 (normal) · 3–7 (acompanhar) · 8–15 (cobrar transportadora) · 16–30 · 31–45 · 46–60 (risco)
  · 61–90 · 91–180 (risco alto) · acima de 180 (crítico). Mesma régua na carga, na tela, no Excel e na TV.
- **Valor principal:** saldo em aberto dos títulos, em R$, com a participação de cada faixa.
- **Devolução em aberto:** para cada nota, o valor devolvido pelo cliente cujo crédito (NCC) o
  Financeiro ainda não compensou, com a marca *total*, *parcial* ou *compensada*. Mostra que a nota
  não tem entrega porque voltou, e que só falta o Financeiro compensar o saldo.
- **Marcas na fila:** notas de *venda à ordem*, *sinistro* e *funcionário* aparecem na fila com
  etiqueta — os grupos têm quadros próprios, mas a pendência nunca é omitida.
- A TV mostra a fila inteira e o recado das notas com mais de 7 dias.

### 7.1 Plano de ação (Justificativa + Observações + Anexos)

- Na fila, a seção **Plano de ação** tem três campos por nota (Silvio 01/10/2026):
  - **Justificativa** — lista com os principais motivos (em rota, agendamento confirmado, entregue com
    baixa disponível no TOTVS, funcionário com baixa disponível, NF não enviada para a Logística, faturada
    sem a nota de remessa, refaturamento aguardando canhoto, devolvida, aguardando devolução, tratativa
    comercial, faturamento contra o transportador (sinistro/avaria), NF cancelada e outros) e um
    **complemento** curto. Alguns motivos **pedem complemento** (agendamento, refaturamento, devolvida,
    tratativa comercial, outros): a tela avisa quando ele falta, mas não impede a gravação.
  - **Responsável** — nome da pessoa que a Logística indica para realizar a ação (texto livre; a tela sugere
    os nomes já usados).
    **Padrão: Ingride Soares**, responsável geral da Logística (Silvio 05/10/2026): toda nota sem responsável informado é dela —
    a tela mostra o nome com a marca *padrão*; delegar = trocar o nome. No banco (migração 009) o campo nasce com o padrão e, se for
    gravado vazio, volta para o padrão. O Excel leva RESPONSÁVEL e RESPONSÁVEL DEFINIDO? (informado × padrão).
  - **Prazo** — data até a qual o responsável deve realizar a ação. A tela marca *vencido há N dias*, *vence
- **Status roteirização** (pedido da Logística, Silvio 14/10/2026) — **primeira coluna do plano de ação**. Vem da
  carga automática (não é digitado): o **romaneio do GFE** atrelado à nota — documento de carga `GW1010` (tipo NFS,
  `GW1_NRROM`) → romaneio `GWN010` — e a previsão de entrega `GWU_DTPENT`. Três textos:
  **Roteirizado com previsão de entrega dd/mm/aaaa** · **Roteirizado SEM previsão de entrega** (há romaneio, previsão em
  branco) · **Não roteirizado** (nenhum romaneio). Qualquer romaneio conta, mesmo ainda *Digitado* (sem saída). Ao passar
  o mouse: número do romaneio, situação (Digitado/Emitido/Liberado/Encerrado) e data/hora de saída. **NF-mãe de venda à
  ordem** não embarca: mostra o romaneio da **remessa** (a mais recente ainda não entregue). A coluna ordena pela
  previsão. O Excel leva **STATUS ROTEIRIZAÇÃO** (texto completo), **ALERTA ROTEIRIZAÇÃO**, **MOTIVO DO ALERTA** e
  **ROMANEIO**. Mesma leitura do SFA (NF 000280444: romaneio 00088932, saída 13/10 14:28, previsão 14/10). Migração 011.
  - **Na tela, texto abreviado** (Silvio 14/10/2026): *Roteirizado c/ Prev. Entrg. dd/mm/aaaa* · *Roteirizado S/ Prev.
    Entrg. ??/??/??* · *Não roteirizado*.
  - **Cor = alerta** (Silvio 14/10/2026): **verde = OK** · **laranja = atenção** · **vermelho = anomalia**. *"Pior que ter
    uma entrega demorada é não ter qualquer previsão de entrega, ou ter uma previsão já frustrada."*
    - **⚠ Anomalia grave** — nota **sem romaneio emitida há mais de 9 dias úteis** (dias úteis = sem sábado, domingo e
      feriado nacional ou de Camaçari, o mesmo calendário das rotinas): fundo vermelho cheio, símbolo ⚠ e moldura dupla.
      **Por que 9** (medição de 14/10/2026): da emissão à criação do romaneio no GFE, nas 1.226 notas de jul–set/2026, a
      mediana é 4 dias úteis e 9 de cada 10 notas têm romaneio em até 9 dias úteis. A Logística só monta o romaneio depois
      da cotação de frete aprovada, perto do carregamento — antes desse prazo a nota não é cobrada. O prazo era 7 e é
      revisto com a mesma medição. A tela e o informe trazem essa explicação em nota de rodapé.
    - **Anomalia (vermelho)** — **previsão superada** (a data já passou) ou **roteirizado sem previsão**. Previsão
      anterior à emissão é erro de digitação no GFE e vale como *sem previsão*.
    - **Atenção (laranja)** — **previsão longa**: mais de 45 dias depois da emissão (na fila de 14/10 a mediana era 30
      dias e 90% ficavam até 38).
    - **OK (verde)** — previsão dentro da régua. **Sem cor** (contorno tracejado) — sem romaneio até 9 dias úteis.
    - O motivo aparece ao passar o mouse.
- **Status da linha** (Silvio 02/10/2026) — cada nota da fila mostra o status do plano em função do prazo: **Vencido há N d** · **Vence hoje** · **Vence em N d** (até 7 dias) · **No prazo** (mais de 7 dias) · **Sem prazo** (há plano, falta a data) · **Sem plano** (nada informado). A coluna ordena do mais urgente para o menos urgente e muda na hora em que o prazo é gravado. Acima da grade, 6 cards de status (card = filtro). O Excel leva **STATUS DO PLANO** (todas as linhas) e **DIAS P/ O PRAZO** (negativo = vencido).
    hoje*, *vence em N dias* ou *em N dias*.
  - **Observações** — texto livre: o que está sendo feito, com quem, próximo passo. Pode ser registrada
    antes de escolher o motivo.
  - **Anexos** — evidências em arquivo (PDF, imagem, Excel, Word, texto, e-mail), até **10 MB** cada,
    guardados numa pasta privada (só usuário logado abre; o link de abertura vale 5 minutos).
    **Remover** um anexo só o tira da fila: o arquivo continua guardado e a remoção fica registrada.
    Ninguém apaga nem substitui um arquivo.
- **Quem informou e quando** é gravado pelo próprio banco, a partir do usuário logado — a tela não
  consegue registrar em nome de outra pessoa. Toda inclusão, troca, exclusão e anexo fica no **histórico**
  (seção 7.2).
- Filtro por motivo, *sem justificativa*, *com justificativa*, *com anexo*, *prazo vencido* e *sem responsável*. O Excel da fila leva a
  justificativa, o complemento, o responsável, o prazo e a situação do prazo, as observações, a quantidade e o nome dos anexos, quem informou e quando.
- O plano de ação é **escrito pelas pessoas, não pela carga automática**: a atualização de hora em hora
  nunca o apaga. Quando a nota ganha data de entrega, ela sai da fila e o plano fica guardado.
  Nada disso volta para o Protheus. Motivo novo entra na lista sem publicar tela.
- **Datas no Excel** de todas as telas saem como data de verdade no padrão brasileiro (dd/mm/aaaa).

### 7.2 Histórico do plano de ação (log de alteração)

- Toda **inclusão, alteração e exclusão** do plano de ação gera uma linha no histórico com **antes e
  depois** (motivo, complemento, responsável, prazo e observações); cada anexo incluído ou removido também (nome do arquivo), **quem** (e-mail do usuário logado, gravado pelo banco) e **quando**
  (hora do servidor).
- **Salvar sem mudar nada não gera registro** e não troca o "quem/quando" da justificativa vigente.
- O histórico é **imutável**: ninguém altera nem apaga uma linha — nem pela tela, nem pelo acesso
  administrativo do banco. Só se acrescenta.
- Na fila, o botão **histórico** de cada nota abre a linha do tempo dela (mais recente primeiro). O botão
  **Exportar histórico** gera o Excel com todas as mudanças de todas as notas (quando, ação, quem, NF,
  cliente, justificativa e complemento de antes e de depois).

### 7.3 Área Dash da tela

- Os gráficos saíram da fila (Silvio 01/10/2026): a tela tem duas abas — **Fila de ação** (a tabela com
  o plano de ação e os quadros de sinistro/funcionários e venda à ordem) e **Dash** (as 9 faixas com
  quantidade e saldo, *saldo por faixa (aging)*, *plano de ação · justificativa*, *plano de ação · prazo* (vencido, vence hoje, até 7 dias, no prazo, sem prazo), *top clientes* e
  *por transportadora*).
- Os filtros do topo valem para as duas abas. Clicar numa barra do Dash filtra a fila (filtro cruzado);
  o Dash mostra quantas notas e quanto saldo ficaram na fila com os filtros do momento.
- **Cards de resumo acima da grade** (Silvio 01/10/2026): na Fila de ação, as 9 faixas aparecem em cards logo acima
  da grade, no mesmo padrão do quadro de Sinistro e funcionários; o Dash repete os cards como visão geral.
- **Card é sempre filtro** (regra Silvio 01/10/2026, vale para todo card de resumo): clicou no card, a grade abaixo mostra
  exatamente as notas que formam aquele número; clicou de novo (ou no card de total), o filtro sai. O card ativo fica
  destacado. Faixas: filtra a fila (e o Dash). Sinistro e funcionários: total · sinistro · funcionários · entrega pendente com
  saldo. Venda à ordem: total · com remessa · com entrega · com remessa sem entrega.
- **A regra vale para todas as telas do dash** (Silvio 01/10/2026, v1.12): Notas emitidas (total · vivas · valor · canceladas),
  Devoluções (cards de total e o de origem da devolução), Top clientes (top 10 · maior cliente · top 3), Região × linha
  (linha e região dominantes viram seleção cruzada; os cards de total limpam) e Auditoria (o card de ocorrências limpa o
  filtro de teste). Card que já é o total da tela não filtra — limpa.
- **Previsão de entrega no Dash** (Silvio 14/10/2026), logo abaixo dos cards de faixa:
  - **Resumo em destaque**: quantas notas da fila (e quanto saldo) estão **sem previsão ou com previsão superada** — o
    problema real da fila —, e quantas delas são anomalia grave.
  - **6 cards** (card = filtro da fila): ⚠ sem romaneio > 9 dias úteis · previsão superada · roteirizado sem previsão ·
    previsão longa · previsão em dia · sem romaneio até 9 dias úteis. Cada um com notas, % das notas, saldo e % do saldo.
  - **Previsto × realizado — entregas por mês** (últimos 6 meses, pelo mês da entrega): barra com a composição do mês —
    no prazo (entregue até a previsão) · atraso 1–3 · 4–10 · mais de 10 dias · entregue sem previsão · previsão inválida —,
    com total de entregas, **% no prazo** (sobre as entregas que tinham previsão), atraso médio das atrasadas e % sem
    previsão. **Só entra data de entrega real** (Financeiro, GFE ou remessa): a nota quitada sem data de entrega fica fora,
    porque a data é a do pagamento (chegava a 400 dias de "atraso"). Previsão anterior à emissão (erro do GFE, ex.: 1973)
    fica fora do % e do atraso. Segue os filtros de UF, transportadora, cliente e NF.
  - **Previsto × realizado por transportadora**: entregas dos últimos 90 dias (no prazo, atrasadas, atraso médio, sem
    previsão) lado a lado com a fila de hoje (previsão superada, roteirizado sem previsão, ⚠ sem romaneio > 9 dias
    úteis). As 15 com mais notas problemáticas; clique no nome filtra a fila.
- **Painel de pendências do plano de ação no Dash** (Silvio 02 e 05/10/2026): cards de status; quadro **Pendências por responsável** (notas, saldo e % do saldo, quantidade por status, maior atraso, próximo prazo — clique no nome filtra o responsável; num número, responsável + status); gráficos **Status do plano por faixa de dias** e **por responsável** (barras empilhadas por status; "sem responsável" em linha de resumo), **Agenda de prazos** (vencidos + cada dia dos próximos 14) e **Atividade no plano de ação** (notas com plano incluído/alterado/anexado por dia, últimos 30 dias, a partir do histórico imutável). Cores = estado do prazo (vermelho vencido · laranja hoje · amarelo até 7 dias · verde no prazo · cinza sem prazo · cinza-claro sem plano), sempre com legenda e rótulo.

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
| 1º-B | **Remessas cobrem 100% da mãe, mas alguma ainda sem data no GFE** → vale a data da **última remessa**: a de entrega no GFE, ou a **emissão** dela quando não tem (fonte "Emissão da última remessa"). Não há mais nada a remeter, então a mãe não fica sem data de entrega — e passa na frente da data do Financeiro. Não conta como entrega comprovada no previsto × realizado |
| 2º | Na falta disso, a data da própria mãe: **Financeiro → GFE → título quitado**. Mãe paga está OK: o cliente não quita sem ter recebido |
| 3º | Sem nenhuma das duas: **pendente** (entra na fila) |

O disparo de boleto não é objeto do painel — o Financeiro tem controle próprio e automático.

**Quadro "Venda à ordem"** (tela *Sem data de entrega*): uma linha por NF-mãe com valor, Σ remessas,
a remeter, entregue, % entregue, **saldo a receber**, data de entrega da mãe (e de onde veio) e situação.
O filtro padrão *"Com pendência e saldo a receber"* mostra só a mãe com situação em aberto **e** saldo a
receber no título; *"Todas"* mostra o quadro inteiro. Mãe sem saldo não é pendência (seção 9.1):

| Situação | Significado |
|---|---|
| Concluída | Remessas cobrem 100% da mãe (com ou sem data no GFE — regra 1º-B); "Entregue" = Σ remessas |
| A remeter | Falta remessar parte do valor |
| Remessa sem entrega | Há remessa sem data de entrega no GFE **e** as remessas ainda não cobrem a mãe |
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

- **Tela:** cada tela do painel se recarrega sozinha a cada 10 minutos, para a TV e os usuários sempre verem o último retrato gravado. O recarregamento zera filtros e rolagem escolhidos na tela; com a tela de login aberta ele não acontece.

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

Login individual por e-mail (mesmo cadastro do app de preços). **Acesso por aplicativo (07/10/2026):**
cada usuário tem a lista de aplicativos liberados — **Preços** e/ou **Dash** — e o banco só entrega os
dados do Dash a quem tem o Dash (trava no banco, não só na tela; vale também para os anexos do plano de
ação). Quem não tem vê o aviso "Seu usuário não tem acesso…". Divisão vigente: Logística (Ingride,
Larissa, Emilly) só Dash; comercial, comercial3 e vendas só Preços; Controladoria, gerentes e diretor de
operações os dois. A TV usa o login de um usuário da Logística. O menu do app de preços tem o cartão do
Dash. Dentro do Dash, todos os usuários com acesso veem todas as telas, inclusive os dois subgrupos da
Auditoria; a segregação por tela (ex.: LOG × FAT) segue prevista e não definida.

## 15-A. Protocolos de expedição (aba "Protocolos" — central on-line)

Central dos protocolos de notas **LIBERADAS PARA EXPEDIÇÃO** pelo Faturamento, com a **ciência** da Logística
(aprovada pelo Silvio em 20/10/2026; etapa 1 = consulta + ciência; etapas 2 e 3 = notas aptas, retenção e protocolo
complementar sob demanda).

| Regra | Como funciona |
|---|---|
| O que aparece | Só protocolos **já enviados** e só as notas deles — nada do que o Faturamento ainda não liberou |
| Cancelada / devolvida | Nota cancelada ou devolvida (total ou parcial) depois da liberação **não aparece**; Controladoria e Faturamento veem só "N oculta(s)" |
| Quem vê a aba | **Homologação:** só Controladoria (papel ADM) e Faturamento (lista PROT_EMISSORES). A partir de **03/11/2026** (ABA_LIBERA_EM) a aba abre sozinha para todo usuário do Dash — e a LOG continua vendo só os protocolos enviados |
| Ciência | Botão "Dar ciência" grava usuário e hora (vale a 1ª; todas ficam no histórico imutável). Alerta: sem ciência há mais de 2 h (CIENCIA_HORAS). Protocolos anteriores a 21/10/2026 = "anterior à central" (sem alerta) |
| PDF | Em pasta privada (prot-pdf). O PDF **enviado** é o documento oficial e nunca é apagado nem alterado (OneDrive + caminho original na pasta). Protocolos anteriores ao padrão atual ganharam uma **2ª via** (mesmas notas, valores, ordem e data; SUFRAMA em vermelho; cliente pela razão social; NF cancelada depois do envio com município "—" explicado no rodapé) — é a que o botão 📄 abre; o histórico registra o evento "2ª via do PDF" com o caminho do original. Gerador: `protocolo_2via.py` (confere quantidade e total com o envio; divergência = pendência) |
| Venda para área de SUFRAMA | Nota de cliente com **inscrição SUFRAMA no cadastro** (SA1.A1_SUFRAMA) sai **em vermelho** com a etiqueta SUFRAMA — no quadro de aptas, no detalhe do protocolo e no PDF enviado (linha vermelha + legenda com a quantidade). Critério escolhido por cobrir 100% das notas com tabela 227/228/229 e das com desconto ZF na nota (teste de 120 dias: 41 notas; a tabela do pedido sozinha perderia 10). Sugestão do Faturamento, 20/10/2026 |
| Situação logística | A de cada nota no próprio dash (entregue com data · em trânsito/a expedir) e a transportadora |
| Aprovação do automático | Desde 23/10/2026 (parâmetro APROVACAO_AUTOMATICO = SIM): às 09h a rotina monta o protocolo do dia como **RASCUNHO** e só o alerta de canceladas/devolvidas sai na hora. Controladoria ou Faturamento aprovam no painel "Protocolo automático do dia — AGUARDANDO APROVAÇÃO": desmarcar = a nota volta às aptas; **Reter** = segura com motivo; **Aprovar e enviar** = a fila (15 min) gera o PDF e envia (assunto normal, central "Automático · aprovado por …"); **Não enviar hoje** = descarta com motivo. Rascunho não aprovado é substituído pelo do dia seguinte (nada se perde). Dia sem notas: e-mail "SEM NOTAS" como antes. NÃO = volta ao envio direto |
| Confirmação de leitura | **Regra universal** (Silvio 22/10/2026): todo e-mail de notificação das rotinas pede confirmação de leitura (Outlook: Opções › Mais opções). A confirmação recebida ("Lida: … PROT-…") vira **ciência na central**: "✓ Fulano · pelo e-mail de notificação · dd/mm hh:mm" (cada leitor no histórico). **Lembrete**: um por protocolo, só se não houver NENHUMA confirmação nem ciência depois de CIENCIA_HORAS (2 h) — se alguém leu, nada é enviado a ninguém. **Modo teste** (EMAIL_TESTE): alerta, protocolo e lembrete vão só para o e-mail de teste, com "[TESTE]" e a lista de quem receberia |
| Reenvio por exceção | Parâmetro REPROTOCOLAR (lista filial|série|doc): nota que já consta em protocolo volta a ser apta e sai de novo no próximo protocolo (caso: PROT-2026-014 de teste, que só foi ao e-mail do Silvio — duplicidade aceita em 22/10/2026). A rotina tira a nota da lista quando o protocolo real sai; na central a nota fica no protocolo mais recente |
| Retenção manual | Nota faturada que não pode ser liberada (ex.: "Comercial solicitou reter"): botão **Reter** no rascunho ou nas aptas, motivo obrigatório, fica fora de qualquer protocolo (automático, complementar, aprovação) até **Liberar**, que vale na hora (o motivo some da tela); quem reteve/liberou e quando ficam no histórico de retenções |
| Envio | Protocolo automático: 1 por dia útil às 09h. Complementares só sob demanda (abaixo). Até 02/11/2026: e-mails só para fiscal@ + fiscal4@; a partir de **03/11/2026** (DESTINO_LIBERA_EM) também para o time LOG. O alerta de canceladas/devolvidas fica só no Fiscal |
| Notas aptas a liberar | Só Controladoria e Faturamento veem: notas autorizadas e ainda sem protocolo, atualizadas a cada carga do dash (prot_apta). Cards Aptas · Retidas · Em pedido na fila · Selecionadas (todos filtram a grade) |
| Atualizar aptas agora | Botão ↻ no quadro de aptas (só Controladoria e Faturamento): grava um pedido (um pendente por vez); a rodada da fila de complementares (a cada 15 min, dias úteis 09h–17h) atende antes da fila e relê as aptas no TOTVS; a tela mostra a situação e recarrega o quadro ao terminar. VPN/Protheus fora = pedido volta à fila com o motivo |
| Segurada | Nota de bonificação marcada **ERRO DE EMISSÃO** no app Redes: nunca vai a protocolo e aparece no quadro de aptas como "Segurada — erro de emissão" (sem caixa de seleção; conta no card "Retidas e seguradas") até ser cancelada no TOTVS. Caso 281598 DOMESTILAR (22/10/2026) |
| Retida | Bonificação com **RETER indicado pelo gestor** (e-mail RETER EXPEDIÇÃO [AV-n] no app Redes) ou com a **venda do 1º pedido cancelada**: não entra em protocolo até o "PODE LIBERAR" enviado (ou justificativa, na venda cancelada). Retenção manual com motivo (botão Reter da aba) também. Bonificação devolvida (anulada) não conta |
| Alerta (bonificação sem faturamento) | Desde a v1.31 (Silvio 28/10/2026, caso NF 281268): bonificação **sem venda do grupo/raiz de CNPJ** no prazo ± BONIF_PRAZO_DIAS é **só ALERTA** — fica **Apta**, com "⚠️ ALERTA: bonificação sem faturamento…" no quadro de aptas e no rascunho do dia, **segue no protocolo** e não gera notificação automática. O alerta traz a **natureza sugerida** pela observação do pedido no TOTVS (VPC em produtos · Campanha 10% · Bonificação autorizada — mostruário, doação, brinde, marketing, cortesia, amostra, premiação · sem classificação), mesma régua da regra B15 do app Redes (v1.32). Reter é decisão do gestor do protocolo, nota a nota (Reter na aba ou RETER no app Redes); indicada a retenção, antes ou depois do protocolo, segue o fluxo de comunicação (RETER → PODE LIBERAR) — migração 032 |
| Protocolo complementar | O emissor marca as notas aptas e pede o protocolo — na próxima rodada ou agendado. Travas no banco: só notas APTAS, sem protocolo, fora de outro pedido em andamento; horário no passado é recusado. Pedido pendente pode ser cancelado. A rotina do Mac processa a fila a cada 15 min nos dias úteis (09h–17h) e envia no mesmo padrão de e-mail + PDF |

A leitura é só por funções do banco (`prot_lista`, `prot_notas`, `prot_historico`, `prot_dar_ciencia`; emissores: `prot_aptas`,
`prot_pedidos`, `prot_solicitar`, `prot_cancelar_pedido`), que aplicam as regras acima — as tabelas não têm leitura direta.
Quem grava os protocolos é a rotina do protocolo (migrações 012 e 013). Cliente = **razão social** do cadastro (A1_NOME).

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
| 1.7 | 29/09/2026 | Histórico da justificativa com antes × depois, quem e quando; salvar sem mudança não registra; histórico imutável; botão de histórico por nota e Excel do histórico (seção 7.2) | Silvio Amaral |
| 1.8 | 30/09/2026 | Recarregamento automático de cada tela a cada 10 minutos (padrão do dash de preço); efeito aceito: perda dos filtros da tela (seção 14) | Silvio Amaral |
| 1.9 | 01/10/2026 | Faixas de dias abertas em 9 (16–30 até acima de 180) na carga, tela, Excel e TV (seção 7); Plano de ação = Justificativa + Observações + Anexos, com histórico (7.1, 7.2); gráficos movidos para a aba Dash (7.3) | Silvio Amaral |
| 1.10 | 01/10/2026 | Plano de ação ganha Responsável (nome indicado pela Logística) e Prazo (data), com histórico, filtros (prazo vencido, sem responsável), quadro de prazos no Dash e colunas no Excel (seção 7.1) | Silvio Amaral |
| 1.11 | 01/10/2026 | Cards de resumo das faixas acima da grade da fila (padrão do quadro de Sinistro e funcionários); todo card de resumo vira filtro — clicou, filtrou; clicou de novo, tira (seção 7.3) | Silvio Amaral |
| 1.12 | 01/10/2026 | Card-filtro estendido às demais telas: Notas emitidas, Devoluções, Top clientes, Região × linha e Auditoria (seção 7.3) | Silvio Amaral |
| 1.13 | 05/10/2026 | Status de cada linha pelo prazo do plano (6 situações), cards de status, Excel com status e dias p/ o prazo (7.1); no Dash, pendências por responsável e gráficos do plano: por faixa, por responsável, agenda de prazos e atividade (7.3) | Silvio Amaral |
| 1.14 | 05/10/2026 | Responsável padrão = Ingride Soares (responsável geral, delega trocando o nome): tela, quadros, gráficos e Excel; banco com default e preenchimento dos vazios (migração 009) (seção 7.1) | Silvio Amaral |
| 1.15 | 07/10/2026 | Acesso por aplicativo (Preços × Dash) com trava no banco; cartão do Dash no menu do app de preços; aviso para usuário sem o Dash (seção 15) | Silvio Amaral |
| 1.32 | 28/10/2026 | Aba **Protocolos**: o alerta de bonificação sem faturamento mostra a **natureza sugerida** pela observação do pedido (regra B15 do app Redes) | Silvio Amaral |
| 1.31 | 28/10/2026 | Aba **Protocolos**: bonificação **sem faturamento** deixa de ser retida automaticamente — vira **ALERTA** (fica apta e segue no protocolo); **retida** só com RETER indicado pelo gestor ou venda do 1º pedido cancelada — migração 032 (seção 15-A) | Silvio Amaral |
| 1.30 | 22/10/2026 | Aba **Protocolos**: fim do modo teste; **reenvio por exceção** (REPROTOCOLAR); **Liberar** vale na hora; filtros NF/cliente valem também para as aptas — migração 020 (seção 15-A) | Silvio Amaral |
| 1.29 | 22/10/2026 | Aba **Protocolos**: **confirmação de leitura** como ciência pelo e-mail de notificação, **lembrete** só sem nenhuma confirmação, **modo teste** de e-mail — migração 019 (seção 15-A) | Silvio Amaral |
| 1.28 | 22/10/2026 | Aba **Protocolos**: **aprovação** do protocolo automático (rascunho às 09h, editar, reter com motivo, aprovar/não enviar) e **retenção manual** com motivo — migração 018 (seção 15-A) | Silvio Amaral |
| 1.27 | 22/10/2026 | Aba **Protocolos**: nota com erro de emissão aparece no quadro de aptas como **SEGURADA** (antes sumia da aba) — migração 017 (seção 15-A) | Silvio Amaral |
| 1.26 | 20/10/2026 | Aba **Protocolos**: rodada da fila de complementares (e do botão ↻ Atualizar aptas) passa de 30 para **15 min** (dias úteis 09h–17h: minutos 05, 20, 35 e 50) | Silvio Amaral |
| 1.25 | 20/10/2026 | Aba **Protocolos**: botão **↻ Atualizar aptas agora** (pedido atendido pela rotina do Mac na rodada da fila; tela acompanha e recarrega) — migração 016 (seção 15-A) | Silvio Amaral |
| 1.24 | 20/10/2026 | Aba **Protocolos**: **2ª via** dos PDFs dos protocolos 001–011 no padrão atual (SUFRAMA em vermelho, razão social), original enviado preservado; botão 📄 abre a 2ª via; evento no histórico (seção 15-A) | Silvio Amaral |
| 1.23 | 20/10/2026 | Aba **Protocolos**: venda para **área de SUFRAMA em vermelho** (cliente com inscrição SUFRAMA no cadastro) nas aptas, no detalhe e no PDF do protocolo — sugestão do Faturamento (seção 15-A) | Silvio Amaral |
| 1.22 | 20/10/2026 | Aba **Protocolos**, etapas 2 e 3: quadro de notas aptas (só Controladoria e Faturamento), retenção automática de bonificação sem faturamento do grupo, protocolo complementar sob demanda pela fila (agendável, cancelável), cliente pela razão social; aba e envio ao time LOG liberados automaticamente em 03/11/2026 (seção 15-A) | Silvio Amaral |
| 1.21 | 20/10/2026 | Aba **Protocolos** (central on-line dos protocolos de expedição, etapa 1): só notas já liberadas; cancelada/devolvida não aparece; ciência da LOG com histórico; homologação = aba só para Controladoria e Faturamento e e-mails só ao Fiscal; protocolo automático às 09h (seção 15-A) | Silvio Amaral |
| 1.20 | 20/10/2026 | Venda à ordem: mãe com **100% remetido** fica com a data da última remessa (entrega no GFE ou, sem ela, a emissão da remessa — fonte "Emissão da última remessa"), na frente do Financeiro; situação Concluída e Entregue = Σ remessas; fora do realizado do previsto × realizado (caso QCOMPRA 280558: FIN 02/10 × remessa 280674 de 05/10) (seção 8) | Silvio Amaral |
| 1.19 | 14/10/2026 | Prazo do romaneio de 7 para **9 dias úteis**, medido no GFE (emissão → romaneio, jul–set/2026: mediana 4, 90% até 9); nota de rodapé explicando o prazo na tela e no informe; informe semanal ganha a seção 2 (previsão de entrega), sem a expressão "anomalia grave" (seções 7.1 e 7.3) | Silvio Amaral |
| 1.18 | 14/10/2026 | Previsão de entrega no Dash: resumo "sem previsão ou previsão superada", 6 cards-filtro, previsto × realizado por mês e por transportadora (só entrega real; previsão anterior à emissão = inválida); anomalia grave = sem romaneio > 7 dias úteis (⚠ + moldura); roteirizado sem previsão passa a vermelho (seções 7.1 e 7.3) | Silvio Amaral |
| 1.17 | 14/10/2026 | Status roteirização: texto abreviado na tela e cor por alerta (verde OK · laranja atenção: previsão > 45 dias da emissão ou sem previsão · vermelho anomalia: previsão vencida ou sem romaneio > 7 dias); Excel com alerta e motivo (seção 7.1) | Silvio Amaral |
| 1.16 | 14/10/2026 | Coluna **Status roteirização** no início do plano de ação: romaneio do GFE (GW1 → GWN) + previsão (GWU_DTPENT); NF-mãe de venda à ordem pelo romaneio da remessa; Excel com STATUS ROTEIRIZAÇÃO e ROMANEIO (seção 7.1, migração 011) | Silvio Amaral |
