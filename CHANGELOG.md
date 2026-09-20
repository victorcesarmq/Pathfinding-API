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
