# SMARTPATH — PLANO DE EXECUÇÃO

**Projeto:** biblioteca open-source de pathfinding para Roblox que corrige as falhas do `PathfindingService` em ambientes fechados e em obstáculos altos, com API de baixo atrito para outros desenvolvedores.

**Destinatário:** agente Claude operando dentro do Roblox Studio.
**Responsável pelo projeto:** Victor.

---

## 0. COMO USAR ESTE DOCUMENTO

### 0.1 Para o Victor

1. Este plano tem **10 fases**. Cada fase tem um bloco `PROMPT` pronto para copiar e colar no agente do Studio. **Não cole o documento inteiro de uma vez** — o agente perde foco e começa a implementar tudo ao mesmo tempo, mal.
2. Junto com o primeiro prompt, forneça ao agente **os dois arquivos**:
   - `ESPEC_NAVEGACAO_ROBLOX.md` (a especificação técnica com os algoritmos e o código de referência — é a fonte da lógica);
   - este arquivo (é a fonte do **processo** e do **contrato de API**).
3. Ao final de cada fase, rode os **critérios de aceite** antes de liberar a próxima. Se algo falhar, mande o agente corrigir naquela fase — não empurre dívida para a seguinte.
4. Quando o agente disser que terminou, peça sempre: *"liste o que você NÃO implementou ou implementou parcialmente nesta fase"*. Modelos tendem a declarar sucesso cedo demais; essa pergunta força a lista.

### 0.2 Para o agente

- Você está construindo uma **biblioteca pública**, não um script de jogo. A prioridade é, nesta ordem: (1) não quebrar o jogo de quem usar, (2) facilidade de uso, (3) desempenho, (4) elegância interna.
- O **contrato de API da Seção 3 está congelado**. Se precisar mudar alguma assinatura, pare, explique o motivo e peça autorização antes.
- Implemente **apenas a fase pedida**. Deixe as demais como stub com `-- TODO(Fase N)`.
- Não invente APIs do Roblox. Se não tiver certeza de que um método existe, pergunte em vez de chutar.
- Toda decisão não trivial vira uma linha no arquivo `DECISIONS.md` (Seção 9).

---

## 1. BRIEFING DO PRODUTO

**Frase que define o projeto:** *pathfinding que conhece o agente de verdade.*

As duas falhas centrais do `PathfindingService` têm a mesma raiz — a malha de navegação é construída com um modelo empobrecido do personagem:

| Falha | Causa real | Resposta da SmartPath |
|---|---|---|
| Falha em locais fechados (`NoPath` em corredor por onde o personagem passaria) | `AgentRadius` infla obstáculos e a voxelização é grossa; corredor estreito some da malha | Escada de raio adaptativo + validação própria por `Spherecast` no raio real |
| Não pula obstáculos que o personagem alcançaria | `AgentCanJump` é booleano; a malha não conhece `JumpHeight` | Predição balística em runtime + (v2) geração automática de `PathfindingLink` |
| Rota oscila entre chamadas iguais | Entrada não normalizada, sem cache, sem histerese | Origem aterrada, cache por célula, string pulling, histerese |
| Geometria invisível colidível bloqueia rotas | `Transparency` não importa para a engine; só `CanCollide` | `PathfindingModifier.PassThrough` + `RaycastParams` filtrado |
| Erro sem diagnóstico (`NoPath` e nada mais) | API pobre em informação | Códigos de erro com dados (`corridor_too_narrow`, `obstacle_too_tall`, ...) |
| Travamento com muitos NPCs | Cada NPC chama `ComputeAsync` sem coordenação | Agendador central com orçamento por frame |

---

## 2. ESCOPO

### 2.1 Dentro da v1.0

1. Raio adaptativo para ambientes fechados.
2. Predição de salto balística (runtime).
3. Filtro de geometria invisível.
4. Estabilização: origem aterrada, cache por célula, string pulling, histerese.
5. Agendador central de cálculos.
6. Códigos de erro diagnósticos.
7. Três níveis de API + camada de compatibilidade (Seção 3).
8. Visualização de debug.
9. Place de demonstração com 8 cenários comparativos.
10. Documentação e publicação (Creator Store + Wally/GitHub).

### 2.2 Fora da v1.0 (backlog explícito)

- Gerador automático de `PathfindingLink` ("baker") → **v2**, Fase 10.
- Evitação dinâmica entre agentes (RVO/steering).
- Pathfinding em voo, natação, escalada.
- Pathfinding hierárquico para mapas gigantes.
- Suporte a rigs não-Humanoid.

**Regra:** qualquer item desta lista que aparecer durante a implementação vira linha em `BACKLOG.md`. Não implemente.

---

## 3. CONTRATO DE API (CONGELADO)

### 3.1 Nível 0 — uma linha

```lua
local SmartPath = require(ReplicatedStorage.SmartPath)

-- Move e retorna quando terminar. Yield.
-- target: Vector3 | BasePart | Model
-- Retorna: success: boolean, reason: string?
local ok, reason = SmartPath.MoveTo(humanoid, target, options?)

-- Versão não-bloqueante: devolve o agente já em movimento.
local agent = SmartPath.MoveToAsync(humanoid, target, options?)

-- Só calcula, não move. Devolve waypoints melhorados.
-- Retorna: waypoints: {Waypoint}?, reason: string?
local waypoints, reason = SmartPath.GetRoute(humanoid, target, options?)
```

**Decisão de design registrada:** a origem **não** é parâmetro. Ela é derivada do `Humanoid`, porque do humanoid a biblioteca extrai posição aterrada, altura de pulo real, velocidade, rig e estado no ar — informação que um `Vector3` não carrega e que é exatamente a que falta ao `PathfindingService`.

### 3.2 Nível 1 — agente persistente

```lua
local agent = SmartPath.new(characterOrHumanoid, options?)

agent:MoveTo(target)          -- não bloqueia
agent:Await()                 -- yield até Reached/Failed; retorna (ok, reason)
agent:Stop()
agent:SetSuspended(bool)      -- pausa sem perder a rota (para cutscene, dash, stun)
agent:GetState() -> string    -- "Idle" | "Following" | "DirectJump" | "Airborne" | "Failed"
agent:GetRoute() -> {Waypoint}?
agent:SetOptions(partialOptions)
agent:Destroy()

agent.Reached        : Signal ()
agent.Failed         : Signal (reason: string, details: table)
agent.Blocked        : Signal ()
agent.Jumped         : Signal (plan: table)
agent.CustomWaypoint : Signal (label: string, waypoint, nextWaypoint)
```

### 3.3 Nível 2 — peças soltas

```lua
SmartPath.Predictor   -- análise balística de obstáculo
SmartPath.Simplifier  -- string pulling seguro
SmartPath.Geometry    -- filtro de geometria invisível
SmartPath.Scheduler   -- fila global de cálculos
SmartPath.Errors      -- tabela de códigos de erro
SmartPath.Version     -- string semver
```

### 3.4 Camada de compatibilidade

Espelha a API oficial para migração de uma linha:

```lua
local SmartPathfindingService = SmartPath.Service

local path = SmartPathfindingService:CreatePath({ AgentRadius = 2, AgentCanJump = true })
path:ComputeAsync(startPos, finishPos)
path.Status        -- Enum.PathStatus (compatível)
path:GetWaypoints()
path.Blocked       -- signal compatível
-- extras não-oficiais:
path.SmartStatus   -- código de erro diagnóstico da SmartPath
path.SmartDetails  -- tabela com dados do diagnóstico
```

### 3.5 Tabela de opções (todos os campos opcionais)

```lua
{
  Indoor = { AdaptiveRadius = true, MinRadius = 0.5, RadiusSteps = {1.5, 1.0, 0.5} },
  Jump   = { Enabled = true, Mode = "Native", MaxHeight = nil, DetourRatio = 1.4 },
  Stability = { Cache = true, Smoothing = true, Hysteresis = 0.15 },
  Geometry  = { AutoFilter = true, RequireNameMatch = true },
  Agent  = { Radius = nil, Height = nil, WalkSpeed = nil },  -- nil = derivar do personagem
  Scheduler = { Priority = 0 },
  Debug = false,
}
```

`nil` em qualquer campo significa "derive do personagem ou use o default". **Nenhum campo pode ser obrigatório.**

### 3.6 Tipo `Waypoint`

```lua
type Waypoint = {
  Position: Vector3,
  Action: Enum.PathWaypointAction,
  Label: string,
  SmartAction: string?,  -- "Walk" | "Jump" | "Drop" | "Link"
  JumpHeight: number?,   -- altura calculada, quando SmartAction == "Jump"
}
```

### 3.7 Códigos de erro (fixos)

| Código | Significado | `details` |
|---|---|---|
| `no_path` | sem rota mesmo após todas as tentativas | `{ triedRadii }` |
| `corridor_too_narrow` | só houve rota com raio reduzido e o corpo não cabe | `{ requiredRadius, agentRadius }` |
| `obstacle_too_tall` | obstáculo acima da capacidade de salto | `{ height, maxJump }` |
| `no_landing` | há salto possível mas sem pouso seguro | `{ drop }` |
| `goal_unreachable` | destino fora da malha (dentro de parede, no ar) | `{ nearestValid }` |
| `invisible_collider` | rota bloqueada por parte invisível colidível | `{ instance }` |
| `stuck` | agente travou após N tentativas | `{ position, strikes }` |
| `cancelled` | `Stop()` ou novo `MoveTo` | `{}` |
| `character_lost` | humanoid morreu/foi removido | `{}` |
| `timeout` | excedeu o tempo máximo | `{ elapsed }` |

---

## 4. ESTRUTURA DE ARQUIVOS

```
ReplicatedStorage/
  SmartPath/                  (Folder)
    init              (ModuleScript)  -- fachada: níveis 0, 2, Service, Version
    Types             (ModuleScript)
    Config            (ModuleScript)  -- defaults + merge + derivação do personagem
    Errors            (ModuleScript)
    Util              (ModuleScript)  -- geometria, física, debug visual
    Signal            (ModuleScript)  -- wrapper leve de BindableEvent
    Scheduler         (ModuleScript)  -- fila global com orçamento por frame
    Geometry          (ModuleScript)  -- filtro de geometria invisível
    RouteCache        (ModuleScript)
    Simplifier        (ModuleScript)
    RouteSolver       (ModuleScript)  -- escada de raio adaptativo + validação
    Predictor         (ModuleScript)  -- predição balística de salto
    JumpExecutor      (ModuleScript)
    Agent             (ModuleScript)  -- nível 1: máquina de estados
    Compat            (ModuleScript)  -- camada SmartPathfindingService
    DECISIONS         (ModuleScript)  -- string com o log de decisões (espelha DECISIONS.md)

ServerStorage/SmartPathDemo/  -- place de demonstração (Fase 8)
```

Se o projeto for versionado com Rojo, o espelho no disco é `src/` com `default.project.json`, `wally.toml`, `README.md`, `DECISIONS.md`, `BACKLOG.md`, `CHANGELOG.md`.

---

## 5. REGRAS PERMANENTES PARA O AGENTE

Valem em **todas** as fases. Releia antes de cada uma.

1. **Zero configuração obrigatória.** Toda função funciona chamada só com os parâmetros mínimos.
2. **Zero estado global mutável** fora dos singletons documentados (`Scheduler`, `Geometry`). Nada de variáveis soltas compartilhadas entre jogos.
3. **Limpeza completa.** Todo objeto com `:Destroy()` desconecta 100% das conexões. Nenhuma conexão em `CharacterAdded`/`Heartbeat` pode sobreviver ao `Destroy`.
4. **Nunca alterar propriedades do mapa do usuário** (`CanCollide`, `Transparency`, `Anchored`). A única exceção autorizada é criar/remover `PathfindingModifier` filho, e mesmo assim de forma reversível e desligável por opção.
5. **Nunca assumir servidor nem cliente.** Todo módulo funciona nos dois; diferenças ficam atrás de `RunService:IsServer()`.
6. **Todo yield é explícito.** Funções que dão yield terminam em `Async` ou estão documentadas como bloqueantes (`MoveTo` nível 0, `Await`).
7. **`pcall` em toda chamada de engine que pode errar** (`ComputeAsync`, `SetNetworkOwner`, `ChangeState`).
8. **Sem dependências externas** na v1. Nem Promise, nem Knit. A lib precisa ser autocontida.
9. **Comentários explicam o porquê, não o quê.** Onde houver constante numérica, comente a origem dela.
10. **Nada de `print` em código de produção.** Só sob `options.Debug`, e sempre prefixado com `[SmartPath]`.
11. **Compatibilidade de tipos:** aceite `Model`, `Humanoid` ou `BasePart` onde fizer sentido, normalizando internamente.
12. **Ao terminar a fase, produza um relatório:** o que foi feito, o que ficou parcial, quais suposições você fez, quais itens novos foram para o `BACKLOG.md`.

---

## 6. FASES

> Cada fase traz: **Objetivo**, **Entregas**, **Critérios de aceite** e o bloco **PROMPT** para colar no agente.

---

### FASE 0 — Fundação e esqueleto

**Objetivo:** criar a estrutura e os contratos antes de qualquer lógica, para que as fases seguintes não briguem entre si.

**Entregas:** a árvore da Seção 4 com todos os ModuleScripts criados; `Types`, `Errors`, `Signal`, `Config`, `Util` implementados de verdade; os demais como stub tipado; `init` já exportando a fachada (funções lançando `error("not implemented (Fase N)")`); `DECISIONS.md`, `BACKLOG.md`, `CHANGELOG.md`.

**Critérios de aceite:**
- [ ] `require(ReplicatedStorage.SmartPath)` funciona sem erro e devolve tabela com `MoveTo`, `GetRoute`, `new`, `Service`, `Version`.
- [ ] `SmartPath.Version == "0.1.0"`.
- [ ] Nenhum stub quebra o `require`.
- [ ] `Config.resolve(character, options)` devolve tabela completa com defaults derivados do personagem (raio, altura, `JumpHeight` real, `WalkSpeed`).
- [ ] `Signal` cria, conecta, dispara e desconecta sem vazar.

```text
PROMPT — FASE 0

Você vai construir a biblioteca SmartPath dentro deste place. Leia os dois documentos que
anexei: ESPEC_NAVEGACAO_ROBLOX.md (algoritmos e código de referência) e
SMARTPATH_PLANO_DE_EXECUCAO.md (processo e contrato de API).

Antes de começar, confirme comigo em uma frase: qual é o objetivo da Fase 0 e o que você
NÃO vai implementar nela.

Execute APENAS a Fase 0 do plano:
- Crie a árvore de módulos da Seção 4 em ReplicatedStorage/SmartPath.
- Implemente de verdade: Types, Errors (todos os códigos da Seção 3.7), Signal (wrapper
  leve sobre BindableEvent, com :Connect, :Fire, :Wait, :Destroy), Config (defaults da
  Seção 3.5 + merge profundo + derivação a partir do personagem: raio e altura reais,
  JumpHeight real considerando UseJumpPower, WalkSpeed, RigType) e Util (flat, getFeetY,
  getMaxJumpHeight, velocityForHeight, groundBelow, pathLength, debug visual).
- Todos os outros módulos ficam como stub que dá require sem erro e cujas funções chamam
  error("SmartPath: not implemented (Fase N)").
- init expõe exatamente a fachada da Seção 3 (níveis 0, 1, 2, Service, Version = "0.1.0").
- Crie DECISIONS.md, BACKLOG.md e CHANGELOG.md.

Siga as REGRAS PERMANENTES da Seção 5 do plano. Ao terminar, rode os critérios de aceite
da Fase 0 e me entregue o relatório da regra 12.
```

---

### FASE 1 — Agendador e filtro de geometria

**Objetivo:** as duas peças de infraestrutura que todo o resto consome.

**Entregas:** `Scheduler` (fila global, orçamento configurável de cálculos por frame, prioridade, cancelamento, coalescência de pedidos idênticos); `Geometry` (classificação por tag `NavSolid`/`NavIgnore` → `CanCollide` → auto-detecção conservadora; `PathfindingModifier.PassThrough`; `buildRaycastParams`; versionamento + sinal `Changed`; `audit()`).

**Critérios de aceite:**
- [ ] 50 pedidos simultâneos ao `Scheduler` não passam do orçamento por frame (medir com MicroProfiler).
- [ ] Pedido cancelado nunca executa.
- [ ] Dois pedidos idênticos pendentes viram um só cálculo.
- [ ] Parte invisível colidível chamada "ZoneTrigger" recebe `PathfindingModifier` com `PassThrough = true`.
- [ ] Parte com tag `NavSolid` **nunca** recebe modifier, mesmo invisível e com nome suspeito.
- [ ] `Geometry.audit()` lista invisíveis colidíveis não classificadas.
- [ ] Remover uma parte do workspace decrementa a lista e incrementa a versão.
- [ ] Desligar `Geometry.AutoFilter` nas opções não deixa efeito residual no mapa.

```text
PROMPT — FASE 1

Continue a biblioteca SmartPath. Execute APENAS a Fase 1 do plano de execução.

1) Scheduler: fila global de cálculos de rota com orçamento por frame (default: 4 cálculos
   por frame, configurável), prioridade numérica, cancelamento por handle e coalescência
   (dois pedidos com a mesma chave pendentes = um cálculo, ambos recebem o resultado).
   API sugerida: Scheduler.submit(key, priority, fn) -> handle; handle:cancel().

2) Geometry: use a Seção 5 da ESPEC_NAVEGACAO_ROBLOX.md como base, com estas mudanças:
   - precisa ser desligável por opção, sem deixar resíduo no mapa;
   - expõe Geometry.getVersion(), Geometry.Changed, Geometry.buildRaycastParams(extra),
     Geometry.audit();
   - tags NavSolid têm precedência absoluta sobre tudo.

Não toque em nenhum outro módulo. Rode os critérios de aceite da Fase 1 e me entregue o
relatório. Liste no BACKLOG.md qualquer ideia que tenha surgido e não faça parte desta fase.
```

---

### FASE 2 — RouteSolver: o coração do problema "ambiente fechado"

**Objetivo:** transformar `NoPath` em rota utilizável.

**Algoritmo da escada adaptativa:**

1. Normalizar origem: ponto do chão sob o root + offset. Se o agente estiver no ar, aguardar aterrar (limite de ~1,5 s).
2. Normalizar destino: se cair dentro de geometria ou no ar, projetar para o chão mais próximo; se falhar, `goal_unreachable` com `nearestValid`.
3. Tentar `ComputeAsync` com o raio configurado.
4. Se falhar, repetir com cada valor de `RadiusSteps` (1.5 → 1.0 → 0.5), parando no primeiro sucesso.
5. **Validar a rota obtida com raio reduzido**: `Spherecast` no raio **real** ao longo de cada segmento. Se o corpo couber, aceita. Se não couber em algum segmento, registra `requiredRadius` e tenta o próximo passo da escada.
6. Se ainda falhar, tentar com `AgentCanJump = false` (às vezes destrava malhas estranhas) e depois com destino aproximado.
7. Se tudo falhar, devolver o erro diagnóstico mais específico possível.

**Entregas:** `RouteSolver`, `RouteCache`, `Simplifier` integrados ao `Scheduler`.

**Critérios de aceite:**
- [ ] Corredor de 4 studs com agente de raio 2: `PathfindingService` puro dá `NoPath`; SmartPath devolve rota atravessável.
- [ ] Corredor de 1 stud (impossível): devolve `corridor_too_narrow` com `requiredRadius`, e **não** devolve rota falsa.
- [ ] Mesma origem/destino 20 vezes: waypoints idênticos (cache + determinismo).
- [ ] String pulling nunca corta por cima de um buraco (cenário com vão no chão).
- [ ] Waypoints com `Action ≠ Walk` nunca são removidos.
- [ ] Destino dentro de uma parede: `goal_unreachable` com `nearestValid` utilizável.

```text
PROMPT — FASE 2

Continue a SmartPath. Execute APENAS a Fase 2: RouteCache, Simplifier e RouteSolver.

Base: Seção 3 da ESPEC_NAVEGACAO_ROBLOX.md (cache por célula, string pulling com validação
de volume E de chão contínuo, histerese) MAIS o algoritmo da escada de raio adaptativo
descrito na Fase 2 do plano de execução.

Pontos críticos que não podem ser esquecidos:
- Origem sempre aterrada; nunca calcular com o agente no ar.
- Toda rota obtida com raio reduzido PRECISA ser validada com Spherecast no raio real; sem
  essa validação a lib passa a recomendar rotas onde o personagem não cabe, que é pior que
  o NoPath original.
- Todo ComputeAsync passa pelo Scheduler da Fase 1.
- Erros seguem exatamente os códigos da Seção 3.7 do plano, com details preenchidos.

Rode os critérios de aceite da Fase 2 e entregue o relatório.
```

---

### FASE 3 — Predictor e JumpExecutor

**Objetivo:** resolver o "não pula mesmo podendo".

**Entregas:** `Predictor` (as 7 etapas da Seção 4 da especificação técnica: parede no joelho → alto demais → topo → profundidade e pouso → corredor aéreo → balística → distância de decolagem); `JumpExecutor` (modos `Native` e `Injected`, com restauração garantida das propriedades do Humanoid).

**Critérios de aceite:**
- [ ] Mureta de 3 studs com `JumpHeight` 7.2: `Predictor` retorna plano válido.
- [ ] Mureta de 9 studs: retorna `nil, "too_tall"`.
- [ ] Mureta de 3 studs e 6 de profundidade a `WalkSpeed` 16: `nil, "too_deep"`.
- [ ] Abismo atrás da mureta: `nil, "no_landing"`.
- [ ] Teto baixo sobre a mureta: `nil, "ceiling"` ou `"air_blocked"`.
- [ ] Com `JumpHeight = 30`, obstáculo de 20 studs vira plano válido (o `PathfindingService` puro jamais subiria lá — este é o cenário-vitrine da biblioteca).
- [ ] Após qualquer salto, `JumpHeight`/`JumpPower` voltam **exatamente** ao valor original, inclusive se o personagem morrer no ar.
- [ ] Modo `Injected` nunca reduz a velocidade horizontal existente.

```text
PROMPT — FASE 3

Continue a SmartPath. Execute APENAS a Fase 3: Predictor e JumpExecutor.

Base: Seções 4 e 6 da ESPEC_NAVEGACAO_ROBLOX.md. Implemente as 7 etapas da análise
(parede no joelho, teste de altura excessiva, localização do topo com múltiplos insets,
varredura de profundidade e ponto de pouso, corredor aéreo para pés e cabeça, balística
com tUp/tDown, distância de decolagem) e os dois modos de execução.

Requisitos adicionais desta fase:
- O Predictor deve funcionar com QUALQUER JumpHeight, inclusive valores altos como 30. O
  diferencial da biblioteca é justamente usar a capacidade real do humanoid, que a engine
  ignora.
- A restauração das propriedades do Humanoid precisa ser à prova de falha: morte no ar,
  personagem removido, dois saltos encadeados. Teste esses três casos.
- Todo retorno negativo traz o motivo em string, para virar diagnóstico depois.

Rode os critérios de aceite da Fase 3 e entregue o relatório.
```

---

### FASE 4 — Agent (nível 1)

**Objetivo:** juntar tudo numa máquina de estados confiável.

**Entregas:** `Agent` com os estados `Idle`/`Following`/`DirectJump`/`Airborne`/`Failed`, seguimento por `Humanoid:Move`, sonda reativa de salto, atalho por salto com validação pós-pouso, anti-stuck escalonado, tratamento de `Blocked`, eventos, `SetSuspended`, `Destroy` limpo, `SetNetworkOwner(nil)` para NPC no servidor.

**Critérios de aceite:**
- [ ] NPC atravessa um percurso com corredor estreito, mureta e rampa sem intervenção.
- [ ] Destino trocado no meio do cálculo: usa o novo, sem rota fantasma.
- [ ] Parte surge sobre a rota: `Blocked` → replan → conclui.
- [ ] Agente encurralado: salto de escape → replan → `Failed("stuck")` após 3 tentativas.
- [ ] `SetSuspended(true)` para o movimento sem perder a rota; `false` retoma no waypoint certo.
- [ ] `Destroy()` com 20 agentes: zero conexões remanescentes (verificar com `getconnections` no Studio ou contagem manual).
- [ ] Nenhum `Humanoid:MoveTo` no código (evita o timeout de 8 s).
- [ ] Funciona igual num NPC no servidor e no personagem do jogador no cliente.

```text
PROMPT — FASE 4

Continue a SmartPath. Execute APENAS a Fase 4: o módulo Agent (nível 1 da API).

Base: Seção 7 da ESPEC_NAVEGACAO_ROBLOX.md, adaptada ao contrato da Seção 3.2 do plano
(nomes de métodos e sinais exatamente como especificado, incluindo :Await(), :GetRoute(),
:SetOptions() e o sinal Jumped).

Atenção especial:
- Durante TODO o voo o agente continua chamando Humanoid:Move na direção do pouso. Parar de
  chamar Move é a causa nº 1 de "cair antes do obstáculo".
- Nunca use Humanoid:MoveTo (timeout de 8 s).
- NPC no servidor: SetNetworkOwner(nil) dentro de pcall.
- Destroy precisa desconectar tudo. Teste criando e destruindo 20 agentes em sequência.

Rode os critérios de aceite da Fase 4 e entregue o relatório.
```

---

### FASE 5 — Fachada e camada de compatibilidade

**Objetivo:** tornar a biblioteca adotável em uma linha.

**Entregas:** `init` com `MoveTo`/`MoveToAsync`/`GetRoute` funcionando de verdade; `Compat` com `SmartPath.Service:CreatePath` espelhando a API oficial e acrescentando `SmartStatus`/`SmartDetails`.

**Critérios de aceite:**
- [ ] `SmartPath.MoveTo(humanoid, part)` funciona sem tabela de opções.
- [ ] Aceita `Vector3`, `BasePart` e `Model` como destino.
- [ ] Destino `BasePart` em movimento: o agente persegue (recalcula quando o alvo se desloca além de um limiar).
- [ ] Um script existente que use `PathfindingService` passa a funcionar trocando só a linha do `require`, sem nenhuma outra mudança.
- [ ] `path.Status` devolve `Enum.PathStatus` válido em todos os casos, inclusive quando a SmartPath achou rota que a engine não acharia.
- [ ] Chamada em loop apertado (10 por segundo) não trava o jogo — o Scheduler segura.

```text
PROMPT — FASE 5

Continue a SmartPath. Execute APENAS a Fase 5: fachada (init) e camada de compatibilidade
(Compat / SmartPath.Service).

Contrato: Seções 3.1, 3.4 e 3.6 do plano de execução, ao pé da letra.

O teste que define esta fase: pegue um script qualquer que use PathfindingService com o
padrão clássico (CreatePath, ComputeAsync, GetWaypoints, loop com MoveTo e Jump) e faça com
que ele funcione trocando APENAS a linha do require. Escreva esse script de teste e
demonstre o antes e o depois.

Rode os critérios de aceite da Fase 5 e entregue o relatório.
```

---

### FASE 6 — Diagnóstico e debug visual

**Objetivo:** o recurso que faz um dev recomendar a lib para outro.

**Entregas:** todos os erros com `details` preenchidos; visualização (waypoints coloridos por ação, ponto de decolagem e de pouso, obstáculo detectado, raio efetivo usado); `SmartPath.explain(reason, details)` devolvendo frase legível; painel de debug opcional na tela com estado, rota, tempo de cálculo e fila do Scheduler.

**Critérios de aceite:**
- [ ] Cada um dos 10 códigos de erro é produzido por um cenário reproduzível no place de teste.
- [ ] `explain("corridor_too_narrow", d)` gera algo como: "O corredor exige raio 0.8, mas o agente tem 2.0. Reduza AgentRadius ou alargue a passagem."
- [ ] Debug desligado: zero instâncias criadas, zero prints, zero custo mensurável.
- [ ] Debug ligado: todas as partes de debug com `CanCollide = false` e `CanQuery = false` (não podem poluir os próprios raycasts da lib).

```text
PROMPT — FASE 6

Continue a SmartPath. Execute APENAS a Fase 6: diagnóstico e debug visual.

- Garanta que os 10 códigos da Seção 3.7 do plano são realmente emitidos, com details úteis.
- Implemente SmartPath.explain(reason, details) -> string legível para humanos.
- Implemente a visualização: waypoints coloridos por ação, decolagem, pouso, obstáculo
  detectado e raio efetivo usado na rota.
- Implemente um painel opcional (ScreenGui) com estado do agente, tamanho da fila do
  Scheduler e tempo do último cálculo.
- Com Debug = false, a biblioteca não pode criar NENHUMA instância nem imprimir nada.
- Toda parte de debug: CanCollide = false e CanQuery = false, e excluída dos RaycastParams.

Crie um cenário reproduzível para CADA código de erro e me mostre a lista com o nome de
cada cenário. Rode os critérios de aceite e entregue o relatório.
```

---

### FASE 7 — Place de demonstração

**Objetivo:** o artefato que vende a biblioteca. Comparação lado a lado, mesma geometria, dois NPCs.

**Cenários obrigatórios (à esquerda `PathfindingService` puro, à direita SmartPath):**

1. Corredor de 4 studs.
2. Sala com porta estreita e mobília.
3. Mureta de 3 studs com desvio longo de 30 studs.
4. Plataforma de 18 studs com `JumpHeight = 25`.
5. Labirinto interno com trigger invisível colidível na passagem.
6. Parede invisível de limite de mapa (tag `NavSolid`) — a SmartPath **respeita**.
7. Obstáculo dinâmico caindo sobre a rota.
8. 20 NPCs simultâneos (comparativo de desempenho).

**Entregas:** place com a geometria, botões de reiniciar por cenário, contador de sucesso/falha, HUD com FPS e fila do Scheduler.

**Critérios de aceite:**
- [ ] Em 1 a 5, o NPC da esquerda falha ou dá volta absurda; o da direita conclui.
- [ ] No 6, **os dois** respeitam a parede (se a SmartPath atravessar, é bug grave).
- [ ] No 7, a SmartPath replaneja e conclui.
- [ ] No 8, a SmartPath não fica pior que o baseline em FPS.
- [ ] Cada cenário reinicia limpo, sem estado residual.

```text
PROMPT — FASE 7

Continue a SmartPath. Execute APENAS a Fase 7: o place de demonstração.

Monte os 8 cenários listados na Fase 7 do plano, cada um com DOIS NPCs idênticos sobre
geometria idêntica: à esquerda usando PathfindingService puro (implementação clássica), à
direita usando SmartPath. Inclua botões de reiniciar por cenário, contador de sucesso/falha
e um HUD com FPS e tamanho da fila do Scheduler.

O cenário 6 (parede invisível com tag NavSolid) é um teste de segurança: se a SmartPath
atravessar, isso é um bug crítico, não um recurso. Verifique explicitamente.

Rode os critérios de aceite da Fase 7 e me diga, cenário a cenário, o resultado dos dois
lados.
```

---

### FASE 8 — Endurecimento

**Objetivo:** o que separa "funciona no meu place" de "biblioteca".

**Checklist de casos-limite a cobrir:**

- Personagem morre durante a rota / no ar.
- Personagem removido (`Destroy`) com agente ativo.
- `WalkSpeed = 0`, `JumpHeight = 0`, `UseJumpPower = true`.
- Rig R6 e R15.
- Destino igual à posição atual.
- Destino a 5.000 studs.
- Mapa sem nenhum chão sob o agente (queda infinita).
- `workspace.Gravity` alterado pelo jogo.
- Dois agentes no mesmo personagem (deve haver erro claro ou reaproveitamento).
- `MoveTo` chamado dentro do handler de `Reached` (reentrância).
- Jogo com `StreamingEnabled` (geometria ainda não carregada).
- Personagem dentro de veículo/`Seated`.

**Critérios de aceite:**
- [ ] Nenhum dos casos acima gera erro não tratado no Output.
- [ ] Cada um devolve erro com código conhecido ou se comporta de forma documentada.
- [ ] Teste de vazamento: criar e destruir 500 agentes; memória estável.
- [ ] Rodar 10 minutos com 20 NPCs sem crescimento de memória.

```text
PROMPT — FASE 8

Continue a SmartPath. Execute APENAS a Fase 8: endurecimento.

Percorra a checklist de casos-limite da Fase 8 do plano de execução, um por um. Para cada
caso: escreva um teste reproduzível, rode, corrija o que quebrar e registre o comportamento
final na documentação.

Faça também o teste de vazamento: criar e destruir 500 agentes e verificar memória estável;
depois 20 NPCs ativos por 10 minutos.

Me entregue a tabela: caso-limite | comportamento antes | correção aplicada | comportamento
agora.
```

---

### FASE 9 — Documentação e publicação

**Entregas:**

- `README.md`: o problema em 3 linhas, GIF do antes/depois, instalação, exemplo de 3 linhas, tabela de opções, tabela de erros, limitações honestas.
- Documentação de API completa (Moonwave ou markdown simples).
- `CHANGELOG.md` com a 1.0.0.
- `wally.toml` + `default.project.json` (Rojo) + repositório GitHub.
- Modelo publicado no Creator Store, com o place de demonstração público.
- Post no DevForum (categoria Community Resources) com GIFs dos cenários.

**Critérios de aceite:**
- [ ] Alguém que nunca viu a lib instala e faz um NPC andar em menos de 5 minutos só com o README.
- [ ] Todas as funções públicas documentadas com parâmetros, retorno e um exemplo.
- [ ] Limitações listadas explicitamente (o que a lib **não** faz — Seção 2.2).
- [ ] Versão semântica marcada em tag no Git.

```text
PROMPT — FASE 9

Continue a SmartPath. Execute APENAS a Fase 9: documentação e empacotamento.

Produza README.md (problema, antes/depois, instalação, exemplo de 3 linhas, tabela de
opções, tabela de erros, limitações honestas), documentação completa da API pública,
CHANGELOG 1.0.0, wally.toml e default.project.json para Rojo, e o rascunho do post de
DevForum para Community Resources.

Regra de honestidade: a seção de limitações precisa listar o que a biblioteca NÃO faz
(Seção 2.2 do plano). Biblioteca que promete demais queima reputação no primeiro bug.

O teste desta fase: um desenvolvedor que nunca viu o projeto consegue, só com o README,
instalar e mover um NPC em menos de 5 minutos.
```

---

### FASE 10 — v2: gerador de links (backlog)

**Não implementar na v1.** Registrado para não se perder: varredura do mapa por bordas e desníveis, teste de alcançabilidade por par (origem, destino) com o perfil de salto real, geração de `PathfindingLink` com `Label`. Com isso o próprio `PathfindingService` passa a escolher saltos sozinho, o que é mais barato em runtime que a predição. É a peça mais valiosa e mais trabalhosa do projeto — merece um ciclo próprio.

---

## 7. ORDEM DE DEPENDÊNCIAS

```
Fase 0 (fundação)
   ├── Fase 1 (Scheduler, Geometry)
   │        └── Fase 2 (RouteSolver, Cache, Simplifier)
   │                 └── Fase 4 (Agent) ── Fase 5 (fachada/compat)
   └── Fase 3 (Predictor, JumpExecutor) ──┘
                                            └── Fase 6 (diagnóstico)
                                                     └── Fase 7 (demo)
                                                              └── Fase 8 (endurecimento)
                                                                       └── Fase 9 (publicação)
```

As Fases 1 e 3 são independentes entre si e podem ser feitas em qualquer ordem.

---

## 8. COMO VALIDAR CADA ENTREGA (roteiro do Victor)

1. Peça o relatório da regra 12 (o que ficou parcial).
2. Rode os critérios de aceite da fase **você mesmo**, no Play mode. Não aceite "testei e funciona" sem ver.
3. Abra dois ou três módulos ao acaso e procure por: `print` solto, número mágico sem comentário, conexão sem desconexão, `wait()` (deve ser `task.wait()`).
4. Pergunte: *"que suposição você fez que, se estiver errada, quebra esta fase?"*
5. Só então libere a fase seguinte.

---

## 9. REGISTRO DE DECISÕES (`DECISIONS.md`)

Formato de cada entrada:

```markdown
## D-001 — Origem não é parâmetro da API
Data: AAAA-MM-DD
Contexto: a assinatura natural seria (startPos, goalPos).
Decisão: receber Humanoid/Model e derivar a origem internamente.
Motivo: do humanoid extraímos posição aterrada, JumpHeight real, WalkSpeed e rig — exatamente
a informação que falta ao PathfindingService. Um Vector3 não carrega nada disso.
Consequência: quem só tem coordenadas usa a camada de compatibilidade.
```

Decisões já tomadas, a registrar na Fase 0: **D-001** (acima), **D-002** rota com raio reduzido exige validação por `Spherecast` no raio real, **D-003** sem dependências externas na v1, **D-004** o baker de links fica para a v2, **D-005** a biblioteca nunca altera propriedades do mapa do usuário.

---

## 10. RISCOS

| Risco | Sinal de alerta | Mitigação |
|---|---|---|
| Escopo infla e a v1 nunca sai | agente propondo recursos fora da Seção 2.1 | `BACKLOG.md` é obrigatório; nada fora do escopo entra |
| Rota com raio reduzido onde o corpo não cabe | NPC travando em batente | validação por `Spherecast` (D-002), critério de aceite da Fase 2 |
| Custo de CPU com muitos agentes | queda de FPS no cenário 8 | Scheduler com orçamento; `ProbeInterval` maior para agentes distantes |
| Engine muda e a camada de compatibilidade quebra | erro após atualização do Studio | testes do place de demo rodados a cada release |
| Manutenção de longo prazo | issues acumulando | decidir desde já: portfólio (lança e documenta) ou produto (mantém) |
