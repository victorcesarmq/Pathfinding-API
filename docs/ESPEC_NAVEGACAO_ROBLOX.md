# ESPECIFICAÇÃO TÉCNICA — Sistema de Navegação de Entidades (Roblox / Luau)

> **Documento destinado a uma IA implementadora.** Contém: base técnica, correções de diagnóstico, arquitetura, contratos de API, algoritmos, código de referência completo, plano de testes e pontos que DEVEM ser validados empiricamente no Roblox Studio.

---

## 0. INSTRUÇÕES PARA A IA IMPLEMENTADORA (LEIA PRIMEIRO)

1. **Implemente TODOS os módulos da Seção 2**, na ordem: `NavConfig` → `NavUtil` → `GeometryFilter` → `RouteCache` → `PathSimplifier` → `JumpPredictor` → `JumpExecutor` → `NavLinks` → `NavigationAgent`.
2. O código de referência abaixo é **ponto de partida funcional**, não dogma. Se encontrar erro de API, corrija e **registre a correção em comentário** (`-- FIX: ...`).
3. **Não invente APIs.** Toda chamada usada aqui existe na API do Roblox (`PathfindingService:CreatePath`, `Path:ComputeAsync`, `Path:GetWaypoints`, `Path.Blocked`, `PathfindingModifier`, `PathfindingLink`, `WorldRoot:Raycast/Spherecast`, `RaycastParams`, `Humanoid:Move`, `Humanoid:ChangeState`, `BasePart:SetNetworkOwner`, `BasePart.AssemblyLinearVelocity`). Se precisar de algo fora desta lista, confirme na documentação oficial (create.roblox.com/docs) antes.
4. O projeto de destino já possui um **LocalScript único em `StarterPlayerScripts`** chamado *Path Recorder & Replayer* (grava rota com pulo/dash em JSON e reproduz com `PathfindingService` + `Humanoid:Move`, com anti-stuck, pulo de escape, look-ahead pós-dash e esferas de debug; o jogo tem dash na tecla **Q**). **Leia esse script antes de integrar.** Regras de integração na Seção 9.
5. O sistema deve funcionar **tanto no cliente** (personagem do jogador, LocalScript) **quanto no servidor** (NPC, Script). Diferenças na Seção 9.3.
6. Toda afirmação marcada com **[VALIDAR]** é comportamento interno da engine que não é 100% documentado — teste no Studio com o modo debug ligado e ajuste constantes.
7. Entregue ao final: os ModuleScripts, um script de exemplo de uso, e a checklist de testes da Seção 10 preenchida.

---

## 1. BASE TÉCNICA: COMO O PATHFINDINGSERVICE FUNCIONA

### 1.1 Pipeline interno (resumo)

1. **Voxelização/navmesh**: a engine converte a geometria **colidível** (`CanCollide = true`) do mundo em uma malha de navegação, a partir de uma grade de voxels (resolução grossa, da ordem de 4 studs) **[VALIDAR resolução exata]**. Partes com `CanCollide = false` são ignoradas pelo pathfinding. **Transparency não importa**: uma parte invisível colidível é tão parede quanto uma visível.
2. **Parâmetros do agente** (passados em `CreatePath`):
   - `AgentRadius`: "infla" os obstáculos. Portas/corredores mais estreitos que ~`2 × AgentRadius` (+ folga da resolução de voxel) somem da malha → `NoPath` em ambientes indoor.
   - `AgentHeight`: exige espaço vertical livre (teto baixo = não navegável).
   - `AgentCanJump`: permite arestas que exigem subir desníveis; gera waypoints com `Action = Jump`. O limite de altura usado é **interno e fixo — não lê o `JumpHeight`/`JumpPower` do seu Humanoid** **[VALIDAR]**.
   - `WaypointSpacing`: distância entre waypoints ao longo da rota. `math.huge` = somente waypoints essenciais (curvas e ações). **Isso é um estabilizador importante.**
   - `Costs`: tabela `{[NomeDoMaterial ou Label] = custo}`. Permite penalizar/privilegiar materiais, `PathfindingModifier.Label` e `PathfindingLink.Label`.
3. **Busca**: algoritmo de menor custo (família A*) sobre a malha → sequência de `PathWaypoint { Position, Action, Label }`.
4. **Invalidação dinâmica**: quando geometria muda sobre a rota calculada, `Path.Blocked(índiceDoWaypoint)` dispara (apenas para a última rota calculada daquele objeto `Path`).
5. **Ferramentas de level design nativas**:
   - `PathfindingModifier` (filho de uma BasePart/Model): `Label` (para custos) e **`PassThrough = true`** (o volume é tratado como atravessável — solução nativa para geometrias invisíveis).
   - `PathfindingLink` (entre `Attachment0` e `Attachment1`): cria uma aresta manual (ex.: salto sobre mureta, porta, teleporte). O waypoint resultante vem com `Action = Custom` e `Label = link.Label`.

### 1.2 Correções ao diagnóstico do relatório original

| Afirmação original | Correção técnica | Consequência de projeto |
|---|---|---|
| "ComputeAsync gera rotas divergentes por amostragem dinâmica / dispersão vetorial" | Para **entradas idênticas e mundo estático**, o resultado é essencialmente estável. A variação real vem de: (a) **origem diferente a cada chamada** (posição do root oscila com animação, agente no ar durante pulo), (b) `WaypointSpacing` pequeno gerando muitos pontos intermediários, (c) geometria dinâmica (portas, partes soltas, outros personagens se colidíveis) alterando a malha, (d) replanejamento frequente sem histerese. | Estabilizar = **normalizar a entrada** (origem aterrada, não calcular no ar), **cache por célula**, **suavização determinística** e **histerese** na troca de rota. |
| "Gerador não prevê balística do salto" | Correto em essência: a malha não conhece o `JumpHeight` real do agente e muretas finas/baixas podem ser tratadas como parede. | Camada própria de **predição de salto** + `PathfindingLink` para muretas conhecidas. |
| "Partes invisíveis poluem a malha de **raycasting** do serviço" | O pathfinding **não usa raycast**; usa voxelização. Porém partes invisíveis colidíveis poluem **ambos**: a navmesh E os raycasts do nosso próprio código (predição/suavização). | Duas correções distintas: `PathfindingModifier.PassThrough` (navmesh) e `RaycastParams` filtrado (raycasts). |

### 1.3 Fatos de física necessários

- Gravidade: `workspace.Gravity` (padrão **196.2** studs/s²).
- Altura máxima de salto: `JumpHeight` (se `UseJumpPower = false`, padrão 7.2) ou `JumpPower² / (2g)` (se `UseJumpPower = true`, padrão 50 → ~6.37).
- Velocidade vertical para atingir altura `h`: `v = √(2·g·h)`.
- Altura no tempo `t`: `y(t) = v·t − g·t²/2`. Tempos em que `y = H`: `t = (v ∓ √(v² − 2gH)) / g`.
- **No ar, o Humanoid continua controlando a velocidade horizontal em direção a `MoveDirection · WalkSpeed`.** Se o código parar de chamar `Humanoid:Move(dir)` durante o voo, o personagem perde velocidade horizontal e **cai antes do obstáculo**. Esta é a principal causa de "perda de momento".
- Física é simulada pelo **dono da rede** (network owner). Personagem do jogador = cliente. NPC = servidor só se `root:SetNetworkOwner(nil)`; caso contrário a engine pode passar a posse a um cliente próximo e o NPC "engasga" ao pular.
- Raycasts/shapecasts **não detectam a parte dentro da qual começam**. Origem de raios deve estar fora da geometria.

---

## 2. ARQUITETURA

### 2.1 Estrutura de arquivos

```
ReplicatedStorage/
  NavSystem/                (Folder)
    NavConfig        (ModuleScript)  constantes + merge
    NavUtil          (ModuleScript)  utilidades geométricas, físicas e debug
    GeometryFilter   (ModuleScript)  detecção/neutralização de geometria invisível
    RouteCache       (ModuleScript)  cache de rotas por célula
    PathSimplifier   (ModuleScript)  deduplicação + string pulling seguro
    JumpPredictor    (ModuleScript)  análise preditiva de obstáculo saltável
    JumpExecutor     (ModuleScript)  execução do salto (nativo ou injetado)
    NavLinks         (ModuleScript)  helpers para PathfindingLink de level design
    NavigationAgent  (ModuleScript)  orquestrador / máquina de estados
```

### 2.2 Fluxo

```
MoveTo(goal)
   │
   ▼
_plan()  ── espera aterrar ── origem aterrada ── RouteCache.get ──(miss)── ComputeAsync
   │                                                        │
   │                                               PathSimplifier.simplify
   │                                                        │
   │                                               RouteCache.put
   ▼
_adoptRoute()  ── histerese (mantém rota atual se a nova não for ≥15% melhor)
   │
   ├── rota com desvio grande? ── JumpPredictor(goal) ── valida pós-pouso ── estado DirectJump
   ▼
Heartbeat _step()
   ├─ Following : Move(dir) → waypoint; ações Jump/Custom; sonda de salto por segmento; anti-stuck
   ├─ DirectJump: Move(dir fixo) → no ponto de decolagem → JumpExecutor
   └─ Airborne  : Move(dir) contínuo até pousar → reindexa rota
```

### 2.3 Máquina de estados do agente

| Estado | Entra quando | Sai quando |
|---|---|---|
| `Idle` | criado / `Stop()` / chegou | `MoveTo()` |
| `Following` | rota adotada / pousou | chegou (`Idle`), salto (`Airborne`), atalho (`DirectJump`), falha (`Failed`) |
| `DirectJump` | predição validou atalho por salto | decolou (`Airborne`) ou abortou (`Following` + replan forçado) |
| `Airborne` | qualquer salto executado | pousou (`Following`) ou excedeu `MaxAirTime` (replan forçado) |
| `Failed` | sem rota e sem salto possível / stuck persistente | `MoveTo()` |

---

## 3. PROBLEMA 1 — ESTABILIZAÇÃO E CONSISTÊNCIA DE ROTAS

### 3.1 Lógica

Cinco mecanismos, todos necessários:

1. **Origem normalizada**: nunca calcule com o agente no ar; use o ponto do chão sob o root (+ offset fixo). Remove a oscilação vertical de animação/pulo da entrada.
2. **`WaypointSpacing = math.huge`**: só pontos essenciais → menos pontos para "tremer".
3. **Cache por célula**: chave = (origem quantizada, destino quantizado). Mesmas células → **exatamente a mesma lista de waypoints** (determinismo garantido por construção, não por torcer pela engine). Invalida por TTL, por `Path.Blocked`, por mudança de versão do `GeometryFilter` e por anti-stuck.
4. **String pulling seguro**: remove waypoints intermediários quando há linha livre (spherecast no volume do agente) **e** chão contínuo (amostragem de raios para baixo — evita "cortar caminho" por cima de buracos). Nunca remove waypoints com `Action ≠ Walk`.
5. **Histerese**: uma rota nova só substitui a atual se for pelo menos `ReplanImprovementRatio` (15%) mais curta — exceto em replan forçado (bloqueio, stuck, destino novo). Elimina a troca de lado que gera o zigue-zague lateral.

### 3.2 Código — `NavConfig`

```lua
-- NavConfig (ModuleScript)
-- Todas as constantes do sistema. Ajuste aqui, nunca espalhe números mágicos pelo código.
local NavConfig = {}

NavConfig.Defaults = {
	Agent = {
		Radius = 2,                  -- raio real do personagem (R15 ≈ 1.5–2). Grande demais fecha portas indoor.
		Height = 5,
		CanJump = true,
		CanClimb = false,
		WaypointSpacing = math.huge, -- somente waypoints essenciais (estabilidade)
	},
	Costs = {
		JumpLink = 1,                -- custo dos PathfindingLinks de salto (ver NavLinks)
	},
	Links = {
		JumpLabel = "JumpLink",      -- Label de PathfindingLink tratado como salto
	},
	Cache = {
		CellSize = 2,                -- quantização (studs) da origem/destino
		TTL = 15,                    -- segundos
		MaxEntries = 128,
	},
	Stabilizer = {
		ReplanImprovementRatio = 0.15,
		MinReplanInterval = 0.5,
		SmoothingProbeRadius = 1.2,  -- raio da esfera do string pulling (≈ 0.6 × AgentRadius)
		SmoothingProbeHeight = 2.5,  -- altura acima do chão onde a esfera viaja
		FloorSampleStep = 2,
		MaxFloorDelta = 1.2,         -- variação máx. de altura do piso num atalho
		GroundProbeUp = 2,
		StartHeightOffset = 1,       -- origem = chão + este offset
		MaxGroundedWait = 1.5,       -- espera máx. para aterrar antes de calcular
	},
	Jump = {
		Mode = "Native",             -- "Native" (recomendado) | "Injected"
		ProbeInterval = 0.1,         -- frequência da sonda por segmento
		ProbeDistance = 10,
		MinTargetDistance = 1.5,
		MinObstacleHeight = 1.2,     -- abaixo disso o Humanoid sobe sozinho (degrau) [VALIDAR]
		MaxWallNormalY = 0.35,       -- |normal.Y| acima disso = rampa, não parede
		HeightSafetyMargin = 0.4,
		TopProbeClearance = 1,
		TopProbeInsets = { 0.3, 0.12, 0.04 }, -- tentativas de "entrar" no topo (paredes finas)
		LandingScanStep = 0.5,
		LandingSearchMax = 8,        -- profundidade máx. analisada do obstáculo
		LandingMargin = 1,
		MaxSafeDrop = 14,            -- queda máxima aceitável após o obstáculo
		AirClearance = 0.5,          -- folga entre pés e topo do obstáculo
		ApexExtra = 0.6,             -- altura extra acima do necessário
		TakeoffMargin = 0.4,
		DetourRatioThreshold = 1.4,  -- rota/linha reta acima disso → considerar salto direto
		MinGainRatio = 0.2,          -- salto precisa encurtar ≥ 20% o trajeto total
		Cooldown = 0.35,
		MinAirTime = 0.15,
		MaxAirTime = 3,
		DirectTimeout = 4,
	},
	Geometry = {
		IgnoreTag = "NavIgnore",     -- CollectionService: força atravessável
		SolidTag = "NavSolid",       -- CollectionService: força sólido (paredes invisíveis de limite de mapa)
		AutoDetect = true,
		RequireNameMatch = true,     -- auto-detecção exige nome suspeito (seguro por padrão)
		InvisibleThreshold = 0.95,
		NamePatterns = { "zone", "trigger", "hitbox", "region", "bounds", "sensor", "detector", "area" },
		ModifierName = "NavAutoPassThrough",
		ModifierLabel = "NavIgnored",
	},
	Follow = {
		ArriveRadius = 1.25,
		StuckTime = 1.0,
		StuckMinProgress = 0.6,
		MaxStuckStrikes = 3,
	},
	Debug = {
		Enabled = false,
		Lifetime = 6,
	},
}

-- merge profundo: dicionários são mesclados, arrays são substituídos inteiros
local function deepMerge(base, over)
	local out = {}
	for k, v in pairs(base) do
		local o = over and over[k]
		if type(v) == "table" and type(o) == "table" and #v == 0 then
			out[k] = deepMerge(v, o)
		elseif o ~= nil then
			out[k] = o
		elseif type(v) == "table" then
			out[k] = table.clone(v)
		else
			out[k] = v
		end
	end
	if over then
		for k, v in pairs(over) do
			if out[k] == nil then out[k] = v end
		end
	end
	return out
end

function NavConfig.merge(overrides)
	return deepMerge(NavConfig.Defaults, overrides)
end

return NavConfig
```

### 3.3 Código — `NavUtil`

```lua
-- NavUtil (ModuleScript)
local Debris = game:GetService("Debris")

local NavUtil = {}
local UP = Vector3.yAxis

function NavUtil.flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Y dos pés. R15: root - meia altura do root - HipHeight. R6: pernas de 2 studs.
function NavUtil.getFeetY(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return root.Position.Y - root.Size.Y / 2 - humanoid.HipHeight
	end
	return root.Position.Y - root.Size.Y / 2 - 2
end

function NavUtil.getMaxJumpHeight(humanoid: Humanoid): number
	if humanoid.UseJumpPower then
		return (humanoid.JumpPower ^ 2) / (2 * workspace.Gravity)
	end
	return humanoid.JumpHeight
end

function NavUtil.velocityForHeight(h: number): number
	return math.sqrt(2 * workspace.Gravity * math.max(h, 0))
end

function NavUtil.groundBelow(pos: Vector3, maxDist: number, params: RaycastParams): RaycastResult?
	return workspace:Raycast(pos, -UP * maxDist, params)
end

-- comprimento da rota a partir de `fromPos`, começando no waypoint `startIndex`
function NavUtil.pathLength(wps, fromPos: Vector3, startIndex: number?): number
	local i0 = startIndex or 1
	if not wps[i0] then return 0 end
	local total = (wps[i0].Position - fromPos).Magnitude
	for i = i0 + 1, #wps do
		total += (wps[i].Position - wps[i - 1].Position).Magnitude
	end
	return total
end

-- ===== Debug visual =====
local debugFolder: Folder? = nil
function NavUtil.getDebugFolder(): Folder
	if debugFolder and debugFolder.Parent then return debugFolder end
	local f = Instance.new("Folder")
	f.Name = "NavDebug"
	f.Parent = workspace
	debugFolder = f
	return f
end

function NavUtil.drawPoint(pos: Vector3, color: Color3, size: number?, lifetime: number?)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.one * (size or 0.6)
	p.Anchored = true
	p.CanCollide = false   -- invisível para pathfinding e raycasts com RespectCanCollide
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Position = pos
	p.Parent = NavUtil.getDebugFolder()
	Debris:AddItem(p, lifetime or 6)
end

function NavUtil.drawRoute(wps, lifetime: number?)
	for _, wp in ipairs(wps) do
		local c = Color3.fromRGB(80, 200, 255)                      -- Walk: azul
		if wp.Action == Enum.PathWaypointAction.Jump then c = Color3.fromRGB(255, 200, 0) end   -- Jump: amarelo
		if wp.Action == Enum.PathWaypointAction.Custom then c = Color3.fromRGB(255, 0, 200) end -- Custom: magenta
		NavUtil.drawPoint(wp.Position, c, 0.6, lifetime)
	end
end

return NavUtil
```

### 3.4 Código — `RouteCache`

```lua
-- RouteCache (ModuleScript)
-- Garante determinismo: mesmas células de origem/destino → mesma lista de waypoints.
-- As listas armazenadas são IMUTÁVEIS (tabelas congeladas). Quem consome não pode modificá-las.
local RouteCache = {}
RouteCache.__index = RouteCache

local function quantize(v: Vector3, cell: number): string
	return string.format("%d,%d,%d",
		math.floor(v.X / cell + 0.5),
		math.floor(v.Y / cell + 0.5),
		math.floor(v.Z / cell + 0.5))
end

function RouteCache.new(cfg)
	return setmetatable({
		_cell = cfg.CellSize,
		_ttl = cfg.TTL,
		_max = cfg.MaxEntries,
		_entries = {},   -- [key] = { waypoints, time, goalKey }
		_order = {},     -- keys em ordem de inserção (despejo FIFO)
		_geoVersion = -1,
	}, RouteCache)
end

function RouteCache:_key(start: Vector3, goal: Vector3): (string, string)
	local g = quantize(goal, self._cell)
	return quantize(start, self._cell) .. "|" .. g, g
end

function RouteCache:_syncVersion(geoVersion: number)
	if geoVersion ~= self._geoVersion then
		self:clear()
		self._geoVersion = geoVersion
	end
end

function RouteCache:get(start: Vector3, goal: Vector3, geoVersion: number)
	self:_syncVersion(geoVersion)
	local key = self:_key(start, goal)
	local e = self._entries[key]
	if not e then return nil end
	if os.clock() - e.time > self._ttl then
		self._entries[key] = nil
		return nil
	end
	return e.waypoints
end

function RouteCache:put(start: Vector3, goal: Vector3, waypoints, geoVersion: number)
	self:_syncVersion(geoVersion)
	local key, goalKey = self:_key(start, goal)
	if not self._entries[key] then
		table.insert(self._order, key)
	end
	self._entries[key] = { waypoints = table.freeze(waypoints), time = os.clock(), goalKey = goalKey }
	while #self._order > self._max do
		local old = table.remove(self._order, 1)
		self._entries[old] = nil
	end
end

function RouteCache:invalidateGoal(goal: Vector3)
	local g = quantize(goal, self._cell)
	for key, e in pairs(self._entries) do
		if e.goalKey == g then self._entries[key] = nil end
	end
end

function RouteCache:clear()
	table.clear(self._entries)
	table.clear(self._order)
end

return RouteCache
```

### 3.5 Código — `PathSimplifier`

```lua
-- PathSimplifier (ModuleScript)
-- 1) remove duplicatas; 2) string pulling com validação de volume livre E chão contínuo.
-- Nunca remove waypoints cuja Action ≠ Walk; nunca atravessa um deles num atalho.
local NavUtil = require(script.Parent.NavUtil)

local PathSimplifier = {}
local UP = Vector3.yAxis
local WALK = Enum.PathWaypointAction.Walk

-- ctx = { params, probeRadius, probeHeight, floorStep, maxFloorDelta, groundProbeUp }
local function canWalkStraight(a: Vector3, b: Vector3, ctx): boolean
	local delta = b - a
	local flatDist = NavUtil.flat(delta).Magnitude
	if flatDist < 0.1 then return true end

	-- (1) volume livre: esfera viajando na altura do tronco
	local origin = a + UP * ctx.probeHeight
	local hit = workspace:Spherecast(origin, ctx.probeRadius, delta, ctx.params)
	if hit then return false end

	-- (2) chão contínuo: amostras para baixo ao longo do segmento
	local n = math.max(1, math.ceil(flatDist / ctx.floorStep))
	for i = 1, n - 1 do
		local p = a:Lerp(b, i / n)
		local r = workspace:Raycast(p + UP * ctx.groundProbeUp, -UP * (ctx.groundProbeUp + ctx.maxFloorDelta), ctx.params)
		if not r then return false end                                   -- buraco
		if math.abs(r.Position.Y - p.Y) > ctx.maxFloorDelta then return false end -- degrau/queda
	end
	return true
end

local function innerAllWalk(wps, i: number, j: number): boolean
	for k = i + 1, j - 1 do
		if wps[k].Action ~= WALK then return false end
	end
	return true
end

function PathSimplifier.simplify(wps, ctx)
	-- 1) deduplicação
	local dedup = {}
	for _, wp in ipairs(wps) do
		local last = dedup[#dedup]
		if last and wp.Action == WALK and last.Action == WALK
			and (wp.Position - last.Position).Magnitude < 0.5 then
			continue
		end
		table.insert(dedup, wp)
	end
	if #dedup <= 2 then return dedup end

	-- 2) string pulling guloso (do mais distante para o mais próximo)
	local result = { dedup[1] }
	local anchor = 1
	while anchor < #dedup do
		local furthest = anchor + 1
		-- segmento que COMEÇA num waypoint de ação (voo) nunca é encurtado
		if dedup[anchor].Action == WALK then
			for j = #dedup, anchor + 2, -1 do
				if innerAllWalk(dedup, anchor, j)
					and canWalkStraight(dedup[anchor].Position, dedup[j].Position, ctx) then
					furthest = j
					break
				end
			end
		end
		table.insert(result, dedup[furthest])
		anchor = furthest
	end
	return result
end

return PathSimplifier
```

> **Custo:** o string pulling é O(n²) em raycasts no pior caso. Com `WaypointSpacing = math.huge` o `n` é pequeno (tipicamente < 15). Como o resultado vai para o cache, o custo é pago uma vez por par de células.

---

## 4. PROBLEMA 2 — PREDIÇÃO HEURÍSTICA DE SALTO (JUMP PREDICTION)

### 4.1 Lógica (vista lateral)

```
            ┌── raio de "muito alto" (feet + alturaUtil + folga) — não pode bater
            │
  agente    │      ▼ raio de topo (de cima para baixo, "entrando" alguns cm no obstáculo)
   ●───────────────┬───────┐
   │  raio joelho →│ MURETA│  ▼ varredura de profundidade → encontra a borda de trás
   │               │       │▼▼▼▼  → ponto de pouso (chão atrás) e queda segura
 ──┴───────────────┴───────┴──────────
```

Etapas do `JumpPredictor.analyze`:

1. **Direção plana** até o alvo.
2. **Raio na altura do joelho** (`pés + MinObstacleHeight`): se não bate → não há obstáculo. Se a normal tem |Y| alto → é rampa, não parede.
3. **Raio "muito alto"** na altura `pés + alturaUtil + folga`: se bate na mesma região → obstáculo alto demais (ou teto baixo) → não saltável.
4. **Topo**: raio vertical para baixo, "entrando" `inset` studs após a face (várias tentativas para paredes finas). `H = topoY − pésY`. Rejeita se `H > alturaUtil`.
5. **Profundidade e pouso**: varre para frente sobre o topo com raios para baixo até encontrar queda (borda traseira). Se não encontrar dentro de `LandingSearchMax` → obstáculo é **plataforma** (pouso no topo). Valida chão no ponto de pouso e queda ≤ `MaxSafeDrop`.
6. **Corredor aéreo**: spherecast na altura dos pés-em-voo e raio na altura da cabeça-em-voo → sem teto/viga no caminho.
7. **Balística**: com `v = √(2g·h)`, calcula `tUp` e `tDown` (momentos em que o corpo cruza a altura de folga). Condição de profundidade: `WalkSpeed · (tDown − tUp) ≥ profundidade + 2·raio`. **Distância de decolagem**: `WalkSpeed · tUp + raio + margem`.

### 4.2 Duas formas de decidir QUANDO saltar

- **(A) Sonda por segmento** (reativa): durante o `Following`, a cada `ProbeInterval` analisa o segmento até o próximo waypoint. Cobre obstáculos que o pathfinding não previu (dinâmicos, muretas finas).
- **(B) Atalho direto** (proativa): ao adotar uma rota, se `comprimentoDaRota / linhaReta > DetourRatioThreshold`, analisa a linha reta até o destino; se há obstáculo saltável, calcula uma **rota de validação a partir do ponto de pouso** (segundo objeto `Path`). Só adota o salto se `(decolagem→pouso) + (pouso→destino)` for ≥ `MinGainRatio` mais curto que o desvio. Isso impede saltar para um "beco".
- **(C) Nativa, para muretas estáticas conhecidas**: `PathfindingLink` com `Label = "JumpLink"` (Seção 8). O pathfinding passa a escolher o salto sozinho, com custo controlado. **Prefira (C) em level design; (A) e (B) cobrem o resto.**

### 4.3 Código — `JumpPredictor`

```lua
-- JumpPredictor (ModuleScript)
local NavUtil = require(script.Parent.NavUtil)

local JumpPredictor = {}
local UP = Vector3.yAxis

-- ctx = { root, humanoid, targetPos, params, agentRadius, agentHeight, walkSpeed, cfg (= Config.Jump) }
-- Retorna (plan | nil, motivo: string)
function JumpPredictor.analyze(ctx)
	local cfg = ctx.cfg
	local root: BasePart = ctx.root
	local humanoid: Humanoid = ctx.humanoid
	local rootPos = root.Position
	local feetY = NavUtil.getFeetY(humanoid, root)

	-- 1) direção
	local toTarget = NavUtil.flat(ctx.targetPos - rootPos)
	local dist = toTarget.Magnitude
	if dist < cfg.MinTargetDistance then return nil, "target_too_close" end
	local dir = toTarget.Unit
	local probeDist = math.min(cfg.ProbeDistance, dist)

	local maxJump = NavUtil.getMaxJumpHeight(humanoid)
	local usable = maxJump - cfg.HeightSafetyMargin
	if usable <= cfg.MinObstacleHeight then return nil, "jump_too_weak" end

	-- 2) parede na altura do joelho
	local kneeOrigin = Vector3.new(rootPos.X, feetY + cfg.MinObstacleHeight, rootPos.Z)
	local wallHit = workspace:Raycast(kneeOrigin, dir * probeDist, ctx.params)
	if not wallHit then return nil, "no_obstacle" end
	if math.abs(wallHit.Normal.Y) > cfg.MaxWallNormalY then return nil, "not_a_wall" end

	-- 3) alto demais? (ou teto baixo logo acima)
	local highY = feetY + usable + cfg.TopProbeClearance
	local highHit = workspace:Raycast(Vector3.new(rootPos.X, highY, rootPos.Z),
		dir * (wallHit.Distance + 0.5), ctx.params)
	if highHit then return nil, "too_tall" end

	-- 4) topo do obstáculo (várias profundidades de entrada para paredes finas)
	local topY: number? = nil
	for _, inset in ipairs(cfg.TopProbeInsets) do
		local p = wallHit.Position + dir * inset
		local r = workspace:Raycast(Vector3.new(p.X, highY, p.Z), -UP * (highY - feetY + 0.5), ctx.params)
		if r and (r.Position.Y - feetY) >= cfg.MinObstacleHeight * 0.5 then
			topY = r.Position.Y
			break
		end
	end
	if not topY then return nil, "top_not_found" end
	local obstacleHeight = topY - feetY
	if obstacleHeight > usable then return nil, "too_tall" end

	-- 5) profundidade e ponto de pouso
	local depth: number? = nil
	local k = 0
	while k < cfg.LandingSearchMax do
		k += cfg.LandingScanStep
		local s = wallHit.Position + dir * k
		local r = workspace:Raycast(Vector3.new(s.X, topY + 0.5, s.Z),
			-UP * (0.5 + obstacleHeight + cfg.MaxSafeDrop), ctx.params)
		if not r then
			depth = k -- abismo logo depois; tratado na validação do pouso
			break
		end
		if r.Position.Y < topY - 0.5 then
			depth = k
			break
		end
	end

	local isPlatform = depth == nil
	local landing: Vector3
	if isPlatform then
		-- obstáculo largo: pousar EM CIMA dele
		local p = wallHit.Position + dir * (ctx.agentRadius + cfg.LandingMargin)
		landing = Vector3.new(p.X, topY, p.Z)
	else
		local p = wallHit.Position + dir * (depth + ctx.agentRadius + cfg.LandingMargin)
		local floor = workspace:Raycast(Vector3.new(p.X, topY + 0.5, p.Z),
			-UP * (0.5 + obstacleHeight + cfg.MaxSafeDrop), ctx.params)
		if not floor then return nil, "no_landing" end
		if topY - floor.Position.Y > cfg.MaxSafeDrop then return nil, "drop_too_high" end
		landing = floor.Position
	end

	-- 6) corredor aéreo (pés e cabeça durante o voo)
	local airLen = NavUtil.flat(landing - rootPos).Magnitude
	local feetFlightY = topY + cfg.AirClearance
	local bodyHit = workspace:Spherecast(
		Vector3.new(rootPos.X, feetFlightY + ctx.agentRadius, rootPos.Z),
		ctx.agentRadius * 0.9, dir * airLen, ctx.params)
	if bodyHit then return nil, "air_blocked" end
	local headHit = workspace:Raycast(
		Vector3.new(rootPos.X, feetFlightY + ctx.agentHeight, rootPos.Z), dir * airLen, ctx.params)
	if headHit then return nil, "ceiling" end

	-- 7) balística
	local g = workspace.Gravity
	local clearH = obstacleHeight + cfg.AirClearance
	local jumpH = math.min(clearH + cfg.ApexExtra, maxJump)
	if jumpH < clearH then return nil, "insufficient_jump" end
	local v = math.sqrt(2 * g * jumpH)
	local disc = v * v - 2 * g * clearH
	if disc < 0 then return nil, "insufficient_jump" end
	local sq = math.sqrt(disc)
	local tUp = (v - sq) / g
	local tDown = (v + sq) / g
	local speed = ctx.walkSpeed

	if not isPlatform then
		local horizontalAbove = speed * (tDown - tUp)
		if horizontalAbove < depth + 2 * ctx.agentRadius then
			return nil, "too_deep"
		end
	end

	return {
		direction = dir,
		wallPoint = wallHit.Position,
		wallInstance = wallHit.Instance,
		obstacleHeight = obstacleHeight,
		obstacleDepth = depth,
		isPlatform = isPlatform,
		landingPoint = landing,
		jumpHeight = jumpH,
		takeoffDistance = speed * tUp + ctx.agentRadius + cfg.TakeoffMargin,
		tUp = tUp,
		tDown = tDown,
	}, "ok"
end

-- distância plana do centro do agente até a face do obstáculo, ao longo da direção do plano
function JumpPredictor.wallDistance(plan, rootPos: Vector3): number
	return NavUtil.flat(plan.wallPoint - rootPos):Dot(plan.direction)
end

return JumpPredictor
```

---

## 5. PROBLEMA 3 — GEOMETRIAS INVISÍVEIS

### 5.1 Lógica

Duas "vítimas" distintas, dois remédios:

| Vítima | Remédio |
|---|---|
| **Navmesh** do PathfindingService | `PathfindingModifier` filho da parte com `PassThrough = true` |
| **Nossos raycasts** (predição, suavização, chão) | `RaycastParams` com `FilterType = Exclude` contendo as partes ignoradas + `RespectCanCollide = true` (ignora triggers já não-colidíveis) |

**Classificação** (ordem de precedência):
1. Tag `NavSolid` → **sempre sólido** (paredes invisíveis de limite de mapa, que DEVEM bloquear).
2. Tag `NavIgnore` → **sempre atravessável** (aplicável em Part, Model ou Folder: afeta descendentes).
3. `CanCollide = false` → já ignorado pelo pathfinding; nada a fazer.
4. Auto-detecção: `Transparency ≥ 0.95` **e** (se `RequireNameMatch`) nome contendo padrão suspeito (`zone`, `trigger`, `hitbox`...).

**Segurança**: a auto-detecção é conservadora por padrão (exige nome). `GeometryFilter.audit()` lista partes invisíveis colidíveis **não** classificadas para o desenvolvedor etiquetar manualmente. **Não** altere `CanCollide` automaticamente — isso muda a física do jogo; a correção certa para um trigger que colide sem necessidade é o desenvolvedor setar `CanCollide = false` no Studio.

**Versão**: toda mudança incrementa `GeometryFilter.getVersion()` e dispara `GeometryFilter.Changed` → agentes reconstroem `RaycastParams` e limpam cache.

### 5.2 Código — `GeometryFilter`

```lua
-- GeometryFilter (ModuleScript) — singleton por ambiente (cliente ou servidor)
local CollectionService = game:GetService("CollectionService")
local NavConfig = require(script.Parent.NavConfig)

local cfg = NavConfig.Defaults.Geometry
local GeometryFilter = {}

local ignored: { [BasePart]: boolean } = {}
local ignoredList: { BasePart } = {}
local version = 0
local started = false
local changedEvent = Instance.new("BindableEvent")
GeometryFilter.Changed = changedEvent.Event

local function bump()
	version += 1
	changedEvent:Fire(version)
end

local function nameMatches(name: string): boolean
	local n = string.lower(name)
	for _, pattern in ipairs(cfg.NamePatterns) do
		if string.find(n, pattern, 1, true) then return true end
	end
	return false
end

local function hasTagInAncestry(inst: Instance, tag: string): boolean
	local cur: Instance? = inst
	while cur and cur ~= workspace do
		if CollectionService:HasTag(cur, tag) then return true end
		cur = cur.Parent
	end
	return false
end

function GeometryFilter.classify(part: Instance): boolean
	if not part:IsA("BasePart") then return false end
	if hasTagInAncestry(part, cfg.SolidTag) then return false end
	if hasTagInAncestry(part, cfg.IgnoreTag) then return true end
	if not part.CanCollide then return false end
	if not cfg.AutoDetect then return false end
	if part.Transparency < cfg.InvisibleThreshold then return false end
	if cfg.RequireNameMatch then return nameMatches(part.Name) end
	return true
end

local function unmark(part: BasePart)
	if not ignored[part] then return end
	ignored[part] = nil
	local i = table.find(ignoredList, part)
	if i then table.remove(ignoredList, i) end
	local mod = part:FindFirstChild(cfg.ModifierName)
	if mod then mod:Destroy() end
	bump()
end

local function mark(part: BasePart)
	if ignored[part] then return end
	ignored[part] = true
	table.insert(ignoredList, part)
	if part.CanCollide and not part:FindFirstChild(cfg.ModifierName) then
		local mod = Instance.new("PathfindingModifier")
		mod.Name = cfg.ModifierName
		mod.PassThrough = true
		mod.Label = cfg.ModifierLabel
		mod.Parent = part
	end
	part.AncestryChanged:Connect(function(_, parent)
		if not parent then unmark(part) end
	end)
	bump()
end

function GeometryFilter.refresh(inst: Instance)
	if not inst:IsA("BasePart") then return end
	if GeometryFilter.classify(inst) then mark(inst) else unmark(inst) end
end

local function refreshTree(inst: Instance)
	GeometryFilter.refresh(inst)
	for _, d in ipairs(inst:GetDescendants()) do GeometryFilter.refresh(d) end
end

function GeometryFilter.start()
	if started then return end
	started = true
	for _, d in ipairs(workspace:GetDescendants()) do GeometryFilter.refresh(d) end
	workspace.DescendantAdded:Connect(function(d)
		-- defer: propriedades costumam ser setadas logo após o parent
		task.defer(GeometryFilter.refresh, d)
	end)
	for _, tag in ipairs({ cfg.IgnoreTag, cfg.SolidTag }) do
		CollectionService:GetInstanceAddedSignal(tag):Connect(refreshTree)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(refreshTree)
	end
end

function GeometryFilter.getVersion(): number
	return version
end

-- RaycastParams para os raycasts do sistema. `extra` = instâncias adicionais a excluir (o próprio personagem).
function GeometryFilter.buildRaycastParams(extra: { Instance }?): RaycastParams
	local list = table.clone(ignoredList) :: { Instance }
	if extra then
		for _, inst in ipairs(extra) do table.insert(list, inst) end
	end
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = list
	p.RespectCanCollide = true
	p.IgnoreWater = true
	return p
end

-- Lista partes invisíveis colidíveis que NÃO foram classificadas — para revisão manual.
function GeometryFilter.audit(): { BasePart }
	local suspects = {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BasePart") and d.CanCollide and d.Transparency >= cfg.InvisibleThreshold
			and not ignored[d] and not hasTagInAncestry(d, cfg.SolidTag) then
			table.insert(suspects, d)
			print("[GeometryFilter.audit] invisível colidível não classificada:", d:GetFullName())
		end
	end
	return suspects
end

return GeometryFilter
```

> **[VALIDAR]** Após adicionar/remover `PathfindingModifier`, a navmesh leva um instante para atualizar. Por isso o agente limpa o cache em `Changed` e o próximo `ComputeAsync` usa a malha nova. Se o agente roda **no cliente**, confirme no Studio que modifiers criados no cliente afetam o pathfinding do cliente; se não, rode `GeometryFilter.start()` **também no servidor** (modifiers criados no servidor replicam).

---

## 6. PROBLEMA 4 — SINCRONIZAÇÃO DE IMPULSO VERTICAL

### 6.1 Lógica

**Modo `Native` (padrão, recomendado):** ajusta temporariamente `JumpHeight` (ou `JumpPower`) para a altura exata calculada, seta `Humanoid.Jump = true` e restaura o valor original quando o estado vira `Freefall` (o impulso já foi aplicado). O próprio Humanoid cuida da transição de estados e da física → zero conflito.

**Modo `Injected` (quando precisar de controle fino ou alturas fora do padrão):** `ChangeState(Jumping)` e, no **primeiro Heartbeat após** a transição, sobrescreve `AssemblyLinearVelocity`:
- Vertical: `vy = √(2g · (alturaAlvo − alturaJáSubida))` — recalculada a partir de onde o corpo está de fato (corrige o que o Humanoid já aplicou).
- Horizontal: `dir · max(velocidadeAtualNaDireção, WalkSpeed)` — **nunca reduz** momento existente (preserva o impulso pós-dash).

**Regras de sincronia (valem para os dois modos):**
1. Só saltar se `FloorMaterial ≠ Air` e estado ∉ {Jumping, Freefall, Seated, Dead, PlatformStanding} e o estado `Jumping` está habilitado.
2. **Durante todo o voo, continuar chamando `Humanoid:Move(dir)`** rumo ao ponto de pouso. É isso que mantém o momento horizontal.
3. Cooldown entre saltos (`Cooldown`).
4. Quem executa deve ser o **dono da rede**: cliente para o personagem do jogador; servidor para NPC com `SetNetworkOwner(nil)`. `ChangeState` chamado por quem não é dono é ignorado/sobrescrito.
5. Nunca combinar `Humanoid.Jump = true` **e** injeção de velocidade no mesmo salto (soma de impulsos → pulo exagerado).

### 6.2 Código — `JumpExecutor`

```lua
-- JumpExecutor (ModuleScript)
local RunService = game:GetService("RunService")
local NavUtil = require(script.Parent.NavUtil)

local JumpExecutor = {}
local ST = Enum.HumanoidStateType

local BLOCKING_STATES = {
	[ST.Jumping] = true, [ST.Freefall] = true, [ST.Seated] = true,
	[ST.Dead] = true, [ST.PlatformStanding] = true, [ST.Ragdoll] = true,
	[ST.FallingDown] = true, [ST.Physics] = true,
}

function JumpExecutor.canJump(humanoid: Humanoid): boolean
	if humanoid.FloorMaterial == Enum.Material.Air then return false end
	if BLOCKING_STATES[humanoid:GetState()] then return false end
	return humanoid:GetStateEnabled(ST.Jumping)
end

-- Modo Native: altura exata via propriedades do Humanoid, restaurando depois.
function JumpExecutor.jumpNative(humanoid: Humanoid, height: number)
	local restore
	if humanoid.UseJumpPower then
		local old = humanoid.JumpPower
		humanoid.JumpPower = NavUtil.velocityForHeight(height)
		restore = function() if humanoid.Parent then humanoid.JumpPower = old end end
	else
		local old = humanoid.JumpHeight
		humanoid.JumpHeight = height
		restore = function() if humanoid.Parent then humanoid.JumpHeight = old end end
	end

	local done = false
	local conn: RBXScriptConnection
	local function finish()
		if done then return end
		done = true
		if conn and conn.Connected then conn:Disconnect() end
		restore()
	end
	conn = humanoid.StateChanged:Connect(function(_, new)
		if new == ST.Freefall or new == ST.Landed then finish() end
	end)
	task.delay(1, finish) -- salvaguarda: nunca deixar JumpHeight alterado
	humanoid.Jump = true
end

-- Modo Injected: estado via ChangeState, velocidade corrigida no primeiro Heartbeat.
function JumpExecutor.jumpInjected(humanoid: Humanoid, root: BasePart, height: number, dir: Vector3, speed: number)
	local startFeet = NavUtil.getFeetY(humanoid, root)
	humanoid:ChangeState(ST.Jumping)
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		conn:Disconnect()
		if not root.Parent then return end
		local risen = NavUtil.getFeetY(humanoid, root) - startFeet
		local vy = NavUtil.velocityForHeight(height - risen)
		local cur = root.AssemblyLinearVelocity
		local along = NavUtil.flat(cur):Dot(dir)
		local h = dir * math.max(along, speed) -- nunca reduz momento existente
		root.AssemblyLinearVelocity = Vector3.new(h.X, vy, h.Z)
	end)
end

function JumpExecutor.execute(mode: string, humanoid: Humanoid, root: BasePart, height: number, dir: Vector3?)
	if mode == "Injected" and dir then
		JumpExecutor.jumpInjected(humanoid, root, height, dir, humanoid.WalkSpeed)
	else
		JumpExecutor.jumpNative(humanoid, height)
	end
end

return JumpExecutor
```

---

## 7. ORQUESTRADOR — `NavigationAgent`

### 7.1 API pública (contrato)

```text
NavigationAgent.new(character: Model, overrides: table?) -> Agent
Agent:MoveTo(goal: Vector3)
Agent:Stop()
Agent:SetSuspended(suspended: boolean)   -- pausa sem perder rota (integração com replayer/dash)
Agent:GetState() -> string
Agent:Destroy()
Agent.Reached        : RBXScriptSignal ()
Agent.Failed         : RBXScriptSignal (reason: string)
Agent.CustomWaypoint : RBXScriptSignal (label: string, waypoint, nextWaypoint?) -- links não-salto (ex.: "DashLink")
```

### 7.2 Código

```lua
-- NavigationAgent (ModuleScript)
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local NavConfig = require(script.Parent.NavConfig)
local NavUtil = require(script.Parent.NavUtil)
local GeometryFilter = require(script.Parent.GeometryFilter)
local RouteCache = require(script.Parent.RouteCache)
local PathSimplifier = require(script.Parent.PathSimplifier)
local JumpPredictor = require(script.Parent.JumpPredictor)
local JumpExecutor = require(script.Parent.JumpExecutor)

local WALK = Enum.PathWaypointAction.Walk
local JUMP = Enum.PathWaypointAction.Jump
local CUSTOM = Enum.PathWaypointAction.Custom

local State = {
	Idle = "Idle", Following = "Following", DirectJump = "DirectJump",
	Airborne = "Airborne", Failed = "Failed",
}

local Agent = {}
Agent.__index = Agent

function Agent.new(character: Model, overrides)
	local self = setmetatable({}, Agent)
	self.Character = character
	self.Humanoid = character:WaitForChild("Humanoid") :: Humanoid
	self.Root = character:WaitForChild("HumanoidRootPart") :: BasePart
	self.Config = NavConfig.merge(overrides)

	local a = self.Config.Agent
	local pathParams = {
		AgentRadius = a.Radius, AgentHeight = a.Height,
		AgentCanJump = a.CanJump, AgentCanClimb = a.CanClimb,
		WaypointSpacing = a.WaypointSpacing, Costs = self.Config.Costs,
	}
	self._path = PathfindingService:CreatePath(pathParams)      -- rota principal (Blocked)
	self._probePath = PathfindingService:CreatePath(pathParams) -- validação pós-pouso
	self._cache = RouteCache.new(self.Config.Cache)

	self._state = State.Idle
	self._goal = nil
	self._waypoints = nil
	self._index = 1
	self._computing = false
	self._replanRequested = false
	self._forceAdopt = false
	self._lastPlanTime = 0
	self._lastProbe = 0
	self._lastJump = 0
	self._jumpPlan = nil
	self._directStart = 0
	self._airStart = 0
	self._airTarget = nil
	self._airDir = nil
	self._suspended = false
	self._stuck = { lastPos = nil, lastTime = 0, strikes = 0 }
	self._params = nil
	self._paramsVersion = -1

	self._reachedEv = Instance.new("BindableEvent")
	self._failedEv = Instance.new("BindableEvent")
	self._customEv = Instance.new("BindableEvent")
	self.Reached = self._reachedEv.Event
	self.Failed = self._failedEv.Event
	self.CustomWaypoint = self._customEv.Event

	GeometryFilter.start()

	self._connections = {
		self._path.Blocked:Connect(function() self:_onBlocked() end),
		GeometryFilter.Changed:Connect(function() self._cache:clear() end),
		RunService.Heartbeat:Connect(function(dt) self:_step(dt) end),
		self.Humanoid.Died:Connect(function() self:Stop() end),
	}

	-- NPC no servidor: física sempre no servidor (sem troca de dono no meio do salto)
	if RunService:IsServer() and not Players:GetPlayerFromCharacter(character) then
		pcall(function() self.Root:SetNetworkOwner(nil) end)
	end
	return self
end

-- ===================== API pública =====================

function Agent:MoveTo(goal: Vector3)
	self._goal = goal
	self._state = State.Following
	self._waypoints = nil
	self._jumpPlan = nil
	self._forceAdopt = true
	self._stuck = { lastPos = nil, lastTime = 0, strikes = 0 }
	self:_requestPlan(true)
end

function Agent:Stop()
	self._state = State.Idle
	self._goal = nil
	self._waypoints = nil
	self._jumpPlan = nil
	if self.Humanoid.Parent then self.Humanoid:Move(Vector3.zero, false) end
end

function Agent:SetSuspended(v: boolean)
	self._suspended = v
	if not v then
		self._stuck.lastPos = nil
		if self._waypoints then self._index = self:_selectStartIndex(self._waypoints, self._index) end
	end
end

function Agent:GetState(): string
	return self._state
end

function Agent:Destroy()
	self:Stop()
	for _, c in ipairs(self._connections) do c:Disconnect() end
	self._reachedEv:Destroy(); self._failedEv:Destroy(); self._customEv:Destroy()
end

-- ===================== Planejamento =====================

function Agent:_getParams(): RaycastParams
	local v = GeometryFilter.getVersion()
	if not self._params or v ~= self._paramsVersion then
		self._params = GeometryFilter.buildRaycastParams({ self.Character, NavUtil.getDebugFolder() })
		self._paramsVersion = v
	end
	return self._params
end

function Agent:_groundedPosition(): Vector3
	local s = self.Config.Stabilizer
	local r = NavUtil.groundBelow(self.Root.Position, self.Config.Agent.Height + 6, self:_getParams())
	if r then return r.Position + Vector3.yAxis * s.StartHeightOffset end
	return self.Root.Position
end

function Agent:_requestPlan(force: boolean)
	if self._computing then
		self._replanRequested = true
		return
	end
	local interval = self.Config.Stabilizer.MinReplanInterval
	if not force and os.clock() - self._lastPlanTime < interval then
		return
	end
	task.spawn(self._plan, self)
end

function Agent:_compute(pathObj, start: Vector3, goal: Vector3)
	local ok, err = pcall(function() pathObj:ComputeAsync(start, goal) end)
	if not ok then
		warn("[NavigationAgent] ComputeAsync falhou:", err)
		return nil
	end
	if pathObj.Status ~= Enum.PathStatus.Success then
		return nil
	end
	local out = {}
	for _, wp in ipairs(pathObj:GetWaypoints()) do
		table.insert(out, table.freeze({ Position = wp.Position, Action = wp.Action, Label = wp.Label }))
	end
	return out
end

function Agent:_simplifyCtx()
	local s = self.Config.Stabilizer
	return {
		params = self:_getParams(),
		probeRadius = s.SmoothingProbeRadius,
		probeHeight = s.SmoothingProbeHeight,
		floorStep = s.FloorSampleStep,
		maxFloorDelta = s.MaxFloorDelta,
		groundProbeUp = s.GroundProbeUp,
	}
end

function Agent:_plan()
	self._computing = true
	self._lastPlanTime = os.clock()

	-- (Estabilização nº1) nunca calcular com o agente no ar
	local t0 = os.clock()
	while self.Humanoid.FloorMaterial == Enum.Material.Air
		and os.clock() - t0 < self.Config.Stabilizer.MaxGroundedWait do
		task.wait()
	end

	local goal = self._goal
	if not goal then self._computing = false return end

	local start = self:_groundedPosition()
	local geoV = GeometryFilter.getVersion()
	local wps = self._cache:get(start, goal, geoV)
	if not wps then
		local raw = self:_compute(self._path, start, goal)
		if raw then
			wps = PathSimplifier.simplify(raw, self:_simplifyCtx())
			self._cache:put(start, goal, wps, geoV)
		end
	end

	-- destino mudou durante o yield do ComputeAsync → descartar e recalcular
	if goal ~= self._goal then
		self._computing = false
		self:_requestPlan(true)
		return
	end

	if wps then
		self:_adoptRoute(wps, goal)
	else
		self:_handleNoPath(goal)
	end

	self._computing = false
	if self._replanRequested then
		self._replanRequested = false
		task.delay(self.Config.Stabilizer.MinReplanInterval, function()
			if self._goal then self:_requestPlan(true) end
		end)
	end
end

function Agent:_adoptRoute(wps, goal: Vector3)
	local rootPos = self.Root.Position
	local newLen = NavUtil.pathLength(wps, rootPos, 2)

	-- (Estabilização nº5) histerese
	if not self._forceAdopt and self._waypoints and self._state == State.Following then
		local curLen = NavUtil.pathLength(self._waypoints, rootPos, self._index)
		if newLen > curLen * (1 - self.Config.Stabilizer.ReplanImprovementRatio) then
			return -- rota atual continua boa o suficiente
		end
	end
	self._forceAdopt = false
	self._waypoints = wps
	self._index = self:_selectStartIndex(wps, 1)
	if self._state ~= State.Airborne then self._state = State.Following end

	if self.Config.Debug.Enabled then NavUtil.drawRoute(wps, self.Config.Debug.Lifetime) end

	self:_considerDirectJump(goal, newLen)
end

function Agent:_analyzeToward(target: Vector3)
	local a = self.Config.Agent
	return JumpPredictor.analyze({
		root = self.Root, humanoid = self.Humanoid, targetPos = target,
		params = self:_getParams(), agentRadius = a.Radius, agentHeight = a.Height,
		walkSpeed = self.Humanoid.WalkSpeed, cfg = self.Config.Jump,
	})
end

-- (Predição, forma B) atalho por salto quando a rota dá uma volta grande
function Agent:_considerDirectJump(goal: Vector3, pathLen: number)
	local j = self.Config.Jump
	local rootPos = self.Root.Position
	local straight = NavUtil.flat(goal - rootPos).Magnitude
	if straight < 1 or pathLen / straight < j.DetourRatioThreshold then return end

	local plan = self:_analyzeToward(goal)
	if not plan then return end

	-- validação pós-pouso: existe rota curta do pouso até o destino?
	local after = self:_compute(self._probePath, plan.landingPoint + Vector3.yAxis * 1, goal)
	if not after then return end
	if goal ~= self._goal then return end
	local afterLen = NavUtil.pathLength(after, plan.landingPoint, 2)
	local viaJump = NavUtil.flat(plan.landingPoint - rootPos).Magnitude + afterLen
	if viaJump >= pathLen * (1 - j.MinGainRatio) then return end

	self._jumpPlan = plan
	self._waypoints = PathSimplifier.simplify(after, self:_simplifyCtx())
	self._index = 1
	self._state = State.DirectJump
	self._directStart = os.clock()
	if self.Config.Debug.Enabled then
		NavUtil.drawPoint(plan.wallPoint, Color3.fromRGB(255, 60, 60), 0.8)
		NavUtil.drawPoint(plan.landingPoint, Color3.fromRGB(60, 255, 60), 0.8)
	end
end

function Agent:_handleNoPath(goal: Vector3)
	-- destino inalcançável pela malha (ex.: plataforma acima do limite interno de salto)
	local plan = self:_analyzeToward(goal)
	if plan then
		self._jumpPlan = plan
		self._waypoints = { table.freeze({ Position = goal, Action = WALK, Label = "" }) }
		self._index = 1
		self._state = State.DirectJump
		self._directStart = os.clock()
		return
	end
	self:_fail("no_path")
end

function Agent:_selectStartIndex(wps, hint: number): number
	local rootPos = self.Root.Position
	local from = math.max(1, hint or 1)
	local best, bestD = from, math.huge
	for i = from, math.min(#wps, from + 5) do
		local d = NavUtil.flat(wps[i].Position - rootPos).Magnitude
		if d < bestD then best, bestD = i, d end
	end
	-- se o mais próximo já ficou para trás (e é Walk), avança
	local nxt = wps[best + 1]
	if nxt and wps[best].Action == WALK then
		local seg = NavUtil.flat(nxt.Position - wps[best].Position)
		if seg.Magnitude > 1e-3 and NavUtil.flat(rootPos - wps[best].Position):Dot(seg) > 0 then
			best += 1
		end
	end
	return best
end

-- ===================== Execução por frame =====================

function Agent:_step(_dt)
	if self._suspended then return end
	local st = self._state
	if st == State.Idle or st == State.Failed then return end
	if self.Humanoid.Health <= 0 then self:Stop() return end

	if st == State.Airborne then return self:_stepAirborne() end
	if st == State.DirectJump then return self:_stepDirectJump() end
	self:_stepFollowing()
end

function Agent:_stepFollowing()
	local wps = self._waypoints
	if not wps then return end -- aguardando cálculo
	local rootPos = self.Root.Position
	local fcfg = self.Config.Follow

	local wp = wps[self._index]
	if not wp then return self:_arrive() end

	if NavUtil.flat(wp.Position - rootPos).Magnitude <= fcfg.ArriveRadius then
		local nextWp = wps[self._index + 1]
		if wp.Action == JUMP then
			self:_jumpToward(nextWp and nextWp.Position or wp.Position)
		elseif wp.Action == CUSTOM then
			self:_handleCustom(wp, nextWp)
		end
		self._index += 1
		wp = wps[self._index]
		if not wp then return self:_arrive() end
		if self._state ~= State.Following then return end
	end

	local dir = NavUtil.flat(wp.Position - rootPos)
	if dir.Magnitude > 1e-3 then
		self.Humanoid:Move(dir.Unit, false)
	end

	-- (Predição, forma A) sonda reativa no segmento atual
	local now = os.clock()
	if now - self._lastProbe >= self.Config.Jump.ProbeInterval then
		self._lastProbe = now
		local plan = self:_analyzeToward(wp.Position)
		if plan and JumpPredictor.wallDistance(plan, rootPos) <= plan.takeoffDistance then
			if self:_executeJump(plan.jumpHeight, plan.direction, plan.landingPoint) then return end
		end
	end

	self:_checkStuck()
end

function Agent:_stepDirectJump()
	local plan = self._jumpPlan
	if not plan then
		self._state = State.Following
		return
	end
	local rootPos = self.Root.Position
	self.Humanoid:Move(plan.direction, false)

	local wallDist = JumpPredictor.wallDistance(plan, rootPos)
	if wallDist <= plan.takeoffDistance then
		self:_executeJump(plan.jumpHeight, plan.direction, plan.landingPoint)
		return
	end
	if os.clock() - self._directStart > self.Config.Jump.DirectTimeout then
		-- abortar: volta à navegação normal com replan forçado
		self._jumpPlan = nil
		self._state = State.Following
		self._forceAdopt = true
		self._cache:invalidateGoal(self._goal)
		self:_requestPlan(true)
	end
end

function Agent:_stepAirborne()
	local rootPos = self.Root.Position
	local dir = self._airTarget and NavUtil.flat(self._airTarget - rootPos) or nil
	if dir and dir.Magnitude > 0.3 then
		self._airDir = dir.Unit
	end
	-- Sincronia de momento: continuar comandando o movimento durante TODO o voo
	if self._airDir then self.Humanoid:Move(self._airDir, false) end

	local elapsed = os.clock() - self._airStart
	local j = self.Config.Jump
	if elapsed > j.MinAirTime and self.Humanoid.FloorMaterial ~= Enum.Material.Air then
		self._state = State.Following
		self._airTarget = nil
		self._jumpPlan = nil
		self._stuck.lastPos = nil
		if self._waypoints then
			self._index = self:_selectStartIndex(self._waypoints, self._index)
		end
	elseif elapsed > j.MaxAirTime then
		self._state = State.Following
		self._forceAdopt = true
		self:_requestPlan(true)
	end
end

-- ===================== Saltos =====================

function Agent:_executeJump(height: number, dir: Vector3?, landing: Vector3?): boolean
	if not JumpExecutor.canJump(self.Humanoid) then return false end
	if os.clock() - self._lastJump < self.Config.Jump.Cooldown then return false end
	self._lastJump = os.clock()
	self._airTarget = landing
	self._airDir = dir
	JumpExecutor.execute(self.Config.Jump.Mode, self.Humanoid, self.Root, height, dir)
	self._state = State.Airborne
	self._airStart = os.clock()
	return true
end

-- salto pedido pelo pathfinding (Action = Jump) ou por link: altura precisa se possível
function Agent:_jumpToward(target: Vector3)
	local plan = self:_analyzeToward(target)
	if plan then
		self:_executeJump(plan.jumpHeight, plan.direction, plan.landingPoint)
	else
		local dir = NavUtil.flat(target - self.Root.Position)
		self:_executeJump(NavUtil.getMaxJumpHeight(self.Humanoid),
			dir.Magnitude > 1e-3 and dir.Unit or nil, target)
	end
end

function Agent:_handleCustom(wp, nextWp)
	if wp.Label == self.Config.Links.JumpLabel then
		self:_jumpToward(nextWp and nextWp.Position or wp.Position)
	else
		self._customEv:Fire(wp.Label, wp, nextWp)
	end
end

-- ===================== Robustez =====================

function Agent:_checkStuck()
	local now = os.clock()
	local pos = self.Root.Position
	local s = self._stuck
	local f = self.Config.Follow
	if not s.lastPos then
		s.lastPos, s.lastTime = pos, now
		return
	end
	if (pos - s.lastPos).Magnitude >= f.StuckMinProgress then
		s.lastPos, s.lastTime, s.strikes = pos, now, 0
		return
	end
	if now - s.lastTime < f.StuckTime then return end

	s.strikes += 1
	s.lastPos, s.lastTime = pos, now
	if s.strikes == 1 then
		-- 1ª tentativa: salto de escape preditivo
		local wp = self._waypoints and self._waypoints[self._index]
		if wp then self:_jumpToward(wp.Position) end
	elseif s.strikes <= f.MaxStuckStrikes then
		self._cache:invalidateGoal(self._goal)
		self._forceAdopt = true
		self:_requestPlan(true)
	else
		self:_fail("stuck")
	end
end

function Agent:_onBlocked()
	if not self._goal then return end
	self._cache:invalidateGoal(self._goal)
	self._forceAdopt = true
	self:_requestPlan(true)
end

function Agent:_arrive()
	self:Stop()
	self._reachedEv:Fire()
end

function Agent:_fail(reason: string)
	self._state = State.Failed
	self._waypoints = nil
	if self.Humanoid.Parent then self.Humanoid:Move(Vector3.zero, false) end
	self._failedEv:Fire(reason)
end

return Agent
```

---

## 8. CAMADA DE LEVEL DESIGN — `NavLinks` (muretas conhecidas)

Para muretas estáticas, o jeito mais barato e estável é ensinar a malha a pular com um `PathfindingLink`. O pathfinding passa a incluir o salto na rota com o custo definido em `Costs.JumpLink`; o waypoint chega como `Action = Custom`, `Label = "JumpLink"` e o `NavigationAgent` executa o salto via `_handleCustom`.

```lua
-- NavLinks (ModuleScript)
local NavLinks = {}

-- Cria um link de salto entre dois pontos do mundo (ex.: um de cada lado da mureta).
function NavLinks.createJumpLink(fromPos: Vector3, toPos: Vector3, label: string?, parent: Instance?, bidirectional: boolean?)
	local a0 = Instance.new("Attachment")
	a0.Name = "NavLinkA0"
	a0.Parent = workspace.Terrain
	a0.WorldPosition = fromPos

	local a1 = Instance.new("Attachment")
	a1.Name = "NavLinkA1"
	a1.Parent = workspace.Terrain
	a1.WorldPosition = toPos

	local link = Instance.new("PathfindingLink")
	link.Attachment0 = a0
	link.Attachment1 = a1
	link.Label = label or "JumpLink"
	link.IsBidirectional = bidirectional ~= false
	link.Parent = parent or workspace
	return link
end

return NavLinks
```

> Preferencialmente, crie os links **no Studio** (Attachments dentro das próprias muretas) e use este helper só para geração procedural. Para o dash do jogo, um link com `Label = "DashLink"` dispara `Agent.CustomWaypoint("DashLink", ...)`, onde o jogo aciona a mecânica de dash existente.

---

## 9. USO E INTEGRAÇÃO

### 9.1 NPC no servidor

```lua
-- ServerScriptService/NPCNav (Script)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NavigationAgent = require(ReplicatedStorage.NavSystem.NavigationAgent)

local npc = workspace:WaitForChild("NPC")
local agent = NavigationAgent.new(npc, { Debug = { Enabled = true } })

agent.Reached:Connect(function() print("chegou") end)
agent.Failed:Connect(function(reason) warn("falhou:", reason) end)

agent:MoveTo(workspace:WaitForChild("Goal").Position)
```

### 9.2 Personagem do jogador (cliente)

```lua
-- StarterPlayerScripts/PlayerNav (LocalScript)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NavigationAgent = require(ReplicatedStorage.NavSystem.NavigationAgent)

local player = Players.LocalPlayer
local agent

local function onCharacter(char)
	if agent then agent:Destroy() end
	agent = NavigationAgent.new(char, { Jump = { Mode = "Native" } })
end
player.CharacterAdded:Connect(onCharacter)
if player.Character then onCharacter(player.Character) end
```

> **Atenção (cliente):** enquanto o agente controla o personagem, os `ControlModule` padrões do jogador também chamam `Move`. Para reprodução automática, desabilite o controle do jogador (`require(player.PlayerScripts.PlayerModule):GetControls():Disable()`) e reabilite ao terminar. O replayer existente provavelmente já trata isso — reutilize a mesma abordagem.

### 9.3 Cliente × servidor

| Aspecto | Cliente (jogador) | Servidor (NPC) |
|---|---|---|
| Dono da física | cliente (automático) | servidor após `SetNetworkOwner(nil)` |
| `ChangeState` / `JumpHeight` | funcionam no próprio personagem | funcionam no NPC |
| `GeometryFilter` | rodar no cliente; **[VALIDAR]** se modifiers locais afetam o pathfinding local, senão rodar também no servidor | rodar no servidor |
| Custo de CPU | um agente só | escala com nº de NPCs — ajuste `ProbeInterval` |

### 9.4 Integração com o *Path Recorder & Replayer* existente

1. **Leia o LocalScript atual inteiro antes de mudar qualquer coisa.** Preserve gravação em JSON, dash (Q), look-ahead pós-dash e esferas de debug.
2. Mova a lógica de "seguir rota" do replayer para usar `NavigationAgent` como **executor de segmentos**: para cada trecho gravado entre eventos, chame `agent:MoveTo(pontoGravado)` e aguarde `Reached`.
3. **Eventos gravados têm prioridade sobre a predição.** Durante a reprodução de um pulo ou dash gravado: `agent:SetSuspended(true)` → executa a ação gravada → aguarda pousar → `agent:SetSuspended(false)`. Isso evita pulo duplo (gravado + predito).
4. **Um só anti-stuck.** Remova o anti-stuck/pulo de escape antigo OU desative o do agente (`Follow.MaxStuckStrikes = 0` exige adaptar `_checkStuck`). Dois sistemas brigando = oscilação.
5. Unifique o debug: use `NavUtil.drawPoint` ou mantenha as esferas atuais, mas ambas devem ter `CanCollide = false` e `CanQuery = false` para não poluir raycasts.
6. O look-ahead pós-dash continua válido: após um dash o `JumpExecutor` em modo `Injected` preserva o momento (nunca reduz velocidade horizontal); em modo `Native`, o `Move` contínuo durante o voo mantém a direção.

---

## 10. TESTES DE ACEITAÇÃO (montar em um place de teste)

| # | Cenário | Critério de aprovação |
|---|---|---|
| T1 | Mesmo início/destino, 20 chamadas `MoveTo` seguidas (resetando posição) | Lista de waypoints **idêntica** nas 20 (compare posições arredondadas) |
| T2 | Agente andando reto; rota nova só 5% mais curta aparece | Rota atual **mantida** (histerese) |
| T3 | Mureta de 3 studs, desvio de ~30 studs | Agente **salta** a mureta (DirectJump) e chega |
| T4 | Mureta de 9 studs (acima da capacidade) | Agente **contorna**; nenhum salto tentado |
| T5 | Parede de 3 studs de altura e **6 de profundidade** | `too_deep` → contorna (não cai em cima e trava) |
| T6 | Mureta com teto baixo logo acima | `air_blocked`/`ceiling` → contorna |
| T7 | Mureta com abismo atrás | `no_landing`/`drop_too_high` → contorna |
| T8 | Porta com trigger invisível `CanCollide = true` chamado "DoorTrigger" | Rota passa pela porta |
| T9 | Parede invisível de limite com tag `NavSolid` | Rota **não** atravessa |
| T10 | Parte ancorada surge sobre a rota durante o trajeto | `Blocked` → replan → chega |
| T11 | Destino alterado enquanto `ComputeAsync` está rodando | Usa o destino **novo** |
| T12 | Salto a 16 de WalkSpeed sobre mureta de 1.5 de profundidade | Pousa do outro lado; sem perda de momento |
| T13 | Mesmo cenário com `Mode = "Injected"` | Mesmo resultado; `JumpHeight` original intacto |
| T14 | `PathfindingLink` "JumpLink" sobre mureta | Waypoint Custom → salto executado |
| T15 | Agente empurrado contra canto | Salto de escape → replan → `Failed("stuck")` após 3 strikes |
| T16 | Desempenho com 10 NPCs | Sem queda perceptível de FPS/heartbeat (MicroProfiler) |

---

## 11. ARMADILHAS — NÃO FAZER

1. Chamar `ComputeAsync` a cada frame ou com o agente no ar.
2. Usar `Humanoid:MoveTo` sem tratar o **timeout de 8 s** — este sistema usa `Humanoid:Move` exatamente para evitar isso.
3. Parar de chamar `Move` durante o voo (perda de momento).
4. Setar `Humanoid.Jump = true` **e** injetar velocidade no mesmo salto.
5. Esquecer o próprio personagem no filtro de raycast (o raio bate no próprio corpo).
6. Alterar `CanCollide` de partes do mapa automaticamente.
7. `AgentRadius` maior que o personagem real em mapas indoor (portas somem).
8. Mutar as tabelas de waypoints do cache (estão congeladas; erro proposital).
9. Rodar a física de NPC sem `SetNetworkOwner(nil)`.
10. Remover waypoints `Jump`/`Custom` na suavização.

---

## 12. PONTOS A VALIDAR EMPIRICAMENTE [VALIDAR]

1. Se o waypoint `Action = Jump` marca o **ponto de decolagem** (assumido aqui) ou o de chegada. Ligue o debug (amarelo) e observe; se for o de chegada, dispare `_jumpToward` ao **iniciar** o segmento em direção a ele.
2. `MinObstacleHeight`: altura máxima que o Humanoid sobe sozinho sem pular no rig do jogo.
3. Se `PathfindingModifier` criado no cliente altera o pathfinding do cliente.
4. Tempo de atualização da navmesh após mudanças de geometria.
5. Resolução efetiva dos voxels (afeta largura mínima de portas com o `AgentRadius` escolhido).
6. Constantes `TakeoffMargin`, `ApexExtra`, `AirClearance` com o rig/animações reais do jogo.
