# CHANGELOG

Formato: [Keep a Changelog](https://keepachangelog.com/). Versionamento semântico.

## [Unreleased]

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
