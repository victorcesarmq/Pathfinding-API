# COMPACT01 — Estado do projeto SmartPath (Fases 0 a 5 concluídas)

Resumo de retomada, escrito depois da Fase 5. Fonte da verdade: o código, `DECISIONS.md` (D-001 a
D-023), `BACKLOG.md` e `CHANGELOG.md`. Este arquivo só orienta; se divergir do código, vale o código.

## 1. O projeto

SmartPath: biblioteca open-source de pathfinding para Roblox (Luau) que corrige as falhas do
`PathfindingService` ("pathfinding que conhece o agente de verdade"). Responsável: Victor. Repo:
`C:\Users\victo\Documents\Pathfinding-API` (repositório git próprio, branch `master`; **quem faz commit
é o Victor, nunca eu**). Os documentos-fonte (`SMARTPATH_PLANO_DE_EXECUCAO.md` e
`ESPEC_NAVEGACAO_ROBLOX.md`) foram colados na conversa e **não estão no repositório**; o Victor foi
orientado a copiá-los para `docs/`. Se existirem lá, releia antes de cada fase.

Método de trabalho do plano: implementar uma fase por vez, rodar os critérios de aceite, entregar
relatório (feito / parcial / suposições / itens novos no `BACKLOG.md`), decisões não triviais viram
entrada em `DECISIONS.md` (e no espelho `src/SmartPath/DECISIONS.luau`). Regras permanentes: zero
configuração obrigatória; sem estado global fora dos singletons documentados (`Scheduler`, `Geometry`,
cache do `RouteSolver`, registro do `JumpExecutor`, registro de agentes do nível 0); `Destroy` limpa
100% das conexões; nunca alterar propriedades do mapa (só criar/remover `PathfindingModifier`); nunca
`Humanoid:MoveTo` (só `Move`); `pcall` em chamadas de engine; sem `print` fora de `Options.Debug`.

## 2. Estado: fases prontas e testadas no Studio

| Fase | Entrega | Teste (Command Bar) |
|---|---|---|
| 0 | esqueleto, `Types`, `Errors`, `Signal`, `Config`, `Util` | (só `rojo build`) |
| 1 | `Scheduler` (orçamento 4/frame, prioridade maior = mais urgente, cancelamento, coalescência), `Geometry` (tags `NavSolid`/`NavIgnore`, auto-detecção, `PathfindingModifier`, `audit`) | `Phase1()` 8/8 |
| 2 | `RouteSolver` (escada de raio + validação por Spherecast), `RouteCache`, `Simplifier` | `Phase2()` 9/9 |
| 3 | `Predictor` (balística), `JumpExecutor` (Native/Injected, restauração à prova de falha) | `Phase3()` 14/14 |
| 4 | `Agent` (máquina de estados, anti-stuck, bloqueio, destino trocado, suspender, Destroy) | `Phase4()` 8/8 |
| 5 | fachada nível 0 (`MoveTo`/`MoveToAsync`/`GetRoute`), `SmartPath.Service` (compatibilidade), alvo móvel | `Phase5()` 8/8 |

Todos os testes: `require(game.ServerStorage.SmartPathTests).PhaseN()` com N de 1 a 5. **Nada disto foi
validado num jogador real no cliente** (ver seção 6).

## 3. Arquitetura (arquivos em `src/SmartPath/`, montado em `ReplicatedStorage.SmartPath` pelo Rojo)

- `init.luau` fachada: `Version = "0.1.0"`, `new`, `MoveTo`, `MoveToAsync`, `GetRoute`, `Service`, e o
  nível 2 (`Predictor`, `Simplifier`, `Geometry`, `Scheduler`, `Errors`). Nível 0 reaproveita um `Agent`
  por `Humanoid` (chaves fracas; destruído com o Humanoid).
- `Agent.luau` nível 1. Estados `Idle`/`Following`/`DirectJump`/`Airborne`/`Failed`. Passo em
  `RunService.PreSimulation`. Sessão de `Await` com threads (sem BindableEvent).
- `RouteSolver.luau` núcleo `solveFrom` (só posições) + `solve` (com personagem) + `solvePositions` (sem
  personagem, para a compatibilidade) + `isRouteClear`/`isRouteClearAt` (revalidação de rota).
- `Compat.luau` `SmartPath.Service:CreatePath(...)`, `ComputeAsync`, `Status`, `GetWaypoints`,
  `Blocked`, mais `SmartStatus`/`SmartDetails`.
- `Predictor.luau`, `JumpExecutor.luau`, `Simplifier.luau`, `RouteCache.luau`, `Geometry.luau` (com
  `PartAdded`), `Scheduler.luau`, `Config.luau` (`resolve`, `merge`, `overlay`), `Util.luau`,
  `Signal.luau`, `Errors.luau`, `Types.luau`, `DECISIONS.luau`.
- Testes: `src/tests/init.luau` montado em `ServerStorage.SmartPathTests` (não faz parte da lib).
- `default.project.json` (Rojo); sobra do template: `src/shared/Hello.luau`, `src/server`, `src/client`.
- Rojo: `rojo serve` já roda (a extensão do VSCode inicia) e o Studio está conectado pelo plugin.

## 4. Contrato de API congelado (Seção 3 do plano)

- Nível 0: `ok, reason = SmartPath.MoveTo(humanoid, target, options?)` (bloqueante);
  `agent = SmartPath.MoveToAsync(...)`; `waypoints, reason = SmartPath.GetRoute(...)`. `target` =
  `Vector3 | BasePart | Model`.
- Nível 1: `SmartPath.new(characterOrHumanoid, options?)` com `:MoveTo`, `:Await()` (retorna
  `ok, reason, details`), `:Stop`, `:SetSuspended`, `:GetState`, `:GetRoute`, `:SetOptions`, `:Destroy`;
  sinais `Reached`, `Failed(reason, details)`, `Blocked`, `Jumped(plan)`, `CustomWaypoint(label, wp, next)`.
- Opções (todas opcionais, `nil` = derivar do personagem): `Indoor {AdaptiveRadius, MinRadius,
  RadiusSteps}`, `Jump {Enabled, Mode "Native"|"Injected", MaxHeight, DetourRatio}`, `Stability {Cache,
  Smoothing, Hysteresis}`, `Geometry {AutoFilter, RequireNameMatch}`, `Agent {Radius, Height,
  WalkSpeed}`, `Scheduler {Priority}`, `Debug` (boolean).
- `Waypoint`: `Position`, `Action`, `Label`, `SmartAction ("Walk"|"Jump"|"Drop"|"Link")?`, `JumpHeight?`.
- Códigos de erro (fixos) e `details`: `no_path {triedRadii}`; `corridor_too_narrow {requiredRadius,
  agentRadius}` (+ `bodyRadius`, `blockedAt`, `triedRadii`); `obstacle_too_tall {height, maxJump}`;
  `no_landing {drop}`; `goal_unreachable {nearestValid}`; `invisible_collider {instance}`; `stuck
  {position, strikes}`; `cancelled {}`; `character_lost {}`; `timeout {elapsed}`.
  **Emitidos hoje:** `no_path`, `corridor_too_narrow`, `goal_unreachable`, `stuck`, `cancelled`,
  `character_lost`. **Ainda não emitidos:** `obstacle_too_tall`, `no_landing`, `invisible_collider`,
  `timeout` (o `Predictor` já devolve `too_tall`, `no_landing`, `drop_too_high` como motivos internos).

## 5. Fatos medidos no Studio (mudaram o projeto; não são óbvios)

- O `AgentRadius` da engine é tolerante: com raio 2 ela atravessa corredores de 4, 3 e até 2 studs; só
  dá `NoPath` em 1 stud (em todos os raios). Por isso toda rota é validada por Spherecast no corpo
  (0,6x o raio, D-009/D-011); a rota é suavizada antes de validar (D-012); a validação segue o terreno
  (D-020, a engine só devolve waypoints nos cantos).
- Waypoint `Action = Jump` é o **destino** do salto (D-019); o `Agent` salta ao chegar ao waypoint anterior.
- `Path.Blocked` não dispara para partes inseridas em runtime e a malha demora mais de 10 s para
  enxergá-las: a lib detecta bloqueio por conta própria (`Geometry.PartAdded` + `isRouteClear`, D-021) e,
  sem rota, espera e tenta de novo por até 30 s.
- Humanoid guarda `JumpHeight` em float32 (7.2 vira 7.19999981): compare com o valor lido de volta.
- `Spherecast` ignora o que já sobrepõe a origem: o `Predictor` também checa sobreposição (D-014).
- Apex do salto dimensionado pela profundidade (D-014); alvo móvel: para a 3 studs, retoma se além de 3,5.
- O rig de teste (root 2x2x1 + Humanoid R15, sem membros) anda, salta e sobe rampa; o teste `Phase4` usa
  `WalkSpeed` 16 (10 no cenário de `Blocked`).

## 6. Pendências e riscos abertos

- **Não validado:** agente controlando o personagem de um jogador no cliente (`PreSimulation`, D-016) e
  perseguição de personagem com corpos colidindo; só NPC no servidor foi exercitado.
- `[VALIDAR]` no rig real do jogo: `AirClearance`, `ApexExtra`, `TakeoffMargin`, `MinObstacleHeight`
  (Predictor); fatores do relaxamento de waypoints (D-018); semântica de `Custom` (links).
- `BACKLOG.md`: aging de prioridade no `Scheduler`; outros personagens contam como obstáculo na
  validação; partes que se MOVEM para dentro da rota não disparam `Blocked`; cache sem invalidação por
  geometria arbitrária; falhas de rota não são cacheadas; centralização de waypoints (parcialmente feita).
- `SmartPath.Version` ainda é `"0.1.0"` (a 1.0.0 é da Fase 9).
- Compat: `WaypointSpacing`, `Costs` e `AgentCanClimb` são ignorados; `Status` antes do cálculo é `NoPath`.

## 7. Próximas fases (resumo do plano; releia o original se estiver em `docs/`)

**Fase 6 — Diagnóstico e debug visual.** Garantir os 10 códigos de erro com `details` úteis; `SmartPath.explain(reason, details)`
devolvendo frase legível (ex.: "O corredor exige raio 0.8, mas o agente tem 2.0. Reduza AgentRadius ou
alargue a passagem."); visualização (waypoints por ação, decolagem, pouso, obstáculo detectado, raio
efetivo); painel opcional (`ScreenGui`) com estado do agente, fila do `Scheduler`, tempo do último
cálculo. `Debug = false`: zero instâncias, zero prints, custo nulo; com `Debug = true` toda parte de
debug com `CanCollide = false`, `CanQuery = false` e excluída dos `RaycastParams`. Critérios: um cenário
reproduzível por código de erro (listar o nome de cada um); `explain` legível. Já existe: `Util.drawPoint`,
`Util.drawRoute`, desenho de rota e de pontos do atalho por salto no `Agent` sob `Options.Debug`.
**Fase 7 — Place de demonstração.** 8 cenários, à esquerda `PathfindingService` puro e à direita SmartPath
(mesma geometria, dois NPCs): corredor de 4 studs; sala com porta estreita e mobília; mureta de 3 com desvio de
30; plataforma de 18 com `JumpHeight` 25; labirinto com trigger invisível colidível; parede invisível com tag
`NavSolid` (a SmartPath tem de respeitar); obstáculo dinâmico caindo; 20 NPCs simultâneos. Botões de
reiniciar, contador sucesso/falha, HUD de FPS e fila do Scheduler.
**Fase 8 — Endurecimento.** Casos-limite: morrer na rota/no ar, personagem removido, `WalkSpeed = 0`,
`JumpHeight = 0`, `UseJumpPower = true`, R6 e R15, destino igual à posição, destino a 5000 studs, sem chão
(queda infinita), `workspace.Gravity` alterado, dois agentes no mesmo personagem, `MoveTo` dentro de
`Reached`, `StreamingEnabled`, personagem sentado/em veículo; teste de vazamento (500 agentes; 20 NPCs por
10 min) com memória estável.
**Fase 9 — Documentação e publicação.** README (problema em 3 linhas, antes/depois, instalação, exemplo de 3
linhas, tabelas de opções e erros, limitações honestas), API completa, CHANGELOG 1.0.0, `wally.toml`, Rojo,
rascunho de post no DevForum. Teste: alguém novo instala e move um NPC em menos de 5 min. **Fase 10:** gerador
de `PathfindingLink` (v2), não implementar na v1.

## 8. Fluxo de teste e armadilhas do ambiente

- **Rodar testes:** Stop → **Run (F8)** → conferir que o log mostra `Server - SmartPathTests` (se mostrar
  `Edit`, o módulo está em cache e o código antigo roda) → colar `require(game.ServerStorage.SmartPathTests).PhaseN()`
  na Command Bar. Sempre pedir o Output completo. Novo módulo = novo teste no harness, geometria própria em
  `x = 2000` (`TEST_ORIGIN`), limpeza no fim (`safe`).
- **Rojo:** valido a árvore com `rojo build -o <scratchpad>\x.rbxlx`; isso NÃO valida sintaxe Luau.
- **Diagnósticos do editor (hook após cada Write/Edit):** há DOIS analisadores. Um trata Lua puro e gera falsos
  positivos em toda sintaxe Luau (`export type`, `?`, `+=`, `if ... then ... else` como expressão): ignorar. O real
  imprime mensagens com prefixo (`TypeError:`, `SyntaxError:`, `LocalUnused:`, `SameLineStatement:`...). Quando a saída for
  grande e for para um arquivo, filtrar com Grep `"message": "[A-Z][A-Za-z]+:` no arquivo persistido. Erros reais
  intermediários (constante usada antes de definida) somem no último edit de uma sequência.
- **Checagem de tipos real, fora do editor (descoberta na Fase 6):** a extensão luau-lsp do VSCode traz
  um binário com `analyze`. Gerar o sourcemap com `rojo sourcemap default.project.json -o <arquivo>` e rodar
  `~/.vscode/extensions/johnnymorganz.luau-lsp-*/bin/server.exe analyze --sourcemap <arquivo> --definitions
  "C:/Users/victo/AppData/Roaming/Code/User/globalStorage/johnnymorganz.luau-lsp/globalTypes.PluginSecurity.d.luau"
  --formatter plain src/SmartPath src/tests`. Saída repetida: filtrar com `sort -u`. Avisos que já existiam
  antes da Fase 6 e não são bug: `Geometry` 159 e 297 (casts), `RouteCache` 58-60, `RouteSolver` "Cannot call a
  value of the union type" (`rc:get`/`rc:put`), `Scheduler` LocalShadow, testes linha ~1442.
- **Formatador automático (stylua) reescreve os arquivos:** reler o trecho antes de cada `Edit`; `old_string`
  com a indentação/quebras erradas falha.
- Nunca commitar sem pedido; Victor já commitou até a Fase 4 (e a 5 depois de aprovada).

## 9. Preferências do Victor

Português, respostas curtas e diretas; explicar o porquê, não só o passo; sem tom de IA em documentos
(pouco negrito, sem narrar edição); relatório de fase com "o que foi feito / o que ficou parcial / suposições /
BACKLOG"; se um teste falha, investigar a causa com dado antes de mudar o código; nada de ofertas de
implementação não pedidas em análises. Fases seguem só depois da aprovação dele ("pode começar").

## 10. Como retomar

1. Ler este arquivo, `DECISIONS.md` (D-015 a D-023 são as mais recentes), `BACKLOG.md` e `CHANGELOG.md`.
2. Se `docs/SMARTPATH_PLANO_DE_EXECUCAO.md` existir, ler a Fase 6 e a Seção 3.
3. Confirmar o estado com `git status`/`git log` (o Victor pode ter commitado) e um `rojo build`.
4. Pedir a "pode começar" da Fase 6 se ainda não veio e implementá-la só com o escopo dela.
