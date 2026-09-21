-- DECISIONS.luau
-- Espelha DECISIONS.md em runtime (Seção 4 do plano de execução). Ao adicionar uma
-- decisão nova, atualize os dois arquivos juntos.

return [[
## D-001 — Origem não é parâmetro da API
Data: 2026-09-20
Contexto: a assinatura natural seria (startPos, goalPos).
Decisão: receber Humanoid/Model e derivar a origem internamente.
Motivo: do humanoid extraímos posição aterrada, JumpHeight real, WalkSpeed e rig — exatamente
a informação que falta ao PathfindingService. Um Vector3 não carrega nada disso.
Consequência: quem só tem coordenadas usa a camada de compatibilidade (SmartPath.Service).

## D-002 — Rota com raio reduzido exige validação por Spherecast
Data: 2026-09-20
Contexto: a escada de raio adaptativo (Fase 2) tenta raios menores quando o raio real falha.
Decisão: toda rota obtida com raio reduzido é validada por Spherecast no raio real do agente
ao longo de cada segmento antes de ser aceita.
Motivo: sem essa validação a lib passaria a recomendar rotas onde o personagem não cabe de
fato, o que é pior que o NoPath original.
Consequência: se nenhum raio da escada passar na validação, o erro é corridor_too_narrow
com requiredRadius.

## D-003 — Sem dependências externas na v1
Data: 2026-09-20
Contexto: bibliotecas como Promise ou Knit facilitariam parte do código assíncrono.
Decisão: a v1 não depende de nenhuma biblioteca externa.
Motivo: a lib precisa ser autocontida e instalável em uma linha, sem exigir que o consumidor
resolva árvore de dependências.
Consequência: yields são feitos com primitivas nativas (task.spawn, task.wait, sinais próprios).

## D-004 — O gerador de PathfindingLink fica para a v2
Data: 2026-09-20
Contexto: gerar PathfindingLink automaticamente (baker) resolveria salto de forma mais barata
em runtime que a predição balística.
Decisão: não implementar na v1; registrado como Fase 10 do plano.
Motivo: é a peça mais valiosa e mais trabalhosa do projeto — misturá-la à v1 arrisca inflar o
escopo e atrasar o lançamento.
Consequência: a v1 depende de predição em runtime (SmartPath.Predictor) para saltos não
mapeados por level design.

## D-005 — A biblioteca nunca altera propriedades do mapa do usuário
Data: 2026-09-20
Contexto: filtrar geometria invisível colidível poderia ser feito desligando CanCollide.
Decisão: a única alteração permitida no mapa é criar/remover PathfindingModifier filho, de
forma reversível e desligável por opção (Geometry.AutoFilter). CanCollide, Transparency e
Anchored nunca são tocados.
Motivo: mudar CanCollide automaticamente altera a física do jogo do consumidor de formas que
ele não pediu e não consegue prever.
Consequência: partes invisíveis colidíveis não classificadas ficam listadas em
Geometry.audit() para o desenvolvedor etiquetar manualmente.

## D-006 — Geometry é global; AutoFilter/RequireNameMatch não são por agente
Data: 2026-09-20
Contexto: a Options.Geometry pública tem AutoFilter/RequireNameMatch na tabela de opções de
cada agente, mas PathfindingModifier é um efeito de mundo — não dá para um agente ver uma
parte como atravessável e outro não.
Decisão: Geometry é o singleton documentado e mantém um único estado global de classificação
por ambiente (cliente/servidor). setAutoFilter/setRequireNameMatch mudam esse estado global;
o último agente a chamá-los decide para todos.
Motivo: qualquer alternativa exigiria estado por agente sobre uma feature inerentemente de
mundo compartilhado.
Consequência: tags NavSolid/NavIgnore continuam funcionando independente do AutoFilter; só a
heurística de auto-detecção é afetada pelo toggle global.

## D-007 — Prioridade do Scheduler: número maior = mais urgente
Data: 2026-09-20
Contexto: o plano não especifica a direção da prioridade numérica do Scheduler.submit.
Decisão: número maior é processado primeiro; em empate, o pedido mais antigo (FIFO) vence.
Motivo: Options.Scheduler.Priority tem default 0, mais natural como "meio da escala" se
prioridades urgentes forem positivas e crescentes.
Consequência: sem aging, um pedido de prioridade baixa pode esperar indefinidamente sob carga
constante de prioridade alta — ver BACKLOG.md.

## D-008 — Cache de rotas compartilhado é singleton documentado
Data: 2026-09-20
Contexto: o critério de aceite exige waypoints idênticos em chamadas repetidas com a mesma
origem/destino, e o nível 0 não tem agente para guardar cache.
Decisão: RouteSolver mantém um RouteCache compartilhado por ambiente, ao lado de Scheduler e
Geometry como singleton documentado. As chaves incluem um perfil (raio, altura, salto,
escada). Agentes podem passar o próprio cache para RouteSolver.solve.
Motivo: sem cache compartilhado, chamadas de nível 0 nunca teriam determinismo.
Consequência: invalida por TTL, versão do Geometry e invalidateGoal. Só sucessos são
cacheados.

## D-009 — A validação de volume usa 0.6x o Agent.Radius (raio físico do corpo)
Data: 2026-09-20
Contexto: Agent.Radius vem do bounding box (inclui membros que não colidem). Validar com ele
recusaria um corredor de 4 studs que o corpo atravessa folgado.
Decisão: o Spherecast de validação usa Util.getBodyRadius = Agent.Radius * 0.6, a proporção
da ESPEC de referência (sonda de 1.2 para raio 2).
Motivo: o raio do CreatePath é folga de navegação; o de validação deve ser o físico.
Consequência: requiredRadius em corridor_too_narrow é convertido de volta para a escala de
Agent.Radius (raio que cabe / 0.6). Constante a validar no rig real do jogo.

## D-010 — Degrau de sonda diagnóstica no fim da escada de raio
Data: 2026-09-20
Contexto: se a engine devolve NoPath até no menor degrau, não dá para distinguir corredor
estreito de destino desconexo.
Decisão: com Indoor.AdaptiveRadius ligado, a escada ganha um último degrau em MinRadius / 2,
validado como os demais: se o corpo cabe, a rota é aceita; se não, corridor_too_narrow.
Motivo: no_path passa a significar conectividade; corridor_too_narrow, geometria.
Consequência: uma tentativa extra de ComputeAsync no caminho de falha. Se a engine recusar
raios tão pequenos, o degrau é inócuo e o resultado volta a ser no_path.

## D-011 — Toda rota da engine é validada por Spherecast, não só as de raio reduzido
Data: 2026-09-20
Contexto: D-002 validava apenas rotas de raio reduzido. Medido no Studio: com AgentRadius 2 a
engine atravessa corredores de 4, 3 e até 2 studs; o raio dela não garante folga.
Decisão: runLadder valida toda rota devolvida, inclusive a do raio configurado.
Motivo: o risco de recomendar rota onde o corpo não cabe existe também no raio cheio.
Consequência: uma passada de Spherecast por segmento em toda rota nova (vai para o cache).
Waypoints encostados na parede podem reprovar rotas que caberiam se centralizadas.

## D-012 — A rota é suavizada ANTES de ser validada
Data: 2026-09-20
Contexto: a rota crua da engine tem cantos deslocados da linha central (trabalha numa grade
que muda com o raio). Validando a rota crua, o corredor de 3 studs era reprovado embora a
linha reta pelo centro tenha folga de sobra.
Decisão: runLadder prepara a rota (origem no chão + string pulling) e só então valida.
Motivo: o Simplifier já testa o corpo (0.6x) a cada atalho, então endireitar antes de validar
não aceita nada que não caiba.
Consequência: a centralização de waypoints perde urgência para corredores retos.

## D-013 — O JumpExecutor guarda um registro global de saltos Native pendentes
Data: 2026-09-20
Contexto: o modo Native altera JumpHeight/JumpPower e precisa devolver o original em qualquer
cenário (pouso, morte no ar, remoção, salto encadeado).
Decisão: tabela de chaves fracas Humanoid -> {original, conexões}, singleton documentado. O
original é capturado uma vez só; um salto encadeado reaproveita o do registro. Restaura por
Freefall/Landed, Died, Destroying, remoção do pai e timeout de 1s, de forma idempotente.
Motivo: sem estado compartilhado entre chamadas não há como saber o valor original.
Consequência: uma alteração do jogo em JumpHeight dentro do 1s do salto é sobrescrita.

## D-014 — O apex do salto é dimensionado pela profundidade; corredor aéreo depois da balística
Data: 2026-09-20
Contexto: a ESPEC usa o apex mínimo e exige tempo acima do obstáculo para profundidade + 2 x
AgentRadius, o que reprova até uma mureta de 3 studs com 1.5 de profundidade.
Decisão: o Predictor escolhe o menor apex que dá tempo acima do obstáculo para o centro
cruzar profundidade + 2 x raio do corpo + margem (h = g x t² / 8); só devolve too_deep se esse
apex passa do JumpHeight real. O corredor aéreo roda depois da balística e varre a coluna do
corpo com esferas empilhadas, dos pés até a cabeça no apex. O topo é medido no mesmo objeto
que o raio do joelho acertou.
Motivo: sem isso a lib recusaria saltos que o personagem faz com folga.
Consequência: saltos podem ser mais altos que o mínimo; obstáculos de várias partes têm o topo
medido só na parte acertada.

## D-015 — Cancelamento não dispara Failed; só resolve o Await
Data: 2026-09-20
Contexto: cancelled é um código de erro (Stop() ou novo MoveTo), mas Failed é o sinal de falha.
Decisão: Stop() e um MoveTo que substitui outro resolvem o Await com (false, "cancelled") sem
disparar Failed, que fica para falhas reais. Destroy() também cancela o Await pendente.
Motivo: quem ouve Failed não deve ser acionado por um Stop que ele mesmo pediu.
Consequência: SmartPath.MoveTo (nível 0) devolve false, "cancelled" nesses casos.

## D-016 — O passo do Agent roda em PreSimulation, não em Heartbeat
Data: 2026-09-20
Contexto: o ControlModule do jogador chama Move em RenderStepped, antes da física; um Move dado
só no Heartbeat seria sobrescrito antes de ser usado.
Decisão: o passo roda em RunService.PreSimulation (cliente e servidor).
Motivo: o agente passa a mandar num personagem de jogador sem desabilitar o ControlModule.
Consequência: [VALIDAR] no cliente; só o NPC no servidor foi exercitado.

## D-017 — O Path fica no cache, e o solver aceita origem explícita
Data: 2026-09-20
Contexto: Path.Blocked só dispara para quem segura o Path; rota vinda do cache não tinha Path.
E validar um atalho por salto exige calcular a partir do ponto de pouso.
Decisão: o RouteCache guarda o Path junto com a rota. RouteSolver.solve ganhou
startGroundOverride e devolve cacheGoal (chave normalizada, para invalidateGoal).
Motivo: sem isso o Blocked só funcionaria para o primeiro agente a calcular cada rota.
Consequência: o cache mantém Paths vivos até o TTL ou despejo.

## D-018 — Relaxamento de waypoints quando a rota não cabe, e blockedAt no diagnóstico
Data: 2026-09-20
Contexto: numa rota com curvas, os waypoints de canto da engine ficam encostados na parede, e o
Spherecast do corpo reprova segmentos que ligam esses cantos (falso corridor_too_narrow).
Decisão: quando a rota já suavizada não cabe, relaxRoute empurra cada waypoint interior de
andar para longe das paredes próximas (até 1.5 studs do original, exigindo chão parecido) e a
validação roda de novo. Só entra como recurso: rota que já cabia fica idêntica. O erro
corridor_too_narrow ganhou blockedAt, o ponto onde o corpo bate.
Motivo: sem isso, mapas com curvas apertadas devolveriam falso corridor_too_narrow.
Consequência: waypoints podem sair até 1.5 studs do que a engine devolveu; fatores a validar.

## D-019 — O waypoint Jump é o DESTINO do salto, não a decolagem
Data: 2026-09-20
Contexto: a ESPEC supunha que Action = Jump marca a decolagem ([VALIDAR] nº 1). O blockedAt de
um corridor_too_narrow caiu na face de uma mureta: a rota tinha um segmento Walk -> Jump
atravessando o obstáculo. É também o padrão documentado pela Roblox.
Decisão: o segmento que chega a um waypoint Jump é o voo e não é validado como caminhada; o
Agent salta ao chegar ao waypoint anterior, em direção ao Jump, e repete a tentativa a cada
frame se ainda não deu. Segmentos que partem de um Custom também não são validados.
Motivo: com a suposição antiga, toda rota da engine com salto era reprovada e o salto saía
tarde demais.
Consequência: a semântica de Custom continua [VALIDAR].

## D-020 — A validação de volume varre o terreno, não uma reta 3D
Data: 2026-09-20
Contexto: a engine só devolve waypoints nos cantos, então numa rampa dois waypoints
consecutivos ficam ligados por uma reta 3D que passa por dentro da rampa; o blockedAt de um
corridor_too_narrow caiu na superfície da rampa.
Decisão: routeClear divide cada segmento em passos horizontais de 2 studs e projeta cada ponto
intermediário no chão antes de varrer a esfera entre pontos consecutivos.
Motivo: rampas e qualquer desnível gradual eram reprovados como "não cabe".
Consequência: mais raios por validação, pagos só quando a rota é nova; o Simplifier mantém a
varredura em reta, protegida pela checagem de chão contínuo.

## D-021 — Bloqueio de rota é detectado por nós; Path.Blocked fica como reforço
Data: 2026-09-20
Contexto: o Path.Blocked não disparou em 40s para uma parede inserida no meio da rota, e a
malha do PathfindingService só a enxergou depois de mais de 10s.
Decisão: Geometry.PartAdded avisa quando uma parte colidível entra no workspace; cada Agent
marca a rota como suja e, no máximo a cada 0.25s, revalida os segmentos restantes com
RouteSolver.isRouteClear; se não cabe mais, dispara Blocked, para o agente, invalida o cache e
replaneja. Enquanto a malha não inclui o obstáculo, o agente espera e tenta de novo a cada 1.5s
por até 30s, em vez de falhar. Path.Blocked continua ligado como reforço.
Motivo: raycasts enxergam a parte na hora, sem depender da malha.
Consequência: partes que se movem para dentro da rota (sem serem novas) ainda não são detectadas.

## D-022 — Camada de compatibilidade: cálculo só por posições, Status mapeado, Blocked sob demanda
Data: 2026-09-20
Contexto: SmartPath.Service:CreatePath(...):ComputeAsync(start, finish) recebe só Vector3; não há
Humanoid para derivar raio, altura de pulo e velocidade.
Decisão: RouteSolver ganhou solvePositions (sem personagem, exclui dos raycasts os modelos com
Humanoid junto da origem). Raio e altura vêm do CreatePath (defaults 2 e 5); WaypointSpacing,
Costs e AgentCanClimb são ignorados. path.Status descreve o resultado da SmartPath (Success mesmo
quando a engine não acharia; goal_unreachable vira FailFinishNotEmpty, o resto NoPath), com os
códigos em SmartStatus/SmartDetails. path.Blocked só observa o mundo quando alguém conecta, com
referência fraca ao Path, e dispara uma vez por cálculo com o índice do waypoint bloqueado.
Motivo: deixa um script clássico funcionar trocando só a linha do require.
Consequência: sem WaypointSpacing as rotas têm poucos waypoints.

## D-023 — Nível 0 reaproveita um Agent por Humanoid; alvo móvel é seguido por limiar
Data: 2026-09-20
Contexto: MoveTo em laço criaria um Agent por chamada, e um destino BasePart/Model pode se mover.
Decisão: init mantém um Agent por Humanoid (chaves fracas), destruído junto com o Humanoid; duas
chamadas para o mesmo personagem se cancelam. Para alvo BasePart/Model, o Agent confere a posição
a cada 0.25s e refaz a rota (forçada) quando o alvo se afasta mais de 4 studs do destino do último
cálculo.
Motivo: sem o registro MoveTo em laço vaza conexões; sem o limiar, replanejar a cada passo do alvo
custaria ComputeAsync demais.
Consequência: com alvo BasePart/Model o último waypoint conta como alcançado a 3 studs (um alvo
que é outro personagem colide a ~2), e ao chegar o agente refaz a rota se o alvo ainda está além
de 3.5 studs; termina a no máximo 3.5 dele.

## D-024 — Diagnóstico de causa: invisible_collider, obstacle_too_tall e no_landing
Data: 2026-09-20
Contexto: quatro dos 10 códigos não eram emitidos; o Predictor só devolvia o motivo, sem medidas.
Decisão: Predictor.analyze devolve um terceiro valor com as medidas (height/maxJump, drop, at,
atLeast) e aceita probeDistance. Toda falha do RouteSolver passa por fail, que procura a parte
invisível colidível (CanCollide, Transparency >= 0.95, sem NavSolid) no ponto de estrangulamento,
no destino ou na primeira batida do Spherecast do corpo na reta início -> destino; achando, o
código vira invisible_collider (instance, position, underlying). Em stuck o Agent procura à
frente SEM o filtro da lib (o gatilho filtrado que o corpo bate). obstacle_too_tall/no_landing só
saem quando não há rota, nem salto direto, e o Predictor, olhando a reta inteira, explica.
Motivo: são as três causas que o desenvolvedor não vê a olho nu.
Consequência: heurística: só a primeira batida e só o primeiro obstáculo da reta contam. NavSolid
nunca é suspeito.

## D-025 — timeout é um orçamento interno, não uma opção
Data: 2026-09-20
Contexto: o contrato tem timeout {elapsed}, mas as opções (Seção 3.5) são congeladas.
Decisão: falha com timeout quando elapsed > 45 + 4 x (maior rota adotada) / WalkSpeed. Recomeça
quando um alvo móvel se afasta e não conta o tempo suspenso. Constantes em Agent._tuning (testes).
Motivo: rede de segurança para o agente que anda mas nunca chega.
Consequência: [VALIDAR] os valores num jogo real.

## D-026 — Debug em módulo próprio, painel explícito, explain em português
Data: 2026-09-20
Contexto: o plano pede waypoints por ação, decolagem, pouso, obstáculo, raio efetivo e painel.
Decisão: Debug.luau concentra o desenho e o painel; Util.draw* saiu. Nada roda com Debug = false.
Toda parte de debug: Anchored, CanCollide/CanQuery/CanTouch falsos, e a pasta entra em todo
RaycastParams (Geometry.addExclusion). O painel só existe quando showPanel é chamado (no servidor
o pai é obrigatório). SmartPath.explain devolve português e nunca erra. MoveTo e GetRoute passam
a devolver details como terceiro valor.
Motivo: o desenho mostra onde, o explain diz o quê.
Consequência: requiredRadius é o maior raio de agente que CABE (o texto do explain diz assim).

## D-027 — O demo é um projeto Rojo à parte; o baseline é protegido com NavSolid; o gatilho usa grupo de colisão
Data: 2026-09-20
Contexto: a Fase 7 pede 8 cenários com um NPC de PathfindingService puro e um da SmartPath sobre
geometria idêntica.
Decisão: o demo mora em src/demo/ com o seu demo.project.json (os testes de fase compartilham
Scheduler e Geometry com ele e se contaminariam). Toda parte da pista clássica leva a tag NavSolid,
porque a Geometry global põe PassThrough em gatilhos invisíveis e ajudaria o baseline; para o
PathfindingService a tag não significa nada. O DoorTrigger do cenário 5 fica num grupo de colisão
que não colide com Default: a malha o vê como parede, o corpo o atravessa. O cenário 8 roda um lado
de cada vez.
Motivo: sem isso o cenário 5 não separaria os dois lados, ou seria impossível para ambos.
Consequência: [VALIDAR] se a malha da engine respeita grupos de colisão. Os cenários 3 e 4 começam a
~7 studs do obstáculo (o atalho por salto só enxerga até 10 studs).

## D-028 — Personagens nunca são parede
Data: 2026-09-20
Contexto: no cenário 8 do demo (20 NPCs numa pista) a SmartPath teve 95 corridor_too_narrow e 54
invisible_collider: outro NPC contava como obstáculo na validação, e o HumanoidRootPart do R15
(invisível e colidível) era apontado como gatilho esquecido.
Decisão: Geometry guarda os modelos com Humanoid e buildRaycastParams os exclui (registrar um
personagem sobe a versão); isInvisibleCollider ignora partes de personagens; corridor_too_narrow
leva rejectedRoute (a rota reprovada), que o Debug desenha em vermelho.
Motivo: um personagem se move; o anti-stuck já cuida de quem bloqueia de verdade.
Consequência: cada personagem novo invalida o cache de rotas uma vez.

## D-029 — Os raios do relaxamento partem atrás do waypoint
Data: 2026-09-20
Contexto: no cenário 5 do demo a engine devolveu um canto exatamente sobre a face de uma parede; um
raio que começa numa superfície não a acerta, então o resgate (D-018) não empurrava o waypoint e a
rota era reprovada com corridor_too_narrow e requiredRadius = 0.
Decisão: os raios do relaxRoute partem 0.3 stud atrás do waypoint (e ganham 0.3 de alcance).
Motivo: a engine tolera raio 2 e leva a rota até a parede.
Consequência: o deslocamento continua limitado a 1.5 stud; o suavizador não cria cantos novos.

## D-030 — Resgate relaxa os cantos crus antes de suavizar; revalidação a cada 1 s
Data: 2026-09-20
Contexto: (1) no cenário 5 do demo o suavizador ligou um canto sobre a face de uma parede ao
destino do outro lado, atravessando a parede (o Spherecast ignora o que sobrepõe a origem, D-014).
(2) no cenário 7 um bloco criado no alto e solto sobre a rota não disparou Blocked, porque
Geometry.PartAdded só avisa de partes novas.
Decisão: (1) o resgate relaxa os cantos crus da engine e suaviza de novo; se ainda não couber,
relaxa a rota já suavizada, como antes. (2) em Following o Agent revalida a rota a cada 1 s.
Motivo: partes que se movem são o caso normal de obstáculo dinâmico.
Consequência: o bloqueio por parte móvel é detectado em até ~1.25 s; uma validação por segundo por
agente.

## D-031 — Reparo de rota: waypoints de desvio inseridos onde o corpo bate
Data: 2026-09-20
Contexto: no cenário 8 do demo, 19 a 26 trechos em ~130 falhavam com corridor_too_narrow nas quinas
de pilares: a engine devolve a reta origem-destino a ~0.6 stud da quina, com 2 waypoints, sem canto
para o resgate relaxar.
Decisão: repairRoute é a última tentativa do resgate; até 8 vezes, onde o corpo bate insere um
waypoint de desvio no lado livre da superfície (normal da batida) a bodyRadius x 1.25 + 0.3. A
validação de volume continua a última palavra. routeClear devolve também a normal.
Motivo: mesmo caso de D-018, sem waypoint interior para empurrar.
Consequência: o desvio é local, e o suavizador não roda de novo depois; batida em superfície
horizontal interrompe o reparo.

## D-032 — Pouso de salto avança além do waypoint Jump; mobília do cenário 2 alta
Data: 2026-09-20
Contexto: (1) no cenário 3 o NPC pousava além do waypoint Jump (destino do salto, D-019), voltava até
ele e seguia: uma voltinha. (2) no cenário 2 a mobília de 3 studs era pulada por engine e SmartPath,
em vez de usar o corredor e a porta.
Decisão: _selectStartIndex ganhou afterLanding: no pouso, um waypoint Jump já ultrapassado é dado
como alcançado. A mobília do cenário 2 passou a 6-8 studs.
Motivo: o destino do salto é referência, não parada; o demo tem de exercitar o que nomeia.
Consequência: o raio de chegada não mudou; o cenário 2 pode ou não discriminar os lados.
]]
