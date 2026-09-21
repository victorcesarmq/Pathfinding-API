# API da SmartPath 1.0

Referência de tudo o que é público. Os exemplos assumem:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SmartPath = require(ReplicatedStorage.SmartPath)
```

Índice: [Tipos](#tipos) · [Nível 0](#nível-0--uma-linha) · [Nível 1](#nível-1--agente-persistente) · [Diagnóstico](#diagnóstico) · [Compatibilidade](#compatibilidade-com-o-pathfindingservice) · [Nível 2](#nível-2--peças-soltas) · [Debug](#debug)

Convenções: `?` depois de um tipo significa opcional. "Bloqueia" significa que a função dá `yield` até terminar. Onde a documentação diz "lança erro", é um erro de programação (argumento inválido), não uma falha de navegação; as falhas de navegação são sempre devolvidas como código (veja [Códigos de erro](#códigos-de-erro)).

---

## Tipos

### `Waypoint`

```lua
type Waypoint = {
    Position: Vector3,
    Action: Enum.PathWaypointAction,  -- Walk, Jump ou Custom
    Label: string,
    SmartAction: "Walk" | "Jump" | "Drop" | "Link"?,
    JumpHeight: number?,
}
```

Um waypoint com `Action = Jump` é o **destino** do salto: o agente salta ao chegar ao waypoint anterior e cai perto deste. Waypoints são tabelas congeladas (`table.freeze`).

### `Options`

Todos os campos são opcionais. `nil` significa "derive do personagem ou use o default"; nenhum campo é obrigatório.

| Campo | Default | O que faz |
|---|---|---|
| `Indoor.AdaptiveRadius` | `true` | Se a rota com o raio cheio não serve, tenta raios menores. |
| `Indoor.MinRadius` | `0.5` | Menor raio da escada. Um degrau de sonda com metade disto também é tentado. |
| `Indoor.RadiusSteps` | `{1.5, 1.0, 0.5}` | Raios intermediários, do maior para o menor. |
| `Jump.Enabled` | `true` (`false` se o Humanoid não salta) | Liga saltos: rotas com salto, atalho por salto e salto reativo. Se o Humanoid tem `JumpHeight`/`JumpPower` ~0 e você não definiu, vira `false`. |
| `Jump.Mode` | `"Native"` | `"Native"` ajusta o `JumpHeight` por um instante e restaura exatamente. `"Injected"` aplica velocidade, sem tocar no `JumpHeight`. |
| `Jump.MaxHeight` | derivado | Altura máxima de salto. Derivada de `JumpHeight`, ou de `JumpPower²/(2·gravidade)`. |
| `Jump.DetourRatio` | `1.4` | Só procura atalho por salto se a rota for pelo menos 1,4x mais longa que a reta. |
| `Stability.Cache` | `true` | Cache de rotas por célula de 2 studs (TTL de 15 s, 128 entradas). |
| `Stability.Smoothing` | `true` | Suaviza a rota (string pulling com verificação de volume e de chão). |
| `Stability.Hysteresis` | `0.15` | Uma rota nova só troca a atual se for 15% mais curta (evita zigue-zague). |
| `Stability.Curves` | `false` | Trajetória em curva: em vez de virar de uma vez em cada canto, o agente mira num ponto adiante **na própria rota** (0,3 s de caminhada, entre 3 e 8 studs). Só arredonda o canto se o corpo couber; saltos, links e o destino continuam exatos. A rota (`GetRoute`, `Debug`) não muda: é só como o agente a segue. |
| `Geometry.AutoFilter` | `true` | Filtra sozinha partes invisíveis e colidíveis com nome de gatilho. **Global ao ambiente**, não por agente. |
| `Geometry.RequireNameMatch` | `true` | O filtro automático exige o nome sugerir gatilho. **Global.** |
| `Agent.Radius` | derivado | Metade da maior dimensão horizontal do bounding box do personagem. |
| `Agent.Height` | derivado | Altura do bounding box. |
| `Agent.WalkSpeed` | derivado | `Humanoid.WalkSpeed` (usado na predição de salto). |
| `Scheduler.Priority` | `0` | Prioridade dos cálculos deste agente: **maior é mais urgente**. |
| `Debug` | `false` | Desenha rota, raio efetivo, saltos e falhas; imprime `[SmartPath]`. Com `false` não cria instância nem imprime. |

Exemplo:

```lua
local options = {
    Indoor = { MinRadius = 0.8 },
    Jump = { Mode = "Injected" },
    Debug = true,
}
```

### Outros tipos

- `CharacterLike = Model | Humanoid | BasePart` — onde a API pede um personagem. Um `BasePart` é resolvido para o modelo que o contém.
- `TargetLike = Vector3 | BasePart | Model` — onde a API pede um destino. `BasePart` e `Model` são **seguidos** se se mexerem (veja `MoveTo`).
- `AgentState = "Idle" | "Following" | "DirectJump" | "Airborne" | "Failed"`.

---

## Nível 0 — uma linha

### `SmartPath.MoveTo(humanoid, target, options?)`

Move o personagem até o destino e só retorna quando termina. **Bloqueia.**

**Parâmetros**
- `humanoid: CharacterLike` — o personagem.
- `target: TargetLike` — o destino. Um `BasePart` ou `Model` que se mexe é perseguido: a rota é refeita quando ele se afasta mais de 4 studs do destino do último cálculo, e o agente para a 3 studs dele.
- `options: Options?` — veja [Options](#options).

**Retorno** `(ok: boolean, reason: string?, details: table?)`
- `true` ao chegar.
- `false, reason, details` numa falha. `reason` é um [código de erro](#códigos-de-erro).

**Lança erro** se o personagem não tem `Humanoid`, ou se o destino não é `Vector3`, `BasePart` ou `Model`. Um destino `NaN` ou infinito não lança: devolve `goal_unreachable`.

**Comportamento**
- Há **um agente por Humanoid**, reaproveitado entre chamadas (inclusive um criado com `SmartPath.new`). Duas chamadas para o mesmo personagem se cancelam: a antiga devolve `false, "cancelled"`.
- Destino a menos de 1,25 stud (no plano) da posição atual: chega na hora, sem calcular rota.
- Em NPC no servidor, o agente tira o dono de rede do `HumanoidRootPart` (`SetNetworkOwner(nil)`) para a física ficar no servidor.

```lua
local ok, reason, details = SmartPath.MoveTo(npc.Humanoid, Vector3.new(80, 0, 30))
if not ok then
    warn(SmartPath.explain(reason, details))
end
```

### `SmartPath.MoveToAsync(humanoid, target, options?)`

Como `MoveTo`, mas **não bloqueia**: devolve o [agente](#nível-1--agente-persistente) já em movimento. Use `:Await()`, os sinais, ou `:Destroy()`.

**Retorno** `Agent`

```lua
local agent = SmartPath.MoveToAsync(npc.Humanoid, workspace.Base)
agent.Reached:Connect(function()
    print("chegou")
end)
```

### `SmartPath.GetRoute(humanoid, target, options?)`

Só **calcula**, não move. Bloqueia. A origem é derivada do personagem (posição aterrada), por isso a função recebe o personagem, e não um `Vector3` de partida.

**Retorno** `(waypoints: {Waypoint}?, reason: string?, details: table?)`
- `waypoints` quando há rota; `nil, reason, details` quando não.

```lua
local waypoints, reason, details = SmartPath.GetRoute(npc.Humanoid, goalPosition)
if waypoints then
    for _, wp in ipairs(waypoints) do
        print(wp.Position, wp.SmartAction)
    end
end
```

---

## Nível 1 — agente persistente

### `SmartPath.new(characterOrHumanoid, options?)`

Cria um agente para o personagem. **Pode dar `yield`** por até 5 s se o personagem ainda estiver carregando (espera pelo `Humanoid` e pelo `HumanoidRootPart`).

**Retorno** `Agent`

**Lança erro** se o personagem não tem `Humanoid`/`HumanoidRootPart`, ou se **já existe um agente vivo** para o mesmo `Humanoid` (dois agentes brigariam pelo `Humanoid:Move`). Chame `:Destroy()` no anterior, ou use `SmartPath.MoveTo`, que reaproveita o existente.

```lua
local agent = SmartPath.new(npc, { Agent = { Radius = 1.5 } })
```

### Métodos do agente

#### `agent:MoveTo(target)`

Começa a mover, **sem bloquear**. Um `MoveTo` novo cancela o anterior (o `Await` do anterior devolve `false, "cancelled"`).

- `target: TargetLike`
- **Lança erro** num agente destruído ou com destino de tipo inválido.

#### `agent:Await()`

**Bloqueia** até o `MoveTo` atual chegar ou falhar. Devolve `(ok: boolean, reason: string?, details: table?)`. Sem `MoveTo` anterior, devolve `false, "cancelled", {}`. Se já terminou, devolve o resultado guardado.

```lua
agent:MoveTo(goal)
local ok, reason, details = agent:Await()
```

#### `agent:Stop()`

Para o agente e encerra a sessão com `cancelled`. Não dispara `Failed`.

#### `agent:SetSuspended(suspended: boolean)`

Pausa sem perder a rota (cutscene, dash, stun). Ao retomar, continua do waypoint certo. O tempo suspenso não conta para os limites de tempo.

#### `agent:GetState()`

Devolve `AgentState`:

| Estado | Significado |
|---|---|
| `Idle` | Sem destino. |
| `Following` | Seguindo os waypoints. |
| `DirectJump` | Correndo até o ponto de decolagem de um atalho por salto. |
| `Airborne` | No ar, guiando o movimento até o pouso. |
| `Failed` | Falhou; veja o sinal `Failed`. |

#### `agent:GetRoute()`

Devolve `{Waypoint}?`: a rota atual, ou `nil` se não há.

#### `agent:SetOptions(partialOptions)`

Mescla um subconjunto de opções. O resto continua como estava (e `nil` continua significando "derive do personagem"). A rota atual **não** é refeita.

#### `agent:Destroy()`

Para o agente, desconecta 100% das conexões (`PreSimulation`, `Died`, `AncestryChanged`, `Geometry.PartAdded` e os sinais públicos) e encerra a sessão. É idempotente. Se o personagem sair do jogo (`Destroy`, pai `nil`), o agente falha com `character_lost` e se destrói sozinho 0,5 s depois.

### Sinais

| Sinal | Parâmetros | Quando dispara |
|---|---|---|
| `Reached` | — | Chegou ao destino. |
| `Failed` | `reason: string, details: table` | Falhou (veja os [códigos](#códigos-de-erro)). |
| `Blocked` | — | Uma parte bloqueou a rota atual; o agente para e refaz a rota. |
| `Jumped` | `plan: table` | Iniciou um salto. `plan` é o plano do `Predictor` (`direction`, `landingPoint`, `jumpHeight`, `wallPoint`...) ou, para saltos pedidos pela malha, um plano com `synthetic = true`. |
| `CustomWaypoint` | `label: string, waypoint, nextWaypoint` | O agente chegou a um waypoint `Custom` (um `PathfindingLink` seu). Links com `Label = "JumpLink"` são tratados como salto e não disparam este sinal. |

É seguro chamar `agent:MoveTo(...)` dentro dos handlers de `Reached` e `Failed`.

```lua
local agent = SmartPath.new(npc)
agent.Reached:Connect(function()
    agent:MoveTo(nextPatrolPoint())
end)
agent.Failed:Connect(function(reason, details)
    warn(SmartPath.explain(reason, details))
end)
agent:MoveTo(firstPatrolPoint)
```

### Comportamentos automáticos

- **Anti-stuck.** Sem progresso por 1 s: 1ª vez, um salto de escape; 2ª e 3ª, replanejar; a 4ª falha com `stuck`. **Não conta como travado** um corpo que não anda de propósito: `WalkSpeed` 0, `Humanoid.Sit` ou `PlatformStand`. Nesses casos o agente espera.
- **Tempo máximo.** `timeout` quando passam `45 s + 4 × (comprimento da maior rota) / WalkSpeed` sem chegar. O orçamento recomeça a cada vez que um alvo móvel se afasta.
- **Bloqueio.** A cada 1 s (e a cada parte nova no mundo) o agente revalida a rota que falta. Se foi bloqueada, dispara `Blocked` e replaneja; se não há rota, espera e tenta de novo por até 30 s (a malha da engine demora para enxergar um obstáculo novo).
- **Jogador no cliente.** O passo roda em `RunService.PreSimulation` e usa só `Humanoid:Move` (nunca `Humanoid:MoveTo`). Em cliente com `StreamingEnabled`, pede `Player:RequestStreamAroundAsync` antes de calcular rotas a mais de 100 studs.

---

## Diagnóstico

### `SmartPath.explain(reason, details?)`

Transforma um código de erro e seus `details` numa frase legível (em português). **Sempre devolve uma string**: `details` ausente, incompleto ou de tipo errado, ou um código desconhecido, viram uma frase, nunca um erro.

**Parâmetros** `reason: string?`, `details: table?`
**Retorno** `string`

```lua
local ok, reason, details = SmartPath.MoveTo(npc.Humanoid, goal)
if not ok then
    print(SmartPath.explain(reason, details))
    -- "O corredor só comporta um agente de raio até 0.8, mas o agente tem 2.0.
    --  Reduza Agent.Radius ou alargue a passagem."
end
```

### Códigos de erro

`SmartPath.Errors` traz as constantes (`Errors.NoPath == "no_path"`), `Errors.All` (lista) e `Errors.isValid(code)`. Os códigos são fixos.

| Código | Significa | `details` | O que fazer |
|---|---|---|---|
| `no_path` | Sem rota mesmo depois de todas as tentativas. | `triedRadii`; `noGround = true` se o agente está no ar sem chão | Confira se há chão contínuo entre os pontos e se algo fechado isola o destino. |
| `corridor_too_narrow` | A engine achou rota, mas o corpo não cabe. | `requiredRadius` (o maior raio de agente que CABERIA), `agentRadius`, `bodyRadius`, `blockedAt`, `triedRadii`, `rejectedRoute` | Reduza `Agent.Radius` ou alargue a passagem. |
| `obstacle_too_tall` | Obstáculo acima do que o agente salta. | `height`, `maxJump`, `atLeast?`, `blockedAt`, `triedRadii` | Aumente o `JumpHeight`, reduza o obstáculo ou abra um desvio. |
| `no_landing` | O salto seria possível, mas não há pouso seguro. | `drop`, `atLeast?`, `blockedAt`, `triedRadii` | Coloque chão depois do obstáculo ou abra outra passagem. |
| `goal_unreachable` | O destino está fora da malha (dentro de parede, no ar, NaN). | `nearestValid`, `requestedGoal` | Use `nearestValid`, ou mude o destino. |
| `invisible_collider` | A rota (ou o corpo) foi barrada por uma parte invisível e colidível. | `instance`, `position`, `underlying?`, `strikes?` | Dê à parte a tag `NavIgnore` (ou um nome de gatilho), `NavSolid` se é limite de mapa, ou `CanCollide = false`. |
| `stuck` | O agente travou depois de 4 tentativas. | `position`, `strikes` | Algo que a malha não vê está no caminho (parte com `NavIgnore`, modelo sem colisão correta). |
| `cancelled` | `Stop()`, novo `MoveTo` ou `Destroy()`. | `{}` | — |
| `character_lost` | O personagem morreu ou foi removido. | `{}` | — |
| `timeout` | Passou do tempo máximo. | `elapsed` | O agente pode estar preso repetindo a tentativa, ou o alvo se afastando. |

`atLeast = true` significa que o valor é um mínimo (o raio só prova que há algo ali). Os `details` de `invisible_collider` levam `underlying` (o código original: `no_path`, `corridor_too_narrow`, `stuck`) quando a causa foi descoberta depois.

---

## Compatibilidade com o PathfindingService

### `SmartPath.Service`

Espelha a API oficial para migrar um script trocando **uma linha**:

```lua
-- antes
local PathfindingService = game:GetService("PathfindingService")
-- depois
local PathfindingService = require(ReplicatedStorage.SmartPath).Service
```

#### `Service:CreatePath(params?)` → `Path`

`params` aceita `AgentRadius` (padrão 2), `AgentHeight` (padrão 5) e `AgentCanJump` (padrão `true`). `WaypointSpacing`, `Costs` e `AgentCanClimb` são **ignorados**. Como aqui só há coordenadas (nenhum personagem), o raio e a altura vêm do `CreatePath` e não do Humanoid.

#### `path:ComputeAsync(start: Vector3, finish: Vector3)`

Bloqueia e calcula. **Lança erro** se algum dos dois não for `Vector3`.

#### `path:GetWaypoints()` → `{Waypoint}`

Uma cópia a cada chamada. As rotas têm poucos waypoints (só onde a direção muda ou há salto).

#### `path.Status` → `Enum.PathStatus`

`Success` quando há rota (mesmo que a engine sozinha não achasse); `FailFinishNotEmpty` para `goal_unreachable`; `NoPath` nos outros casos e antes do primeiro cálculo.

#### `path.SmartStatus` e `path.SmartDetails`

Extras não oficiais: o código de erro da SmartPath (ou `nil` em sucesso) e seus `details`.

#### `path.Blocked`

Objeto com `Connect`, `Once` e `Wait`. Dispara uma vez por cálculo, com o índice do waypoint em que termina o segmento bloqueado, quando uma parte nova cai sobre a rota. Só passa a observar o mundo quando alguém se conecta.

```lua
local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentCanJump = true })
path:ComputeAsync(startPosition, goalPosition)
if path.Status == Enum.PathStatus.Success then
    for _, waypoint in ipairs(path:GetWaypoints()) do
        humanoid:MoveTo(waypoint.Position)
        humanoid.MoveToFinished:Wait()
    end
else
    warn(path.SmartStatus)
end
```

---

## Nível 2 — peças soltas

Tudo aqui também é usado internamente; expor as peças é para quem quer só uma parte da biblioteca.

### `SmartPath.Geometry` — filtro de geometria invisível

A engine trata como parede toda parte com `CanCollide = true`, invisível ou não. O `Geometry` põe um `PathfindingModifier` com `PassThrough` nas partes que devem ser atravessadas, e devolve `RaycastParams` que as ignoram. Ele **nunca altera** `CanCollide`, `Transparency` ou `Anchored` do seu mapa.

Precedência: tag `NavSolid` (sempre sólido, vence tudo) > tag `NavIgnore` (sempre atravessável) > `CanCollide = false` (a engine já ignora) > filtro automático (`Transparency ≥ 0.95` **e**, se `RequireNameMatch`, nome contendo `zone`, `trigger`, `hitbox`, `region`, `bounds`, `sensor`, `detector` ou `area`). As tags valem também no ancestral (marque o modelo).

| Função | Descrição |
|---|---|
| `Geometry.start()` | Liga o filtro e classifica o workspace. É chamado sozinho pelo primeiro cálculo. Idempotente. |
| `Geometry.stop()` | Desliga e remove 100% do que criou (os modifiers). |
| `Geometry.isRunning(): boolean` | Se está ligado. |
| `Geometry.setAutoFilter(enabled)` / `getAutoFilter()` | Liga/desliga o filtro automático (as tags continuam valendo). Global ao ambiente. |
| `Geometry.setRequireNameMatch(enabled)` / `getRequireNameMatch()` | Exigir nome de gatilho no filtro automático. Global. |
| `Geometry.getVersion(): number` | Sobe a cada mudança de classificação (invalida o cache de rotas). |
| `Geometry.getIgnoredCount(): number` | Quantas partes estão classificadas como atravessáveis. |
| `Geometry.Changed` | Evento; dispara com a nova versão. |
| `Geometry.PartAdded` | Evento; dispara com uma parte colidível e consultável que entrou no workspace (já com as propriedades definidas). |
| `Geometry.buildRaycastParams(extra?): RaycastParams` | `RaycastParams` (Exclude) sem as partes atravessáveis, os personagens e a pasta de debug, mais o que você passar em `extra: {Instance}`. |
| `Geometry.isInvisibleCollider(part): boolean` | Se a parte é invisível, colidível, sem `NavSolid` e não é parte de um personagem. |
| `Geometry.addExclusion(instance)` | Inclui uma instância em todo `RaycastParams` da biblioteca. |
| `Geometry.audit(): {BasePart}` | Lista partes invisíveis e colidíveis que **não** foram classificadas, para revisão manual. |

```lua
-- lista o que ainda pode estar bloqueando rotas sem você saber
for _, part in ipairs(SmartPath.Geometry.audit()) do
    print("suspeita:", part:GetFullName())
end
```

### `SmartPath.Scheduler` — fila global de cálculos

Todo `ComputeAsync` da biblioteca passa por aqui: um orçamento de cálculos por frame, para que muitos NPCs não travem o jogo.

| Função | Descrição |
|---|---|
| `Scheduler.submit(key, priority, fn): Handle` | Enfileira `fn`. Pedidos pendentes com a **mesma `key`** viram um só cálculo. Maior `priority` é mais urgente. |
| `Scheduler.setBudget(n)` | Cálculos iniciados por frame (mínimo 1; padrão 4). |
| `Scheduler.getBudget(): number` | O orçamento atual. |
| `Scheduler.getQueueLength(): number` | Quantos pedidos esperam. |

`Handle`: `handle:cancel()`, `handle:await(): ...any` (bloqueia e devolve o retorno de `fn`), `handle:isDone(): boolean`, `handle:isCancelled(): boolean`. Um pedido cancelado antes de começar nunca executa.

```lua
local handle = SmartPath.Scheduler.submit("minha-chave", 0, function()
    return expensiveComputation()
end)
local result = handle:await()
```

### `SmartPath.Predictor` — predição de salto balística

Diz se o agente, com o `JumpHeight` **real** dele, consegue saltar o obstáculo entre ele e o alvo, de que altura, onde decolar e onde pousar.

#### `Predictor.analyze(ctx)` → `(plan?, reason: string, info?)`

`ctx`:

| Campo | Descrição |
|---|---|
| `root: BasePart` | O `HumanoidRootPart`. |
| `humanoid: Humanoid` | |
| `targetPos: Vector3` | Para onde o agente quer ir. |
| `params: RaycastParams` | Use `Geometry.buildRaycastParams()`. |
| `agentRadius?`, `agentHeight?`, `walkSpeed?` | Padrões: 2, 5 e o `WalkSpeed` do humanoid. |
| `maxJumpHeight?` | Padrão: derivado do humanoid. |
| `probeDistance?` | Até onde à frente procurar o obstáculo (padrão 10 studs). |

`plan` (quando viável): `direction`, `wallPoint`, `wallInstance`, `obstacleHeight`, `obstacleDepth?`, `isPlatform`, `landingPoint`, `jumpHeight`, `takeoffDistance`, `tUp`, `tDown`. Sem plano, `reason` é um de: `no_obstacle`, `not_a_wall`, `target_too_close`, `jump_too_weak`, `too_tall`, `top_not_found`, `no_landing`, `drop_too_high`, `insufficient_jump`, `too_deep`, `air_blocked`, `ceiling`; `info` traz medidas quando existem (`height`, `maxJump`, `drop`, `at`, `atLeast`).

#### `Predictor.wallDistance(plan, rootPos): number`

Distância plana do centro do agente até a face do obstáculo, ao longo da direção do plano. O agente decola quando esta distância é `≤ plan.takeoffDistance`.

```lua
local plan, reason = SmartPath.Predictor.analyze({
    root = npc.HumanoidRootPart,
    humanoid = npc.Humanoid,
    targetPos = goal,
    params = SmartPath.Geometry.buildRaycastParams({ npc }),
})
if plan then
    print("salta", plan.obstacleHeight, "studs; pousa em", plan.landingPoint)
else
    print("sem plano:", reason)
end
```

### `SmartPath.Simplifier` — string pulling seguro

Remove waypoints redundantes só quando o corpo cabe **e** o chão é contínuo no atalho. Nunca remove nem atravessa um waypoint de ação (salto, link).

| Função | Descrição |
|---|---|
| `Simplifier.buildContext(params, agentRadius): Context` | Contexto com o raio físico do corpo (0,6 × `agentRadius`). |
| `Simplifier.simplify(waypoints, context): {Waypoint}` | Devolve os waypoints simplificados. |

```lua
local context = SmartPath.Simplifier.buildContext(SmartPath.Geometry.buildRaycastParams(), 2)
local simpler = SmartPath.Simplifier.simplify(waypoints, context)
```

### `SmartPath.Version`

`string` semver (`"1.0.0"`).

---

## Debug

Nada aqui roda com `Options.Debug = false`. Com `true`, o agente desenha e imprime sozinho:

- rota, com pontos e linhas por ação (azul: andar; amarelo: saltar; laranja: queda; magenta: link);
- o **raio efetivo** usado (disco verde se coube com o raio cheio, laranja se foi reduzido);
- decolagem (turquesa), pouso (verde) e obstáculo (vermelho) de cada salto;
- o ponto de cada falha, e a rota rejeitada em vermelho no `corridor_too_narrow`;
- linhas `[SmartPath] ...` no Output, com a frase do `explain`.

Toda parte desenhada tem `Anchored`, e `CanCollide`, `CanQuery` e `CanTouch` desligados, e a pasta `workspace.SmartPathDebug` é excluída dos `RaycastParams` da biblioteca.

### `SmartPath.Debug.showPanel(agent, parent?)`

Painel na tela com o estado do agente, a rota, o raio usado, o tempo do último cálculo, a fila do `Scheduler` e o último erro. Só existe quando você o pede.

- `agent: Agent`
- `parent: Instance?` — no cliente o padrão é o `PlayerGui`; no servidor não há tela e o `parent` é **obrigatório** (a função lança erro sem ele).
- **Retorno** `Panel = { Gui: ScreenGui, Refresh: () -> (), GetText: () -> string, Destroy: () -> () }`

```lua
local panel = SmartPath.Debug.showPanel(agent) -- no cliente
-- ...
panel.Destroy()
```

### Desenho manual

`Debug.point(pos, color, size?, lifetime?)`, `Debug.line(a, b, color, lifetime?)`, `Debug.route(waypoints, lifetime?)`, `Debug.radius(pos, usedRadius, agentRadius, lifetime?)`, `Debug.obstacle(pos, instance?, text?, lifetime?)`, `Debug.jump(plan, lifetime?)`, `Debug.failure(reason, details?, lifetime?)`. `Debug.describe(agent): string` devolve o texto do painel; `Debug.clear()` apaga a pasta de debug; `Debug.Colors` tem as cores usadas. O tempo de vida padrão é 6 s.

---

## Módulos internos

`Agent`, `RouteSolver`, `RouteCache`, `JumpExecutor`, `Config`, `Util`, `Signal`, `Types`, `Compat`, `Diagnostics` e `DECISIONS` existem dentro da pasta da biblioteca, mas **não** fazem parte da API pública: podem mudar sem aviso entre versões menores.
