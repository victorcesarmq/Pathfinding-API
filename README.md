# SmartPath

**Pathfinding para Roblox que conhece o agente de verdade.**

O `PathfindingService` monta a malha de navegação com um modelo pobre do personagem: só um raio e uma altura, sem saber o quanto ele pula, e trata como parede tudo o que tem `CanCollide`, mesmo uma zona invisível. A SmartPath usa o `PathfindingService` por baixo, mas valida cada rota contra o corpo real do `Humanoid`, calcula saltos com o `JumpHeight` de verdade e diz **por que** uma rota falhou.

```lua
local SmartPath = require(game.ReplicatedStorage.SmartPath)
local ok, reason, details = SmartPath.MoveTo(workspace.Zombie.Humanoid, workspace.Base.Position)
if not ok then warn(SmartPath.explain(reason, details)) end
```

Sem tabela de opções, sem origem, sem configuração: raio, altura, velocidade e força do pulo saem do próprio personagem.

- [Instalação](#instalação) · [Primeiros passos](#primeiros-passos-em-5-minutos) · [O que muda na prática](#o-que-muda-na-prática) · [Opções](#opções) · [Erros](#erros) · [Limitações](#limitações-o-que-a-smartpath-não-faz) · [API completa](docs/API.md)

---

## O que muda na prática

Resultados medidos no place de demonstração (Roblox Studio), com dois NPCs idênticos sobre a mesma geometria: à esquerda o `PathfindingService` puro, do jeito que a documentação da Roblox ensina; à direita a SmartPath.

| Situação | `PathfindingService` puro | SmartPath |
|---|---|---|
| Plataforma de 18 studs com `JumpHeight` 25 | `NoPath` (a malha não conhece o `JumpHeight`) | Salta e chega (2,4 s) |
| Labirinto com um gatilho invisível e colidível na passagem | `NoPath` | Atravessa e chega |
| Caverna com uma zona invisível cobrindo o interior (entrar, sair, andar lá dentro) | A rota vira "bloco maciço": sem rota, ou uma rota por cima do teto | Os três casos concluem |
| Sala com porta de 3 studs e corredor de 3,2 entre móveis | `NoPath` | Chega, reduzindo o raio de 2,0 para 1,0 |
| Limite de mapa invisível declarado com a tag `NavSolid` | Respeita | Respeita (teste de segurança: a SmartPath nunca o atravessa) |
| Bloco que cai sobre a rota | Refaz a rota pelo `Path.Blocked` | Detecta e refaz a rota |
| 20 NPCs simultâneos | 60 FPS | 60 FPS; mais trechos concluídos (87 a 89 contra 69 a 74 em 30 s) |
| Corredor de 4 studs; mureta de 3 studs | Chega | Chega. **Empate**: a engine resolve sozinha |

Vazamento de memória: 500 agentes criados e destruídos, e 20 NPCs andando por 10 minutos, sem crescimento de memória nem de instâncias.

Os cenários e o código de cada teste estão em [`src/demo`](src/demo). Veja em [Limitações](#limitações-o-que-a-smartpath-não-faz) o que **não** foi coberto.

---

## Instalação

Escolha uma.

**Wally**

```toml
# wally.toml do seu projeto
[dependencies]
SmartPath = "seu-usuario/smartpath@1.0.0"
```

**Modelo do Creator Store.** Pegue o modelo `SmartPath`, coloque-o em `ReplicatedStorage` e pronto.

**Rojo.** Copie a pasta [`src/SmartPath`](src/SmartPath) para o seu projeto e mapeie:

```json
"ReplicatedStorage": {
  "SmartPath": { "$path": "src/SmartPath" }
}
```

**Manual.** Coloque a pasta `SmartPath` (um `ModuleScript` com filhos) em `ReplicatedStorage`.

Não há dependências. Foi feita para o servidor (NPCs) e para o cliente (o personagem do jogador), mas **só o servidor foi validado num jogo real**: veja [Limitações](#limitações-o-que-a-smartpath-não-faz).

---

## Primeiros passos em 5 minutos

1. Coloque a `SmartPath` em `ReplicatedStorage` (veja acima).
2. Tenha no `workspace` um NPC (`Model` com `Humanoid` e `HumanoidRootPart`) e um lugar para ele ir. Vale um rig de teste ou o de qualquer `Humanoid`.
3. Crie um `Script` (servidor) em `ServerScriptService`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SmartPath = require(ReplicatedStorage.SmartPath)

local npc = workspace:WaitForChild("Zombie")
local ok, reason, details = SmartPath.MoveTo(npc.Humanoid, Vector3.new(50, 0, 20))

if ok then
    print("chegou")
else
    warn(SmartPath.explain(reason, details))
end
```

4. Rode (Play). O NPC anda até lá. `MoveTo` **bloqueia** até chegar ou falhar; para não bloquear, use `SmartPath.MoveToAsync`.

O destino pode ser um `Vector3`, um `BasePart` ou um `Model`. Um `BasePart` ou `Model` que se mexe é **seguido** (o NPC persegue o jogador):

```lua
SmartPath.MoveToAsync(npc.Humanoid, player.Character)
```

Para ver o que a biblioteca está decidindo, ligue o debug (desenha a rota, o raio usado, os saltos e o ponto de cada falha):

```lua
SmartPath.MoveTo(npc.Humanoid, goal, { Debug = true })
```

### Trajetória em curva

Por padrão o agente anda em linha reta até cada waypoint e vira de uma vez no canto. Para uma trajetória mais natural:

```lua
SmartPath.MoveTo(npc.Humanoid, goal, { Stability = { Curves = true } })
```

O agente passa a mirar num ponto um pouco adiante na rota e só arredonda um canto quando o corpo cabe (a mesma validação de volume da rota). Saltos e o destino continuam exatos, e o `GetRoute` devolve os mesmos waypoints. Como a curva ainda foi calibrada só com o rig de teste, a distância de olhar à frente pode precisar de ajuste no seu.

### Com um agente persistente

Para patrulha, perseguição e eventos, crie um agente por personagem:

```lua
local agent = SmartPath.new(npc)

agent.Reached:Connect(function()
    agent:MoveTo(nextPatrolPoint())
end)
agent.Failed:Connect(function(reason, details)
    warn(SmartPath.explain(reason, details))
end)

agent:MoveTo(firstPatrolPoint)
-- ao terminar com o NPC:
-- agent:Destroy()
```

Há um agente por personagem: `SmartPath.new` dá erro se já existe um, e `SmartPath.MoveTo` reaproveita o existente.

### Já tenho um script com `PathfindingService`

Troque **uma linha**; `CreatePath`, `ComputeAsync`, `Status`, `GetWaypoints` e `Blocked` continuam iguais:

```lua
-- local PathfindingService = game:GetService("PathfindingService")
local PathfindingService = require(game.ReplicatedStorage.SmartPath).Service
```

O `path.SmartStatus` e o `path.SmartDetails` trazem o diagnóstico da SmartPath. Diferenças: `WaypointSpacing`, `Costs` e `AgentCanClimb` são ignorados, e como só há coordenadas (sem personagem), o raio e a altura vêm do `CreatePath`.

### Zonas invisíveis, gatilhos e limites de mapa

Uma parte invisível com `CanCollide = true` (a zona que dispara "você entrou na caverna", por exemplo) é uma parede para o `PathfindingService`. A SmartPath a atravessa sozinha se ela for invisível (`Transparency ≥ 0.95`) e tiver um nome de gatilho (`zone`, `trigger`, `hitbox`, `region`, `bounds`, `sensor`, `detector`, `area`). Para controlar isso explicitamente, use tags (na parte ou no modelo dela):

| Tag | Efeito |
|---|---|
| `NavIgnore` | Sempre atravessável pela rota. |
| `NavSolid` | Sempre sólida, mesmo invisível e com nome de gatilho. Use em limites de mapa. Vence tudo. |

`SmartPath.Geometry.audit()` lista as partes invisíveis e colidíveis que ainda não foram classificadas. A biblioteca **nunca** altera o seu mapa (`CanCollide`, `Transparency`, `Anchored`): só cria e remove `PathfindingModifier`.

Se a parte também barra o **corpo** (`CanCollide = true` e sem grupo de colisão que a ignore), o NPC anda até ela e trava: o erro é `invisible_collider`, com a parte exata. Aí a correção é no mapa.

---

## Opções

Todas são opcionais; `nil` significa "derive do personagem ou use o default".

```lua
SmartPath.MoveTo(humanoid, goal, {
    Indoor = { AdaptiveRadius = true, MinRadius = 0.5, RadiusSteps = { 1.5, 1.0, 0.5 } },
    Jump = { Enabled = true, Mode = "Native", MaxHeight = nil, DetourRatio = 1.4 },
    Stability = { Cache = true, Smoothing = true, Hysteresis = 0.15, Curves = false },
    Geometry = { AutoFilter = true, RequireNameMatch = true },
    Agent = { Radius = nil, Height = nil, WalkSpeed = nil },
    Scheduler = { Priority = 0 },
    Debug = false,
})
```

| Campo | Default | Para que serve |
|---|---|---|
| `Indoor.AdaptiveRadius` | `true` | Tenta raios menores quando o raio cheio não acha rota. |
| `Indoor.MinRadius` / `RadiusSteps` | `0.5` / `{1.5, 1, 0.5}` | Os raios da escada. |
| `Jump.Enabled` | `true` | Liga saltos. `false` automático se o `Humanoid` não salta. |
| `Jump.Mode` | `"Native"` | `"Native"` ajusta o `JumpHeight` por um instante e restaura; `"Injected"` aplica velocidade. |
| `Jump.MaxHeight` | do `Humanoid` | Altura máxima de salto. |
| `Jump.DetourRatio` | `1.4` | Só procura atalho por salto se a rota for 1,4x mais longa que a reta. |
| `Stability.Cache` | `true` | Cache de rotas (células de 2 studs, 15 s). |
| `Stability.Smoothing` | `true` | Suaviza a rota. |
| `Stability.Hysteresis` | `0.15` | Uma rota nova só troca a atual se for 15% mais curta. |
| `Stability.Curves` | `false` | O agente faz curvas nos cantos em vez de virar de uma vez (só onde o corpo cabe). Opcional; desligado, nada muda. |
| `Geometry.AutoFilter` / `RequireNameMatch` | `true` / `true` | Filtro de zonas invisíveis. **Global ao jogo**, não por agente. |
| `Agent.Radius` / `Height` / `WalkSpeed` | do personagem | Sobrescreve o que a biblioteca mediu. |
| `Scheduler.Priority` | `0` | Maior é mais urgente. |
| `Debug` | `false` | Desenho e mensagens `[SmartPath]`. Desligado, não cria instância nem imprime. |

Detalhes de cada um em [docs/API.md](docs/API.md#options).

---

## Erros

Toda falha de navegação vem como um **código fixo** mais uma tabela `details`. `SmartPath.explain(reason, details)` transforma em uma frase.

| Código | Significa | `details` |
|---|---|---|
| `no_path` | Sem rota depois de todas as tentativas. | `triedRadii` (`noGround` se o agente está no ar sem chão) |
| `corridor_too_narrow` | A engine achou rota, mas o corpo não cabe. | `requiredRadius`, `agentRadius`, `blockedAt`, `rejectedRoute` |
| `obstacle_too_tall` | Obstáculo maior que o salto do agente. | `height`, `maxJump` |
| `no_landing` | O salto seria possível, mas não há pouso seguro. | `drop` |
| `goal_unreachable` | O destino está fora da malha (dentro de parede, no ar). | `nearestValid`, `requestedGoal` |
| `invisible_collider` | Uma parte invisível e colidível barrou a rota ou o corpo. | `instance` |
| `stuck` | O agente travou depois de 4 tentativas de sair. | `position`, `strikes` |
| `cancelled` | `Stop()`, novo `MoveTo` ou `Destroy()`. | — |
| `character_lost` | O personagem morreu ou foi removido. | — |
| `timeout` | Passou do tempo máximo. | `elapsed` |

Exemplo de `explain`: *"O corredor só comporta um agente de raio até 0.8, mas o agente tem 2.0. Reduza Agent.Radius ou alargue a passagem."* As frases estão em português. A tabela completa, com o que fazer em cada caso, está em [docs/API.md](docs/API.md#códigos-de-erro).

---

## Limitações: o que a SmartPath **não** faz

Uma biblioteca que promete demais queima reputação no primeiro bug. Isto é o que ela não faz, ou não garante.

**Fora do escopo da 1.0** (planejado ou descartado):
- **Não gera `PathfindingLink` automaticamente** (saltos escolhidos pela malha). Os saltos são calculados em tempo de execução. Um gerador de links é o plano da v2.
- **Não faz evitação entre agentes.** NPCs se empurram; o anti-stuck resolve quase sempre (no demo com 20 NPCs, 1 `stuck` em ~88 trechos), mas não há desvio local.
- **Não faz voo, natação nem escalada**, nem pathfinding hierárquico para mapas gigantes.
- **Não suporta rigs sem `Humanoid`.**

**O que a engine já resolve sozinha** (medido): corredores de 3 a 4 studs e muretas de até ~3 studs. Nesses casos a SmartPath **empata**; o ganho está em saltos além do limite da engine, zonas invisíveis, diagnóstico e nos casos acima.

**Limites do que a SmartPath faz:**
- **Só reduz o raio, não a altura.** Um teto ou uma copa de árvore mais baixa que a altura do agente faz a engine devolver `no_path`, e a SmartPath não tenta uma altura menor.
- **Obstáculos de salto só são vistos de perto.** O atalho por salto procura obstáculos a até 10 studs do agente; um obstáculo mais longe só é percebido ao chegar perto. Com o `JumpHeight` padrão (~6,4), a conta do `Predictor` limita obstáculos finos a ~3,5 studs (calculado, não medido); com `JumpHeight` maior, sobe (medido até 18 studs com `JumpHeight` 25).
- **Pode chegar perto, não no ponto.** Se o destino não está na malha, a rota pode ser aproximada para o ponto válido mais próximo (até 8 studs), e o agente conclui com sucesso ali. O `Reached` não informa que houve aproximação.
- **Obstáculos que se movem** para dentro da rota são detectados em até ~1,25 s, não na hora.
- **`Geometry` é global** por ambiente (servidor ou cliente): `AutoFilter` e `RequireNameMatch` valem para todos os agentes; a última chamada decide.
- **Nunca altera o seu mapa.** Se a folhagem, o teto ou um gatilho têm `CanCollide = true`, o corpo colide com eles fisicamente, e a solução é no mapa (`CanCollide = false`).
- **Desempenho com muitos NPCs:** a média de FPS é igual à do baseline, mas o pior frame com 20 NPCs começando ao mesmo tempo é maior (147 a 183 ms contra 116 a 122 ms nas nossas medições).
- **Compatibilidade:** `WaypointSpacing`, `Costs` e `AgentCanClimb` do `CreatePath` são ignorados.

**Ainda não validado num jogo real:**
- O agente controlando o **personagem de um jogador no cliente** (o passo roda em `PreSimulation`). Só NPCs de servidor foram exercitados.
- **`StreamingEnabled`**: o pedido de stream no cliente existe, mas não foi testado com streaming ligado.
- Constantes marcadas como `[VALIDAR]` no código (folgas de salto, fatores de relaxamento), calibradas com o rig de teste, podem precisar de ajuste no seu rig.

---

## Desenvolvimento

O repositório tem três projetos Rojo:

| Arquivo | O que monta |
|---|---|
| `default.project.json` | Só a biblioteca (é o que o Wally e o Creator Store empacotam). |
| `dev.project.json` | A biblioteca e os testes (`ServerStorage.SmartPathTests`). |
| `demo.project.json` | A biblioteca, o place de demonstração e o HUD. |

```bash
rojo serve dev.project.json                              # testes no Studio
rojo build demo.project.json -o SmartPathDemo.rbxlx      # o demo (abra e dê Play)
rojo build default.project.json -o SmartPath.rbxm        # o modelo da biblioteca
```

Testes (Studio, em **Run**, na Command Bar): `require(game.ServerStorage.SmartPathTests).Phase1()` até `Phase8()`, e `Phase8Soak(10)` para 20 NPCs por 10 minutos.

As decisões de projeto estão em [DECISIONS.md](DECISIONS.md), o histórico em [CHANGELOG.md](CHANGELOG.md) e o que ficou para depois em [BACKLOG.md](BACKLOG.md).

## Licença

[MIT](LICENSE).
