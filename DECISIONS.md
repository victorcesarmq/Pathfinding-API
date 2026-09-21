# DECISIONS

Registro de decisões de design não triviais da SmartPath (Seção 9 do
`SMARTPATH_PLANO_DE_EXECUCAO.md`). Toda entrada nova também deve ser refletida em
`src/SmartPath/DECISIONS.luau`.

## D-001 — Origem não é parâmetro da API
Data: 2026-09-20
Contexto: a assinatura natural seria (startPos, goalPos).
Decisão: receber Humanoid/Model e derivar a origem internamente.
Motivo: do humanoid extraímos posição aterrada, JumpHeight real, WalkSpeed e rig — exatamente
a informação que falta ao PathfindingService. Um Vector3 não carrega nada disso.
Consequência: quem só tem coordenadas usa a camada de compatibilidade (`SmartPath.Service`).

## D-002 — Rota com raio reduzido exige validação por Spherecast
Data: 2026-09-20
Contexto: a escada de raio adaptativo (Fase 2) tenta raios menores quando o raio real falha.
Decisão: toda rota obtida com raio reduzido é validada por Spherecast no raio real do agente
ao longo de cada segmento antes de ser aceita.
Motivo: sem essa validação a lib passaria a recomendar rotas onde o personagem não cabe de
fato, o que é pior que o `NoPath` original — o problema deixaria de ser "sem rota" e passaria a
ser "rota falsa".
Consequência: se nenhum raio da escada passar na validação, o erro é `corridor_too_narrow`
com `requiredRadius`.

## D-003 — Sem dependências externas na v1
Data: 2026-09-20
Contexto: bibliotecas como Promise ou Knit facilitariam parte do código assíncrono.
Decisão: a v1 não depende de nenhuma biblioteca externa.
Motivo: a lib precisa ser autocontida e instalável em uma linha (Wally ou cópia direta),
sem exigir que o consumidor resolva árvore de dependências.
Consequência: yields são feitos com primitivas nativas (`task.spawn`, `task.wait`, sinais
próprios).

## D-004 — O gerador de PathfindingLink fica para a v2
Data: 2026-09-20
Contexto: gerar `PathfindingLink` automaticamente (baker) resolveria salto de forma mais
barata em runtime que a predição balística.
Decisão: não implementar na v1; registrado como Fase 10 do plano.
Motivo: é a peça mais valiosa e mais trabalhosa do projeto — misturá-la à v1 arrisca inflar
o escopo e atrasar o lançamento (ver Seção 10, risco "Escopo infla").
Consequência: a v1 depende de predição em runtime (`SmartPath.Predictor`) para saltos não
mapeados por level design.

## D-005 — A biblioteca nunca altera propriedades do mapa do usuário
Data: 2026-09-20
Contexto: filtrar geometria invisível colidível poderia ser feito desligando `CanCollide`.
Decisão: a única alteração permitida no mapa é criar/remover `PathfindingModifier` filho, de
forma reversível e desligável por opção (`Geometry.AutoFilter`). `CanCollide`, `Transparency`
e `Anchored` nunca são tocados.
Motivo: mudar `CanCollide` automaticamente altera a física do jogo do consumidor de formas
que ele não pediu e não consegue prever; é regra permanente (Seção 5, regra 4).
Consequência: partes invisíveis colidíveis não classificadas ficam listadas em
`Geometry.audit()` para o desenvolvedor etiquetar manualmente.

## D-006 — Geometry é global; AutoFilter/RequireNameMatch não são por agente
Data: 2026-09-20
Contexto: a Options.Geometry pública (Seção 3.5) tem `AutoFilter`/`RequireNameMatch` na
tabela de opções de cada agente, mas `PathfindingModifier` é um efeito de mundo — não dá
para um agente ver uma parte como atravessável e outro não, a navmesh é uma só.
Decisão: `Geometry` é o singleton documentado (regra 2) e mantém um único estado global de
classificação por ambiente (cliente/servidor). `Geometry.setAutoFilter`/`setRequireNameMatch`
mudam esse estado global; quando um agente (Fase 4) definir `Options.Geometry` diferente de
outro já ativo, o último a chamar `setAutoFilter`/`setRequireNameMatch` decide para todos —
não existe "visão de mundo" por agente.
Motivo: qualquer alternativa exigiria estado por agente sobre uma feature que é
inerentemente de mundo compartilhado (regra 4: só criamos/removemos `PathfindingModifier`
de forma global e reversível).
Consequência: tags `NavSolid`/`NavIgnore` continuam funcionando independente do AutoFilter
(são intenção explícita do desenvolvedor, nunca desligam); só a heurística de auto-detecção
por Transparency+nome é afetada pelo toggle global.

## D-007 — Prioridade do Scheduler: número maior = mais urgente
Data: 2026-09-20
Contexto: o plano não especifica a direção da prioridade numérica do `Scheduler.submit`.
Decisão: número maior é processado primeiro; em empate, o pedido mais antigo (FIFO) vence.
Motivo: `Options.Scheduler.Priority` (Seção 3.5) tem default `0` — um valor neutro que faz
mais sentido como "meio da escala" se prioridades mais urgentes forem positivas e crescentes
(ex.: jogador em perigo = prioridade alta) do que se a escala fosse invertida.
Consequência: quem chamar `Scheduler.submit` com prioridade alta (ex.: 10) é atendido antes
de quem usa o default. Sem aging: sob carga constante de prioridade alta, um pedido de
prioridade baixa pode esperar indefinidamente — ver item correspondente em `BACKLOG.md`.

## D-008 — Cache de rotas compartilhado é singleton documentado
Data: 2026-09-20
Contexto: o critério de aceite exige waypoints idênticos em chamadas repetidas com a mesma
origem/destino, e o nível 0 (`GetRoute`/`MoveTo`) não tem agente para guardar cache.
Decisão: `RouteSolver` mantém um `RouteCache` compartilhado por ambiente (cliente/servidor),
ao lado de `Scheduler` e `Geometry` como singleton documentado (regra 2). As chaves incluem
um perfil (raio, altura, salto, escada), então agentes de tamanhos diferentes não se misturam.
Agentes (Fase 4) podem passar o próprio cache para `RouteSolver.solve`.
Motivo: sem cache compartilhado, chamadas de nível 0 nunca teriam determinismo, e NPCs indo ao
mesmo alvo recalculariam a mesma rota.
Consequência: o cache invalida por TTL (15s), por versão do `Geometry` e por
`invalidateGoal`. Só sucessos são cacheados: falhas sempre recalculam.

## D-009 — A validação de volume usa 0.6x o Agent.Radius (raio físico do corpo)
Data: 2026-09-20
Contexto: `Agent.Radius` é derivado do bounding box do personagem (Fase 0), que inclui braços
e pernas que não colidem com o Humanoid. Validar com esse raio recusaria um corredor de 4
studs que o corpo atravessa folgado — justamente o caso que a lib existe para resolver.
Decisão: o `Spherecast` de validação (RouteSolver e Simplifier) usa `Util.getBodyRadius` =
`Agent.Radius * 0.6`, a mesma proporção da ESPEC de referência (sonda de 1.2 para raio 2).
Motivo: o raio do `CreatePath` é uma folga de navegação; o de validação deve ser o físico.
Consequência: `requiredRadius` no erro `corridor_too_narrow` é convertido de volta para a
escala de `Agent.Radius` (raio que cabe / 0.6), para ser comparável com `agentRadius`.
Constante a validar empiricamente no rig real do jogo.

## D-010 — Degrau de sonda diagnóstica no fim da escada de raio
Data: 2026-09-20
Contexto: se a engine devolve NoPath até no menor degrau (0.5), não dá para distinguir
"o corredor é estreito demais" de "o destino é desconexo": ambos viram `no_path`.
Decisão: com `Indoor.AdaptiveRadius` ligado, a escada ganha um último degrau em
`MinRadius / 2`. A rota dele passa pela mesma validação de volume: se o corpo cabe, é aceita
(é rota válida); se não cabe, o erro é `corridor_too_narrow` com o maior raio que coube.
Motivo: `no_path` passa a significar "nem um agente minúsculo chega lá" (conectividade), e
`corridor_too_narrow` significa "chega, mas o corpo não cabe" (geometria).
Consequência: uma tentativa extra de `ComputeAsync` no caminho de falha. Se a engine recusar
raios tão pequenos, o degrau é inócuo e o resultado volta a ser `no_path`.

## D-011 — Toda rota da engine é validada por Spherecast, não só as de raio reduzido
Data: 2026-09-20
Contexto: D-002 validava apenas rotas de raio reduzido, supondo que a engine garante folga no
raio cheio. Medido no Studio: com `AgentRadius = 2` a engine atravessa corredores de 4, 3 e
até 2 studs (só recusa 1 stud). O raio dela não é "metade da largura mínima".
Decisão: `runLadder` valida toda rota devolvida, inclusive a do raio configurado. Se o corpo
(0.6x, D-009) não cabe, o degrau é registrado como estreito e a escada continua.
Motivo: o risco que D-002 queria evitar (recomendar rota onde o personagem não cabe) existe
também no raio cheio.
Consequência: uma passada de `Spherecast` por segmento em toda rota nova (o resultado vai
para o cache). Risco: waypoints de canto encostados na parede podem reprovar rotas que caberiam
se centralizadas (ver BACKLOG.md). A premissa do plano de que "AgentRadius infla obstáculos e
faz corredores estreitos sumirem" vale menos do que o esperado nesta engine: o ganho da
escada de raio aparece em vãos de ~1 stud, ou onde o raio configurado é maior que o do rig.

## D-012 — A rota é suavizada ANTES de ser validada
Data: 2026-09-20
Contexto: medido no Studio, a rota crua da engine tem cantos deslocados da linha central
(ela trabalha numa grade, e a grade muda com o raio). Validando a rota crua, o corredor de 3
studs era reprovado (folga medida de 1.0 contra corpo de 1.2) e o de 4 só passava no raio 0.25,
embora a linha reta pelo centro tenha folga de sobra.
Decisão: `runLadder` prepara a rota (origem no chão + string pulling) e só então valida.
Motivo: o `Simplifier` já testa o corpo (0.6x) a cada atalho, então endireitar antes de
validar não aceita nada que não caiba; só deixa de reprovar rotas que a suavização conserta.
Consequência: o item "centralização de waypoints" do `BACKLOG.md` perde urgência (a
suavização resolve o caso de corredor reto); segue valendo para curvas apertadas.

## D-013 — O JumpExecutor guarda um registro global de saltos Native pendentes
Data: 2026-09-20
Contexto: o modo Native altera `JumpHeight`/`JumpPower` do Humanoid e precisa devolver o valor
original em qualquer cenário: pouso, morte no ar, personagem removido, ou um segundo salto
encadeado antes de o primeiro restaurar (o segundo capturaria o valor já alterado e o
restauraria errado para sempre, que é o defeito da implementação de referência da ESPEC).
Decisão: `JumpExecutor` mantém uma tabela de chaves fracas `Humanoid -> {original, conexões}`,
mais um singleton documentado (regra 2). O original é capturado uma vez só; um salto encadeado
reaproveita o do registro. A restauração dispara por Freefall/Landed, `Died`, `Destroying`,
remoção do pai e por um timeout de 1s, e é idempotente.
Motivo: sem estado compartilhado entre chamadas não há como saber qual é o valor original.
Consequência: se o jogo alterar `JumpHeight` durante o salto (dentro do 1s), o original
restaurado sobrescreve a alteração dele; janela curta e improvável.

## D-014 — O apex do salto é dimensionado pela profundidade; corredor aéreo depois da balística
Data: 2026-09-20
Contexto: a ESPEC usa o apex mínimo (altura de clareza + 0.6) e exige `walkSpeed * (tDown -
tUp) >= profundidade + 2 * AgentRadius`. Com raio 2, isso reprova até uma mureta de 3 studs
com 1.5 de profundidade (tempo acima do obstáculo de ~0.16s dá 2.5 studs, contra 6 exigidos),
mesmo o humanoid podendo saltar mais alto e ficar mais tempo no ar.
Decisão: o `Predictor` escolhe o menor apex que dá tempo acima do obstáculo para o centro
cruzar `profundidade + 2 * raio do corpo + margem` (h = g * t² / 8, com t = distância /
WalkSpeed); só devolve `too_deep` se esse apex passa do `JumpHeight` real. O raio usado é o do
corpo (D-009). A checagem do corredor aéreo (esferas de pés e de cabeça) roda depois da
balística, porque precisa do apex e do ponto de decolagem, e varre a coluna do corpo com
esferas empilhadas (dos pés na altura de voo até a cabeça no apex): com só duas esferas, pés
e cabeça, uma laje entre as duas passava despercebida (achado no teste de teto baixo).
O topo do obstáculo é medido no mesmo objeto que o raio do joelho acertou, para que uma laje
sobre a mureta não seja confundida com o topo dela.
Motivo: sem isso a lib recusaria saltos que o personagem faz com folga, que é a falha central
que ela existe para resolver.
Consequência: saltos podem ser mais altos que o mínimo. Obstáculos compostos por várias
partes (ex.: escada) têm o topo medido só na parte acertada pelo joelho.

## D-015 — Cancelamento não dispara `Failed`; só resolve o `Await`
Data: 2026-09-20
Contexto: o contrato lista `cancelled` entre os códigos de erro ("Stop() ou novo MoveTo"), e
`Failed` é o sinal de falha. Um `Stop()` é ação do próprio usuário.
Decisão: `Stop()` e um `MoveTo` que substitui outro resolvem o `Await` da sessão cancelada com
`(false, "cancelled")`, mas não disparam `Failed`. `Failed` fica para falhas reais (`no_path`,
`stuck`, `character_lost`, ...). `Destroy()` também cancela o `Await` pendente.
Motivo: quem ouve `Failed` para tratar falha de navegação não deve ser acionado por um Stop que
ele mesmo pediu.
Consequência: `SmartPath.MoveTo` (nível 0) devolve `false, "cancelled"` nesses casos.

## D-016 — O passo do Agent roda em PreSimulation, não em Heartbeat
Data: 2026-09-20
Contexto: a ESPEC usa Heartbeat. No cliente, o ControlModule do jogador chama `Humanoid:Move`
em RenderStepped, que ocorre antes da física; um `Move` dado só no Heartbeat (depois da física)
seria sobrescrito por ele antes de ser usado.
Decisão: `_step` roda em `RunService.PreSimulation` (existe em cliente e servidor), depois do
RenderStepped e antes da física.
Motivo: é o que faz o agente mandar num personagem de jogador sem desabilitar o ControlModule.
Consequência: [VALIDAR] no cliente com um jogador real; só o NPC no servidor foi exercitado.

## D-017 — O Path fica no cache, e o solver aceita origem explícita
Data: 2026-09-20
Contexto: `Path.Blocked` só dispara para quem segura o objeto Path. Uma rota vinda do cache não
tinha Path, então o agente que a recebesse nunca seria avisado de bloqueio. E a validação de um
atalho por salto precisa calcular a partir do ponto de pouso, não da posição do personagem.
Decisão: o `RouteCache` guarda o `Path` junto com a rota (o evento dispara para qualquer um que
o segure). `RouteSolver.solve` ganhou `startGroundOverride` e devolve `cacheGoal` (o destino
normalizado usado como chave, necessário para `invalidateGoal`).
Motivo: sem isso o `Blocked` só funcionaria para o primeiro agente a calcular cada rota.
Consequência: o cache mantém Paths vivos até o TTL ou despejo.

## D-018 — Relaxamento de waypoints quando a rota não cabe, e `blockedAt` no diagnóstico
Data: 2026-09-20
Contexto: o percurso do teste do Agent (corredor de 4 studs, contorno da mureta, rampa) falhou
com `corridor_too_narrow`. Numa rota com curvas, os waypoints de canto que a engine devolve
ficam encostados na parede, e o `Spherecast` do corpo reprova segmentos que ligam esses cantos
(o item "centralização de waypoints" do backlog, agora mostrado por um caso real).
Decisão: quando a rota (já suavizada) não cabe, `relaxRoute` empurra cada waypoint interior de
andar para longe das paredes mais perto que 1.25x o raio do corpo (raios horizontais na altura
do tronco, até 4 iterações, no máximo 1.5 studs do original, exigindo chão parecido no novo
ponto) e a validação roda de novo. Só entra como recurso: rota que já cabia fica idêntica.
O erro `corridor_too_narrow` ganhou `blockedAt`, o ponto onde o corpo bate, para diagnóstico.
Motivo: sem isso, qualquer mapa com curvas apertadas devolveria falso `corridor_too_narrow`.
Consequência: waypoints podem sair até 1.5 studs do que a engine devolveu. Os fatores são
próprios e precisam ser validados em mapas reais.

## D-019 — O waypoint `Jump` é o DESTINO do salto, não a decolagem
Data: 2026-09-20
Contexto: a ESPEC supunha que `Action = Jump` marca o ponto de decolagem e listava isso como
`[VALIDAR]` nº 1. No percurso do teste do Agent, o `blockedAt` do `corridor_too_narrow` caiu
exatamente na face da mureta (x = 24, y = 2.5): a rota tinha um segmento `Walk -> Jump`
atravessando o obstáculo, ou seja, o waypoint Jump ficava do outro lado dele. Isso também é o
padrão documentado pela Roblox: "ao começar a ir para um waypoint Jump, pule".
Decisão: o segmento que CHEGA a um waypoint `Jump` é o voo e não é validado como caminhada
(`RouteSolver.routeClear`); o `Agent` salta ao chegar ao waypoint ANTERIOR, em direção ao
waypoint Jump, e repete a tentativa a cada frame se ainda não deu (cooldown, no ar). Segmentos
que partem de um `Custom` também não são validados.
Motivo: com a suposição antiga, toda rota da engine com um salto era reprovada como
`corridor_too_narrow`, e o agente saltaria tarde demais (já em cima do obstáculo).
Consequência: resolve o item 1 da seção 12 da ESPEC. Ainda [VALIDAR] a semântica de `Custom`.

## D-020 — A validação de volume varre o terreno, não uma reta 3D
Data: 2026-09-20
Contexto: com `WaypointSpacing = math.huge` a engine só devolve waypoints nos cantos, então numa
rampa dois waypoints consecutivos (pé da rampa e plataforma) ficam ligados por uma reta 3D que
passa por dentro do corpo da rampa. O `blockedAt` de um `corridor_too_narrow` no percurso de
teste caiu na superfície da rampa (x = 57, y = 3.4), com a esfera varrida pela reta e não pelo chão.
Decisão: `routeClear` divide cada segmento em passos horizontais de 2 studs e projeta cada ponto
intermediário no chão (raio para baixo, de 3 acima a 9 abaixo do ponto interpolado) antes de
varrer a esfera entre pontos consecutivos. Sem chão embaixo, usa o ponto interpolado.
Motivo: rampas, escadas rolantes e qualquer desnível gradual eram reprovados como "não cabe".
Consequência: mais raios por validação (um por passo de 2 studs), pagos só quando a rota é nova
(depois vai para o cache). O `Simplifier` mantém a varredura em reta, protegida pela checagem de
chão contínuo (`maxFloorDelta`).

## D-021 — Bloqueio de rota é detectado por nós; `Path.Blocked` fica como reforço
Data: 2026-09-20
Contexto: medido no Studio, o `Path.Blocked` não disparou em 40s para uma parede inserida no
meio da rota (`Blocked 0`), e a malha do `PathfindingService` só passou a enxergar a parede
depois de mais de 10s (o replan, antes disso, devolvia a rota reta de novo).
Decisão: (1) `Geometry.PartAdded` avisa quando uma parte colidível e consultável entra no
workspace; (2) cada `Agent` marca a rota como "suja" (personagens ignorados) e, no máximo a
cada 0.25s, revalida os segmentos restantes com `RouteSolver.isRouteClear`, a mesma varredura
que aceitou a rota; se não cabe mais, dispara `Blocked`, para o agente, invalida o cache do
destino e replaneja; (3) enquanto a malha não inclui o obstáculo (o solver não acha rota), o
agente espera e tenta de novo a cada 1.5s por até 30s, em vez de falhar com `corridor_too_narrow`.
`Path.Blocked` continua ligado, e os dois caminhos convergem em `_onBlocked`.
Motivo: a revalidação usa raycasts, que enxergam a parte na hora, sem depender da malha.
Consequência: partes que se MOVEM para dentro da rota (sem serem novas) ainda não são
detectadas. Durante a espera o solver refaz a escada a cada 1.5s (várias chamadas de
`ComputeAsync`, limitadas pelo Scheduler).

## D-022 — Camada de compatibilidade: cálculo só por posições, Status mapeado, Blocked sob demanda
Data: 2026-09-20
Contexto: `SmartPath.Service:CreatePath(...):ComputeAsync(start, finish)` recebe só `Vector3`; não
há Humanoid para derivar raio, altura de pulo e velocidade (a razão de D-001 existir).
Decisão: (1) `RouteSolver` foi dividido em `solveFrom` (só posições) e dois pontos de entrada:
`solve` (com personagem) e `solvePositions` (sem personagem, que exclui dos raycasts os modelos
com Humanoid a 4 studs da origem, pois quem pede a rota costuma ser um deles). (2) O raio e a
altura vêm do `CreatePath` (ou dos defaults dele, 2 e 5); `AgentCanJump` liga/desliga o salto;
`WaypointSpacing`, `Costs` e `AgentCanClimb` são ignorados. (3) `path.Status` descreve o
resultado da SmartPath: `Success` mesmo quando a engine sozinha não acharia; `goal_unreachable`
vira `FailFinishNotEmpty`, o resto vira `NoPath`; antes de calcular é `NoPath`. Os códigos vão em
`SmartStatus`/`SmartDetails`. (4) `path.Blocked` é um objeto com `Connect`/`Once`/`Wait` que só
começa a observar o mundo (D-021) quando alguém conecta, com referência fraca ao Path, para que
scripts que criam um Path por navegação não acumulem observadores; dispara uma vez por cálculo
com o índice do waypoint em que termina o segmento bloqueado.
Motivo: é o que deixa um script clássico funcionar trocando só a linha do require.
Consequência: sem `WaypointSpacing` as rotas têm poucos waypoints; um script que dependa de
espaçamento fixo precisa ajustar.

## D-023 — Nível 0 reaproveita um Agent por Humanoid; alvo móvel é seguido por limiar
Data: 2026-09-20
Contexto: `SmartPath.MoveTo(humanoid, target)` em laço criaria um Agent (com conexões) por
chamada, e um destino `BasePart`/`Model` pode se mover.
Decisão: `init` mantém um Agent por Humanoid (chaves fracas), criado na primeira chamada e
destruído quando o Humanoid é destruído; chamadas seguintes reaproveitam o agente (e aplicam
`SetOptions` se vierem opções), e duas chamadas para o mesmo personagem se cancelam (a antiga
devolve `false, "cancelled"`). Para alvo `BasePart`/`Model`, o Agent confere a posição a cada
0.25s e refaz a rota (forçada, sem histerese) quando o alvo se afasta mais de 4 studs do destino
do último cálculo.
Motivo: sem o registro, MoveTo em laço vaza conexões; sem o limiar, replanejar a cada passo do
alvo custaria ComputeAsync demais e causaria zigue-zague.
Consequência: o último waypoint conta como alcançado a 3 studs do ponto quando o destino é um
`BasePart`/`Model` (um alvo que é outro personagem colide a ~2 studs, então exigir 1.25 faria o
agente empurrá-lo até cair no anti-stuck). Ao chegar, se o alvo ainda está além de 3.5 studs
(andou depois do último cálculo), o agente refaz a rota em vez de declarar chegada; termina a no
máximo 3.5 studs do alvo. Corrigido depois do teste: a primeira versão terminava a até ~5 studs.

## D-024 — Diagnóstico de causa: invisible_collider, obstacle_too_tall e no_landing
Data: 2026-09-20
Contexto: a Fase 6 exige que os 10 códigos sejam emitidos. Quatro não saíam de lugar nenhum
(`obstacle_too_tall`, `no_landing`, `invisible_collider`, `timeout`); o `Predictor` só devolvia
`too_tall`/`no_landing` como motivo interno, sem medidas.
Decisão: (1) `Predictor.analyze` ganhou um terceiro retorno com as medidas (`height`+`maxJump`
para `too_tall`/`insufficient_jump`; `drop` para `no_landing`/`drop_too_high`; `at` = onde está a
parede; `atLeast = true` quando o raio só prova um mínimo) e a opção `probeDistance`.
(2) `invisible_collider`: toda falha do `RouteSolver` passa por `fail`, que procura a parte
invisível colidível (`Geometry.isInvisibleCollider`: `CanCollide`, `Transparency >= 0.95`, sem
`NavSolid`) no ponto de estrangulamento (`corridor_too_narrow`), no destino (`goal_unreachable`
por parede) ou na PRIMEIRA batida do Spherecast do corpo na reta início -> destino (`no_path`).
Achando, o código vira `invisible_collider` com `instance`, `position` e `underlying` (o código
original). Se o agente trava (`stuck`), o `Agent` faz o mesmo para a frente do corpo, mas SEM o
filtro da lib: o gatilho que a lib filtrou (a malha o atravessa) e o corpo bate é exatamente o
caso. (3) `obstacle_too_tall`/`no_landing`: só quando o `Agent` não tem rota (`no_path`), não
consegue o salto direto e o `Predictor`, olhando a reta inteira até o destino (`probeDistance =
math.huge`, só na hora de falhar), explica por que o salto é impossível.
Motivo: parte invisível, obstáculo alto e vazio sem chão são as três causas que o desenvolvedor
não vê a olho nu e que hoje viravam um `no_path` mudo.
Consequência: é heurística, e assumida como tal: só a primeira batida conta (uma parede visível
antes da invisível esconde o diagnóstico, que fica `no_path`), e só o primeiro obstáculo da reta
é analisado (uma torre alta atrás de um desvio não é apontada). `NavSolid` nunca é suspeito: é
limite de mapa declarado.

## D-025 — `timeout` é um orçamento interno, não uma opção
Data: 2026-09-20
Contexto: o código `timeout {elapsed}` existe no contrato, mas a tabela de opções (Seção 3.5) é
congelada e não tem campo de tempo máximo.
Decisão: o `Agent` guarda o instante em que a movimentação começou e falha com `timeout` quando
`elapsed > 45 + 4 x (maior rota adotada) / WalkSpeed`. O orçamento recomeça quando um alvo móvel
se afasta (perseguir sem fim não estoura) e não conta o tempo suspenso. As duas constantes ficam
em `Agent._tuning`, só para os testes encurtarem.
Motivo: é a rede de segurança para o que o anti-stuck não pega (o agente anda, mas nunca chega).
Os 45 s cobrem a janela de espera por bloqueio (30 s, D-021) com folga.
Consequência: [VALIDAR] os valores num jogo real; um agente propositalmente lento em mapa enorme
pode precisar de mais tempo e não tem como pedir (registrado em `BACKLOG.md`).

## D-026 — Debug em módulo próprio, painel explícito, `explain` em português
Data: 2026-09-20
Contexto: os desenhos de debug estavam em `Util` (dois pontos e uma rota) e o plano pede mais:
waypoints por ação, decolagem, pouso, obstáculo, raio efetivo, painel.
Decisão: (1) `Debug.luau` concentra pasta, partes, linhas, disco de raio, marcas de obstáculo e
falha e o painel; `Util.drawPoint/drawRoute/getDebugFolder` foram removidos. Nada aqui roda com
`Options.Debug = false`: quem chama checa a opção, então não há instância, print nem custo. (2)
Toda parte de debug: `Anchored` verdadeiro; `CanCollide`, `CanQuery` e `CanTouch` falsos; como
segunda barreira a pasta entra em todo `RaycastParams` da lib (`Geometry.addExclusion`, que também
sobe a versão para o `Agent` reconstruir seus params). (3) O painel
(`SmartPath.Debug.showPanel(agent, parent?)`) só existe quando o desenvolvedor o chama, não por
`Options.Debug`; no cliente o pai é o `PlayerGui`, no servidor não há tela e o pai é obrigatório.
(4) `SmartPath.explain` devolve texto em português (o exemplo do plano está em português) e nunca
erra: details ausente, incompleto ou de tipo errado e código desconhecido viram frase. (5)
`MoveTo` e `GetRoute` passam a devolver `details` como terceiro valor (quem lê só `ok, reason` não
percebe): sem ele o nível 0 não teria como chamar `explain`.
Motivo: um erro só é útil se dá para agir sobre ele; o desenho mostra onde, o `explain` diz o quê.
Consequência: `requiredRadius` em `corridor_too_narrow` é o maior raio de agente que CABERIA (o
nome vem do plano), e `explain` o diz assim ("só comporta um agente de raio até X"). O texto é
uma tabela de funções em `Diagnostics.luau`, pronta para tradução. O `Scheduler` ainda faz `warn`
incondicional quando um job lança erro (é bug, não fluxo normal; ver `BACKLOG.md`).

## D-027 — O demo é um projeto Rojo à parte; o baseline é protegido com NavSolid; o gatilho usa grupo de colisão
Data: 2026-09-20
Contexto: a Fase 7 pede o place de demonstração: 8 cenários, um NPC de PathfindingService puro à
esquerda e um da SmartPath à direita, sobre geometria idêntica. Três problemas apareceram no desenho.
Decisão: (1) O demo mora em `src/demo/` e tem o seu `demo.project.json` (biblioteca + demo, sem os
testes). Os dois compartilham o `Scheduler` e a `Geometry`, que são singletons; rodar 40 NPCs junto
com os testes de fase mudaria os resultados dos dois. (2) `Geometry` é global (D-006): ela põe
`PathfindingModifier` PassThrough em qualquer gatilho invisível do workspace, inclusive na pista
do lado clássico, o que ajudaria o baseline e invalidaria a comparação. Toda parte da pista
clássica leva a tag `NavSolid` ("SmartPath, não toque"), que para o PathfindingService não significa
nada. A geometria continua idêntica; só a tag difere. (3) Um gatilho invisível com `CanCollide`
verdadeiro também bloqueia o corpo (o Phase 6 mostrou: `stuck`). O `DoorTrigger` do cenário 5
fica num grupo de colisão que não colide com `Default`: a malha do PathfindingService o vê como
parede, o corpo o atravessa. É o caso real (gatilho colidível só para `Touched`).
Motivo: sem (2) e (3) o cenário 5 ou não separaria os dois lados, ou seria impossível para ambos.
Consequência: [VALIDAR] no Studio se a malha da engine respeita grupos de colisão; se respeitar, o
lado clássico atravessa o gatilho e o cenário 5 não distingue os dois lados. O cenário 8 roda um
lado de cada vez (30 s cada, mais 5 s sem NPCs) para que o FPS de um não contamine o do outro.
Os cenários 3 e 4 começam a ~7 studs do obstáculo: o atalho por salto só enxerga obstáculos a até
10 studs (`PROBE_DISTANCE` do `Predictor`); ver `BACKLOG.md`.

## D-028 — Personagens nunca são parede: excluídos dos RaycastParams; o corpo de outro NPC não é "invisível colidível"
Data: 2026-09-20
Contexto: o cenário 8 do demo (20 NPCs na mesma pista) deu 149 falhas da SmartPath em 256 trechos:
95 `corridor_too_narrow` e 54 `invisible_collider`. Dois defeitos diferentes, ambos por tratar outro
personagem como geometria. (1) Os `RaycastParams` da lib só excluíam o próprio personagem, então a
validação de volume reprovava rotas por causa de um NPC parado (item do BACKLOG desde a Fase 4).
(2) O `HumanoidRootPart` do R15 é invisível e colidível; o diagnóstico de `stuck` (D-024) o
apontava como "parte invisível colidível".
Decisão: `Geometry` passa a guardar os modelos com `Humanoid` (`trackCharacter`, na varredura
inicial e no `DescendantAdded`) e `buildRaycastParams` os inclui na lista de exclusão; registrar um
personagem novo sobe a versão, para o `RaycastParams` cacheado de cada `Agent` se refazer.
`Geometry.isInvisibleCollider` devolve falso para qualquer parte dentro de um modelo com
`Humanoid`. Além disso, o `corridor_too_narrow` passou a levar `rejectedRoute` (a rota que a
engine devolveu e o corpo não coube), que o `Debug` desenha em vermelho.
Motivo: um personagem se move; validar a rota contra a posição dele num instante é errado, e o
anti-stuck já cuida de quem bloqueia de verdade.
Consequência: registrar cada personagem invalida o cache de rotas (um evento por NPC criado); num
jogo com muitos spawns seguidos isso reduz a taxa de acerto do cache, sem afetar a correção. Uma
parte qualquer que esteja dentro de um modelo com `Humanoid` (uma arma, por exemplo) também
deixa de ser suspeita de `invisible_collider`.

## D-029 — Os raios do relaxamento partem atrás do waypoint
Data: 2026-09-20
Contexto: no cenário 5 do demo a engine devolveu uma rota com um canto exatamente sobre a face de
uma parede (x = -1.0, face em x = -1). O resgate de D-018 não o empurrou, porque um raio que
começa numa superfície não a acerta, e a rota foi reprovada com `corridor_too_narrow` e
`requiredRadius = 0`, embora houvesse espaço de sobra ao redor.
Decisão: os raios horizontais do `relaxRoute` partem 0.3 stud atrás do waypoint e ganham 0.3 de
alcance; a distância à parede é medida a partir do waypoint. Um canto encostado ou colado é
detectado e empurrado (no máximo `RELAX_MAX_SHIFT`, como antes).
Motivo: a engine tolera raio 2 e leva a rota até a parede; o resgate existe para esse caso.
Consequência: o resgate continua limitado a 1.5 stud de deslocamento; um canto mais enterrado
que isso segue reprovado. O suavizador também não cria cantos novos (só liga os da engine), então a
rota resultante pode ser mais colada nas paredes do que o ideal.

## D-030 — Resgate relaxa os cantos crus antes de suavizar; o agente revalida a rota a cada 1 s
Data: 2026-09-20
Contexto: dois achados do demo. (1) Cenário 5: o `rejectedRoute` mostrou que o suavizador ligou um
canto sobre a face de uma parede diretamente ao destino do outro lado, atravessando a parede: o
`Spherecast` ignora o que já sobrepõe a origem (D-014), e a âncora estava em cima da parede. A
rota reprovava, e o relaxamento de D-018/D-029, aplicado à rota já suavizada, movia o canto mas o
trecho seguinte continuava cortando a parede. (2) Cenário 7: um bloco criado no alto e depois
solto sobre a rota não disparou `Blocked`, porque `Geometry.PartAdded` só avisa de partes novas,
e o bloco já estava no mundo (ainda sem bloquear) quando foi criado.
Decisão: (1) no resgate, `runLadder` relaxa os cantos CRUS da engine e passa pelo suavizador de novo
(`prepareRoute(relaxRoute(raw))`); se ainda não couber, tenta relaxar a rota já suavizada, como
antes. Nenhuma âncora do suavizador fica encostada na parede. (2) Em `Following`, com rota vinda do
solver, o `Agent` marca a rota como suja a cada `ROUTE_RECHECK_INTERVAL` (1 s) e a revalida com a
mesma varredura de sempre; o custo é uma validação por segundo por agente.
Motivo: (1) o resgate só serve se a rota que ele devolve não passa por dentro de uma parede.
(2) partes que se movem (blocos, portas) são o caso normal de obstáculo dinâmico.
Consequência: (1) o resgate só roda quando a rota não cabe, então rotas que já cabiam não mudam. (2) o
bloqueio por parte móvel é detectado em até 1 s (mais até 0.25 s do intervalo de `_checkRoute`),
não na hora; fecha em parte o item do `BACKLOG.md` sobre partes que se movem para dentro da rota.

## D-031 — Reparo de rota: waypoints de desvio inseridos onde o corpo bate
Data: 2026-09-20
Contexto: no cenário 8 do demo, 19 a 26 dos ~130 trechos da SmartPath falhavam com
`corridor_too_narrow`, sempre nas quinas de pilares (o pilar central, por exemplo, nos cantos
(-7, ±2)). O relatório mostrou `rota` com 2 waypoints: a engine é tolerante e devolve a reta de
origem a destino passando a ~0.6 stud da quina, sem nenhum canto. O resgate de D-018/D-029/D-030
só move waypoints que já existem, então não havia o que relaxar.
Decisão: `repairRoute` é a última tentativa do resgate em `runLadder`. Repete até 8 vezes: mede a
rota, e onde o corpo bate insere um waypoint de desvio no lado livre da superfície (a normal da
batida, projetada no plano) a `bodyRadius x 1.25 + 0.3` do ponto de contato, apoiado no chão. Só
roda quando a rota não coube nem com os relaxamentos, e a validação de volume continua a última
palavra: a rota reparada só é aceita se a MESMA varredura a aprovar. `routeClear` passou a devolver
também a normal da batida.
Motivo: é o mesmo caso que D-018 tratava (a engine leva a rota até a parede), mas sem waypoint
interior para empurrar.
Consequência: o desvio é local e pode deixar a rota mais quebrada que o ideal; o suavizador não
roda de novo depois do reparo. Uma batida em superfície horizontal (normal vertical) interrompe o
reparo, porque desviar de lado não a resolve. Cobertura: `Phase2` ganhou um cenário com a reta
roçando a quina de um pilar.

## D-032 — Pouso de salto avança além do waypoint Jump; mobília do cenário 2 é alta demais para pular
Data: 2026-09-20
Contexto: dois achados de quem assistiu ao demo. (1) Cenário 3: ao saltar a mureta o NPC pousava
um pouco além do waypoint `Jump` (o destino do salto, D-019), voltava até ele e só então seguia:
uma "voltinha" perceptível. `_selectStartIndex` só avançava sobre waypoints `Walk` já ultrapassados.
(2) Cenário 2: a mobília tinha 3 studs, e tanto a engine quanto a SmartPath saltavam por cima da
mesa em vez de usar o corredor entre mesa e estante e a porta de 3 studs; o cenário não testava
o que dizia testar.
Decisão: (1) `_selectStartIndex` ganhou `afterLanding`; no pouso, um waypoint `Jump` que o agente
já ultrapassou (produto escalar com o segmento seguinte) é dado como alcançado. (2) A mobília do
cenário 2 passou a 6 a 8 studs (armário, estante, gabinete, cômoda), acima do que a engine pula.
Motivo: (1) o destino do salto é um ponto de referência, não uma parada obrigatória. (2) um cenário
de demonstração tem de exercitar a capacidade que nomeia.
Consequência: (1) uma rota que termina num waypoint `Jump` continua sendo concluída pelo raio de
chegada, que não mudou. (2) o cenário 2 pode passar a discriminar os dois lados, ou não; depende
do que a engine faz com o corredor de 3.2 studs, e o próximo relatório diz.

## D-033 — Endurecimento: comportamento documentado dos casos-limite
Data: 2026-09-21
Contexto: a Fase 8 percorre a checklist de casos-limite. A leitura do código antes de escrever os
testes mostrou vários sem comportamento definido (o agente "travava" onde na verdade o corpo não
podia andar; dois agentes no mesmo Humanoid; queda sem fim chamando a engine à toa).
Decisão, caso a caso:
- Personagem morre (na rota ou no ar): `character_lost`; o `JumpExecutor` restaura o JumpHeight.
- Personagem removido do jogo (`Destroy`, pai nil): `character_lost` e o agente se destrói 0.5 s
  depois (os handlers de `Failed` rodam antes). Antes ele ficava com 5 conexões vivas até alguém
  chamar `Destroy`. Personagem que só morreu NÃO destrói o agente (a engine o remove depois).
- `WalkSpeed` 0, `Humanoid.Sit` ou `PlatformStand`: o corpo não anda de propósito (stun, veículo);
  isso não é `stuck`. O anti-stuck ignora, o agente espera e retoma quando o corpo volta a andar; a
  rede de segurança é o `timeout` (D-025).
- `JumpHeight` 0 (ou `JumpPower` 0): `Jump.Enabled` é DERIVADO do personagem quando o usuário não o
  definiu (`Config.resolve`, na criação e no `SetOptions`); a rota não tem saltos e um obstáculo sem
  passagem dá `no_path`. Um pedido de salto com altura 0 não faz nada em vez de simular um pulo.
- `UseJumpPower` verdadeiro: já era coberto (`getMaxJumpHeight` usa JumpPower²/2g; `JumpExecutor`
  restaura o JumpPower).
- R6 e R15: tudo é derivado do bounding box e de `Util.getFeetY`; testado com rigs reais, zero opções.
- Destino igual à posição (a menos do raio de chegada, 1.25, e de uma tolerância de altura): chega na
  hora, sem chamar o solver. Destino NaN ou infinito: `goal_unreachable`, sem propagar NaN.
- Destino a 5000 studs: sem chão lá, `goal_unreachable` (a projeção do destino falha); ilha isolada,
  `no_path`. Sem nada especial para distâncias grandes.
- Sem chão sob o agente (queda infinita, fora do mapa): depois de esperar aterrar (1.5 s), se não há
  chão embaixo e o `FloorMaterial` continua `Air`, o solver devolve `no_path` com `noGround = true`
  sem chamar a engine. `explain` diz isso.
- `workspace.Gravity` alterado: o `Predictor` e o `JumpExecutor` já liam a gravidade viva.
- Dois agentes no mesmo personagem: `SmartPath.new` dá ERRO CLARO se já existe um agente vivo para o
  Humanoid; `SmartPath.MoveTo` reaproveita o existente (inclusive um criado com `new`). O registro é
  um só para os dois níveis; depois de `:Destroy()` pode criar outro. `Agent.new` (nível 2) não
  restringe.
- `MoveTo` dentro de `Reached` ou de `Failed`: já funcionava (o sinal dispara por último e a sessão
  nova não é atropelada); agora é teste.
- StreamingEnabled: no CLIENTE, antes de calcular uma rota para um destino a mais de 100 studs, o
  agente chama `Player:RequestStreamAroundAsync(destino, 2)` (protegido por pcall). No servidor não faz
  nada. Uma região não carregada, enquanto isso, é um destino sem chão: `goal_unreachable`. [VALIDAR]
  em um jogo real com StreamingEnabled: não há como ligar streaming em um teste de servidor.
Motivo: uma biblioteca é o que ela faz nos casos que o autor não pensou; cada um deles agora tem um
resultado previsível e um teste.
Consequência: `Config.resolve` passa a devolver `Jump.Enabled = false` para um Humanoid que não salta,
mesmo sem o usuário pedir; quem quiser forçar passa `Jump = { Enabled = true }`.
