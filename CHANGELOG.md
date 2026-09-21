# CHANGELOG

Formato: [Keep a Changelog](https://keepachangelog.com/). Versionamento semântico.

## [1.0.0] - 2026-09-21

Primeira versão pública.

### Adicionado
- **Três níveis de API.** Nível 0: `SmartPath.MoveTo`, `MoveToAsync` e `GetRoute` (uma linha, sem
  configuração; raio, altura, velocidade e salto saem do `Humanoid`). Nível 1: `SmartPath.new`, um
  agente persistente com `MoveTo`, `Await`, `Stop`, `SetSuspended`, `GetState`, `GetRoute`,
  `SetOptions`, `Destroy` e os sinais `Reached`, `Failed`, `Blocked`, `Jumped` e `CustomWaypoint`.
  Nível 2: `Predictor`, `Simplifier`, `Geometry`, `Scheduler`, `Errors`, `Debug`.
- **`SmartPath.Service`**: espelha o `PathfindingService` (`CreatePath`, `ComputeAsync`, `Status`,
  `GetWaypoints`, `Blocked`); um script clássico passa a usar a SmartPath trocando uma linha.
- **Raio adaptativo** para ambientes fechados e **validação de toda rota** por `Spherecast` no raio
  físico do corpo (0,6 × o raio do agente). Resgate de rotas que a engine leva coladas na parede:
  relaxamento dos cantos e reparo por waypoints de desvio.
- **Saltos por balística**: o `Predictor` usa o `JumpHeight` real (qualquer valor, não o limite fixo da
  malha); atalho por salto, salto reativo e `JumpExecutor` (`Native` e `Injected`) com restauração à
  prova de falha.
- **Filtro de geometria invisível** (`PathfindingModifier.PassThrough`, tags `NavIgnore` e `NavSolid`,
  `Geometry.audit()`), sem nunca alterar o mapa.
- **Estabilização**: origem aterrada, cache por célula, string pulling seguro, histerese.
- **Agendador central** (`Scheduler`) com orçamento por frame e coalescência de pedidos iguais.
- **Trajetória em curva opcional** (`Stability.Curves`, desligada por padrão, D-035): o agente mira num ponto
  adiante na rota em vez de virar de uma vez em cada canto, só onde o corpo cabe.
- **Diagnóstico**: 10 códigos de erro com `details`, `SmartPath.explain` (frase legível em
  português) e debug visual (waypoints por ação, decolagem, pouso, obstáculo, raio efetivo, rota
  rejeitada, painel opcional). `Debug = false` não cria instância nem imprime.
- **Endurecimento** (D-033): morte e remoção do personagem, `WalkSpeed` 0, sentado, `JumpHeight` 0,
  `UseJumpPower`, R6 e R15, gravidade alterada, destino igual à posição, destino NaN ou distante, sem
  chão sob o agente, dois agentes no mesmo personagem, `MoveTo` dentro de `Reached`.
- **Place de demonstração** com 11 cenários (`PathfindingService` puro à esquerda, SmartPath à
  direita), HUD, relatório e comandos de diagnóstico.
- Documentação: [README](README.md), [API](docs/API.md), [decisões](DECISIONS.md) e
  [backlog](BACKLOG.md). Empacotamento: `wally.toml`, `default.project.json` (só a biblioteca),
  licença MIT.

### Alterado
- `default.project.json` agora monta só a biblioteca (é o que o Wally e o Creator Store empacotam).
  O projeto de desenvolvimento (testes) passou para `dev.project.json`: use
  `rojo serve dev.project.json`.
- Pequenas limpezas de tipos sem mudança de comportamento (`RouteCache`, `Geometry`, `Scheduler`,
  `RouteSolver`).

### Limitações conhecidas
Listadas no [README](README.md#limitações-o-que-a-smartpath-não-faz). As principais: não gera
`PathfindingLink`, não faz evitação entre agentes, só reduz o raio (não a altura), o atalho por
salto só vê obstáculos a até 10 studs, e o uso no cliente (jogador) e com `StreamingEnabled` ainda
não foi validado num jogo real.

---

## Histórico de desenvolvimento (por fase, antes da 1.0.0)

### Added — Fase 0 (fundação e esqueleto)
- Estrutura de módulos da SmartPath em `ReplicatedStorage.SmartPath` (Seção 4 do plano).
- `Types`, `Errors`, `Signal`, `Config`, `Util` implementados.
- `Config.resolve` deriva raio, altura, `WalkSpeed` e `JumpHeight` real (considerando
  `UseJumpPower`) a partir do personagem.
- Demais módulos (`Scheduler`, `Geometry`, `RouteCache`, `Simplifier`, `RouteSolver`,
  `Predictor`, `JumpExecutor`, `Agent`, `Compat`) como stubs tipados.
- Fachada `init` expondo a API da Seção 3: `MoveTo`, `MoveToAsync`, `GetRoute`, `new`,
  `Service`, `Version`, e o nível 2 (`Predictor`, `Simplifier`, `Geometry`, `Scheduler`,
  `Errors`).
- `Version = "0.1.0"`.
- `DECISIONS.md`/`DECISIONS.luau`, `BACKLOG.md`, `CHANGELOG.md`.

### Added — Fase 1 (agendador e filtro de geometria)
- `Scheduler`: fila global com orçamento por frame (default 4, configurável via
  `setBudget`), prioridade numérica (maior = mais urgente, D-007), cancelamento por
  `Handle:cancel()` e coalescência de pedidos idênticos pendentes (`Handle:await()`).
- `Geometry`: classificação por tag `NavSolid` (precedência absoluta) / `NavIgnore` /
  auto-detecção conservadora (Transparency + nome suspeito); `PathfindingModifier` com
  `PassThrough` reversível; `getVersion()`/`Changed`/`buildRaycastParams()`/`audit()`;
  `setAutoFilter()`/`setRequireNameMatch()` desligáveis sem resíduo no mapa (D-006).
- `src/tests`: harness manual (`ServerStorage.SmartPathTests`) para rodar os critérios de
  aceite de cada fase no Command Bar do Studio.
- D-006 e D-007 em `DECISIONS.md`.

### Added — Fase 2 (RouteSolver, RouteCache, Simplifier)
- `RouteSolver.solve`: origem aterrada, destino normalizado, escada de raio adaptativo
  (`RadiusSteps` + degrau de sonda em `MinRadius / 2`), validação de toda rota de raio
  reduzido por `Spherecast` no raio físico do corpo, retry sem salto, destino aproximado, e
  erros diagnósticos `no_path` / `corridor_too_narrow` / `goal_unreachable` /
  `character_lost` com `details`. Todo `ComputeAsync` passa pelo `Scheduler`.
- `RouteCache`: cache por célula com perfil de agente, TTL, versão do `Geometry` e despejo
  FIFO; listas de waypoints congeladas.
- `Simplifier`: deduplicação + string pulling com validação de volume e de chão contínuo;
  nunca remove waypoints com `Action ≠ Walk`.
- `Util.getBodyRadius` (0.6x `Agent.Radius`).
- `SmartPathTests.Phase2()`: 6 cenários com geometria própria (corredor de 4 e de 1 stud,
  determinismo, vão no chão, ações do Simplifier, destino dentro da parede).
- D-008 a D-012 em `DECISIONS.md` (D-011: toda rota é validada, inclusive a de raio cheio;
  D-012: a rota é suavizada antes de ser validada).

### Changed
- O stub de `SmartPath.GetRoute` agora aponta para a Fase 5 (onde a fachada é ligada).

### Added — Fase 3 (Predictor, JumpExecutor)
- `Predictor.analyze`: parede no joelho, alto demais, topo (medido no mesmo objeto), profundidade
  e ponto de pouso, balística com apex dimensionado pela profundidade, corredor aéreo de pés e
  cabeça. Funciona com qualquer `JumpHeight`. Todo retorno negativo traz o motivo (`too_tall`,
  `too_deep`, `no_landing`, `drop_too_high`, `air_blocked`, `ceiling`, ...).
- `JumpExecutor`: modos `Native` (restauração à prova de morte, remoção e salto encadeado) e
  `Injected` (nunca reduz a velocidade horizontal; `injectedVelocity` é função pura).
- `SmartPathTests.Phase3()`: 14 cenários (7 do Predictor, 7 do JumpExecutor).
- D-013 e D-014 em `DECISIONS.md`.

### Added — Fase 4 (Agent)
- `Agent` (`SmartPath.new`): máquina de estados `Idle`/`Following`/`DirectJump`/`Airborne`/
  `Failed`; `MoveTo`, `Await`, `Stop`, `SetSuspended`, `GetState`, `GetRoute`, `SetOptions`,
  `Destroy`; sinais `Reached`, `Failed`, `Blocked`, `Jumped`, `CustomWaypoint`.
- Segue por `Humanoid:Move` (nunca `Humanoid:MoveTo`), com sonda reativa de salto, atalho por
  salto validado a partir do pouso, histerese, `Path.Blocked` com replan, anti-stuck escalonado
  (salto de escape, replan, replan, `stuck`), descarte de cálculo velho quando o destino muda.
- `RouteSolver.solve` aceita origem explícita e devolve `cacheGoal`; o cache guarda o `Path`.
- `Config.overlay` (mescla de duas camadas de overrides, usada por `SetOptions`).
- `SmartPathTests.Phase4()`: 8 cenários com agentes e rigs reais.
- D-015 a D-021 em `DECISIONS.md` (D-019: `Jump` é o destino do salto; D-020: validação segue o
  terreno; D-021: detecção própria de bloqueio).
- `Geometry.PartAdded` e `RouteSolver.isRouteClear`: o agente revalida a rota quando surge uma
  parte nova, sem depender do `Path.Blocked` da engine.

### Added — Fase 5 (fachada e compatibilidade)
- `SmartPath.MoveTo`, `MoveToAsync` e `GetRoute` funcionando, sem tabela de opções obrigatória,
  com `Vector3`, `BasePart` ou `Model` como destino. Um `Agent` por `Humanoid`, reaproveitado.
- Destino `BasePart`/`Model` em movimento é perseguido (replan quando se afasta mais de 4 studs).
- `SmartPath.Service` (compatibilidade): `CreatePath`, `ComputeAsync`, `Status`, `GetWaypoints` e
  `Blocked` espelhando o `PathfindingService`, mais `SmartStatus`/`SmartDetails`. Um script
  clássico passa a usar a SmartPath trocando só a linha do `require`.
- `RouteSolver.solvePositions`, `RouteSolver.isRouteClearAt`; `solveFrom` separa o núcleo que só
  precisa de posições.
- `SmartPathTests.Phase5()`: 8 cenários.
- D-022 e D-023 em `DECISIONS.md`.

### Added — Fase 6 (diagnóstico e debug visual)
- Os 10 códigos de erro são emitidos, com `details`: `obstacle_too_tall {height, maxJump}`,
  `no_landing {drop}`, `invisible_collider {instance}` e `timeout {elapsed}` passam a existir (ver
  D-024 e D-025). `stuck` vira `invisible_collider` quando o corpo bate numa parte invisível que
  a malha não vê.
- `SmartPath.explain(reason, details)`: frase legível para cada código; nunca lança erro.
- `SmartPath.Debug`: waypoints por ação (andar, salto, queda, link), decolagem, pouso, obstáculo,
  disco do raio efetivo, marca do ponto de falha e painel opcional (`showPanel`) com estado, rota,
  raio, tempo do último cálculo, fila do `Scheduler` e último erro. Partes de debug sem colisão,
  sem consulta e fora dos `RaycastParams`; `Debug = false` não cria instância nem imprime.
- `MoveTo` e `GetRoute` devolvem `details` como terceiro valor.
- `Predictor.analyze` devolve um terceiro valor com as medidas da falha e aceita `probeDistance`.
- `Geometry.isInvisibleCollider`, `Geometry.addExclusion`; `Diagnostics.luau`, `Debug.luau`.
- Removidos `Util.drawPoint`, `Util.drawRoute` e `Util.getDebugFolder` (agora em `Debug`).
- `SmartPathTests.Phase6()`: um cenário por código de erro, `explain`, Debug desligado, Debug
  ligado, marca de falha e painel.
- D-024 a D-026 em `DECISIONS.md`.

### Added — Fase 7 (place de demonstração)
- `demo.project.json` e `src/demo/`: 8 cenários, cada um com o NPC de PathfindingService puro à
  esquerda (`Classic.luau`, o exemplo da documentação da Roblox) e o da SmartPath à direita, sobre
  geometria idêntica. Reiniciar refaz as duas pistas do zero.
- HUD (`HUD.client.luau`): FPS do cliente e do servidor, fila do `Scheduler`, botões Reiniciar/Ver
  por cenário, contadores de sucesso e falha de cada lado, "Rodar todos", "Zerar contadores".
- `Runner.runReport()` (atributo `Command` da pasta `SmartPathDemo`): roda os 8 cenários em sequência e imprime o resultado
  dos dois lados. `Runner.checkCleanRestart(id)`: confere que reiniciar não deixa resíduo.
- Cenário 6 verifica explicitamente que a SmartPath respeita o limite `NavSolid` (nenhum
  `PathfindingModifier` na parede, o NPC não a atravessa, motivo de recusa limpo).
- D-027 em `DECISIONS.md`.
- Fase 7, correções na biblioteca achadas pelo demo (D-028): `Geometry` exclui personagens dos
  `RaycastParams`; o corpo de outro NPC deixa de ser `invisible_collider`; `corridor_too_narrow`
  traz `rejectedRoute` e o `Debug` a desenha em vermelho.
- `Runner.diagnose(id)` (comando `diagnose:N`): rotas da engine e da SmartPath de um cenário, sem
  mover ninguém, com sondas de conectividade da malha.
- `relaxRoute` detecta cantos exatamente sobre a face da parede (raios partem 0.3 stud atrás do
  waypoint, D-029); corrige o `corridor_too_narrow` com `requiredRadius = 0` do cenário 5 do demo.
- Resgate de rota relaxa os cantos crus da engine antes de suavizar (D-030): corrige o
  `corridor_too_narrow` do cenário 5 do demo.
- O `Agent` revalida a rota a cada 1 s enquanto segue (D-030): detecta blocos que caem e portas que
  fecham sobre a rota, que não disparam `Geometry.PartAdded`.
- Reparo de rota (D-031): quando nem o relaxamento resolve, `RouteSolver` insere waypoints de desvio
  onde o corpo bate; corrige rotas retas que roçam quinas de pilares (cenário 8 do demo).
  `Phase2` ganhou o teste "quina de pilar".
- Ao pousar de um salto o agente não volta ao waypoint `Jump` que já ultrapassou (D-032). A mobília
  do cenário 2 do demo passou a 6-8 studs (a de 3 era pulada).

### Added — Fase 8 (endurecimento)
- Casos-limite tratados (D-033): personagem removido destrói o agente; WalkSpeed 0, sentado e
  PlatformStand não viram `stuck`; `Jump.Enabled` derivado do Humanoid; destino igual à posição;
  destino NaN; sem chão sob o agente (`no_path` com `noGround`); `SmartPath.new` recusa um segundo
  agente para o mesmo personagem; `RequestStreamAroundAsync` no cliente com StreamingEnabled.
- `SmartPathTests.Phase8()`: um teste por caso da checklist e o de 500 agentes; `Phase8Soak(min)`: 20
  NPCs por N minutos com memória amostrada a cada 30 s.
- Demo: cenários 9 a 11 (caverna com zona invisível colidível cobrindo o interior): entrar, sair e
  mover-se dentro. Rodam pelo HUD ou por `run:9`, `run:10`, `run:11`.
