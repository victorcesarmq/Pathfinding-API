--!nocheck
--!nolint
--[[
	SmartPath 1.0.0 — bundle em um único arquivo.

	Gerado por tools/bundle.py a partir de src/SmartPath. Não edite aqui: edite os módulos e gere de novo.

	Como usar:
	  1. Crie um ModuleScript (o nome que quiser, por exemplo "SmartPath") em ReplicatedStorage.
	  2. Cole este arquivo inteiro nele.
	  3. local SmartPath = require(game.ReplicatedStorage.SmartPath)

	Módulos incluídos (17): Types, Util, Config, Errors, Geometry, Diagnostics, Signal, Scheduler, Debug, JumpExecutor, Predictor, RouteCache, Simplifier, RouteSolver, Agent, Compat, SmartPath.
	Cada um está dentro de uma função e só é executado na primeira vez que alguém o requer.
]]

local realRequire = require

local sources: {[string]: (any, any) -> any} = {}
local cache: {[string]: { value: any }} = {}
local loading: {[string]: boolean} = {}
local handles: {[string]: any} = {}
local bundled: {[any]: string} = {}

-- Faz o papel do `script` de cada módulo: `script.Parent.Util` e, no módulo principal, `script.Util`.
local root: any = setmetatable({ Name = "SmartPath" }, {
	__index = function(_, key)
		return handles[key]
	end,
})
bundled[root] = "SmartPath"

local function load(name: string): any
	local done = cache[name]
	if done then
		return done.value
	end
	if loading[name] then
		error("SmartPath (bundle): dependência circular em " .. name, 3)
	end
	loading[name] = true
	local handle = if name == "SmartPath" then root else handles[name]
	local value = sources[name](handle, function(target: any)
		local targetName = bundled[target]
		if targetName then
			return load(targetName)
		end
		return realRequire(target)
	end)
	loading[name] = nil
	cache[name] = { value = value }
	return value
end

handles["Types"] = { Name = "Types", Parent = root }
bundled[handles["Types"]] = "Types"
handles["Util"] = { Name = "Util", Parent = root }
bundled[handles["Util"]] = "Util"
handles["Config"] = { Name = "Config", Parent = root }
bundled[handles["Config"]] = "Config"
handles["Errors"] = { Name = "Errors", Parent = root }
bundled[handles["Errors"]] = "Errors"
handles["Geometry"] = { Name = "Geometry", Parent = root }
bundled[handles["Geometry"]] = "Geometry"
handles["Diagnostics"] = { Name = "Diagnostics", Parent = root }
bundled[handles["Diagnostics"]] = "Diagnostics"
handles["Signal"] = { Name = "Signal", Parent = root }
bundled[handles["Signal"]] = "Signal"
handles["Scheduler"] = { Name = "Scheduler", Parent = root }
bundled[handles["Scheduler"]] = "Scheduler"
handles["Debug"] = { Name = "Debug", Parent = root }
bundled[handles["Debug"]] = "Debug"
handles["JumpExecutor"] = { Name = "JumpExecutor", Parent = root }
bundled[handles["JumpExecutor"]] = "JumpExecutor"
handles["Predictor"] = { Name = "Predictor", Parent = root }
bundled[handles["Predictor"]] = "Predictor"
handles["RouteCache"] = { Name = "RouteCache", Parent = root }
bundled[handles["RouteCache"]] = "RouteCache"
handles["Simplifier"] = { Name = "Simplifier", Parent = root }
bundled[handles["Simplifier"]] = "Simplifier"
handles["RouteSolver"] = { Name = "RouteSolver", Parent = root }
bundled[handles["RouteSolver"]] = "RouteSolver"
handles["Agent"] = { Name = "Agent", Parent = root }
bundled[handles["Agent"]] = "Agent"
handles["Compat"] = { Name = "Compat", Parent = root }
bundled[handles["Compat"]] = "Compat"

-- ============================== Types.luau ==============================
sources["Types"] = function(script: any, require: any): any
-- Types.luau
-- Tipos compartilhados da SmartPath. Este módulo não
-- expõe valores de runtime além de uma tabela vazia — `export type` é a única razão
-- dele existir.

type SmartAction = "Walk" | "Jump" | "Drop" | "Link"

type Waypoint = {
	Position: Vector3,
	Action: Enum.PathWaypointAction,
	Label: string,
	SmartAction: SmartAction?,
	JumpHeight: number?,
}

type IndoorOptions = {
	AdaptiveRadius: boolean?,
	MinRadius: number?,
	RadiusSteps: { number }?,
}

type JumpOptions = {
	Enabled: boolean?,
	Mode: ("Native" | "Injected")?,
	MaxHeight: number?,
	DetourRatio: number?,
}

type StabilityOptions = {
	Cache: boolean?,
	Smoothing: boolean?,
	Hysteresis: number?,
	Curves: boolean?,
}

type GeometryOptions = {
	AutoFilter: boolean?,
	RequireNameMatch: boolean?,
}

type AgentOptions = {
	Radius: number?,
	Height: number?,
	WalkSpeed: number?,
}

type SchedulerOptions = {
	Priority: number?,
}

-- Tabela de opções. Todo campo é opcional; `nil` sempre significa
-- "derive do personagem ou use o default" (zero configuração obrigatória).
type Options = {
	Indoor: IndoorOptions?,
	Jump: JumpOptions?,
	Stability: StabilityOptions?,
	Geometry: GeometryOptions?,
	Agent: AgentOptions?,
	Scheduler: SchedulerOptions?,
	Debug: boolean?,
}

-- Options já resolvido por Config.resolve: todo campo preenchido.
type ResolvedOptions = {
	Indoor: {
		AdaptiveRadius: boolean,
		MinRadius: number,
		RadiusSteps: { number },
	},
	Jump: {
		Enabled: boolean,
		Mode: "Native" | "Injected",
		MaxHeight: number?,
		DetourRatio: number,
	},
	Stability: {
		Cache: boolean,
		Smoothing: boolean,
		Hysteresis: number,
		Curves: boolean,
	},
	Geometry: {
		AutoFilter: boolean,
		RequireNameMatch: boolean,
	},
	Agent: {
		Radius: number,
		Height: number,
		WalkSpeed: number,
	},
	Scheduler: {
		Priority: number,
	},
	Debug: boolean,
}

type AgentState = "Idle" | "Following" | "DirectJump" | "Airborne" | "Failed"

-- aceito onde a API pede um personagem: normalizado internamente por Util.
type CharacterLike = Model | Humanoid | BasePart

-- aceito onde a API pede um destino.
type TargetLike = Vector3 | BasePart | Model

return {}
end

-- ============================== Util.luau ==============================
sources["Util"] = function(script: any, require: any): any
-- Util.luau
-- Geometria, física e normalização de personagem usadas pelo resto da SmartPath.
-- Números mágicos ficam em Config; aqui só fórmulas e leitura de estado do jogo.

local Types = require(script.Parent.Types)

local Util = {}
local UP = Vector3.yAxis

-- ===== Normalização de personagem (aceitar Model, Humanoid ou BasePart) =====

function Util.resolveHumanoid(characterLike: Types.CharacterLike): Humanoid?
	if typeof(characterLike) ~= "Instance" then
		return nil
	end
	if characterLike:IsA("Humanoid") then
		return characterLike
	end
	if characterLike:IsA("Model") then
		return characterLike:FindFirstChildOfClass("Humanoid")
	end
	if characterLike:IsA("BasePart") then
		local model = characterLike:FindFirstAncestorOfClass("Model")
		return model and model:FindFirstChildOfClass("Humanoid") or nil
	end
	return nil
end

function Util.resolveRoot(characterLike: Types.CharacterLike): BasePart?
	if typeof(characterLike) ~= "Instance" then
		return nil
	end
	if characterLike:IsA("BasePart") then
		return characterLike
	end
	local humanoid = Util.resolveHumanoid(characterLike)
	return humanoid and humanoid.RootPart or nil
end

function Util.resolveModel(characterLike: Types.CharacterLike): Model?
	if typeof(characterLike) ~= "Instance" then
		return nil
	end
	if characterLike:IsA("Model") then
		return characterLike
	end
	local root = Util.resolveRoot(characterLike)
	return root and root:FindFirstAncestorOfClass("Model") or nil
end

-- destino aceito pela API (Vector3 | BasePart | Model) → posição concreta
function Util.resolveTargetPosition(target: Types.TargetLike): Vector3?
	if typeof(target) == "Vector3" then
		return target
	end
	if typeof(target) == "Instance" then
		if target:IsA("BasePart") then
			return target.Position
		end
		if target:IsA("Model") then
			if target.PrimaryPart then
				return target.PrimaryPart.Position
			end
			local ok, cframe = pcall(function()
				return target:GetPivot()
			end)
			if ok then
				return (cframe :: CFrame).Position
			end
		end
	end
	return nil
end

-- ===== Geometria plana =====

function Util.flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Y dos pés. R15: root - meia altura do root - HipHeight. R6: pernas de 2 studs.
function Util.getFeetY(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return root.Position.Y - root.Size.Y / 2 - humanoid.HipHeight
	end
	return root.Position.Y - root.Size.Y / 2 - 2
end

-- raio efetivo do agente: metade da maior dimensão horizontal do bounding box atual
-- (cobre R15/R6, acessórios e personagens customizados sem precisar adivinhar o rig)
function Util.getAgentRadius(character: Model): number
	local ok, _cframe, size = pcall(function()
		return character:GetBoundingBox()
	end)
	if not ok then
		return 2 -- default (R15 ≈ 1.5–2)
	end
	return math.max((size :: Vector3).X, (size :: Vector3).Z) / 2
end

function Util.getAgentHeight(character: Model): number
	local ok, _cframe, size = pcall(function()
		return character:GetBoundingBox()
	end)
	if not ok then
		return 5
	end
	return (size :: Vector3).Y
end

-- Raio físico do corpo, usado para validar volume livre (Spherecast). Agent.Radius vem do
-- bounding box e inclui braços/pernas que não colidem com o Humanoid; a implementação de
-- referência usa 1.2 de sonda para Agent.Radius 2, ou seja, 0.6x.
-- Ver D-009 em DECISIONS.md.
Util.BODY_RADIUS_RATIO = 0.6

function Util.getBodyRadius(agentRadius: number): number
	return agentRadius * Util.BODY_RADIUS_RATIO
end

-- ===== Física de salto =====

function Util.getMaxJumpHeight(humanoid: Humanoid): number
	if humanoid.UseJumpPower then
		return (humanoid.JumpPower ^ 2) / (2 * workspace.Gravity)
	end
	return humanoid.JumpHeight
end

function Util.velocityForHeight(h: number): number
	return math.sqrt(2 * workspace.Gravity * math.max(h, 0))
end

function Util.groundBelow(pos: Vector3, maxDist: number, params: RaycastParams?): RaycastResult?
	return workspace:Raycast(pos, -UP * maxDist, params)
end

-- comprimento da rota a partir de `fromPos`, começando no waypoint `startIndex`
function Util.pathLength(waypoints: { Types.Waypoint }, fromPos: Vector3, startIndex: number?): number
	local i0 = startIndex or 1
	if not waypoints[i0] then
		return 0
	end
	local total = (waypoints[i0].Position - fromPos).Magnitude
	for i = i0 + 1, #waypoints do
		total += (waypoints[i].Position - waypoints[i - 1].Position).Magnitude
	end
	return total
end

-- ===== Debug (só sob options.Debug, sempre prefixado; o desenho fica em Debug.luau) =====

function Util.debugPrint(enabled: boolean, ...: any)
	if not enabled then
		return
	end
	print("[SmartPath]", ...)
end

return Util
end

-- ============================== Config.luau ==============================
sources["Config"] = function(script: any, require: any): any
-- Config.luau
-- Defaults da API pública (a tabela de opções é estável) + merge profundo + derivação
-- a partir do personagem. `nil` num campo de Options sempre significa "default ou
-- derivado do personagem" (zero configuração obrigatória).

local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

local Config = {}

-- abaixo disto o Humanoid não passa nem de um degrau (Predictor: MIN_OBSTACLE_HEIGHT)
local MIN_JUMP_HEIGHT = 1.2

local Defaults: Types.Options = {
	Indoor = {
		AdaptiveRadius = true,
		MinRadius = 0.5,
		RadiusSteps = { 1.5, 1.0, 0.5 },
	},
	Jump = {
		Enabled = true,
		Mode = "Native",
		DetourRatio = 1.4,
	},
	Stability = {
		Cache = true,
		Smoothing = true,
		Hysteresis = 0.15,
		Curves = false, -- desligado: quem não pede não muda de comportamento (D-035)
	},
	Geometry = {
		AutoFilter = true,
		RequireNameMatch = true,
	},
	Agent = {},
	Scheduler = {
		Priority = 0,
	},
	Debug = false,
}

Config.Defaults = Defaults

-- merge profundo: dicionários mesclam campo a campo; arrays (ex.: RadiusSteps) são
-- substituídos inteiros — misturar índices de arrays de tamanhos diferentes não tem
-- semântica clara aqui.
local function isArray(t: { [any]: any }): boolean
	return #t > 0
end

local function deepMerge(base: { [string]: any }, over: { [string]: any }?): { [string]: any }
	local out: { [string]: any } = {}
	for k, v in pairs(base) do
		local o = over and over[k]
		if type(v) == "table" and not isArray(v) and type(o) == "table" then
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
			if out[k] == nil then
				out[k] = v
			end
		end
	end
	return out
end

function Config.merge(overrides: Types.Options?): { [string]: any }
	return deepMerge(Config.Defaults :: any, overrides :: any)
end

-- Mescla duas camadas de overrides do usuário, sem os defaults no meio: o Agent guarda o
-- que o usuário pediu e re-resolve a cada SetOptions, mantendo `nil` = "derive do personagem".
function Config.overlay(base: Types.Options?, over: Types.Options?): Types.Options
	return deepMerge((base or {}) :: any, over :: any) :: any
end

-- Resolve as opções finais para um personagem específico: aplica os overrides do
-- usuário sobre os defaults e preenche todo campo nil de Agent/Jump com um valor
-- derivado do próprio personagem.
function Config.resolve(character: Types.CharacterLike, overrides: Types.Options?): Types.ResolvedOptions
	local merged = Config.merge(overrides)

	local humanoid = Util.resolveHumanoid(character)
	local model = Util.resolveModel(character)

	local agent = merged.Agent
	if agent.Radius == nil then
		agent.Radius = model and Util.getAgentRadius(model) or 2
	end
	if agent.Height == nil then
		agent.Height = model and Util.getAgentHeight(model) or 5
	end
	if agent.WalkSpeed == nil then
		agent.WalkSpeed = humanoid and humanoid.WalkSpeed or 16
	end

	if merged.Jump.MaxHeight == nil then
		merged.Jump.MaxHeight = humanoid and Util.getMaxJumpHeight(humanoid) or 7.2
	end

	-- Um Humanoid que não salta (JumpHeight 0, JumpPower 0) não pode ganhar rotas com saltos: se o
	-- usuário não decidiu, Jump.Enabled é derivado do personagem (D-033). Vale na criação e no SetOptions.
	local userJump = overrides and overrides.Jump
	if not (userJump and userJump.Enabled ~= nil) and humanoid and Util.getMaxJumpHeight(humanoid) < MIN_JUMP_HEIGHT then
		merged.Jump.Enabled = false
	end

	return merged :: Types.ResolvedOptions
end

return Config
end

-- ============================== Errors.luau ==============================
sources["Errors"] = function(script: any, require: any): any
-- Errors.luau
-- Códigos de erro diagnósticos da SmartPath.
-- CONGELADO: mudar uma chave aqui é mudança de contrato público, exige autorização.

type ErrorCode =
	"no_path"
	| "corridor_too_narrow"
	| "obstacle_too_tall"
	| "no_landing"
	| "goal_unreachable"
	| "invisible_collider"
	| "stuck"
	| "cancelled"
	| "character_lost"
	| "timeout"

local Errors = {
	NoPath = "no_path" :: ErrorCode,
	CorridorTooNarrow = "corridor_too_narrow" :: ErrorCode,
	ObstacleTooTall = "obstacle_too_tall" :: ErrorCode,
	NoLanding = "no_landing" :: ErrorCode,
	GoalUnreachable = "goal_unreachable" :: ErrorCode,
	InvisibleCollider = "invisible_collider" :: ErrorCode,
	Stuck = "stuck" :: ErrorCode,
	Cancelled = "cancelled" :: ErrorCode,
	CharacterLost = "character_lost" :: ErrorCode,
	Timeout = "timeout" :: ErrorCode,
}

Errors.All = {
	Errors.NoPath,
	Errors.CorridorTooNarrow,
	Errors.ObstacleTooTall,
	Errors.NoLanding,
	Errors.GoalUnreachable,
	Errors.InvisibleCollider,
	Errors.Stuck,
	Errors.Cancelled,
	Errors.CharacterLost,
	Errors.Timeout,
} :: { ErrorCode }

function Errors.isValid(code: string): boolean
	for _, c in ipairs(Errors.All) do
		if c == code then
			return true
		end
	end
	return false
end

return Errors
end

-- ============================== Geometry.luau ==============================
sources["Geometry"] = function(script: any, require: any): any
-- Geometry.luau
-- Filtro de geometria invisível colidível. Duas "vítimas" diferentes, dois remédios:
-- PathfindingModifier
-- com PassThrough para a navmesh do PathfindingService, e RaycastParams filtrado para os
-- raycasts da própria SmartPath (predição, suavização, chão).
--
-- Singleton documentado: existe um por ambiente (cliente ou
-- servidor) — cada um requer sua própria cópia do módulo e mantém sua própria lista.
--
-- AutoFilter/RequireNameMatch são globais ao ambiente, não por agente: ver D-006 em
-- DECISIONS.md sobre por que isso é assim, mesmo a Options.Geometry sendo
-- lida por agente.

local CollectionService = game:GetService("CollectionService")

local Geometry = {}

-- Constantes internas de classificação. Não fazem parte da tabela de
-- Options pública porque afetam o mapa inteiro, não um agente específico.
local IGNORE_TAG = "NavIgnore"
local SOLID_TAG = "NavSolid"
local INVISIBLE_THRESHOLD = 0.95
local NAME_PATTERNS = { "zone", "trigger", "hitbox", "region", "bounds", "sensor", "detector", "area" }
local MODIFIER_NAME = "SmartPathAutoPassThrough"
local MODIFIER_LABEL = "SmartPathIgnored"

type ClassifyReason = "tag" | "auto"

type Entry = {
	reason: ClassifyReason,
}

local ignored: { [BasePart]: Entry } = {}
local ignoredList: { BasePart } = {}
-- Modelos com Humanoid (personagens de jogadores e NPCs). Eles se movem sozinhos, então nenhuma
-- consulta de rota pode tratá-los como parede (D-028): entram em todo RaycastParams como excluídos.
local characters: { [Model]: boolean } = {}
local version = 0
local started = false
local autoFilterEnabled = true
local requireNameMatch = true

local changedEvent = Instance.new("BindableEvent")
Geometry.Changed = changedEvent.Event

-- Dispara quando uma parte colidível e consultável entra no workspace (depois do defer, com as
-- propriedades já setadas). O Path.Blocked da engine não é confiável para partes inseridas em
-- runtime (D-021), então os agentes usam isto para revalidar a rota que estão seguindo.
local partAddedEvent = Instance.new("BindableEvent")
Geometry.PartAdded = partAddedEvent.Event

local descendantConn: RBXScriptConnection? = nil
local ancestryConns: { [BasePart]: RBXScriptConnection } = {}
local tagConns: { RBXScriptConnection } = {}

local function bump()
	version += 1
	changedEvent:Fire(version)
end

local function nameMatches(name: string): boolean
	local n = string.lower(name)
	for _, pattern in ipairs(NAME_PATTERNS) do
		if string.find(n, pattern, 1, true) then
			return true
		end
	end
	return false
end

local function hasTagInAncestry(inst: Instance, tag: string): boolean
	local cur: Instance? = inst
	while cur and cur ~= workspace do
		if CollectionService:HasTag(cur, tag) then
			return true
		end
		cur = cur.Parent
	end
	return false
end

-- Classificação (ordem de precedência):
-- 1) NavSolid  -> sempre sólido, precedência ABSOLUTA sobre tudo, inclusive heurística.
-- 2) NavIgnore -> sempre atravessável.
-- 3) CanCollide = false -> já ignorado pelo pathfinding; nada a fazer.
-- 4) auto-detecção (se AutoFilter ligado): Transparency alta + (se exigido) nome suspeito.
local function classify(part: Instance): (boolean, ClassifyReason?)
	if not part:IsA("BasePart") then
		return false, nil
	end
	if hasTagInAncestry(part, SOLID_TAG) then
		return false, nil
	end
	if hasTagInAncestry(part, IGNORE_TAG) then
		return true, "tag"
	end
	if not part.CanCollide then
		return false, nil
	end
	if not autoFilterEnabled then
		return false, nil
	end
	if part.Transparency < INVISIBLE_THRESHOLD then
		return false, nil
	end
	if requireNameMatch and not nameMatches(part.Name) then
		return false, nil
	end
	return true, "auto"
end

local function unmark(part: BasePart)
	if not ignored[part] then
		return
	end
	ignored[part] = nil
	local i = table.find(ignoredList, part)
	if i then
		table.remove(ignoredList, i)
	end
	local mod = part:FindFirstChild(MODIFIER_NAME)
	if mod then
		mod:Destroy()
	end
	local conn = ancestryConns[part]
	if conn then
		conn:Disconnect()
		ancestryConns[part] = nil
	end
	bump()
end

local function mark(part: BasePart, reason: ClassifyReason)
	if ignored[part] then
		ignored[part].reason = reason
		return
	end
	ignored[part] = { reason = reason }
	table.insert(ignoredList, part)
	if part.CanCollide and not part:FindFirstChild(MODIFIER_NAME) then
		local mod = Instance.new("PathfindingModifier")
		mod.Name = MODIFIER_NAME
		mod.PassThrough = true
		mod.Label = MODIFIER_LABEL
		mod.Parent = part
	end
	ancestryConns[part] = part.AncestryChanged:Connect(function(_, parent)
		if not parent then
			unmark(part)
		end
	end)
	bump()
end

local function trackCharacter(humanoid: Humanoid)
	local model = humanoid.Parent
	if model and model:IsA("Model") and not characters[model] then
		characters[model] = true
		bump() -- o RaycastParams cacheado de um Agent (por versão) passa a excluí-lo
	end
end

-- personagem de verdade: parte de um modelo com Humanoid
local function inCharacter(part: Instance): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function refresh(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	local shouldIgnore, reason = classify(inst)
	if shouldIgnore and reason then
		mark(inst, reason :: ClassifyReason)
	else
		unmark(inst)
	end
end

local function refreshTree(inst: Instance)
	refresh(inst)
	for _, d in ipairs(inst:GetDescendants()) do
		refresh(d)
	end
end

-- reclassifica tudo que já está marcado e varre o workspace de novo — usado quando
-- AutoFilter/RequireNameMatch mudam, já que a classificação de partes existentes pode
-- ter mudado de resultado.
local function refreshAll()
	for _, part in ipairs(table.clone(ignoredList)) do
		refresh(part)
	end
	for _, d in ipairs(workspace:GetDescendants()) do
		refresh(d)
	end
end

function Geometry.start()
	if started then
		return
	end
	started = true
	for _, d in ipairs(workspace:GetDescendants()) do
		refresh(d)
		if d:IsA("Humanoid") then
			trackCharacter(d)
		end
	end
	descendantConn = workspace.DescendantAdded:Connect(function(d)
		if d:IsA("Humanoid") then
			trackCharacter(d)
		end
		-- defer: propriedades (Transparency, CanCollide, Name) costumam ser setadas logo
		-- após o parent
		task.defer(function()
			refresh(d)
			if d:IsA("BasePart") and d.CanCollide and d.CanQuery and not ignored[d] then
				partAddedEvent:Fire(d)
			end
		end)
	end)
	for _, tag in ipairs({ IGNORE_TAG, SOLID_TAG }) do
		table.insert(tagConns, CollectionService:GetInstanceAddedSignal(tag):Connect(refreshTree))
		table.insert(tagConns, CollectionService:GetInstanceRemovedSignal(tag):Connect(refreshTree))
	end
end

-- Desliga completamente e desfaz 100% do resíduo no mapa: desligar não pode deixar efeito
-- residual.
function Geometry.stop()
	if not started then
		return
	end
	started = false
	if descendantConn then
		descendantConn:Disconnect()
		descendantConn = nil
	end
	for _, conn in ipairs(tagConns) do
		conn:Disconnect()
	end
	table.clear(tagConns)
	for _, part in ipairs(table.clone(ignoredList)) do
		unmark(part)
	end
	table.clear(characters)
end

function Geometry.isRunning(): boolean
	return started
end

-- Liga/desliga a heurística de auto-detecção (Transparency + nome suspeito). Tags
-- NavSolid/NavIgnore continuam funcionando independente disso: são intenção explícita do
-- desenvolvedor, não heurística, então desligar AutoFilter não deve mexer nelas.
function Geometry.setAutoFilter(enabled: boolean)
	if autoFilterEnabled == enabled then
		return
	end
	autoFilterEnabled = enabled
	if started then
		refreshAll()
	end
end

function Geometry.getAutoFilter(): boolean
	return autoFilterEnabled
end

function Geometry.setRequireNameMatch(enabled: boolean)
	if requireNameMatch == enabled then
		return
	end
	requireNameMatch = enabled
	if started then
		refreshAll()
	end
end

function Geometry.getRequireNameMatch(): boolean
	return requireNameMatch
end

function Geometry.getVersion(): number
	return version
end

function Geometry.getIgnoredCount(): number
	return #ignoredList
end

-- Instâncias que a própria SmartPath cria e que nunca podem contar como mapa (a pasta de
-- debug). Entram em todo RaycastParams; as que saíram do jogo são descartadas aqui.
local libraryExclusions: { Instance } = {}

function Geometry.addExclusion(inst: Instance)
	if table.find(libraryExclusions, inst) then
		return
	end
	table.insert(libraryExclusions, inst)
	bump() -- params já construídos (o do Agent é cacheado por versão) passam a incluí-la
end

-- Parte invisível e colidível que o desenvolvedor não declarou sólida: suspeita nº 1 quando algo
-- bloqueia sem motivo visível. NavSolid é intenção explícita (limite de mapa), então nunca é
-- suspeita. Não olha se a lib a filtrou (`ignored`): as consultas do solver já excluem as
-- filtradas, e o diagnóstico de "travou" quer justamente as que o corpo bate e a malha não vê.
function Geometry.isInvisibleCollider(part: Instance): boolean
	return part:IsA("BasePart")
		and part.CanCollide
		and part.Transparency >= INVISIBLE_THRESHOLD
		and not hasTagInAncestry(part, SOLID_TAG)
		-- o HumanoidRootPart do R15 é invisível e colidível: é o corpo de outro personagem, não um
		-- gatilho esquecido no mapa
		and not inCharacter(part)
end

-- RaycastParams para os raycasts da própria SmartPath. `extra` = instâncias adicionais a
-- excluir (tipicamente o personagem do próprio agente).
function Geometry.buildRaycastParams(extra: { Instance }?): RaycastParams
	local list: { Instance } = {}
	for _, part in ipairs(ignoredList) do
		table.insert(list, part)
	end
	for model in pairs(characters) do
		if model.Parent then
			table.insert(list, model)
		else
			characters[model] = nil
		end
	end
	for i = #libraryExclusions, 1, -1 do
		local inst = libraryExclusions[i]
		if inst.Parent then
			table.insert(list, inst)
		else
			table.remove(libraryExclusions, i)
		end
	end
	if extra then
		for _, inst in ipairs(extra) do
			table.insert(list, inst)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = list
	params.RespectCanCollide = true
	params.IgnoreWater = true
	return params
end

-- Lista partes invisíveis colidíveis que NÃO foram classificadas, para revisão manual.
-- Nunca alteramos CanCollide sozinhos (D-005): quem decide é o desenvolvedor.
function Geometry.audit(): { BasePart }
	local suspects = {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if
			d:IsA("BasePart")
			and d.CanCollide
			and not ignored[d]
			and Geometry.isInvisibleCollider(d)
		then
			table.insert(suspects, d)
		end
	end
	return suspects
end

return Geometry
end

-- ============================== Diagnostics.luau ==============================
sources["Diagnostics"] = function(script: any, require: any): any
-- Diagnostics.luau
-- Fase 6: transforma falhas em causas que o desenvolvedor consegue agir sobre.
--   explain          código de erro + details -> frase legível (SmartPath.explain);
--   findInvisible*   procura a parte invisível colidível que bloqueia uma rota (invisible_collider);
--   refineJumpFailure converte um no_path em obstacle_too_tall / no_landing quando o Predictor
--                     explica por que o salto até o destino é impossível.
-- Só funções puras e consultas de leitura ao workspace; não guarda estado.

local Errors = require(script.Parent.Errors)
local Geometry = require(script.Parent.Geometry)

local Diagnostics = {}

type Details = { [string]: any }

-- ===== explain =====

local function num(v: any, decimals: number?): string
	if typeof(v) ~= "number" then
		return "?"
	end
	return string.format("%." .. (decimals or 1) .. "f", v)
end

local function vec(v: any): string
	if typeof(v) ~= "Vector3" then
		return "?"
	end
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

local function nameOf(inst: any): string
	if typeof(inst) ~= "Instance" then
		return "uma parte desconhecida"
	end
	local ok, full = pcall(function()
		return inst:GetFullName()
	end)
	return if ok then full else inst.Name
end

local function radiiList(list: any): string
	if typeof(list) ~= "table" or #list == 0 then
		return "nenhum"
	end
	local parts = {}
	for _, r in ipairs(list) do
		table.insert(parts, num(r, 2))
	end
	return table.concat(parts, ", ")
end

local function atLeast(d: Details): string
	return if d.atLeast then "pelo menos " else ""
end

-- Uma função por código. Cada uma tolera details incompleto: explain nunca pode errar.
local explainers: { [string]: (d: Details) -> string } = {
	[Errors.NoPath] = function(d)
		if d.noGround then
			return "O agente não tem chão sob os pés (está em queda ou fora do mapa), então não há de onde "
				.. "calcular uma rota."
		end
		return string.format(
			"Não existe rota até o destino, nem depois de tentar os raios %s. Confira se há chão contínuo entre "
				.. "os dois pontos e se algum obstáculo fechado isola o destino.",
			radiiList(d.triedRadii)
		)
	end,
	[Errors.CorridorTooNarrow] = function(d)
		local text = string.format(
			"O corredor só comporta um agente de raio até %s, mas o agente tem %s. Reduza Agent.Radius ou alargue "
				.. "a passagem.",
			num(d.requiredRadius),
			num(d.agentRadius)
		)
		if typeof(d.blockedAt) == "Vector3" then
			text ..= " O ponto mais apertado fica perto de " .. vec(d.blockedAt) .. "."
		end
		return text
	end,
	[Errors.ObstacleTooTall] = function(d)
		return string.format(
			"Há um obstáculo de %s%s studs no caminho e o agente salta no máximo %s. Aumente o JumpHeight, "
				.. "reduza o obstáculo ou abra um desvio.",
			atLeast(d),
			num(d.height),
			num(d.maxJump)
		)
	end,
	[Errors.NoLanding] = function(d)
		return string.format(
			"O agente conseguiria saltar o obstáculo, mas não há chão seguro do outro lado (queda de %s%s studs). "
				.. "Coloque chão depois do obstáculo ou abra outra passagem.",
			atLeast(d),
			num(d.drop)
		)
	end,
	[Errors.GoalUnreachable] = function(d)
		if typeof(d.nearestValid) == "Vector3" then
			return "O destino está fora da malha de navegação (dentro de uma parede ou no ar). O ponto válido mais "
				.. "próximo é "
				.. vec(d.nearestValid)
				.. "."
		end
		return "O destino está fora da malha de navegação (dentro de uma parede ou no ar) e não há ponto válido "
			.. "por perto."
	end,
	[Errors.InvisibleCollider] = function(d)
		return string.format(
			"A rota está bloqueada por uma parte invisível e colidível: %s. Se for um gatilho, dê a ela a tag "
				.. "NavIgnore (ou um nome como \"Trigger\"); se for um limite de mapa, dê a tag NavSolid; se não "
				.. "deveria colidir, desligue CanCollide.",
			nameOf(d.instance)
		)
	end,
	[Errors.Stuck] = function(d)
		return string.format(
			"O agente travou perto de %s depois de %s tentativas de sair. Algo que a malha de navegação não "
				.. "enxerga (uma parte com tag NavIgnore, um modelo sem colisão correta) está no caminho.",
			vec(d.position),
			if typeof(d.strikes) == "number" then tostring(d.strikes) else "?"
		)
	end,
	[Errors.Cancelled] = function(_)
		return "A movimentação foi cancelada por Stop() ou por um novo MoveTo."
	end,
	[Errors.CharacterLost] = function(_)
		return "O personagem morreu ou foi removido durante a movimentação."
	end,
	[Errors.Timeout] = function(d)
		return string.format(
			"O agente passou de %s s sem chegar ao destino. Ele pode estar preso repetindo a mesma tentativa, "
				.. "ou o destino se afastando dele.",
			num(d.elapsed)
		)
	end,
}

-- Devolve sempre uma string. `details` pode ser nil ou incompleto.
function Diagnostics.explain(reason: string?, details: Details?): string
	if reason == nil then
		return "Nenhum motivo informado."
	end
	local fn = explainers[reason]
	if not fn then
		return "Motivo desconhecido: " .. tostring(reason) .. "."
	end
	local d: Details = if typeof(details) == "table" then details else {}
	local ok, text = pcall(fn, d)
	if ok then
		return text
	end
	return "Falha (" .. reason .. ") com dados que a SmartPath não soube descrever."
end

-- ===== Causa: parte invisível colidível =====

-- Primeira parte invisível colidível que toca um ponto (o "onde bateu" de um corredor estreito,
-- ou o destino dentro de uma parede).
function Diagnostics.findInvisibleAt(position: Vector3, radius: number, overlap: OverlapParams): BasePart?
	local ok, parts = pcall(function()
		return workspace:GetPartBoundsInRadius(position, radius, overlap)
	end)
	if not ok then
		return nil
	end
	for _, part in ipairs(parts :: { BasePart }) do
		if Geometry.isInvisibleCollider(part) then
			return part
		end
	end
	return nil
end

-- A primeira coisa que o corpo (esfera de `radius`) bate no caminho reto de `from` até `to`: se for
-- uma parte invisível colidível, é ela. Só a PRIMEIRA batida conta: uma parede visível antes dela
-- pode ser a causa de verdade, e apontar a parte invisível de trás seria palpite.
function Diagnostics.findInvisibleAlong(params: RaycastParams, from: Vector3, to: Vector3, radius: number): (BasePart?, Vector3?)
	local delta = to - from
	if delta.Magnitude < 1e-3 then
		return nil, nil
	end
	local ok, hit = pcall(function()
		return workspace:Spherecast(from, radius, delta, params)
	end)
	if not ok or not hit then
		return nil, nil
	end
	local inst = (hit :: RaycastResult).Instance
	if inst and Geometry.isInvisibleCollider(inst) then
		return inst :: BasePart, (hit :: RaycastResult).Position
	end
	return nil, nil
end

-- ===== Causa: salto impossível =====

-- `why`/`info` vêm do Predictor.analyze feito em direção ao destino. Só converte no_path: se a
-- malha achou rota mas o corpo não coube (corridor_too_narrow) ou o destino não existe
-- (goal_unreachable), o problema não é um obstáculo a saltar. Retorna (código, details) ou nil.
function Diagnostics.refineJumpFailure(reason: string, details: Details, why: string?, info: Details?): (string?, Details?)
	if reason ~= Errors.NoPath or not info then
		return nil, nil
	end
	if why == "too_tall" or why == "insufficient_jump" then
		return Errors.ObstacleTooTall,
			{
				height = info.height,
				maxJump = info.maxJump,
				atLeast = info.atLeast,
				blockedAt = info.at,
				triedRadii = details.triedRadii,
			}
	end
	if why == "no_landing" or why == "drop_too_high" then
		return Errors.NoLanding,
			{ drop = info.drop, atLeast = info.atLeast, blockedAt = info.at, triedRadii = details.triedRadii }
	end
	return nil, nil
end

return Diagnostics
end

-- ============================== Signal.luau ==============================
sources["Signal"] = function(script: any, require: any): any
-- Signal.luau
-- Wrapper leve sobre BindableEvent (:Connect, :Fire, :Wait, :Destroy). Existe para que
-- :Destroy() em qualquer objeto da lib desconecte 100% das conexões a partir de um único
-- ponto sem expor o BindableEvent bruto — quem consome um sinal público
-- não deve poder chamar :Fire() nele por engano.

local Signal = {}
Signal.__index = Signal

type Signal = typeof(setmetatable(
	{} :: {
		_bindable: BindableEvent,
		_connections: { RBXScriptConnection },
	},
	Signal
))

function Signal.new(): Signal
	local self = setmetatable({
		_bindable = Instance.new("BindableEvent"),
		_connections = {},
	}, Signal)
	return self
end

function Signal.Connect(self: Signal, fn: (...any) -> ()): RBXScriptConnection
	local conn = self._bindable.Event:Connect(fn)
	table.insert(self._connections, conn)
	return conn
end

function Signal.Once(self: Signal, fn: (...any) -> ()): RBXScriptConnection
	local conn: RBXScriptConnection
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal.Wait(self: Signal): ...any
	return self._bindable.Event:Wait()
end

function Signal.Fire(self: Signal, ...: any)
	self._bindable:Fire(...)
end

function Signal.Destroy(self: Signal)
	for _, conn in ipairs(self._connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)
	self._bindable:Destroy()
end

return Signal
end

-- ============================== Scheduler.luau ==============================
sources["Scheduler"] = function(script: any, require: any): any
-- Scheduler.luau
-- Fila global de cálculos de rota com orçamento por frame, prioridade numérica,
-- cancelamento e coalescência de pedidos idênticos.
-- Singleton documentado: existe um por ambiente
-- (cliente/servidor), cada um com sua própria fila.
--
-- Prioridade: número MAIOR = mais urgente (ver D-007 em DECISIONS.md). Em empate, o
-- pedido mais antigo (menor `seq`) vai primeiro, para evitar starvation por ordem.
--
-- O orçamento limita quantos jobs são INICIADOS por frame, não quantos ficam "em voo":
-- ComputeAsync já dá yield sozinho, então o custo que queremos limitar é o de disparar a
-- chamada (voxelização/busca), não o de esperar ela terminar.

local RunService = game:GetService("RunService")
local Signal = require(script.Parent.Signal)

local Scheduler = {}

type Handle = {
	cancel: (self: Handle) -> (),
	await: (self: Handle) -> ...any,
	isDone: (self: Handle) -> boolean,
	isCancelled: (self: Handle) -> boolean,
}

type Entry = {
	key: string,
	priority: number,
	fn: () -> ...any,
	seq: number,
	waiters: { HandleImpl },
	started: boolean,
}

type HandleImpl = {
	_entry: Entry,
	_cancelled: boolean,
	_done: boolean,
	_results: { any }?,
	_resultsN: number,
	_completed: Signal.Signal,
}

local HandleMeta = {}
HandleMeta.__index = HandleMeta

local queue: { Entry } = {}
local byKey: { [string]: Entry } = {}
local seqCounter = 0
local budget = 4

local function newHandle(entry: Entry): HandleImpl
	return (
		setmetatable({
			_entry = entry,
			_cancelled = false,
			_done = false,
			_results = nil,
			_resultsN = 0,
			_completed = Signal.new(),
		}, HandleMeta) :: any
	) :: HandleImpl
end

function HandleMeta:cancel()
	local this = self :: HandleImpl
	if this._done or this._cancelled then
		return
	end
	this._cancelled = true
	this._completed:Fire() -- libera quem estiver em :await()

	local entry = this._entry
	if entry.started then
		return -- já disparado: não dá pra abortar o fn em voo, só descartar o resultado
	end
	local idx = table.find(entry.waiters, this :: any)
	if idx then
		table.remove(entry.waiters, idx)
	end
	if #entry.waiters == 0 then
		-- ninguém mais espera esse cálculo: some da fila antes de rodar (regra: pedido
		-- cancelado nunca executa)
		local qIdx = table.find(queue, entry)
		if qIdx then
			table.remove(queue, qIdx)
		end
		if byKey[entry.key] == entry then
			byKey[entry.key] = nil
		end
	end
end

function HandleMeta:isDone(): boolean
	return (self :: HandleImpl)._done
end

function HandleMeta:isCancelled(): boolean
	return (self :: HandleImpl)._cancelled
end

function HandleMeta:await(): ...any
	local this = self :: HandleImpl
	if this._done then
		return table.unpack(this._results :: { any }, 1, this._resultsN)
	end
	if this._cancelled then
		return nil, "cancelled"
	end
	this._completed:Wait()
	if this._cancelled then
		return nil, "cancelled"
	end
	return table.unpack(this._results :: { any }, 1, this._resultsN)
end

-- ===== Submissão =====

-- Duas submissões com a mesma `key` enquanto a primeira ainda não rodou viram um único
-- cálculo: a prioridade efetiva é a maior das duas, e cada chamador recebe seu próprio
-- Handle (pode cancelar seu próprio interesse sem afetar o outro chamador).
function Scheduler.submit(key: string, priority: number, fn: () -> ...any): Handle
	local existing = byKey[key]
	if existing and not existing.started then
		existing.priority = math.max(existing.priority, priority)
		local handle = newHandle(existing)
		table.insert(existing.waiters, handle)
		return handle :: any
	end

	seqCounter += 1
	local entry: Entry = {
		key = key,
		priority = priority,
		fn = fn,
		seq = seqCounter,
		waiters = {},
		started = false,
	}
	local handle = newHandle(entry)
	table.insert(entry.waiters, handle)
	table.insert(queue, entry)
	byKey[key] = entry
	return handle :: any
end

-- ===== Configuração do orçamento =====

function Scheduler.setBudget(n: number)
	budget = math.max(1, math.floor(n))
end

function Scheduler.getBudget(): number
	return budget
end

function Scheduler.getQueueLength(): number
	return #queue
end

-- ===== Execução =====

local function popBest(): Entry?
	if #queue == 0 then
		return nil
	end
	local bestIdx = 1
	for i = 2, #queue do
		local a, b = queue[i], queue[bestIdx]
		if a.priority > b.priority or (a.priority == b.priority and a.seq < b.seq) then
			bestIdx = i
		end
	end
	return table.remove(queue, bestIdx)
end

local function runEntry(entry: Entry)
	entry.started = true
	if byKey[entry.key] == entry then
		byKey[entry.key] = nil
	end
	task.spawn(function()
		local ok, packed = pcall(function()
			return table.pack(entry.fn())
		end)
		local results
		if ok then
			results = packed
		else
			-- falha aqui não é rotina de debug: é bug real, por isso não fica atrás de
			-- options.Debug
			warn("[SmartPath] Scheduler: job falhou:", packed)
			results = table.pack(nil, "scheduler_job_error")
		end
		for _, handle in ipairs(entry.waiters) do
			if not handle._cancelled then
				handle._results = results
				handle._resultsN = results.n
				handle._done = true
				handle._completed:Fire()
			end
		end
	end)
end

RunService.Heartbeat:Connect(function()
	local processed = 0
	while processed < budget do
		local entry = popBest()
		if not entry then
			break
		end
		if #entry.waiters == 0 then
			continue -- todo mundo cancelou enquanto esperava; não conta orçamento
		end
		processed += 1
		runEntry(entry)
	end
end)

return Scheduler
end

-- ============================== Debug.luau ==============================
sources["Debug"] = function(script: any, require: any): any
-- Debug.luau
-- Fase 6: visualização e painel (SmartPath.Debug). Tudo aqui só roda quando quem chama já checou Options.Debug
-- (ou, no caso do painel, quando o desenvolvedor pede explicitamente): com Debug = false nenhuma
-- função deste módulo é chamada, então não há instância, print nem custo.
--
-- Regra das partes de debug: Anchored, CanCollide = false, CanQuery = false, CanTouch = false. Uma
-- parte de debug que colidisse ou aparecesse em Raycast/Spherecast mudaria o resultado dos
-- cálculos que ela está mostrando. Como segunda barreira a pasta também entra em todo
-- RaycastParams da lib (Geometry.addExclusion).

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Types = require(script.Parent.Types)
local Geometry = require(script.Parent.Geometry)
local Scheduler = require(script.Parent.Scheduler)
local Diagnostics = require(script.Parent.Diagnostics)

local Debug = {}

local FOLDER_NAME = "SmartPathDebug"
local DEFAULT_LIFETIME = 6
local PANEL_REFRESH_INTERVAL = 0.25

Debug.Colors = {
	Walk = Color3.fromRGB(80, 200, 255), -- azul
	Jump = Color3.fromRGB(255, 200, 0), -- amarelo
	Drop = Color3.fromRGB(255, 140, 40), -- laranja
	Link = Color3.fromRGB(255, 0, 200), -- magenta
	Takeoff = Color3.fromRGB(0, 230, 200), -- turquesa
	Landing = Color3.fromRGB(60, 255, 60), -- verde
	Obstacle = Color3.fromRGB(255, 60, 60), -- vermelho
	Radius = Color3.fromRGB(120, 200, 120), -- verde suave: raio cheio (o pouso é verde vivo)
	RadiusReduced = Color3.fromRGB(255, 140, 40), -- laranja: o agente passou com raio reduzido
}

-- ===== Pasta e partes =====

local folder: Folder? = nil

-- Cria a pasta na primeira chamada (nunca antes: Debug desligado não cria instância).
function Debug.getFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = workspace
	Geometry.addExclusion(created)
	folder = created
	return created
end

-- A pasta se ela já existe; nunca a cria. Para os testes de "zero instâncias".
function Debug.peekFolder(): Folder?
	local f = folder
	if f and f.Parent then
		return f
	end
	return nil
end

function Debug.clear()
	local f = folder
	folder = nil
	if f then
		f:Destroy()
	end
end

local function newPart(shape: Enum.PartType, size: Vector3, color: Color3, cframe: CFrame, lifetime: number?): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Size = size
	p.Anchored = true
	p.CanCollide = false -- nunca poluir a navmesh nem os próprios raycasts da lib
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Material = Enum.Material.Neon
	p.Color = color
	p.CFrame = cframe
	p.Parent = Debug.getFolder()
	Debris:AddItem(p, lifetime or DEFAULT_LIFETIME)
	return p
end

local function addLabel(part: BasePart, text: string, color: Color3?)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(180, 22)
	gui.StudsOffset = Vector3.new(0, 1.6, 0)
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 14
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = gui
	gui.Parent = part
end

-- ===== Desenho =====

function Debug.point(pos: Vector3, color: Color3, size: number?, lifetime: number?): Part
	return newPart(Enum.PartType.Ball, Vector3.one * (size or 0.6), color, CFrame.new(pos), lifetime)
end

function Debug.line(a: Vector3, b: Vector3, color: Color3, lifetime: number?)
	local len = (b - a).Magnitude
	if len < 0.05 then
		return
	end
	newPart(Enum.PartType.Block, Vector3.new(0.12, 0.12, len), color, CFrame.lookAt((a + b) / 2, b), lifetime)
end

local function colorFor(wp: Types.Waypoint): Color3
	if wp.SmartAction == "Jump" or wp.Action == Enum.PathWaypointAction.Jump then
		return Debug.Colors.Jump
	elseif wp.SmartAction == "Drop" then
		return Debug.Colors.Drop
	elseif wp.SmartAction == "Link" or wp.Action == Enum.PathWaypointAction.Custom then
		return Debug.Colors.Link
	end
	return Debug.Colors.Walk
end

-- Waypoints coloridos por ação (azul andar, amarelo saltar, laranja queda, magenta link), ligados
-- por linhas da cor do waypoint de chegada.
function Debug.route(waypoints: { Types.Waypoint }, lifetime: number?)
	local prev: Types.Waypoint? = nil
	for _, wp in ipairs(waypoints) do
		local color = colorFor(wp)
		local isJump = color == Debug.Colors.Jump
		Debug.point(wp.Position, color, if isJump then 1 else 0.6, lifetime)
		if prev then
			Debug.line(prev.Position, wp.Position, color, lifetime)
		end
		prev = wp
	end
end

-- Raio efetivo usado na rota: disco no início, verde se coube com o raio cheio, laranja se foi
-- preciso reduzir. O texto mostra os dois números.
function Debug.radius(pos: Vector3, usedRadius: number, agentRadius: number, lifetime: number?)
	local reduced = usedRadius < agentRadius - 1e-3
	local d = math.max(usedRadius * 2, 0.2)
	local disc = newPart(
		Enum.PartType.Cylinder,
		Vector3.new(0.1, d, d),
		if reduced then Debug.Colors.RadiusReduced else Debug.Colors.Radius,
		CFrame.new(pos + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		lifetime
	)
	disc.Transparency = 0.6
	addLabel(
		disc,
		string.format("raio %.2f de %.2f%s", usedRadius, agentRadius, if reduced then " (reduzido)" else ""),
		disc.Color
	)
end

-- Obstáculo detectado: esfera vermelha e, se for uma parte, uma moldura ao redor dela (a moldura
-- vive na pasta de debug: a parte do mapa não é tocada).
function Debug.obstacle(pos: Vector3, instance: Instance?, text: string?, lifetime: number?)
	local marker = Debug.point(pos, Debug.Colors.Obstacle, 1.2, lifetime)
	if text then
		addLabel(marker, text, Debug.Colors.Obstacle)
	end
	if instance and instance:IsA("BasePart") then
		local box = Instance.new("SelectionBox")
		box.Adornee = instance
		box.Color3 = Debug.Colors.Obstacle
		box.LineThickness = 0.06
		box.Parent = Debug.getFolder()
		Debris:AddItem(box, lifetime or DEFAULT_LIFETIME)
	end
end

-- Decolagem, pouso e obstáculo de um salto. `plan` é o do Predictor; um plano sintético (salto
-- pedido pelo pathfinding, sem análise) só tem pouso e direção.
function Debug.jump(plan: { [string]: any }, lifetime: number?)
	local landing = plan.landingPoint
	local wall = plan.wallPoint
	local dir = plan.direction
	if typeof(wall) == "Vector3" then
		Debug.obstacle(wall, nil, "obstáculo", lifetime)
	end
	local takeoff: Vector3? = nil
	if typeof(wall) == "Vector3" and typeof(dir) == "Vector3" and typeof(plan.takeoffDistance) == "number" then
		takeoff = wall - dir * plan.takeoffDistance
		Debug.point(takeoff :: Vector3, Debug.Colors.Takeoff, 0.9, lifetime)
	end
	if typeof(landing) == "Vector3" then
		Debug.point(landing, Debug.Colors.Landing, 0.9, lifetime)
		if takeoff then
			Debug.line(takeoff, landing, Debug.Colors.Jump, lifetime)
		end
	end
end

-- Marca o ponto que explica uma falha, conforme o código.
function Debug.failure(reason: string, details: { [string]: any }?, lifetime: number?)
	local d: { [string]: any } = details or {}
	if reason == "corridor_too_narrow" and typeof(d.blockedAt) == "Vector3" then
		local rejected = d.rejectedRoute
		if typeof(rejected) == "table" then
			-- a rota que a engine devolveu e o corpo não coube, em vermelho
			local prev: Vector3? = nil
			for _, wp in ipairs(rejected :: { Types.Waypoint }) do
				Debug.point(wp.Position, Debug.Colors.Obstacle, 0.5, lifetime)
				if prev then
					Debug.line(prev, wp.Position, Debug.Colors.Obstacle, lifetime)
				end
				prev = wp.Position
			end
		end
		Debug.obstacle(d.blockedAt, nil, "corredor estreito", lifetime)
	elseif reason == "invisible_collider" and typeof(d.instance) == "Instance" then
		local part = d.instance :: Instance
		local pos = if typeof(d.position) == "Vector3"
			then d.position
			elseif part:IsA("BasePart") then part.Position
			else nil
		if pos then
			Debug.obstacle(pos, part, "invisível colidível", lifetime)
		end
	elseif reason == "goal_unreachable" then
		if typeof(d.requestedGoal) == "Vector3" then
			Debug.obstacle(d.requestedGoal, nil, "destino inválido", lifetime)
		end
		if typeof(d.nearestValid) == "Vector3" then
			Debug.point(d.nearestValid, Debug.Colors.Landing, 0.9, lifetime)
		end
	elseif reason == "stuck" and typeof(d.position) == "Vector3" then
		Debug.obstacle(d.position, nil, "travou", lifetime)
	end
end

-- ===== Painel =====

-- Texto do painel (função pura sobre o estado do agente, testável sem tela).
function Debug.describe(agent: any): string
	local lines = {}
	if agent._destroyed then
		return "SmartPath · agente destruído"
	end
	table.insert(lines, "SmartPath · " .. tostring(agent._state))

	local route = agent._route
	if route then
		table.insert(lines, string.format("Rota: waypoint %d de %d", math.min(agent._index, #route), #route))
	else
		table.insert(lines, "Rota: nenhuma")
	end

	local details = agent._lastDetails
	if details and typeof(details.radius) == "number" and typeof(details.agentRadius) == "number" then
		table.insert(
			lines,
			string.format(
				"Raio: %.2f de %.2f%s%s",
				details.radius,
				details.agentRadius,
				if details.reduced then " (reduzido)" else "",
				if details.cached then " · cache" else ""
			)
		)
	end

	if agent._lastCalcTime then
		table.insert(lines, string.format("Último cálculo: %.1f ms", agent._lastCalcTime * 1000))
	else
		table.insert(lines, "Último cálculo: —")
	end
	table.insert(lines, "Fila do Scheduler: " .. Scheduler.getQueueLength())

	local failure = agent._lastFailure
	if failure then
		table.insert(lines, "Último erro: " .. failure.reason)
		table.insert(lines, Diagnostics.explain(failure.reason, failure.details))
	end
	return table.concat(lines, "\n")
end

type Panel = {
	Gui: ScreenGui,
	Refresh: () -> (),
	GetText: () -> string,
	Destroy: () -> (),
}

-- Painel na tela com o estado de UM agente. Só existe quando o desenvolvedor o pede; Debug = false
-- não o cria. No cliente o pai padrão é o PlayerGui; no servidor não há tela, passe `parent`.
function Debug.showPanel(agent: any, parent: Instance?): Panel
	local host = parent
	if not host then
		local player = Players.LocalPlayer
		host = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	end
	if not host then
		error("SmartPath.Debug.showPanel: sem PlayerGui (servidor?): passe o `parent` do painel", 2)
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "SmartPathPanel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1000
	local label = Instance.new("TextLabel")
	label.Position = UDim2.fromOffset(12, 12)
	label.Size = UDim2.fromOffset(360, 150)
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	label.BackgroundTransparency = 0.25
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.Code
	label.TextSize = 14
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = ""
	label.Parent = gui

	local conn: RBXScriptConnection? = nil
	local last = 0
	local destroyed = false

	local function refresh()
		if not destroyed then
			label.Text = Debug.describe(agent)
		end
	end
	local function destroy()
		if destroyed then
			return
		end
		destroyed = true
		if conn then
			conn:Disconnect()
			conn = nil
		end
		gui:Destroy()
	end

	conn = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - last >= PANEL_REFRESH_INTERVAL then
			last = now
			refresh()
		end
	end)
	-- se alguém destruir a tela por fora, a conexão de atualização não pode sobrar
	gui.Destroying:Connect(destroy)

	refresh()
	gui.Parent = host
	return {
		Gui = gui,
		Refresh = refresh,
		GetText = function()
			return Debug.describe(agent)
		end,
		Destroy = destroy,
	}
end

return Debug
end

-- ============================== JumpExecutor.luau ==============================
sources["JumpExecutor"] = function(script: any, require: any): any
-- JumpExecutor.luau
-- Execução do salto nos modos Native e Injected, com restauração garantida das
-- propriedades do Humanoid.
--
-- Native (padrão): ajusta JumpHeight/JumpPower para a altura exata, seta Humanoid.Jump e
-- restaura quando o impulso já foi aplicado. O Humanoid cuida da física: zero conflito.
-- Injected: ChangeState(Jumping) e, no primeiro Heartbeat, sobrescreve a velocidade, sem
-- nunca reduzir o momento horizontal existente (preserva o impulso de um dash).
-- Nunca combinamos Jump = true e injeção de velocidade no mesmo salto (somaria impulsos).
--
-- A restauração do Native não pode falhar, senão o NPC fica com o pulo de outro salto para
-- sempre. Ela dispara por qualquer um de: estado Freefall/Landed, morte, remoção do
-- Humanoid, e um timeout. E o original é guardado uma vez só: um segundo salto encadeado
-- reaproveita o original em vez de capturar o valor já alterado pelo primeiro (D-013).

local RunService = game:GetService("RunService")
local Util = require(script.Parent.Util)

local JumpExecutor = {}
local ST = Enum.HumanoidStateType

local BLOCKING_STATES = {
	[ST.Jumping] = true,
	[ST.Freefall] = true,
	[ST.Seated] = true,
	[ST.Dead] = true,
	[ST.PlatformStanding] = true,
	[ST.Ragdoll] = true,
	[ST.FallingDown] = true,
	[ST.Physics] = true,
}

-- Salvaguarda (task.delay(1, finish)): mesmo que nenhum evento chegue, o valor
-- original volta em no máximo isso.
local RESTORE_TIMEOUT = 1

type NativeState = {
	original: number,
	useJumpPower: boolean,
	conns: { RBXScriptConnection },
}

-- Registro do salto Native pendente por Humanoid. Chaves fracas: um Humanoid coletado não
-- deixa entrada para trás. É estado global documentado em D-013.
local pending: { [Humanoid]: NativeState } = setmetatable({}, { __mode = "k" }) :: any

function JumpExecutor.canJump(humanoid: Humanoid): boolean
	if humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end
	if BLOCKING_STATES[humanoid:GetState()] then
		return false
	end
	return humanoid:GetStateEnabled(ST.Jumping)
end

function JumpExecutor.isRestorePending(humanoid: Humanoid): boolean
	return pending[humanoid] ~= nil
end

local function disconnectAll(state: NativeState)
	for _, c in ipairs(state.conns) do
		if c.Connected then
			c:Disconnect()
		end
	end
	table.clear(state.conns)
end

-- Idempotente e seguro contra estado velho: só restaura se `state` ainda é o registrado
-- (um salto posterior substitui o registro, e o timeout do anterior vira no-op).
local function restore(humanoid: Humanoid, state: NativeState)
	if pending[humanoid] ~= state then
		return
	end
	pending[humanoid] = nil
	disconnectAll(state)
	-- pcall e sem checar Parent: um Humanoid removido continua com a propriedade alterada
	-- se alguém o reparentar depois, então restauramos mesmo assim
	pcall(function()
		if state.useJumpPower then
			humanoid.JumpPower = state.original
		else
			humanoid.JumpHeight = state.original
		end
	end)
end

-- Modo Native: altura exata via propriedades do Humanoid, restaurando depois.
function JumpExecutor.jumpNative(humanoid: Humanoid, height: number)
	local useJumpPower: boolean
	local original: number
	local prev = pending[humanoid]
	if prev then
		-- salto encadeado: o valor atual é o do salto anterior, o original é o dele
		useJumpPower, original = prev.useJumpPower, prev.original
		disconnectAll(prev)
	else
		useJumpPower = humanoid.UseJumpPower
		original = if useJumpPower then humanoid.JumpPower else humanoid.JumpHeight
	end

	if useJumpPower then
		humanoid.JumpPower = Util.velocityForHeight(height)
	else
		humanoid.JumpHeight = height
	end

	local state: NativeState = { original = original, useJumpPower = useJumpPower, conns = {} }
	pending[humanoid] = state
	local function finish()
		restore(humanoid, state)
	end
	table.insert(
		state.conns,
		humanoid.StateChanged:Connect(function(_, new)
			-- o impulso já foi aplicado quando o Jumping vira Freefall (ou pousa direto)
			if new == ST.Freefall or new == ST.Landed then
				finish()
			end
		end)
	)
	table.insert(state.conns, humanoid.Died:Connect(finish))
	table.insert(state.conns, humanoid.Destroying:Connect(finish))
	table.insert(
		state.conns,
		humanoid.AncestryChanged:Connect(function(_, parent)
			if not parent then
				finish()
			end
		end)
	)
	task.delay(RESTORE_TIMEOUT, finish)

	humanoid.Jump = true
end

-- Velocidade final do modo Injected. Função pura, para poder ser testada sem física.
-- Regra: a velocidade horizontal nunca diminui. Soma-se à componente ao longo de `dir` só o
-- que falta para chegar a `speed`, mantendo a componente lateral (um dash de lado continua
-- valendo); se mesmo assim a magnitude cairia (ex.: indo de costas rápido), fica como está.
function JumpExecutor.injectedVelocity(current: Vector3, dir: Vector3, speed: number, verticalSpeed: number): Vector3
	local flatCur = Util.flat(current)
	local d = Util.flat(dir)
	local h = flatCur
	if d.Magnitude > 1e-3 then
		local unit = d.Unit
		local along = flatCur:Dot(unit)
		h = flatCur + unit * math.max(speed - along, 0)
		if h.Magnitude < flatCur.Magnitude then
			h = flatCur
		end
	end
	return Vector3.new(h.X, verticalSpeed, h.Z)
end

-- Modo Injected: estado via ChangeState, velocidade corrigida no primeiro Heartbeat.
function JumpExecutor.jumpInjected(humanoid: Humanoid, root: BasePart, height: number, dir: Vector3, speed: number)
	local startFeet = Util.getFeetY(humanoid, root)
	humanoid:ChangeState(ST.Jumping)
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		conn:Disconnect()
		if not root.Parent then
			return
		end
		-- vertical recalculada de onde o corpo está de fato: corrige o que o Humanoid já
		-- aplicou no ChangeState
		local risen = Util.getFeetY(humanoid, root) - startFeet
		local vy = Util.velocityForHeight(height - risen)
		root.AssemblyLinearVelocity = JumpExecutor.injectedVelocity(root.AssemblyLinearVelocity, dir, speed, vy)
	end)
end

-- Retorna (true) se o salto foi disparado, ou (false, motivo).
function JumpExecutor.execute(
	mode: string,
	humanoid: Humanoid,
	root: BasePart,
	height: number,
	direction: Vector3?
): (boolean, string?)
	if not JumpExecutor.canJump(humanoid) then
		return false, "cannot_jump"
	end
	if mode == "Injected" and direction then
		JumpExecutor.jumpInjected(humanoid, root, height, direction, humanoid.WalkSpeed)
	else
		JumpExecutor.jumpNative(humanoid, height)
	end
	return true, nil
end

return JumpExecutor
end

-- ============================== Predictor.luau ==============================
sources["Predictor"] = function(script: any, require: any): any
-- Predictor.luau
-- Predição balística de salto.
-- Diz se o agente, com o JumpHeight REAL que tem (qualquer valor, não o limite interno
-- fixo da malha do PathfindingService), consegue saltar o obstáculo entre ele e o alvo, de
-- que altura, a que distância da parede decolar e onde pousa.
--
-- Etapas: (1) direção, (2) parede na altura do joelho, (3) alto demais?, (4) topo do
-- obstáculo, (5) profundidade e ponto de pouso, (6) balística e (7) corredor aéreo. A ordem
-- de 6 e 7 é invertida em relação à implementação de referência: o corredor precisa da altura do apex e do ponto
-- de decolagem, que só existem depois da balística (ver D-014).
--
-- Retorna (plano, "ok") ou (nil, motivo, dados?). Todo retorno negativo traz o motivo:
-- no_obstacle, not_a_wall, target_too_close, jump_too_weak, too_tall, top_not_found, no_landing,
-- drop_too_high, insufficient_jump, too_deep, air_blocked, ceiling. Os que medem algo trazem
-- também `dados` (Fase 6): too_tall e insufficient_jump { height, maxJump }, no_landing e
-- drop_too_high { drop }, todos com `at` (onde está a parede); `atLeast = true` quando o valor é um
-- mínimo (o raio só prova que há algo ali). O Agent os converte em obstacle_too_tall e no_landing.

local Util = require(script.Parent.Util)

local Predictor = {}
local UP = Vector3.yAxis

type Context = {
	root: BasePart,
	humanoid: Humanoid,
	targetPos: Vector3,
	params: RaycastParams,
	agentRadius: number?,
	agentHeight: number?,
	walkSpeed: number?,
	maxJumpHeight: number?,
	-- até onde à frente procurar o obstáculo (default PROBE_DISTANCE); o diagnóstico de falha passa
	-- math.huge para achar o primeiro obstáculo da linha inteira até o destino
	probeDistance: number?,
}

type Plan = {
	direction: Vector3,
	wallPoint: Vector3,
	wallInstance: Instance,
	obstacleHeight: number,
	obstacleDepth: number?,
	isPlatform: boolean,
	landingPoint: Vector3,
	jumpHeight: number,
	takeoffDistance: number,
	tUp: number,
	tDown: number,
}

-- Constantes de referência. Os valores marcados [VALIDAR]
-- dependem do rig e das animações do jogo e precisam ser confirmados no Studio.
local DEFAULT_AGENT_RADIUS = 2
local DEFAULT_AGENT_HEIGHT = 5
local PROBE_DISTANCE = 10 -- até onde à frente procuramos o obstáculo
local MIN_TARGET_DISTANCE = 1.5
local MIN_OBSTACLE_HEIGHT = 1.2 -- abaixo disso o Humanoid sobe sozinho (degrau) [VALIDAR]
local MAX_WALL_NORMAL_Y = 0.35 -- |normal.Y| acima disso é rampa, não parede
local HEIGHT_SAFETY_MARGIN = 0.4
local TOP_PROBE_CLEARANCE = 1
local TOP_PROBE_INSETS = { 0.3, 0.12, 0.04 } -- quanto "entrar" no topo, para paredes finas
local LANDING_SCAN_STEP = 0.5
local LANDING_SEARCH_MAX = 8 -- mais fundo que isso é plataforma: pousa em cima
local LANDING_MARGIN = 1
local MAX_SAFE_DROP = 14
local AIR_CLEARANCE = 0.5 -- folga entre os pés e o topo do obstáculo [VALIDAR]
local APEX_EXTRA = 0.6 -- altura extra mínima acima do necessário [VALIDAR]
local TAKEOFF_MARGIN = 0.4 -- [VALIDAR]
-- as esferas do corredor aéreo são um pouco menores que o corpo para não brigar com a borda
local BODY_CAST_SHRINK = 0.9

-- distância plana do centro do agente até a face do obstáculo, ao longo da direção do plano
function Predictor.wallDistance(plan: Plan, rootPos: Vector3): number
	return Util.flat(plan.wallPoint - rootPos):Dot(plan.direction)
end

-- Topo do MESMO objeto que o raio do joelho acertou. Se houver uma laje/viga sobre o
-- obstáculo, um raio vindo de cima acertaria a laje e confundiria teto com topo.
local function findTop(
	wallHit: RaycastResult,
	dir: Vector3,
	highY: number,
	feetY: number,
	fallback: RaycastParams
): number?
	local include = RaycastParams.new()
	include.FilterType = Enum.RaycastFilterType.Include
	include.FilterDescendantsInstances = { wallHit.Instance }
	for _, filter in ipairs({ include, fallback }) do
		for _, inset in ipairs(TOP_PROBE_INSETS) do
			local p = wallHit.Position + dir * inset
			local r = workspace:Raycast(Vector3.new(p.X, highY, p.Z), -UP * (highY - feetY + 0.5), filter)
			if r and (r.Position.Y - feetY) >= MIN_OBSTACLE_HEIGHT * 0.5 then
				return r.Position.Y
			end
		end
	end
	return nil
end

function Predictor.analyze(ctx: Context): (Plan?, string, { [string]: any }?)
	local root = ctx.root
	local humanoid = ctx.humanoid
	local rootPos = root.Position
	local feetY = Util.getFeetY(humanoid, root)
	local agentRadius = ctx.agentRadius or DEFAULT_AGENT_RADIUS
	local agentHeight = ctx.agentHeight or DEFAULT_AGENT_HEIGHT
	local bodyRadius = Util.getBodyRadius(agentRadius)
	local speed = ctx.walkSpeed or humanoid.WalkSpeed
	local maxJump = ctx.maxJumpHeight or Util.getMaxJumpHeight(humanoid)
	local g = workspace.Gravity

	-- 1) direção
	local toTarget = Util.flat(ctx.targetPos - rootPos)
	local dist = toTarget.Magnitude
	if dist < MIN_TARGET_DISTANCE then
		return nil, "target_too_close"
	end
	local dir = toTarget.Unit
	local probeDist = math.min(ctx.probeDistance or PROBE_DISTANCE, dist)

	local usable = maxJump - HEIGHT_SAFETY_MARGIN
	if usable <= MIN_OBSTACLE_HEIGHT then
		return nil, "jump_too_weak"
	end

	-- 2) parede na altura do joelho
	local kneeOrigin = Vector3.new(rootPos.X, feetY + MIN_OBSTACLE_HEIGHT, rootPos.Z)
	local wallHit = workspace:Raycast(kneeOrigin, dir * probeDist, ctx.params)
	if not wallHit then
		return nil, "no_obstacle"
	end
	if math.abs(wallHit.Normal.Y) > MAX_WALL_NORMAL_Y then
		return nil, "not_a_wall"
	end

	-- 3) alto demais? (raio à altura máxima útil + folga: se bate, o obstáculo passa disso)
	local highY = feetY + usable + TOP_PROBE_CLEARANCE
	local highHit =
		workspace:Raycast(Vector3.new(rootPos.X, highY, rootPos.Z), dir * (wallHit.Distance + 0.5), ctx.params)
	if highHit then
		-- o raio só diz que há algo naquela altura: a altura real é essa ou maior (atLeast)
		return nil, "too_tall", { height = highY - feetY, maxJump = maxJump, atLeast = true, at = wallHit.Position }
	end

	-- 4) topo do obstáculo
	local topY = findTop(wallHit, dir, highY, feetY, ctx.params)
	if not topY then
		return nil, "top_not_found"
	end
	local obstacleHeight = topY - feetY
	if obstacleHeight > usable then
		return nil, "too_tall", { height = obstacleHeight, maxJump = maxJump, at = wallHit.Position }
	end

	-- 5) profundidade e ponto de pouso
	local scanDrop = 0.5 + obstacleHeight + MAX_SAFE_DROP
	local depth: number? = nil
	local k = 0
	while k < LANDING_SEARCH_MAX do
		k += LANDING_SCAN_STEP
		local s = wallHit.Position + dir * k
		local r = workspace:Raycast(Vector3.new(s.X, topY + 0.5, s.Z), -UP * scanDrop, ctx.params)
		if not r or r.Position.Y < topY - 0.5 then
			depth = k -- fim do obstáculo; se não há chão, o pouso é validado logo abaixo
			break
		end
	end

	local isPlatform = depth == nil
	local landing: Vector3
	if isPlatform then
		-- obstáculo largo: pousa EM CIMA dele
		local p = wallHit.Position + dir * (agentRadius + LANDING_MARGIN)
		landing = Vector3.new(p.X, topY, p.Z)
	else
		local p = wallHit.Position + dir * ((depth :: number) + agentRadius + LANDING_MARGIN)
		local floor = workspace:Raycast(Vector3.new(p.X, topY + 0.5, p.Z), -UP * scanDrop, ctx.params)
		if not floor then
			-- sem chão em todo o alcance da varredura: a queda é essa ou maior (atLeast)
			return nil, "no_landing", { drop = obstacleHeight + MAX_SAFE_DROP, atLeast = true, at = wallHit.Position }
		end
		if topY - floor.Position.Y > MAX_SAFE_DROP then
			return nil, "drop_too_high", { drop = topY - floor.Position.Y, at = wallHit.Position }
		end
		landing = floor.Position
	end

	-- 6) balística. Em vez da altura mínima da implementação de referência (clareza + APEX_EXTRA), o apex é o menor
	-- que dá tempo ACIMA do obstáculo para o corpo cruzar a profundidade inteira: os pés
	-- precisam ficar acima do topo enquanto o centro percorre profundidade + 2 raios (a frente
	-- do corpo passa a face, a traseira passa a borda de trás). Tempo acima da clareza para um
	-- apex h acima dela: t = 2*sqrt(2h/g), logo h = g*t²/8.
	local clearH = obstacleHeight + AIR_CLEARANCE
	if clearH > maxJump then
		return nil, "insufficient_jump", { height = obstacleHeight, maxJump = maxJump, at = wallHit.Position }
	end
	local jumpH = clearH + APEX_EXTRA
	if not isPlatform then
		if speed <= 0 then
			return nil, "too_deep"
		end
		local travel = (depth :: number) + 2 * bodyRadius + TAKEOFF_MARGIN
		local t = travel / speed
		jumpH = clearH + math.max(APEX_EXTRA, g * t * t / 8)
		if jumpH > maxJump then
			return nil, "too_deep"
		end
	end
	jumpH = math.min(jumpH, maxJump) -- plataforma: basta alcançar o topo, o apex pode ser menor

	local v = math.sqrt(2 * g * jumpH)
	local sq = math.sqrt(math.max(v * v - 2 * g * clearH, 0))
	local tUp = (v - sq) / g -- quando o corpo cruza a altura de clareza, subindo
	local tDown = (v + sq) / g -- e descendo
	-- o centro decola a esta distância da face: a frente do corpo (centro + raio) chega na
	-- parede já na altura de clareza
	local takeoffDistance = speed * tUp + bodyRadius + TAKEOFF_MARGIN

	-- 7) corredor aéreo: o corpo ocupa uma coluna, dos pés (na altura de voo sobre o
	-- obstáculo) até a cabeça no apex. Duas esferas (pés e cabeça) deixam um vão vertical onde
	-- uma laje ou viga passa despercebida, então varremos esferas empilhadas cobrindo a coluna
	-- inteira, da decolagem até o pouso. A de baixo bloqueada é o "corpo no ar" (air_blocked);
	-- as de cima são teto (ceiling).
	local castRadius = bodyRadius * BODY_CAST_SHRINK
	local takeoffPoint = wallHit.Position - dir * takeoffDistance
	local flightLen = Util.flat(landing - takeoffPoint).Magnitude
	local baseY = topY + AIR_CLEARANCE + bodyRadius
	local topCenterY = math.max(feetY + jumpH + agentHeight - bodyRadius, baseY)
	-- Spherecast ignora tudo o que já sobrepõe a esfera na origem, então uma laje que começa
	-- antes do ponto de decolagem (teto sobre a aproximação, o caso comum) nunca seria vista
	-- pela varredura. Por isso cada nível também checa a sobreposição na origem.
	local overlap = OverlapParams.new()
	overlap.FilterType = ctx.params.FilterType
	overlap.FilterDescendantsInstances = ctx.params.FilterDescendantsInstances
	overlap.RespectCanCollide = true
	local y = baseY
	while true do
		local center = Vector3.new(takeoffPoint.X, y, takeoffPoint.Z)
		local blocked = #workspace:GetPartBoundsInRadius(center, castRadius, overlap) > 0
			or workspace:Spherecast(center, castRadius, dir * flightLen, ctx.params) ~= nil
		if blocked then
			return nil, if y == baseY then "air_blocked" else "ceiling"
		end
		if y >= topCenterY then
			break
		end
		y = math.min(y + castRadius, topCenterY) -- passo de um raio: as esferas se sobrepõem
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
		takeoffDistance = takeoffDistance,
		tUp = tUp,
		tDown = tDown,
	},
		"ok"
end

return Predictor
end

-- ============================== RouteCache.luau ==============================
sources["RouteCache"] = function(script: any, require: any): any
-- RouteCache.luau
-- Cache de rotas por célula.
-- Garante determinismo: mesmas células de origem/destino (e mesmo perfil de agente) devolvem
-- EXATAMENTE a mesma lista de waypoints, por construção e não por torcer pela engine.
-- As listas armazenadas são imutáveis (congeladas): quem consome não pode modificá-las.
--
-- Invalida por TTL, por mudança na versão do Geometry, por invalidateGoal (Blocked/stuck)
-- e por despejo FIFO quando passa de MaxEntries.

local Types = require(script.Parent.Types)

local RouteCache = {}
RouteCache.__index = RouteCache

type Config = {
	CellSize: number?,
	TTL: number?,
	MaxEntries: number?,
}

type Entry = {
	waypoints: { Types.Waypoint },
	meta: { [string]: any }?,
	time: number,
	goalKey: string,
}

type RouteCache = typeof(setmetatable(
	{} :: {
		_cell: number,
		_ttl: number,
		_max: number,
		_entries: { [string]: Entry },
		_order: { string },
		_geoVersion: number,
	},
	RouteCache
))

-- Defaults do cache.
RouteCache.DEFAULT_CELL_SIZE = 2
local DEFAULT_TTL = 15
local DEFAULT_MAX_ENTRIES = 128

function RouteCache.quantize(v: Vector3, cell: number): string
	return string.format(
		"%d,%d,%d",
		math.floor(v.X / cell + 0.5),
		math.floor(v.Y / cell + 0.5),
		math.floor(v.Z / cell + 0.5)
	)
end

function RouteCache.new(config: Config?): RouteCache
	local cfg: Config = config or {}
	return setmetatable({
		_cell = cfg.CellSize or RouteCache.DEFAULT_CELL_SIZE,
		_ttl = cfg.TTL or DEFAULT_TTL,
		_max = cfg.MaxEntries or DEFAULT_MAX_ENTRIES,
		_entries = {},
		_order = {}, -- chaves em ordem de inserção (despejo FIFO)
		_geoVersion = -1,
	}, RouteCache)
end

-- `profile` separa rotas de agentes com raio/altura/opções diferentes: o mesmo par de
-- células dá rotas diferentes conforme o tamanho do agente.
function RouteCache._key(self: RouteCache, start: Vector3, goal: Vector3, profile: string): (string, string)
	local goalKey = RouteCache.quantize(goal, self._cell)
	return profile .. "|" .. RouteCache.quantize(start, self._cell) .. "|" .. goalKey, goalKey
end

function RouteCache._remove(self: RouteCache, key: string)
	self._entries[key] = nil
	-- mantém _order sem chaves velhas: senão o despejo FIFO poderia apagar uma entrada nova
	-- que reaproveitou a mesma chave
	local i = table.find(self._order, key)
	if i then
		table.remove(self._order, i)
	end
end

function RouteCache._syncVersion(self: RouteCache, geoVersion: number)
	if geoVersion ~= self._geoVersion then
		self:clear()
		self._geoVersion = geoVersion
	end
end

function RouteCache.get(
	self: RouteCache,
	start: Vector3,
	goal: Vector3,
	profile: string,
	geoVersion: number
): ({ Types.Waypoint }?, { [string]: any }?)
	self:_syncVersion(geoVersion)
	local key = self:_key(start, goal, profile)
	local e = self._entries[key]
	if not e then
		return nil, nil
	end
	if os.clock() - e.time > self._ttl then
		self:_remove(key)
		return nil, nil
	end
	return e.waypoints, e.meta
end

function RouteCache.put(
	self: RouteCache,
	start: Vector3,
	goal: Vector3,
	profile: string,
	waypoints: { Types.Waypoint },
	geoVersion: number,
	meta: { [string]: any }?
)
	self:_syncVersion(geoVersion)
	local key, goalKey = self:_key(start, goal, profile)
	if not self._entries[key] then
		table.insert(self._order, key)
	end
	if not table.isfrozen(waypoints) then
		table.freeze(waypoints)
	end
	self._entries[key] = { waypoints = waypoints, meta = meta, time = os.clock(), goalKey = goalKey }
	while #self._order > self._max do
		self:_remove(self._order[1])
	end
end

-- Remove toda rota que termina na célula do destino (qualquer origem/perfil).
function RouteCache.invalidateGoal(self: RouteCache, goal: Vector3)
	local goalKey = RouteCache.quantize(goal, self._cell)
	for key, e in pairs(table.clone(self._entries)) do
		if e.goalKey == goalKey then
			self:_remove(key)
		end
	end
end

function RouteCache.clear(self: RouteCache)
	table.clear(self._entries)
	table.clear(self._order)
end

function RouteCache.size(self: RouteCache): number
	return #self._order
end

return RouteCache
end

-- ============================== Simplifier.luau ==============================
sources["Simplifier"] = function(script: any, require: any): any
-- Simplifier.luau
-- 1) remove duplicatas; 2) string pulling guloso com validação de volume livre E de chão
-- contínuo.
-- Nunca remove waypoints cuja Action ≠ Walk e nunca atravessa um deles num atalho.
--
-- Custo: O(n²) em raycasts no pior caso. Com WaypointSpacing = math.huge o n é pequeno
-- (tipicamente < 15) e o resultado vai para o RouteCache, então o custo é pago uma vez
-- por par de células.

local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

local Simplifier = {}
local UP = Vector3.yAxis
local WALK = Enum.PathWaypointAction.Walk

type Context = {
	params: RaycastParams,
	probeRadius: number,
	probeHeight: number,
	floorStep: number,
	maxFloorDelta: number,
	groundProbeUp: number,
}

-- Constantes de referência.
local DEDUP_DISTANCE = 0.5 -- waypoints Walk mais próximos que isso são o mesmo ponto
local PROBE_HEIGHT = 2.5 -- altura acima do chão onde a esfera viaja (tronco)
local FLOOR_STEP = 2 -- espaçamento das amostras de chão ao longo do segmento
local MAX_FLOOR_DELTA = 1.2 -- variação máxima de altura do piso num atalho
local GROUND_PROBE_UP = 2 -- os raios de chão partem daqui, acima do ponto amostrado

-- O raio da sonda é o raio FÍSICO do corpo (Util.getBodyRadius), não o Agent.Radius
-- inflado usado no CreatePath: string pulling não deve cortar onde o corpo não cabe, mas
-- também não deve recusar atalhos que o corpo faz de verdade.
function Simplifier.buildContext(params: RaycastParams, agentRadius: number): Context
	return {
		params = params,
		probeRadius = Util.getBodyRadius(agentRadius),
		probeHeight = PROBE_HEIGHT,
		floorStep = FLOOR_STEP,
		maxFloorDelta = MAX_FLOOR_DELTA,
		groundProbeUp = GROUND_PROBE_UP,
	}
end

local function canWalkStraight(a: Vector3, b: Vector3, ctx: Context): boolean
	local delta = b - a
	local flatDist = Util.flat(delta).Magnitude
	if flatDist < 0.1 then
		return true
	end

	-- (1) volume livre: esfera viajando na altura do tronco
	local hit = workspace:Spherecast(a + UP * ctx.probeHeight, ctx.probeRadius, delta, ctx.params)
	if hit then
		return false
	end

	-- (2) chão contínuo: amostras para baixo ao longo do segmento (evita cortar por cima
	-- de buracos, que o Spherecast na altura do tronco não vê)
	local n = math.max(1, math.ceil(flatDist / ctx.floorStep))
	for i = 1, n - 1 do
		local p = a:Lerp(b, i / n)
		local r =
			workspace:Raycast(p + UP * ctx.groundProbeUp, -UP * (ctx.groundProbeUp + ctx.maxFloorDelta), ctx.params)
		if not r then
			return false -- buraco
		end
		if math.abs(r.Position.Y - p.Y) > ctx.maxFloorDelta then
			return false -- degrau ou queda
		end
	end
	return true
end

local function innerAllWalk(wps: { Types.Waypoint }, i: number, j: number): boolean
	for k = i + 1, j - 1 do
		if wps[k].Action ~= WALK then
			return false
		end
	end
	return true
end

function Simplifier.simplify(waypoints: { Types.Waypoint }, ctx: Context): { Types.Waypoint }
	-- 1) deduplicação
	local dedup: { Types.Waypoint } = {}
	for _, wp in ipairs(waypoints) do
		local last = dedup[#dedup]
		if
			last
			and wp.Action == WALK
			and last.Action == WALK
			and (wp.Position - last.Position).Magnitude < DEDUP_DISTANCE
		then
			continue
		end
		table.insert(dedup, wp)
	end
	if #dedup <= 2 then
		return dedup
	end

	-- 2) string pulling guloso (do waypoint mais distante para o mais próximo)
	local result: { Types.Waypoint } = { dedup[1] }
	local anchor = 1
	while anchor < #dedup do
		local furthest = anchor + 1
		-- segmento que COMEÇA num waypoint de ação (salto/link) nunca é encurtado
		if dedup[anchor].Action == WALK then
			for j = #dedup, anchor + 2, -1 do
				if
					innerAllWalk(dedup, anchor, j)
					and canWalkStraight(dedup[anchor].Position, dedup[j].Position, ctx)
				then
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

return Simplifier
end

-- ============================== RouteSolver.luau ==============================
sources["RouteSolver"] = function(script: any, require: any): any
-- RouteSolver.luau
-- Escada de raio adaptativo + validação por Spherecast no raio físico.
-- Transforma o NoPath do PathfindingService em rota utilizável em ambientes fechados, sem
-- nunca recomendar uma rota onde o corpo não cabe (D-002).
--
-- Fluxo (algoritmo da Fase 2):
--   1. origem aterrada: ponto do chão sob o root (+ offset); aguarda aterrar se no ar;
--   2. destino normalizado: projetado para o chão; dentro de geometria = goal_unreachable;
--   3. ComputeAsync com o raio configurado, depois com cada degrau da escada (RadiusSteps);
--   4. toda rota obtida é validada por Spherecast no raio físico do corpo (D-002, D-011);
--   5. sem rota: tenta AgentCanJump = false, depois um destino aproximado;
--   6. se tudo falhar, devolve o erro diagnóstico mais específico possível.
--
-- Todo ComputeAsync passa pelo Scheduler. `solve` DÁ YIELD (é bloqueante).
-- Toda falha sai por `fail` (Fase 6): se a causa é uma parte invisível colidível, o código vira
-- invisible_collider.

local PathfindingService = game:GetService("PathfindingService")

local Types = require(script.Parent.Types)
local Errors = require(script.Parent.Errors)
local Util = require(script.Parent.Util)
local Geometry = require(script.Parent.Geometry)
local Scheduler = require(script.Parent.Scheduler)
local RouteCache = require(script.Parent.RouteCache)
local Simplifier = require(script.Parent.Simplifier)
local Diagnostics = require(script.Parent.Diagnostics)
local Debug = require(script.Parent.Debug)

local RouteSolver = {}

local UP = Vector3.yAxis
local WALK = Enum.PathWaypointAction.Walk

-- ===== Constantes (origem indicada em cada uma) =====

-- Origem = chão + este offset.
local START_HEIGHT_OFFSET = 1
-- Espera máxima para aterrar antes de calcular.
local MAX_GROUNDED_WAIT = 1.5
-- O raio do chão sob o root tem alcance Height + 6.
local GROUND_PROBE_EXTRA = 6
-- WaypointSpacing = math.huge -> só waypoints essenciais (estabilidade).
local WAYPOINT_SPACING = math.huge

-- Normalização do destino. O raio de projeção parte um pouco acima do destino para não
-- nascer dentro do piso; o alcance cobre destinos flutuando (alvo pulando, por exemplo).
local GOAL_LIFT = 2
local GOAL_SNAP_DISTANCE = 100
-- "Dentro de geometria": esfera pequena um pouco acima do destino, para que um destino
-- exatamente sobre a superfície do piso não conte como dentro dele.
local GOAL_INSIDE_PROBE_HEIGHT = 0.5
local GOAL_INSIDE_PROBE_RADIUS = 0.25

-- Busca do ponto válido mais próximo: anéis crescentes com direções fixas (determinístico).
local NEAREST_SEARCH_MAX = 16
local NEAREST_SEARCH_STEP = 1
local NEAREST_SEARCH_DIRECTIONS = 16
local NEAREST_RAY_LIFT = 2
local NEAREST_RAY_DROP = 20
local MIN_WALKABLE_NORMAL_Y = 0.7 -- cos(~45°): mais íngreme que isso não é chão de pé
local STAND_CENTER_HEIGHT = 2.5 -- centro do volume do corpo em pé (= PROBE_HEIGHT do Simplifier)
-- Destino aproximado (passo 6): só vale a pena se for diferente do destino original.
local APPROX_GOAL_RADIUS = 8
local APPROX_MIN_DISTANCE = 1

-- Validação de volume: bisseção do maior raio que cabe ao longo da rota.
local FIT_BISECT_ITERATIONS = 7
local MIN_CAST_RADIUS = 0.05 -- Spherecast com raio ~0 é instável

-- Varredura de validação que acompanha o terreno (D-020): passo horizontal, e de quanto acima
-- e abaixo do ponto interpolado se procura o chão (cobre rampas de até ~3 studs de erro).
local SWEEP_STEP = 2 -- mesmo espaçamento das amostras de chão do Simplifier
local SWEEP_GROUND_LIFT = 3
local SWEEP_GROUND_DROP = 9

-- Relaxamento de waypoints (D-018). Valores próprios, a validar no Studio.
local RELAX_DIRECTIONS = 8 -- raios horizontais ao redor do waypoint
local RELAX_ITERATIONS = 4
local RELAX_STEP = 0.8 -- fração do empurrão aplicada por iteração
local RELAX_MAX_SHIFT = 1.5 -- quanto um waypoint pode se afastar do original
local RELAX_CLEARANCE_FACTOR = 1.25 -- folga alvo = raio do corpo x este fator
-- Os raios do relaxamento partem um pouco ATRÁS do waypoint: a engine põe cantos exatamente sobre a
-- face da parede (medido no cenário 5 do demo, x = -1.0 numa parede com face em x = -1), e um raio
-- que começa numa superfície não a acerta, então o waypoint nunca era empurrado.
local RELAX_RAY_BACK = 0.3
-- Reparo (D-031): quantos waypoints de desvio se inserem, no máximo, e a folga extra além da do corpo.
local REPAIR_MAX_INSERTIONS = 8
local REPAIR_MARGIN = 0.3

-- Diagnóstico de parte invisível colidível (Fase 6, D-024): raio da busca em volta do ponto de
-- estrangulamento de um corredor estreito.
local INVISIBLE_PROBE_RADIUS = 0.5

-- Cache compartilhado entre chamadas (D-008). Agentes podem passar o seu próprio.
local sharedCache = RouteCache.new()

type Context = {
	options: Types.ResolvedOptions,
	agentRadius: number,
	agentHeight: number,
	bodyRadius: number,
	params: RaycastParams,
	overlapParams: OverlapParams,
	simplifyCtx: Simplifier.Context,
	start: Vector3,
	startGround: Vector3,
	ladder: { number },
	tried: { number },
	jumpEnabled: boolean,
}

type LadderResult = {
	route: { Types.Waypoint }?,
	radius: number?,
	path: Path?,
	narrowFit: number?,
	narrowAt: Vector3?,
	narrowRoute: { Types.Waypoint }?,
	finishBlocked: boolean,
}

function RouteSolver.getSharedCache(): RouteCache.RouteCache
	return sharedCache
end

-- ===== Utilidades =====

local function round2(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end

local function convertWaypoints(pathWaypoints: { PathWaypoint }): { Types.Waypoint }
	local out: { Types.Waypoint } = {}
	for _, wp in ipairs(pathWaypoints) do
		local smart: Types.SmartAction = "Walk"
		if wp.Action == Enum.PathWaypointAction.Jump then
			smart = "Jump"
		elseif wp.Action == Enum.PathWaypointAction.Custom then
			smart = "Link"
		end
		table.insert(
			out,
			table.freeze({
				Position = wp.Position,
				Action = wp.Action,
				Label = wp.Label,
				SmartAction = smart,
			})
		)
	end
	return out
end

local function buildOverlapParams(rayParams: RaycastParams): OverlapParams
	local p = OverlapParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = rayParams.FilterDescendantsInstances
	p.RespectCanCollide = true
	return p
end

-- Modelos com Humanoid junto de um ponto (a origem de um solve sem personagem). Excluí-los dos
-- raycasts impede que o corpo de quem pediu a rota conte como obstáculo dela.
local CHARACTER_EXCLUDE_RADIUS = 4

local function charactersNear(pos: Vector3): { Instance }
	local found: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(pos, CHARACTER_EXCLUDE_RADIUS)) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not seen[model] and model:FindFirstChildOfClass("Humanoid") then
			seen[model] = true
			table.insert(found, model)
		end
	end
	return found
end

-- D-006: Geometry é global; o último solve a chamar decide AutoFilter/RequireNameMatch.
local function ensureGeometry(options: Types.ResolvedOptions)
	Geometry.setAutoFilter(options.Geometry.AutoFilter)
	Geometry.setRequireNameMatch(options.Geometry.RequireNameMatch)
	Geometry.start()
end

-- Degraus da escada: o raio configurado primeiro, depois cada RadiusSteps menor que ele e
-- não menor que MinRadius; por fim o raio de sonda (D-010), metade de MinRadius.
local function buildLadder(
	agentRadius: number,
	indoor: { AdaptiveRadius: boolean, MinRadius: number, RadiusSteps: { number } }
): { number }
	local ladder = { agentRadius }
	if not indoor.AdaptiveRadius then
		return ladder
	end
	local steps = table.clone(indoor.RadiusSteps)
	table.sort(steps, function(a, b)
		return a > b
	end)
	for _, step in ipairs(steps) do
		if step < ladder[#ladder] and step >= indoor.MinRadius then
			table.insert(ladder, step)
		end
	end
	local probe = indoor.MinRadius / 2
	if probe > 0 and probe < ladder[#ladder] then
		table.insert(ladder, probe)
	end
	return ladder
end

-- ===== Origem e destino =====

local function isInsideSolid(point: Vector3, ctx: Context): boolean
	local parts = workspace:GetPartBoundsInRadius(
		point + UP * GOAL_INSIDE_PROBE_HEIGHT,
		GOAL_INSIDE_PROBE_RADIUS,
		ctx.overlapParams
	)
	return #parts > 0
end

local function isStandable(groundPos: Vector3, ctx: Context): boolean
	local parts =
		workspace:GetPartBoundsInRadius(groundPos + UP * STAND_CENTER_HEIGHT, ctx.bodyRadius, ctx.overlapParams)
	return #parts == 0
end

-- Ponto de chão em que o corpo cabe, o mais próximo de `center` dentro de `maxRadius`.
local function findNearestStandable(center: Vector3, ctx: Context, maxRadius: number): Vector3?
	local d = NEAREST_SEARCH_STEP
	while d <= maxRadius do
		local best: Vector3? = nil
		local bestDist = math.huge
		for k = 0, NEAREST_SEARCH_DIRECTIONS - 1 do
			local angle = (k / NEAREST_SEARCH_DIRECTIONS) * 2 * math.pi
			local origin =
				Vector3.new(center.X + math.cos(angle) * d, center.Y + NEAREST_RAY_LIFT, center.Z + math.sin(angle) * d)
			local hit = workspace:Raycast(origin, -UP * (NEAREST_RAY_LIFT + NEAREST_RAY_DROP), ctx.params)
			if hit and hit.Normal.Y >= MIN_WALKABLE_NORMAL_Y and isStandable(hit.Position, ctx) then
				local dist = (hit.Position - center).Magnitude
				if dist < bestDist then
					best, bestDist = hit.Position, dist
				end
			end
		end
		if best then
			return best
		end
		d += NEAREST_SEARCH_STEP
	end
	return nil
end

-- Retorna (goal normalizado) ou (nil, nearestValid) quando o destino não existe na malha.
local function normalizeGoal(goal: Vector3, ctx: Context): (Vector3?, Vector3?)
	if isInsideSolid(goal, ctx) then
		return nil, findNearestStandable(goal, ctx, NEAREST_SEARCH_MAX)
	end
	local hit = workspace:Raycast(goal + UP * GOAL_LIFT, -UP * (GOAL_LIFT + GOAL_SNAP_DISTANCE), ctx.params)
	if not hit then
		return nil, findNearestStandable(goal, ctx, NEAREST_SEARCH_MAX)
	end
	return hit.Position, nil
end

-- ===== ComputeAsync via Scheduler =====

local function computeOnce(
	radius: number,
	height: number,
	canJump: boolean,
	start: Vector3,
	goal: Vector3
): ({ Types.Waypoint }?, any, Path?)
	local ok, result = pcall(function()
		local path = PathfindingService:CreatePath({
			AgentRadius = radius,
			AgentHeight = height,
			AgentCanJump = canJump,
			AgentCanClimb = false,
			WaypointSpacing = WAYPOINT_SPACING,
		})
		path:ComputeAsync(start, goal)
		return path
	end)
	if not ok then
		return nil, "compute_error", nil
	end
	local path = result :: Path
	if path.Status ~= Enum.PathStatus.Success then
		return nil, path.Status, nil
	end
	return convertWaypoints(path:GetWaypoints()), path.Status, path
end

local function compute(ctx: Context, radius: number, canJump: boolean, start: Vector3, goal: Vector3)
	-- pedidos com a mesma chave pendentes viram um único cálculo (coalescência do Scheduler)
	local cell = RouteCache.DEFAULT_CELL_SIZE
	local key = string.format(
		"route|%.2f|%.2f|%d|%s|%s",
		radius,
		ctx.agentHeight,
		canJump and 1 or 0,
		RouteCache.quantize(start, cell),
		RouteCache.quantize(goal, cell)
	)
	local handle = Scheduler.submit(key, ctx.options.Scheduler.Priority, function()
		return computeOnce(radius, ctx.agentHeight, canJump, start, goal)
	end)
	return handle:await()
end

-- ===== Validação de volume (D-002) =====

-- Ponto sobre o chão, na vertical de `p`. Sem chão embaixo (borda, vão), fica como está.
local function groundedPoint(p: Vector3, ctx: Context): Vector3
	local hit = workspace:Raycast(p + UP * SWEEP_GROUND_LIFT, -UP * (SWEEP_GROUND_LIFT + SWEEP_GROUND_DROP), ctx.params)
	if hit then
		return Vector3.new(p.X, hit.Position.Y, p.Z)
	end
	return p
end

-- (livre?, onde bateu, segmento, normal da superfície). O ponto de batida vira `blockedAt` no erro.
local function routeClear(
	waypoints: { Types.Waypoint },
	radius: number,
	ctx: Context
): (boolean, Vector3?, number?, Vector3?)
	for i = 1, #waypoints - 1 do
		local a, b = waypoints[i], waypoints[i + 1]
		-- O waypoint Jump é o DESTINO do salto (D-019): o segmento que chega nele é o voo por
		-- cima do obstáculo, não caminhada, e não se valida com o corpo no chão. O mesmo vale
		-- para o segmento que parte de um link (Custom).
		if b.Action == WALK and a.Action ~= Enum.PathWaypointAction.Custom then
			local delta = b.Position - a.Position
			if delta.Magnitude > 0.05 then
				-- A varredura segue o terreno (D-020): a engine só devolve waypoints nos cantos,
				-- então numa rampa a reta 3D entre dois waypoints corta o corpo da rampa por
				-- baixo. Em passos horizontais, cada ponto intermediário é projetado no chão.
				local steps = math.max(1, math.ceil(Util.flat(delta).Magnitude / SWEEP_STEP))
				local prev = a.Position
				for s = 1, steps do
					local nextPos = b.Position
					if s < steps then
						nextPos = groundedPoint(a.Position:Lerp(b.Position, s / steps), ctx)
					end
					local d = nextPos - prev
					if d.Magnitude > 0.01 then
						local hit = workspace:Spherecast(prev + UP * ctx.simplifyCtx.probeHeight, radius, d, ctx.params)
						if hit then
							return false, hit.Position, i, hit.Normal
						end
					end
					prev = nextPos
				end
			end
		end
	end
	return true, nil
end

-- (cabe?, maior raio que cabe, onde o corpo bate). O segundo valor alimenta o `requiredRadius`.
local function measureFit(waypoints: { Types.Waypoint }, ctx: Context): (boolean, number, Vector3?)
	local clear, blockedAt = routeClear(waypoints, ctx.bodyRadius, ctx)
	if clear then
		return true, ctx.bodyRadius, nil
	end
	local lo, hi = 0, ctx.bodyRadius
	for _ = 1, FIT_BISECT_ITERATIONS do
		local mid = (lo + hi) / 2
		if routeClear(waypoints, math.max(mid, MIN_CAST_RADIUS), ctx) then
			lo = mid
		else
			hi = mid
		end
	end
	return false, lo, blockedAt
end

-- Relaxamento: a rota da engine vem com waypoints de canto encostados na parede (D-018). Cada
-- waypoint interior é empurrado para longe das paredes que estão mais perto que a folga alvo,
-- medidas por raios horizontais na altura do tronco. Só roda quando a rota não cabe; a
-- validação decide depois se o resultado serve. Não move waypoints de ação nem origem/destino.
local function relaxRoute(route: { Types.Waypoint }, ctx: Context): { Types.Waypoint }
	local wps = table.clone(route)
	local clearance = ctx.bodyRadius * RELAX_CLEARANCE_FACTOR
	local sctx = ctx.simplifyCtx
	for i = 2, #wps - 1 do
		local wp = wps[i]
		if wp.Action == WALK then
			local origin = wp.Position
			local pos = origin
			for _ = 1, RELAX_ITERATIONS do
				local push = Vector3.zero
				for k = 0, RELAX_DIRECTIONS - 1 do
					local angle = (k / RELAX_DIRECTIONS) * 2 * math.pi
					local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
					local hit = workspace:Raycast(
						pos + UP * sctx.probeHeight - dir * RELAX_RAY_BACK,
						dir * (clearance + RELAX_RAY_BACK),
						ctx.params
					)
					if hit then
						push -= dir * (clearance - (hit.Distance - RELAX_RAY_BACK))
					end
				end
				if push.Magnitude < 0.01 then
					break
				end
				local candidate = pos + push * RELAX_STEP
				local shift = candidate - origin
				if shift.Magnitude > RELAX_MAX_SHIFT then
					candidate = origin + shift.Unit * RELAX_MAX_SHIFT
				end
				-- o novo ponto precisa ter chão parecido: relaxar não pode levar a rota para um buraco
				local ground = workspace:Raycast(
					candidate + UP * sctx.groundProbeUp,
					-UP * (sctx.groundProbeUp + sctx.maxFloorDelta),
					ctx.params
				)
				if not ground or math.abs(ground.Position.Y - pos.Y) > sctx.maxFloorDelta then
					break
				end
				pos = Vector3.new(candidate.X, ground.Position.Y, candidate.Z)
			end
			if pos ~= origin then
				wps[i] = table.freeze({
					Position = pos,
					Action = wp.Action,
					Label = wp.Label,
					SmartAction = wp.SmartAction,
				})
			end
		end
	end
	return table.freeze(wps)
end

-- Reparo (D-031): a engine é tolerante e devolve a reta que passa a 0.6 stud da quina de um pilar
-- (medido no cenário 8 do demo). A rota tem 2 waypoints, então não há o que relaxar. Aqui, a cada
-- batida do corpo, entra um waypoint de desvio no lado livre da superfície (a normal da batida),
-- a uma folga do corpo, e a rota é medida de novo. Só roda quando a rota não cabe.
local function repairRoute(route: { Types.Waypoint }, ctx: Context): { Types.Waypoint }
	local wps = table.clone(route)
	local clearance = ctx.bodyRadius * RELAX_CLEARANCE_FACTOR + REPAIR_MARGIN
	for _ = 1, REPAIR_MAX_INSERTIONS do
		local clear, at, segment, normal = routeClear(wps, ctx.bodyRadius, ctx)
		if clear or not at or not segment or not normal then
			break
		end
		local away = Util.flat(normal)
		if away.Magnitude < 0.05 then
			break -- batida em superfície horizontal: desviar de lado não resolve
		end
		local detour = groundedPoint(at + away.Unit * clearance, ctx)
		table.insert(
			wps,
			segment + 1, -- o segmento i vai de wps[i] a wps[i + 1]
			table.freeze({ Position = detour, Action = WALK, Label = "", SmartAction = "Walk" } :: Types.Waypoint)
		)
	end
	return table.freeze(wps)
end

-- ===== Escada =====

-- Origem de volta ao chão + suavização, e só então a rota é validada (D-012). A rota crua da
-- engine tem cantos deslocados da linha central (ela trabalha numa grade); o string pulling
-- já checa o corpo, então endireitar antes de validar não aceita nada que não caiba.
local function prepareRoute(ctx: Context, route: { Types.Waypoint }): { Types.Waypoint }
	local wps = table.clone(route)
	-- o primeiro waypoint é a origem que passamos (chão + offset); volta para o chão para
	-- que toda a rota seja feita de pontos de piso. A guarda evita mexer se a engine não
	-- devolveu a origem como primeiro ponto.
	local first = wps[1]
	if first and (first.Position - ctx.start).Magnitude < 1.5 then
		wps[1] = table.freeze({
			Position = ctx.startGround,
			Action = first.Action,
			Label = first.Label,
			SmartAction = first.SmartAction,
		})
	end
	if ctx.options.Stability.Smoothing then
		wps = Simplifier.simplify(wps, ctx.simplifyCtx)
	end
	return table.freeze(wps)
end

local function runLadder(ctx: Context, canJump: boolean, goal: Vector3): LadderResult
	local result: LadderResult =
		{ route = nil, radius = nil, path = nil, narrowFit = nil, narrowAt = nil, narrowRoute = nil, finishBlocked = false }
	for _, radius in ipairs(ctx.ladder) do
		if not table.find(ctx.tried, radius) then
			table.insert(ctx.tried, radius)
		end
		local raw, status, path = compute(ctx, radius, canJump, ctx.start, goal)
		if raw then
			-- toda rota é validada, inclusive a de raio cheio (D-011): a engine aceitou um
			-- corredor de 2 studs com AgentRadius 2, então o raio dela não garante que o
			-- corpo cabe
			local route = prepareRoute(ctx, raw)
			local fits, maxFit, blockedAt = measureFit(route, ctx)
			if not fits then
				-- rescue (D-018, D-030): waypoints encostados na parede reprovam rotas que caberiam.
				-- Primeiro relaxa os cantos CRUS da engine e suaviza de novo: o suavizador aceita
				-- atalhos a partir de um canto sobre a parede (o Spherecast ignora o que sobrepõe a
				-- origem), e um atalho assim atravessa a parede e não tem conserto depois.
				local relaxed = prepareRoute(ctx, relaxRoute(raw, ctx))
				local relaxedFits, relaxedFit, relaxedAt = measureFit(relaxed, ctx)
				if not relaxedFits then
					-- segunda tentativa: relaxar a rota já suavizada
					local second = relaxRoute(route, ctx)
					local secondFits, secondFit, secondAt = measureFit(second, ctx)
					if secondFits or secondFit > relaxedFit then
						relaxed, relaxedFits, relaxedFit, relaxedAt = second, secondFits, secondFit, secondAt
					end
				end
				if not relaxedFits then
					-- última tentativa: inserir waypoints de desvio onde o corpo bate (D-031)
					local repaired = repairRoute(route, ctx)
					local repairedFits, repairedFit, repairedAt = measureFit(repaired, ctx)
					if repairedFits or repairedFit > relaxedFit then
						relaxed, relaxedFits, relaxedFit, relaxedAt = repaired, repairedFits, repairedFit, repairedAt
					end
				end
				if relaxedFits then
					route, fits = relaxed, true
				elseif relaxedFit > maxFit then
					maxFit, blockedAt = relaxedFit, relaxedAt
				end
			end
			if fits then
				result.route, result.radius, result.path = route, radius, path
				return result
			end
			-- a engine achou rota, mas o corpo não cabe: registra e tenta o próximo degrau
			-- (um raio diferente pode achar outro caminho)
			if result.narrowFit == nil or maxFit > result.narrowFit then
				result.narrowFit, result.narrowAt, result.narrowRoute = maxFit, blockedAt, route
			end
		elseif status == Enum.PathStatus.FailFinishNotEmpty then
			result.finishBlocked = true
		end
	end
	return result
end

-- ===== API =====

-- Revalida uma rota já aceita, a partir do segmento `fromIndex`, com a MESMA varredura que a
-- aceitou. O Agent usa quando uma parte nova surge no mundo (D-021): se a rota ainda cabe, nada
-- mudou para ele; se não, foi bloqueada. Retorna (livre?, onde bateu, índice do waypoint em que o
-- segmento bloqueado termina, na numeração de `route`).
local function checkRoute(
	params: RaycastParams,
	route: { Types.Waypoint },
	options: Types.ResolvedOptions,
	fromIndex: number
): (boolean, Vector3?, number?)
	local from = math.max(1, fromIndex)
	local slice: { Types.Waypoint } = {}
	for i = from, #route do
		table.insert(slice, route[i])
	end
	-- só params e simplifyCtx são usados por routeClear
	local ctx = { params = params, simplifyCtx = Simplifier.buildContext(params, options.Agent.Radius) }
	local clear, at, segment = routeClear(slice, Util.getBodyRadius(options.Agent.Radius), ctx :: any)
	if clear then
		return true, nil, nil
	end
	return false, at, if segment then from + segment else nil -- o segmento i termina no waypoint i + 1
end

function RouteSolver.isRouteClear(
	character: Types.CharacterLike,
	route: { Types.Waypoint },
	options: Types.ResolvedOptions,
	fromIndex: number?,
	target: Types.TargetLike?
): (boolean, Vector3?, number?)
	local root = Util.resolveRoot(character)
	if not root then
		return true, nil, nil
	end
	local extra: { Instance } = { Util.resolveModel(character) or root }
	if target and typeof(target) == "Instance" then
		table.insert(extra, target)
	end
	return checkRoute(Geometry.buildRaycastParams(extra), route, options, fromIndex or 1)
end

-- Igual, mas sem personagem: exclui os modelos com Humanoid junto do início da rota.
function RouteSolver.isRouteClearAt(
	route: { Types.Waypoint },
	options: Types.ResolvedOptions,
	fromIndex: number?,
	target: Types.TargetLike?
): (boolean, Vector3?, number?)
	local first = route[1]
	local extra: { Instance } = if first then charactersNear(first.Position) else {}
	if target and typeof(target) == "Instance" then
		table.insert(extra, target)
	end
	return checkRoute(Geometry.buildRaycastParams(extra), route, options, fromIndex or 1)
end

-- Fase 6 (D-024): toda falha passa por aqui antes de sair do solver. Se a causa é uma parte
-- invisível colidível que a lib não filtrou, o código vira invisible_collider (com a parte em
-- details.instance) e o código original vai em details.underlying. Com Debug ligado, marca o ponto.
local function fail(
	ctx: Context,
	code: string,
	details: { [string]: any },
	goalRaw: Vector3,
	goal: Vector3?
): (nil, string, { [string]: any })
	local culprit: BasePart? = nil
	local at: Vector3? = nil
	if code == Errors.CorridorTooNarrow then
		local blockedAt = details.blockedAt
		if typeof(blockedAt) == "Vector3" then
			culprit = Diagnostics.findInvisibleAt(blockedAt, INVISIBLE_PROBE_RADIUS, ctx.overlapParams)
			at = blockedAt
		end
	elseif code == Errors.GoalUnreachable and not goal then
		-- destino dentro de uma parede: era invisível?
		local inside = goalRaw + UP * GOAL_INSIDE_PROBE_HEIGHT
		at = inside
		culprit = Diagnostics.findInvisibleAt(inside, GOAL_INSIDE_PROBE_RADIUS, ctx.overlapParams)
	elseif code == Errors.NoPath or code == Errors.GoalUnreachable then
		local lift = UP * STAND_CENTER_HEIGHT
		local target = goal or goalRaw
		culprit, at =
			Diagnostics.findInvisibleAlong(ctx.params, ctx.startGround + lift, target + lift, ctx.bodyRadius)
	end
	if culprit then
		details = table.clone(details)
		details.underlying = code
		details.instance = culprit
		details.position = at
		code = Errors.InvisibleCollider
	end
	if ctx.options.Debug then
		Util.debugPrint(true, "sem rota:", code, Diagnostics.explain(code, details))
		Debug.failure(code, details)
	end
	return nil, code, details
end

-- Núcleo do solver: tudo o que só precisa de posições (origem no chão, destino, filtro de
-- raycast). `solve` (com personagem) e `solvePositions` (só Vector3, para a camada de
-- compatibilidade) preparam esses três e chamam esta função.
local function solveFrom(
	params: RaycastParams,
	target: Types.TargetLike,
	goalRaw: Vector3,
	startGround: Vector3,
	options: Types.ResolvedOptions,
	cache: RouteCache.RouteCache?
): ({ Types.Waypoint }?, string?, { [string]: any }?)
	local agentRadius = options.Agent.Radius
	local agentHeight = options.Agent.Height
	local start = startGround + UP * START_HEIGHT_OFFSET

	local ctx: Context = {
		options = options,
		agentRadius = agentRadius,
		agentHeight = agentHeight,
		bodyRadius = Util.getBodyRadius(agentRadius),
		params = params,
		overlapParams = buildOverlapParams(params),
		simplifyCtx = Simplifier.buildContext(params, agentRadius),
		start = start,
		startGround = startGround,
		ladder = buildLadder(agentRadius, options.Indoor),
		tried = {},
		jumpEnabled = options.Jump.Enabled,
	}

	local goal, nearestValid = normalizeGoal(goalRaw, ctx)
	if not goal then
		return fail(ctx, Errors.GoalUnreachable, { nearestValid = nearestValid, requestedGoal = goalRaw }, goalRaw, nil)
	end

	local rc: RouteCache.RouteCache = cache or sharedCache
	local useCache = options.Stability.Cache
	local profile = string.format(
		"r%.2f|h%.2f|j%d|%s",
		agentRadius,
		agentHeight,
		ctx.jumpEnabled and 1 or 0,
		table.concat(ctx.ladder, ",")
	)
	local geoVersion = Geometry.getVersion()
	if useCache then
		local cached, meta = rc:get(start, goal, profile, geoVersion)
		if cached then
			local details = table.clone(meta or {})
			details.cached = true
			return cached, nil, details
		end
	end

	local result = runLadder(ctx, ctx.jumpEnabled, goal)

	-- passo 6a: AgentCanJump = false às vezes destrava malhas estranhas
	if not result.route and ctx.jumpEnabled then
		local retry = runLadder(ctx, false, goal)
		if retry.route then
			result = retry
		else
			result.narrowFit = if retry.narrowFit or result.narrowFit
				then math.max(retry.narrowFit or 0, result.narrowFit or 0)
				else nil
			result.finishBlocked = result.finishBlocked or retry.finishBlocked
		end
	end

	-- passo 6b: destino aproximado, só quando o problema foi de conectividade (se uma rota
	-- existiu mas o corpo não coube, mudar o destino não resolve)
	local effectiveGoal = goal
	local approximated = false
	if not result.route and result.narrowFit == nil then
		local approx = findNearestStandable(goal, ctx, APPROX_GOAL_RADIUS)
		if approx and (approx - goal).Magnitude > APPROX_MIN_DISTANCE then
			local retry = runLadder(ctx, ctx.jumpEnabled, approx)
			if retry.route then
				result = retry
				effectiveGoal = approx
				approximated = true
			end
		end
	end

	local route = result.route
	if not route then
		if result.narrowFit ~= nil then
			return fail(ctx, Errors.CorridorTooNarrow, {
				requiredRadius = round2(result.narrowFit / Util.BODY_RADIUS_RATIO),
				agentRadius = agentRadius,
				bodyRadius = ctx.bodyRadius,
				blockedAt = result.narrowAt,
				rejectedRoute = result.narrowRoute, -- a rota que não coube (Debug a desenha em vermelho)
				triedRadii = ctx.tried,
			}, goalRaw, goal)
		end
		if result.finishBlocked then
			return fail(ctx, Errors.GoalUnreachable, {
				nearestValid = findNearestStandable(goal, ctx, NEAREST_SEARCH_MAX),
				requestedGoal = goalRaw,
			}, goalRaw, goal)
		end
		return fail(ctx, Errors.NoPath, { triedRadii = ctx.tried }, goalRaw, goal)
	end

	-- a rota já vem preparada (origem no chão, suavizada e congelada) de runLadder
	local wps = route

	local usedRadius = result.radius or agentRadius
	local details = {
		radius = usedRadius,
		agentRadius = agentRadius,
		reduced = usedRadius < agentRadius,
		cached = false,
		approximated = approximated,
		goal = effectiveGoal,
		-- destino normalizado usado como chave do cache: quem quiser invalidar a rota
		-- (RouteCache.invalidateGoal) precisa dele, não do destino bruto
		cacheGoal = goal,
		triedRadii = ctx.tried,
		path = result.path,
	}

	-- só guarda no cache se a geometria não mudou durante o cálculo. O Path fica junto: o
	-- Path.Blocked dispara para qualquer um que o segure, então quem receber esta rota do
	-- cache também é avisado quando algo bloqueia o caminho.
	if useCache and Geometry.getVersion() == geoVersion then
		rc:put(start, goal, profile, wps, geoVersion, table.clone(details))
	end

	Util.debugPrint(
		options.Debug,
		string.format("rota com %d waypoints (raio %.2f de %.2f)", #wps, usedRadius, agentRadius)
	)
	return wps, nil, details
end

-- Retorna (waypoints, nil, details) em sucesso ou (nil, código de erro, details) em falha.
-- `options` deve vir de Config.resolve. `cache` é opcional (default: cache compartilhado).
-- `startGroundOverride` calcula a partir de um ponto de chão em vez da posição do personagem
-- (o Agent usa para validar a rota a partir do ponto de pouso de um salto): pula a espera
-- por aterrar e a projeção da origem.
function RouteSolver.solve(
	character: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.ResolvedOptions,
	cache: RouteCache.RouteCache?,
	startGroundOverride: Vector3?
): ({ Types.Waypoint }?, string?, { [string]: any }?)
	local humanoid = Util.resolveHumanoid(character)
	local root = Util.resolveRoot(character)
	if not humanoid or not root or humanoid.Health <= 0 then
		return nil, Errors.CharacterLost, {}
	end
	local model = Util.resolveModel(character)

	local goalRaw = Util.resolveTargetPosition(target)
	if not goalRaw then
		error("SmartPath: RouteSolver.solve: destino inválido (esperado Vector3, BasePart ou Model)", 2)
	end

	ensureGeometry(options)

	-- exclui o próprio personagem e o alvo dos raycasts/overlaps (o alvo não pode contar
	-- como "geometria" que bloqueia o destino dele mesmo)
	local extra: { Instance } = { model or root }
	if typeof(target) == "Instance" then
		table.insert(extra, target)
	end
	local params = Geometry.buildRaycastParams(extra)

	local startGround: Vector3
	if startGroundOverride then
		startGround = startGroundOverride
	else
		-- (estabilização nº1) nunca calcular com o agente no ar
		local t0 = os.clock()
		while humanoid.FloorMaterial == Enum.Material.Air and os.clock() - t0 < MAX_GROUNDED_WAIT do
			task.wait()
		end
		if humanoid.Health <= 0 or not root.Parent then
			return nil, Errors.CharacterLost, {}
		end
		local groundHit = Util.groundBelow(root.Position, options.Agent.Height + GROUND_PROBE_EXTRA, params)
		if not groundHit and humanoid.FloorMaterial == Enum.Material.Air then
			-- ainda no ar depois de esperar aterrar e sem chão embaixo (queda infinita, fora do mapa):
			-- nenhuma rota sai de um ponto no vazio, então nem chama a engine (D-033)
			return nil, Errors.NoPath, { triedRadii = {}, noGround = true }
		end
		startGround = groundHit and groundHit.Position or root.Position
	end
	return solveFrom(params, target, goalRaw, startGround, options, cache)
end

-- Variante sem personagem, para quem só tem coordenadas (a camada de compatibilidade,
-- D-001/D-022). Sem um personagem para excluir dos raycasts, exclui os modelos com Humanoid
-- que estão junto da origem (quem chama costuma ser um deles).
function RouteSolver.solvePositions(
	startPos: Vector3,
	target: Types.TargetLike,
	options: Types.ResolvedOptions,
	cache: RouteCache.RouteCache?
): ({ Types.Waypoint }?, string?, { [string]: any }?)
	local goalRaw = Util.resolveTargetPosition(target)
	if not goalRaw then
		error("SmartPath: RouteSolver.solvePositions: destino inválido (esperado Vector3, BasePart ou Model)", 2)
	end

	ensureGeometry(options)

	local extra = charactersNear(startPos)
	if typeof(target) == "Instance" then
		table.insert(extra, target)
	end
	local params = Geometry.buildRaycastParams(extra)

	-- a origem pode vir de um personagem no ar ou no meio do corpo: projeta no chão sob ela
	local groundHit = workspace:Raycast(
		startPos + UP,
		-UP * (options.Agent.Height + GROUND_PROBE_EXTRA + 1),
		params
	)
	local startGround = groundHit and groundHit.Position or startPos
	return solveFrom(params, target, goalRaw, startGround, options, cache)
end

return RouteSolver
end

-- ============================== Agent.luau ==============================
sources["Agent"] = function(script: any, require: any): any
-- Agent.luau
-- Agente persistente (nível 1 da API) e máquina de estados que junta o RouteSolver, o
-- Predictor e o JumpExecutor.
--
-- Estados: Idle -> Following -> (DirectJump ->) Airborne -> Following ... -> Idle | Failed.
--   Following : segue os waypoints com Humanoid:Move, sonda reativa de salto, anti-stuck.
--   DirectJump: corre em direção fixa até o ponto de decolagem de um atalho por salto.
--   Airborne  : durante TODO o voo continua chamando Move rumo ao pouso. Parar de chamar Move
--               é a causa nº 1 de "cair antes do obstáculo" (o Humanoid perde o momento).
--
-- Nunca usa Humanoid:MoveTo (timeout de 8s): só Humanoid:Move, todo frame.
-- Fase 6: toda falha traz código + details (ver Diagnostics.explain); o Agent produz stuck,
-- timeout, obstacle_too_tall, no_landing e invisible_collider (as causas de "travou").
-- O passo roda em PreSimulation, e não em Heartbeat: o ControlModule do jogador chama Move em
-- RenderStepped, que vem ANTES da física; um Move dado só no Heartbeat (depois da física)
-- seria sobrescrito por ele no frame seguinte [VALIDAR no cliente].

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Types = require(script.Parent.Types)
local Errors = require(script.Parent.Errors)
local Config = require(script.Parent.Config)
local Util = require(script.Parent.Util)
local Signal = require(script.Parent.Signal)
local Geometry = require(script.Parent.Geometry)
local RouteSolver = require(script.Parent.RouteSolver)
local Predictor = require(script.Parent.Predictor)
local JumpExecutor = require(script.Parent.JumpExecutor)
local Diagnostics = require(script.Parent.Diagnostics)
local Debug = require(script.Parent.Debug)

local Agent = {}
Agent.__index = Agent

local WALK = Enum.PathWaypointAction.Walk
local JUMP = Enum.PathWaypointAction.Jump
local CUSTOM = Enum.PathWaypointAction.Custom

-- Constantes internas (valores de referência). Não fazem parte da tabela de Options pública,
-- que é estável.
local ARRIVE_RADIUS = 1.25 -- distância plana para considerar um waypoint alcançado
local STUCK_TIME = 1.0 -- sem progresso por este tempo = uma tentativa de anti-stuck
local STUCK_MIN_PROGRESS = 0.6 -- deslocamento que conta como progresso
local MAX_STUCK_STRIKES = 3 -- salto de escape, replan, replan; a seguinte falha com "stuck"
local MIN_REPLAN_INTERVAL = 0.5
-- Detecção própria de bloqueio (D-021): o Path.Blocked da engine não dispara para partes
-- inseridas em runtime. Uma parte nova só marca a rota como "suja"; a revalidação roda no
-- máximo a cada ROUTE_CHECK_INTERVAL, seja quantas partes surjam (ex.: um personagem nascendo).
local ROUTE_CHECK_INTERVAL = 0.25
-- Uma parte que já estava no mundo e SE MOVE para dentro da rota (bloco que cai, porta) não dispara
-- Geometry.PartAdded. Enquanto segue, o agente revalida a rota a cada ROUTE_RECHECK_INTERVAL (D-030).
local ROUTE_RECHECK_INTERVAL = 1
-- Depois de um bloqueio a malha da engine demora a incluir o obstáculo (medido: mais de 10s), e
-- nesse intervalo o replan não acha rota. Em vez de falhar, o agente espera e tenta de novo.
local BLOCKED_RETRY_WINDOW = 30
local BLOCKED_RETRY_INTERVAL = 1.5
-- Alvo móvel (BasePart/Model como destino): a posição dele é conferida a cada
-- TARGET_CHECK_INTERVAL e a rota é refeita quando ele se afasta mais que TARGET_MOVE_THRESHOLD
-- do destino do último cálculo. O limiar evita replanejar a cada passo do alvo (custo e
-- zigue-zague); consequência: o agente termina a no máximo ~esse limiar de um alvo que parou.
local TARGET_CHECK_INTERVAL = 0.25
local TARGET_MOVE_THRESHOLD = 4
-- Chegada perto de um alvo móvel. O último waypoint conta como alcançado a TARGET_STOP_DISTANCE:
-- um alvo que é outro personagem colide com o agente a ~2 studs, então exigir o ARRIVE_RADIUS
-- (1.25) do ponto dele faria o agente empurrá-lo até cair no anti-stuck. E ao chegar, se o alvo
-- ainda está além de TARGET_RESUME_DISTANCE (ele andou depois do último cálculo), o agente segue
-- em vez de declarar chegada; assim termina a no máximo essa distância dele.
local TARGET_STOP_DISTANCE = 3
local TARGET_RESUME_DISTANCE = 3.5
local PROBE_INTERVAL = 0.1 -- frequência da sonda reativa de salto
local JUMP_COOLDOWN = 0.35
local MIN_AIR_TIME = 0.15 -- antes disso um FloorMaterial ~= Air ainda é o chão da decolagem
local MAX_AIR_TIME = 3
local DIRECT_TIMEOUT = 4 -- tempo máximo correndo até a decolagem de um atalho
local MIN_GAIN_RATIO = 0.2 -- o atalho por salto precisa encurtar o trajeto em ≥ 20%
local START_INDEX_LOOKAHEAD = 5
local JUMP_LINK_LABEL = "JumpLink" -- Label de PathfindingLink tratado como salto (v2)
local DEBUG_LIFETIME = 6
local LOAD_TIMEOUT = 5 -- espera por Humanoid/HumanoidRootPart de um personagem ainda carregando
-- Curvas (Stability.Curves, D-035): o agente mira num ponto adiante NA ROTA, em vez de virar de uma vez
-- em cada canto. A distância é WalkSpeed x este tempo, limitada; [VALIDAR] no rig do jogo.
local CURVE_LOOKAHEAD_TIME = 0.3
local CURVE_MIN_LOOKAHEAD = 3
local CURVE_MAX_LOOKAHEAD = 8
local CURVE_VALIDATE_ATTEMPTS = 3 -- quantas vezes a distância é reduzida à metade até o corpo caber
-- Endurecimento (Fase 8, D-033)
-- Personagem removido do jogo: o agente falha com character_lost e se destrói depois deste atraso, para
-- que os handlers de Failed rodem antes (o BindableEvent entrega no ciclo seguinte).
local REMOVED_DESTROY_DELAY = 0.5
-- Destino já ao alcance: não há o que calcular (MoveTo até onde se está).
local ALREADY_THERE_HEIGHT_TOLERANCE = 6
-- StreamingEnabled no cliente: pede a região do destino só se ele está longe o bastante para ainda
-- não ter sido enviada, e espera no máximo isto.
local STREAM_REQUEST_MIN_DISTANCE = 100
local STREAM_REQUEST_TIMEOUT = 2
-- Diagnóstico de travamento (Fase 6): ao esgotar o anti-stuck, procura à frente uma parte
-- invisível colidível. Parte de um pouco atrás para que uma parede encostada no corpo não fique
-- na origem do Spherecast (que ignora o que sobrepõe a origem, D-014).
local STUCK_PROBE_BACK = 1.5
local STUCK_PROBE_AHEAD = 3
local STUCK_PROBE_KNEE_HEIGHT = 1
local STUCK_PROBE_KNEE_RADIUS = 0.5
-- códigos de falha que o Agent produz (o solver imprime e desenha os seus)
local DRAWN_BY_AGENT: { [string]: boolean } = {
	[Errors.Stuck] = true,
	[Errors.ObstacleTooTall] = true,
	[Errors.NoLanding] = true,
	[Errors.InvisibleCollider] = true,
	[Errors.Timeout] = true,
}

-- Tempo máximo de uma movimentação (código `timeout`). Não é opção pública (a tabela de opções é estável):
-- orçamento = BASE + FACTOR x (maior rota adotada) / WalkSpeed. BASE cobre a janela de espera
-- por bloqueio (30 s) com folga; FACTOR tolera um agente bem mais lento que o ideal. Exposto em
-- Agent._tuning só para os testes encurtarem.
Agent._tuning = { TimeoutBase = 45, TimeoutFactor = 4 }

type Session = {
	done: boolean,
	ok: boolean?,
	reason: string?,
	details: { [string]: any }?,
	waiters: { thread },
}

type StuckData = {
	lastPos: Vector3?,
	lastTime: number,
	strikes: number,
}

type AgentData = {
	Character: Model?,
	Humanoid: Humanoid,
	Root: BasePart,
	Options: Types.ResolvedOptions,
	Reached: Signal.Signal,
	Failed: Signal.Signal,
	Blocked: Signal.Signal,
	Jumped: Signal.Signal,
	CustomWaypoint: Signal.Signal,
	_userOptions: Types.Options,
	_state: Types.AgentState,
	_target: Types.TargetLike?,
	_goal: Vector3?,
	_cacheGoal: Vector3?,
	_route: { Types.Waypoint }?,
	_index: number,
	_planning: boolean,
	_replanRequested: boolean,
	_generation: number,
	_forceAdopt: boolean,
	_lastPlanTime: number,
	_lastProbe: number,
	_lastJump: number,
	_jumpPlan: Predictor.Plan?,
	_directStart: number,
	_airStart: number,
	_airTarget: Vector3?,
	_airDir: Vector3?,
	_suspended: boolean,
	_suspendedAt: number,
	_stuck: StuckData,
	_params: RaycastParams?,
	_paramsVersion: number,
	_connections: { RBXScriptConnection },
	_blockedConn: RBXScriptConnection?,
	_session: Session?,
	_destroyed: boolean,
	_routeDirty: boolean,
	_lastRouteCheck: number,
	_routeFromSolver: boolean,
	_blockedRetryUntil: number,
	_plannedGoal: Vector3?,
	_lastTargetCheck: number,
	_sessionStart: number,
	_maxRouteLen: number,
	_lastCalcTime: number?,
	_lastDetails: { [string]: any }?,
	_lastFailure: { reason: string, details: { [string]: any } }?,
	_curveLimit: number,
	_lastCurveCheck: number,
}

type Agent = typeof(setmetatable({} :: AgentData, Agent))

-- ===================== Sessão (Await) =====================
-- Uma sessão por MoveTo. Await é implementado com threads em vez de BindableEvent: sem
-- instância para vazar e sem depender da ordem de entrega do sinal ao destruir o agente.

local function newSession(): Session
	return { done = false, ok = nil, reason = nil, details = nil, waiters = {} }
end

local function finishSession(self: Agent, ok: boolean, reason: string?, details: { [string]: any }?)
	local s = self._session
	if not s or s.done then
		return
	end
	s.done, s.ok, s.reason, s.details = true, ok, reason, details
	local waiters = s.waiters
	s.waiters = {}
	for _, thread in ipairs(waiters) do
		task.spawn(thread, ok, reason, details)
	end
end

local function fire(self: Agent, signal: Signal.Signal, ...: any)
	if not self._destroyed then
		signal:Fire(...)
	end
end

-- ===================== Criação =====================

-- Pode dar yield por até LOAD_TIMEOUT se o personagem ainda estiver carregando.
function Agent.new(characterOrHumanoid: Types.CharacterLike, options: Types.Options?): Agent
	local model = Util.resolveModel(characterOrHumanoid)
	local humanoid = Util.resolveHumanoid(characterOrHumanoid)
	if not humanoid and model then
		humanoid = model:WaitForChild("Humanoid", LOAD_TIMEOUT) :: Humanoid?
	end
	local root = Util.resolveRoot(characterOrHumanoid)
	if not root and model then
		local found = model:WaitForChild("HumanoidRootPart", LOAD_TIMEOUT)
		root = if found and found:IsA("BasePart") then found else nil
	end
	if not humanoid or not root then
		error("SmartPath: Agent.new: o personagem precisa de um Humanoid e um HumanoidRootPart", 2)
	end

	local userOptions = Config.overlay({}, options)
	local self = (
		setmetatable({
			Character = model,
			Humanoid = humanoid,
			Root = root,
			Options = Config.resolve(humanoid, userOptions),
			Reached = Signal.new(),
			Failed = Signal.new(),
			Blocked = Signal.new(),
			Jumped = Signal.new(),
			CustomWaypoint = Signal.new(),
			_userOptions = userOptions,
			_state = "Idle",
			_target = nil,
			_goal = nil,
			_cacheGoal = nil,
			_route = nil,
			_index = 1,
			_planning = false,
			_replanRequested = false,
			_generation = 0,
			_forceAdopt = false,
			_lastPlanTime = 0,
			_lastProbe = 0,
			_lastJump = 0,
			_jumpPlan = nil,
			_directStart = 0,
			_airStart = 0,
			_airTarget = nil,
			_airDir = nil,
			_suspended = false,
			_suspendedAt = 0,
			_stuck = { lastPos = nil, lastTime = 0, strikes = 0 },
			_params = nil,
			_paramsVersion = -1,
			_connections = {},
			_blockedConn = nil,
			_session = nil,
			_destroyed = false,
			_routeDirty = false,
			_lastRouteCheck = 0,
			_routeFromSolver = false,
			_blockedRetryUntil = 0,
			_plannedGoal = nil,
			_lastTargetCheck = 0,
			_sessionStart = 0,
			_maxRouteLen = 0,
			_lastCalcTime = nil,
			_lastDetails = nil,
			_lastFailure = nil,
			_curveLimit = math.huge,
			_lastCurveCheck = 0,
		}, Agent) :: any
	) :: Agent

	table.insert(
		self._connections,
		RunService.PreSimulation:Connect(function()
			self:_step()
		end)
	)
	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			self:_onCharacterLost()
		end)
	)
	table.insert(
		self._connections,
		Geometry.PartAdded:Connect(function(part: BasePart)
			self:_onPartAdded(part)
		end)
	)
	local function onRemoved(_, parent: Instance?)
		if not parent then
			self:_onCharacterLost()
			task.delay(REMOVED_DESTROY_DELAY, function()
				if not self._destroyed then
					self:Destroy()
				end
			end)
		end
	end
	table.insert(self._connections, humanoid.AncestryChanged:Connect(onRemoved))
	table.insert(self._connections, root.AncestryChanged:Connect(onRemoved))

	-- NPC no servidor: a física fica sempre no servidor (sem troca de dono no meio do salto)
	if RunService:IsServer() and not (model and Players:GetPlayerFromCharacter(model)) then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
	return self
end

-- ===================== API pública =====================

-- Não bloqueia. Um MoveTo novo cancela o anterior (o Await do anterior devolve
-- false, "cancelled").
function Agent.MoveTo(self: Agent, target: Types.TargetLike)
	if self._destroyed then
		error("SmartPath: Agent:MoveTo chamado num agente destruído", 2)
	end
	local goal = Util.resolveTargetPosition(target)
	if not goal then
		error("SmartPath: Agent:MoveTo: destino inválido (esperado Vector3, BasePart ou Model)", 2)
	end

	finishSession(self, false, Errors.Cancelled, {})
	self._session = newSession()

	self._generation += 1 -- invalida qualquer cálculo em voo do destino anterior
	self._target = target
	self._goal = goal
	self._cacheGoal = nil
	self._route = nil
	self._index = 1
	self._jumpPlan = nil
	self._state = "Following"
	self._forceAdopt = true
	self._stuck = { lastPos = nil, lastTime = 0, strikes = 0 }
	self._routeFromSolver = false
	self._routeDirty = false
	self._blockedRetryUntil = 0
	self._plannedGoal = nil
	self._lastFailure = nil
	self:_restartBudget()
	self:_watchPath(nil)

	if self.Humanoid.Health <= 0 or not self.Root.Parent then
		self:_fail(Errors.CharacterLost, {})
		return
	end
	-- NaN ou infinito vindo de um cálculo do jogo: não é um lugar; falha em vez de propagar NaN
	local m = goal.X + goal.Y + goal.Z
	if m ~= m or math.abs(m) == math.huge then
		self:_fail(Errors.GoalUnreachable, { requestedGoal = goal })
		return
	end
	self:_requestPlan(true)
end

-- Yield até chegar ou falhar. Retorna (true) ou (false, motivo, details).
function Agent.Await(self: Agent): (boolean, string?, { [string]: any }?)
	local s = self._session
	if not s then
		return false, Errors.Cancelled, {}
	end
	if s.done then
		return s.ok :: boolean, s.reason, s.details
	end
	table.insert(s.waiters, coroutine.running())
	return coroutine.yield()
end

function Agent.Stop(self: Agent)
	self:_halt()
	finishSession(self, false, Errors.Cancelled, {})
end

-- Pausa sem perder a rota (cutscene, dash, stun). Ao retomar, continua do waypoint certo.
function Agent.SetSuspended(self: Agent, suspended: boolean)
	if self._suspended == suspended or self._destroyed then
		return
	end
	self._suspended = suspended
	if suspended then
		self._suspendedAt = os.clock()
		-- Move é persistente: sem zerar, o Humanoid continuaria andando na última direção
		if self.Humanoid.Parent then
			self.Humanoid:Move(Vector3.zero, false)
		end
	else
		-- a pausa não conta para os timeouts de salto
		local paused = os.clock() - self._suspendedAt
		self._directStart += paused
		self._airStart += paused
		self._sessionStart += paused
		self._stuck.lastPos = nil
		if self._route and self._state == "Following" then
			self._index = self:_selectStartIndex(self._route, self._index)
		end
	end
end

function Agent.GetState(self: Agent): Types.AgentState
	return self._state
end

function Agent.GetRoute(self: Agent): { Types.Waypoint }?
	return self._route
end

-- Aceita um subconjunto de opções; o resto continua como estava. A rota atual não é refeita.
function Agent.SetOptions(self: Agent, partial: Types.Options)
	self._userOptions = Config.overlay(self._userOptions, partial)
	self.Options = Config.resolve(self.Humanoid, self._userOptions)
end

function Agent.Destroy(self: Agent)
	if self._destroyed then
		return
	end
	self:_halt()
	finishSession(self, false, Errors.Cancelled, {})
	self._destroyed = true
	for _, c in ipairs(self._connections) do
		if c.Connected then
			c:Disconnect()
		end
	end
	table.clear(self._connections)
	self.Reached:Destroy()
	self.Failed:Destroy()
	self.Blocked:Destroy()
	self.Jumped:Destroy()
	self.CustomWaypoint:Destroy()
end

-- Só para testes: quantas conexões do agente ainda estão vivas (deve ser 0 após Destroy).
function Agent._liveConnectionCount(self: Agent): number
	local n = 0
	for _, c in ipairs(self._connections) do
		if c.Connected then
			n += 1
		end
	end
	if self._blockedConn and self._blockedConn.Connected then
		n += 1
	end
	return n
end

-- ===================== Interno: parada e falha =====================

-- Para tudo sem resolver a sessão (quem chama decide: Stop cancela, _arrive conclui).
function Agent._halt(self: Agent)
	self._generation += 1
	self._state = "Idle"
	self._goal = nil
	self._target = nil
	self._cacheGoal = nil
	self._route = nil
	self._jumpPlan = nil
	self._airTarget = nil
	self._airDir = nil
	self:_watchPath(nil)
	if self.Humanoid.Parent then
		self.Humanoid:Move(Vector3.zero, false)
	end
end

function Agent._fail(self: Agent, reason: string, details: { [string]: any }?)
	local d: { [string]: any } = details or {}
	self._lastFailure = { reason = reason, details = d }
	-- invisible_collider vindo do solver já foi impresso e desenhado lá; só o que nasce de stuck é daqui
	local fromSolver = reason == Errors.InvisibleCollider and d.underlying ~= Errors.Stuck
	if self.Options.Debug and DRAWN_BY_AGENT[reason] and not fromSolver then
		Util.debugPrint(true, "falha:", reason, Diagnostics.explain(reason, d))
		Debug.failure(reason, d, DEBUG_LIFETIME)
	end
	self:_halt()
	self._state = "Failed"
	finishSession(self, false, reason, d)
	fire(self, self.Failed, reason, d)
end

function Agent._arrive(self: Agent)
	local target = self._target
	if target and typeof(target) == "Instance" then
		local pos = Util.resolveTargetPosition(target)
		if pos and Util.flat(pos - self.Root.Position).Magnitude > TARGET_RESUME_DISTANCE then
			-- o alvo andou depois do último cálculo: segue em vez de declarar chegada. Sem rota, o
			-- passo não chama _arrive de novo enquanto o replan não termina.
			self._goal = pos
			self._route = nil
			self._forceAdopt = true
			self:_restartBudget()
			if self.Humanoid.Parent then
				self.Humanoid:Move(Vector3.zero, false) -- Move é persistente
			end
			self:_requestPlan(true)
			return
		end
	end
	self:_halt()
	finishSession(self, true, nil, nil)
	-- por último: um MoveTo chamado dentro do handler de Reached começa uma sessão nova sem
	-- ser atropelado por este código
	fire(self, self.Reached)
end

function Agent._onCharacterLost(self: Agent)
	if self._destroyed or self._state == "Idle" or self._state == "Failed" then
		return
	end
	self:_fail(Errors.CharacterLost, {})
end

-- A rota atual foi bloqueada, avisada pela engine (Path.Blocked) ou detectada por nós
-- (_checkRoute). Para o agente para não empurrar o obstáculo, descarta a rota e replaneja.
function Agent._onBlocked(self: Agent)
	if not self._goal or self._destroyed then
		return
	end
	fire(self, self.Blocked)
	RouteSolver.getSharedCache():invalidateGoal(self._cacheGoal or self._goal)
	self._route = nil
	self._routeFromSolver = false
	self._blockedRetryUntil = os.clock() + BLOCKED_RETRY_WINDOW
	self._forceAdopt = true
	if self.Humanoid.Parent then
		self.Humanoid:Move(Vector3.zero, false) -- Move é persistente
	end
	self:_requestPlan(true)
end

-- Uma parte colidível entrou no workspace: a rota pode ter sido bloqueada. Personagens (que se
-- movem sozinhos e nascem com dezenas de partes) não contam.
function Agent._onPartAdded(self: Agent, part: BasePart)
	if self._destroyed or self._state == "Idle" or self._state == "Failed" then
		return
	end
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return
	end
	self._routeDirty = true
end

-- Revalida os segmentos restantes da rota com a mesma varredura que a aceitou.
function Agent._checkRoute(self: Agent)
	local now = os.clock()
	if now - self._lastRouteCheck < ROUTE_CHECK_INTERVAL then
		return -- continua suja; tenta no próximo frame elegível
	end
	local route = self._route
	if self._planning or self._state ~= "Following" or not route or not self._routeFromSolver then
		-- sem rota validada para checar (calculando, no ar, ou rota que não veio do solver): a
		-- rota nova, quando chegar, já foi validada contra o mundo atual
		if not self._planning then
			self._routeDirty = false
		end
		return
	end
	self._routeDirty = false
	self._lastRouteCheck = now
	local clear = RouteSolver.isRouteClear(self.Humanoid, route, self.Options, math.max(1, self._index - 1), self._target)
	if not clear then
		self:_onBlocked()
	end
end

-- Path.Blocked pertence ao objeto Path da rota atual; troca a conexão a cada rota nova.
function Agent._watchPath(self: Agent, path: Path?)
	if self._blockedConn then
		self._blockedConn:Disconnect()
		self._blockedConn = nil
	end
	if path then
		self._blockedConn = path.Blocked:Connect(function()
			self:_onBlocked()
		end)
	end
end

-- ===================== Interno: planejamento =====================

function Agent._getParams(self: Agent): RaycastParams
	local v = Geometry.getVersion()
	local params = self._params
	if not params or v ~= self._paramsVersion then
		local exclude: { Instance } = { self.Character or self.Root }
		params = Geometry.buildRaycastParams(exclude)
		self._params = params
		self._paramsVersion = v
	end
	return params :: RaycastParams
end

-- Orçamento de tempo da movimentação atual (código `timeout`). Recomeça quando o alvo se move.
function Agent._restartBudget(self: Agent)
	self._sessionStart = os.clock()
	self._maxRouteLen = 0
end

function Agent._checkTimeout(self: Agent)
	local userSpeed = self._userOptions.Agent and self._userOptions.Agent.WalkSpeed
	local speed = math.max(userSpeed or self.Humanoid.WalkSpeed, 1)
	local budget = Agent._tuning.TimeoutBase + Agent._tuning.TimeoutFactor * self._maxRouteLen / speed
	local elapsed = os.clock() - self._sessionStart
	if elapsed > budget then
		self:_fail(Errors.Timeout, { elapsed = math.floor(elapsed * 10 + 0.5) / 10 })
	end
end

function Agent._requestPlan(self: Agent, force: boolean)
	if self._destroyed then
		return
	end
	if self._planning then
		self._replanRequested = true
		return
	end
	if not force and os.clock() - self._lastPlanTime < MIN_REPLAN_INTERVAL then
		return
	end
	self._planning = true
	task.spawn(self._plan, self)
end

-- Alvo móvel: refaz a rota quando o alvo se afasta do destino do último cálculo.
function Agent._checkTarget(self: Agent)
	local target = self._target
	if not target or typeof(target) ~= "Instance" then
		return
	end
	local now = os.clock()
	if now - self._lastTargetCheck < TARGET_CHECK_INTERVAL then
		return
	end
	self._lastTargetCheck = now
	local pos = Util.resolveTargetPosition(target)
	local planned = self._plannedGoal
	if pos and planned and (pos - planned).Magnitude > TARGET_MOVE_THRESHOLD then
		self._goal = pos
		self._forceAdopt = true -- o destino mudou: a histerese não pode manter a rota velha
		self:_restartBudget() -- perseguir um alvo que se move não estoura o tempo máximo
		self:_requestPlan(true)
	end
end

function Agent._plan(self: Agent)
	local gen = self._generation
	local target = self._target
	if not target then
		self._planning = false
		return
	end
	self._lastPlanTime = os.clock()
	if typeof(target) == "Instance" then
		-- o solver relê a posição do alvo; o Agent guarda a mesma para arrival, salto direto e
		-- para saber a partir de quanto o alvo "se moveu"
		self._goal = Util.resolveTargetPosition(target) or self._goal
	end
	self._plannedGoal = self._goal

	-- destino igual à posição (ou a menos de um raio de chegada): já chegou, sem calcular rota
	local here = self.Root.Position
	local plannedGoal = self._goal
	if
		plannedGoal
		and Util.flat(plannedGoal - here).Magnitude <= ARRIVE_RADIUS
		and math.abs(plannedGoal.Y - here.Y) <= math.max(self.Options.Agent.Height, ALREADY_THERE_HEIGHT_TOLERANCE)
	then
		self._planning = false
		self:_arrive()
		return
	end

	-- StreamingEnabled: no cliente, a geometria perto do destino pode nem existir ainda
	if
		plannedGoal
		and workspace.StreamingEnabled
		and RunService:IsClient()
		and (plannedGoal - here).Magnitude > STREAM_REQUEST_MIN_DISTANCE
	then
		local player = Players.LocalPlayer
		if player then
			pcall(function()
				player:RequestStreamAroundAsync(plannedGoal, STREAM_REQUEST_TIMEOUT)
			end)
		end
	end

	local t0 = os.clock()
	local wps, reason, details = RouteSolver.solve(self.Humanoid, target, self.Options)
	self._lastCalcTime = os.clock() - t0

	if self._destroyed then
		return
	end
	if gen ~= self._generation or not self._goal then
		-- o destino mudou (ou houve Stop) durante o cálculo: descarta a rota, sem rota fantasma
		self._planning = false
		self._replanRequested = false
		if self._goal then
			self:_requestPlan(true)
		end
		return
	end

	if wps then
		self:_adoptRoute(wps, details or {}, gen)
	else
		self:_handleNoRoute(reason or Errors.NoPath, details or {})
	end

	self._planning = false
	if self._replanRequested then
		self._replanRequested = false
		task.delay(MIN_REPLAN_INTERVAL, function()
			if self._goal and not self._destroyed then
				self:_requestPlan(true)
			end
		end)
	end
end

function Agent._adoptRoute(self: Agent, wps: { Types.Waypoint }, details: { [string]: any }, gen: number)
	local rootPos = self.Root.Position
	local newLen = Util.pathLength(wps, rootPos, 2)

	-- histerese: uma rota nova só substitui a atual se for pelo menos `Hysteresis` mais curta,
	-- exceto em replan forçado (bloqueio, stuck, destino novo). Evita a troca de lado que gera o
	-- zigue-zague lateral.
	if not self._forceAdopt and self._route and self._state == "Following" then
		local curLen = Util.pathLength(self._route, rootPos, self._index)
		if newLen > curLen * (1 - self.Options.Stability.Hysteresis) then
			return
		end
	end
	self._forceAdopt = false
	self._route = wps
	self._lastDetails = details
	self._curveLimit = math.huge
	self._maxRouteLen = math.max(self._maxRouteLen, newLen)
	self._routeFromSolver = true
	self._blockedRetryUntil = 0
	self._index = self:_selectStartIndex(wps, 1)
	if self._state ~= "Airborne" then
		self._state = "Following"
	end
	self._cacheGoal = details.cacheGoal
	self:_watchPath(details.path)

	if self.Options.Debug then
		Debug.route(wps, DEBUG_LIFETIME)
		local used, full = details.radius, details.agentRadius
		if typeof(used) == "number" and typeof(full) == "number" and wps[1] then
			Debug.radius(wps[1].Position, used, full, DEBUG_LIFETIME)
		end
	end

	self:_considerDirectJump(newLen, gen)
end

function Agent._analyzeToward(
	self: Agent,
	targetPos: Vector3,
	probeDistance: number?
): (Predictor.Plan?, string, { [string]: any }?)
	local userMax = self._userOptions.Jump and self._userOptions.Jump.MaxHeight
	local userSpeed = self._userOptions.Agent and self._userOptions.Agent.WalkSpeed
	return Predictor.analyze({
		root = self.Root,
		humanoid = self.Humanoid,
		targetPos = targetPos,
		params = self:_getParams(),
		agentRadius = self.Options.Agent.Radius,
		agentHeight = self.Options.Agent.Height,
		-- vivos: o jogo pode mudar WalkSpeed/JumpHeight depois que o agente foi criado
		walkSpeed = userSpeed or self.Humanoid.WalkSpeed,
		maxJumpHeight = userMax,
		probeDistance = probeDistance,
	})
end

-- Atalho por salto (predição proativa): se a rota dá uma volta grande, analisa a linha reta até
-- o destino; se há obstáculo saltável, valida uma rota a partir do ponto de pouso. Só adota o
-- salto se (decolagem->pouso) + (pouso->destino) for bem mais curto que o desvio: isso impede
-- saltar para um beco.
function Agent._considerDirectJump(self: Agent, pathLen: number, gen: number)
	if not self.Options.Jump.Enabled then
		return
	end
	local goal, target = self._goal, self._target
	if not goal or not target then
		return
	end
	local rootPos = self.Root.Position
	local straight = Util.flat(goal - rootPos).Magnitude
	if straight < 1 or pathLen / straight < self.Options.Jump.DetourRatio then
		return
	end

	local plan = self:_analyzeToward(goal)
	if not plan then
		return
	end

	local after = RouteSolver.solve(self.Humanoid, target, self.Options, nil, plan.landingPoint)
	if self._destroyed or gen ~= self._generation or not after then
		return
	end
	local afterLen = Util.pathLength(after, plan.landingPoint, 2)
	local viaJump = Util.flat(plan.landingPoint - rootPos).Magnitude + afterLen
	if viaJump >= pathLen * (1 - MIN_GAIN_RATIO) then
		return
	end

	self._jumpPlan = plan
	self._route = after
	self._index = 1
	self._state = "DirectJump"
	self._directStart = os.clock()
end

-- Sem rota: o destino pode estar atrás de um obstáculo que a malha não sabe saltar (a engine
-- ignora o JumpHeight real do Humanoid). Tenta o salto direto antes de desistir.
function Agent._handleNoRoute(self: Agent, reason: string, details: { [string]: any })
	local goal = self._goal
	if goal and self.Options.Jump.Enabled then
		local plan = self:_analyzeToward(goal)
		if plan then
			self._jumpPlan = plan
			local goalWp: Types.Waypoint = { Position = goal, Action = WALK, Label = "", SmartAction = "Walk" }
			table.freeze(goalWp)
			local route = { goalWp }
			self._route = route
			if self.Options.Debug then
				Debug.route(route, DEBUG_LIFETIME)
			end
			self._routeFromSolver = false
			self._index = 1
			self._state = "DirectJump"
			self._directStart = os.clock()
			return
		end
	end
	if os.clock() < self._blockedRetryUntil then
		-- a malha ainda não incluiu o obstáculo que bloqueou a rota: espera e tenta de novo
		task.delay(BLOCKED_RETRY_INTERVAL, function()
			if self._goal and not self._destroyed and os.clock() < self._blockedRetryUntil then
				self._forceAdopt = true
				self:_requestPlan(true)
			end
		end)
		return
	end
	-- Diagnóstico (Fase 6): sem rota e sem salto possível, o primeiro obstáculo da linha reta até o
	-- destino pode ser a explicação. Olha a linha inteira, não só os 10 studs da sonda normal.
	if goal and reason == Errors.NoPath and self.Options.Jump.Enabled then
		local _, why, info = self:_analyzeToward(goal, math.huge)
		local code, refined = Diagnostics.refineJumpFailure(reason, details, why, info)
		if code and refined then
			self:_fail(code, refined)
			return
		end
	end
	self:_fail(reason, details)
end

-- `afterLanding`: chamado ao pousar de um salto. O waypoint Jump é o DESTINO do salto (D-019) e o
-- agente costuma pousar um pouco além dele; se já passou dele, avança em vez de voltar até lá.
function Agent._selectStartIndex(self: Agent, wps: { Types.Waypoint }, hint: number, afterLanding: boolean?): number
	local rootPos = self.Root.Position
	local from = math.max(1, hint)
	local best, bestD = from, math.huge
	for i = from, math.min(#wps, from + START_INDEX_LOOKAHEAD) do
		local d = Util.flat(wps[i].Position - rootPos).Magnitude
		if d < bestD then
			best, bestD = i, d
		end
	end
	-- se o mais próximo já ficou para trás (e é Walk, ou o destino de um salto que acabou de
	-- acontecer), avança
	local nxt = wps[best + 1]
	if nxt and (wps[best].Action == WALK or (afterLanding and wps[best].Action == JUMP)) then
		local seg = Util.flat(nxt.Position - wps[best].Position)
		if seg.Magnitude > 1e-3 and Util.flat(rootPos - wps[best].Position):Dot(seg) > 0 then
			best += 1
		end
	end
	return best
end

-- ===================== Interno: execução por frame =====================

function Agent._step(self: Agent)
	if self._destroyed then
		return
	end
	if
		not self._routeDirty
		and self._state == "Following"
		and self._routeFromSolver
		and os.clock() - self._lastRouteCheck >= ROUTE_RECHECK_INTERVAL
	then
		self._routeDirty = true
	end
	-- antes do return de suspenso: um agente pausado também precisa saber que a rota foi bloqueada
	if self._routeDirty then
		self:_checkRoute()
	end
	if self._suspended then
		return
	end
	local st = self._state
	if st == "Idle" or st == "Failed" then
		return
	end
	self:_checkTimeout()
	if self._state == "Failed" then
		return
	end
	self:_checkTarget()
	if st == "Airborne" then
		self:_stepAirborne()
	elseif st == "DirectJump" then
		self:_stepDirectJump()
	else
		self:_stepFollowing()
	end
end

-- ===== Curvas (Stability.Curves, D-035) =====

-- Um waypoint "duro" precisa ser alcançado de verdade: o que antecede um salto ou um link (a decolagem é
-- feita ali), o próprio Jump/Custom, e o último. Os demais ("macios") podem ser cortados em curva.
local function isHardWaypoint(wps: { Types.Waypoint }, i: number): boolean
	local wp, nxt = wps[i], wps[i + 1]
	return wp.Action ~= WALK or nxt == nil or nxt.Action ~= WALK
end

-- O agente já passou de um waypoint macio: está além dele, na direção do segmento seguinte.
local function passedSoftWaypoint(wps: { Types.Waypoint }, i: number, rootPos: Vector3): boolean
	if isHardWaypoint(wps, i) then
		return false
	end
	local seg = Util.flat(wps[i + 1].Position - wps[i].Position)
	return seg.Magnitude > 1e-3 and Util.flat(rootPos - wps[i].Position):Dot(seg) > 0
end

-- Ponto a `distance` studs adiante na poligonal [rootPos, waypoints...], parando no primeiro waypoint
-- duro (nunca passa dele).
local function pointAlongRoute(wps: { Types.Waypoint }, index: number, rootPos: Vector3, distance: number): Vector3
	local remaining = distance
	local from = rootPos
	local i = index
	while true do
		local wp = wps[i]
		local len = Util.flat(wp.Position - from).Magnitude
		if len >= remaining or isHardWaypoint(wps, i) or not wps[i + 1] then
			if len < 1e-3 then
				return wp.Position
			end
			return from:Lerp(wp.Position, math.min(remaining, len) / len)
		end
		remaining -= len
		from = wp.Position
		i += 1
	end
end

-- Para onde o agente mira. Sem Curves é o waypoint atual (comportamento de sempre). Com Curves, um
-- ponto adiante na rota, na maior distância (até o máximo) em que o corpo ainda cabe na reta até ele:
-- a validação é a mesma varredura de volume da rota, refeita a cada PROBE_INTERVAL.
function Agent._aimPoint(self: Agent, wps: { Types.Waypoint }, rootPos: Vector3): Vector3
	local wp = wps[self._index]
	if not self.Options.Stability.Curves then
		return wp.Position
	end
	local now = os.clock()
	local wanted = math.clamp(self.Humanoid.WalkSpeed * CURVE_LOOKAHEAD_TIME, CURVE_MIN_LOOKAHEAD, CURVE_MAX_LOOKAHEAD)
	if now - self._lastCurveCheck >= PROBE_INTERVAL then
		self._lastCurveCheck = now
		local bodyRadius = Util.getBodyRadius(self.Options.Agent.Radius)
		local origin = Vector3.new(rootPos.X, Util.getFeetY(self.Humanoid, self.Root) + 2.5, rootPos.Z)
		local distance = wanted
		local fits = false
		for _ = 1, CURVE_VALIDATE_ATTEMPTS do
			local aim = pointAlongRoute(wps, self._index, rootPos, distance)
			local delta = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
			if delta.Magnitude < 1e-3 or not workspace:Spherecast(origin, bodyRadius, delta, self:_getParams()) then
				fits = true
				break
			end
			distance /= 2
		end
		self._curveLimit = if fits then distance else 0
	end
	local distance = math.min(wanted, self._curveLimit)
	if distance <= 0 then
		return wp.Position
	end
	return pointAlongRoute(wps, self._index, rootPos, distance)
end

function Agent._stepFollowing(self: Agent)
	local wps = self._route
	if not wps then
		return -- aguardando cálculo
	end
	local rootPos = self.Root.Position

	local wp = wps[self._index]
	if not wp then
		return self:_arrive()
	end

	local arriveRadius = ARRIVE_RADIUS
	if self._index == #wps and typeof(self._target) == "Instance" then
		arriveRadius = TARGET_STOP_DISTANCE -- perseguindo um alvo: não empurra o corpo dele
	end
	if
		Util.flat(wp.Position - rootPos).Magnitude <= arriveRadius
		or (self.Options.Stability.Curves and passedSoftWaypoint(wps, self._index, rootPos))
	then
		local nextWp = wps[self._index + 1]
		if nextWp and nextWp.Action == JUMP and self.Options.Jump.Enabled then
			-- o waypoint Jump é o destino do salto (D-019): decola daqui, do waypoint anterior.
			-- Se ainda não deu (cooldown, no ar), fica e tenta no próximo frame.
			if not self:_jumpToward(nextWp.Position) then
				self:_checkStuck()
				return
			end
		elseif wp.Action == CUSTOM then
			self:_handleCustom(wp, nextWp)
		end
		self._index += 1
		wp = wps[self._index]
		if not wp then
			return self:_arrive()
		end
		if self._state ~= "Following" then
			return -- o waypoint disparou um salto
		end
	end

	local aim = self:_aimPoint(wps, rootPos) -- sem Curves, é o próprio waypoint
	local dir = Util.flat(aim - rootPos)
	if dir.Magnitude > 1e-3 then
		self.Humanoid:Move(dir.Unit, false)
	end

	-- predição reativa: sonda o segmento atual (cobre o que o pathfinding não previu)
	if self.Options.Jump.Enabled then
		local now = os.clock()
		if now - self._lastProbe >= PROBE_INTERVAL then
			self._lastProbe = now
			local plan = self:_analyzeToward(aim)
			if plan and Predictor.wallDistance(plan, rootPos) <= plan.takeoffDistance then
				if self:_executeJump(plan.jumpHeight, plan.direction, plan.landingPoint, plan) then
					return
				end
			end
		end
	end

	self:_checkStuck()
end

function Agent._stepDirectJump(self: Agent)
	local plan = self._jumpPlan
	if not plan then
		self._state = "Following"
		return
	end
	self.Humanoid:Move(plan.direction, false)

	if Predictor.wallDistance(plan, self.Root.Position) <= plan.takeoffDistance then
		self:_executeJump(plan.jumpHeight, plan.direction, plan.landingPoint, plan)
		return
	end
	if os.clock() - self._directStart > DIRECT_TIMEOUT then
		-- não conseguiu decolar: volta à navegação normal com replan forçado
		self._jumpPlan = nil
		self._state = "Following"
		self._forceAdopt = true
		RouteSolver.getSharedCache():invalidateGoal(self._cacheGoal or self._goal or self.Root.Position)
		self:_requestPlan(true)
	end
end

function Agent._stepAirborne(self: Agent)
	local rootPos = self.Root.Position
	local toLanding = self._airTarget and Util.flat(self._airTarget - rootPos) or nil
	if toLanding and toLanding.Magnitude > 0.3 then
		self._airDir = toLanding.Unit
	end
	-- sincronia de momento: continua comandando o movimento durante TODO o voo
	if self._airDir then
		self.Humanoid:Move(self._airDir, false)
	end

	local elapsed = os.clock() - self._airStart
	if elapsed > MIN_AIR_TIME and self.Humanoid.FloorMaterial ~= Enum.Material.Air then
		self._state = "Following"
		self._airTarget = nil
		self._jumpPlan = nil
		self._stuck.lastPos = nil
		if self._route then
			self._index = self:_selectStartIndex(self._route, self._index, true)
		end
	elseif elapsed > MAX_AIR_TIME then
		self._state = "Following"
		self._forceAdopt = true
		self:_requestPlan(true)
	end
end

-- ===================== Interno: saltos =====================

function Agent._executeJump(
	self: Agent,
	height: number,
	dir: Vector3?,
	landing: Vector3?,
	plan: Predictor.Plan?
): boolean
	if os.clock() - self._lastJump < JUMP_COOLDOWN then
		return false
	end
	local ok = JumpExecutor.execute(self.Options.Jump.Mode, self.Humanoid, self.Root, height, dir)
	if not ok then
		return false
	end
	if self.Options.Debug then
		Debug.jump((plan or { landingPoint = landing, direction = dir }) :: any, DEBUG_LIFETIME)
	end
	self._lastJump = os.clock()
	self._airTarget = landing
	self._airDir = dir
	self._state = "Airborne"
	self._airStart = os.clock()
	-- salto sem análise do Predictor (waypoint Jump da engine): plano sintético
	fire(self, self.Jumped, plan or { direction = dir, landingPoint = landing, jumpHeight = height, synthetic = true })
	return true
end

-- Salto pedido pelo pathfinding (Action = Jump), por link ou pelo anti-stuck: altura precisa se
-- o Predictor entende o obstáculo, senão o máximo que o Humanoid alcança.
-- Retorna true se o salto foi disparado.
function Agent._jumpToward(self: Agent, target: Vector3): boolean
	if not self.Options.Jump.Enabled then
		return false
	end
	local plan = self:_analyzeToward(target)
	if plan then
		return self:_executeJump(plan.jumpHeight, plan.direction, plan.landingPoint, plan)
	end
	local userMax = self._userOptions.Jump and self._userOptions.Jump.MaxHeight
	local dir = Util.flat(target - self.Root.Position)
	local maxHeight = userMax or Util.getMaxJumpHeight(self.Humanoid)
	if maxHeight <= 0 then
		return false -- JumpHeight 0: pedir um salto não faz nada
	end
	return self:_executeJump(
		maxHeight,
		if dir.Magnitude > 1e-3 then dir.Unit else nil,
		target,
		nil
	)
end

function Agent._handleCustom(self: Agent, wp: Types.Waypoint, nextWp: Types.Waypoint?)
	if wp.Label == JUMP_LINK_LABEL then
		self:_jumpToward(nextWp and nextWp.Position or wp.Position)
	else
		fire(self, self.CustomWaypoint, wp.Label, wp, nextWp)
	end
end

-- ===================== Interno: robustez =====================

function Agent._checkStuck(self: Agent)
	local now = os.clock()
	local pos = self.Root.Position
	local s = self._stuck
	-- WalkSpeed 0, sentado ou em PlatformStand: o corpo não anda de propósito (stun, veículo). Isso
	-- não é "travado": o agente espera, e o orçamento de tempo (timeout) é a rede de segurança.
	local h = self.Humanoid
	if h.WalkSpeed <= 0 or h.Sit or h.PlatformStand then
		s.lastPos = nil
		return
	end
	if not s.lastPos then
		s.lastPos, s.lastTime = pos, now
		return
	end
	if (pos - s.lastPos).Magnitude >= STUCK_MIN_PROGRESS then
		s.lastPos, s.lastTime, s.strikes = pos, now, 0
		return
	end
	if now - s.lastTime < STUCK_TIME then
		return
	end

	s.strikes += 1
	s.lastPos, s.lastTime = pos, now
	if s.strikes == 1 and self.Options.Jump.Enabled then
		-- 1ª tentativa: salto de escape
		local route = self._route
		local wp = route and route[self._index]
		if wp then
			self:_jumpToward(wp.Position)
		end
	elseif s.strikes <= MAX_STUCK_STRIKES then
		RouteSolver.getSharedCache():invalidateGoal(self._cacheGoal or self._goal or pos)
		self._forceAdopt = true
		self:_requestPlan(true)
	else
		local culprit, at = self:_findInvisibleAhead()
		if culprit then
			self:_fail(Errors.InvisibleCollider, {
				instance = culprit,
				position = at,
				underlying = Errors.Stuck,
				strikes = s.strikes,
			})
		else
			self:_fail(Errors.Stuck, { position = pos, strikes = s.strikes })
		end
	end
end

-- O que travou o agente pode ser uma parte invisível colidível que a malha não vê (marcada
-- NavIgnore, ou filtrada pela lib por parecer um gatilho) mas o corpo bate. Por isso o
-- Spherecast NÃO usa o filtro da lib: só exclui o próprio personagem. Devolve (parte, ponto).
function Agent._findInvisibleAhead(self: Agent): (BasePart?, Vector3?)
	local route = self._route
	local wp = route and route[self._index]
	if not wp then
		return nil, nil
	end
	local pos = self.Root.Position
	local flat = Util.flat(wp.Position - pos)
	if flat.Magnitude < 1e-3 then
		return nil, nil
	end
	local dir = flat.Unit
	local exclude: { Instance } = { self.Character or self.Root }
	local dbg = Debug.peekFolder()
	if dbg then
		table.insert(exclude, dbg)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true

	local feetY = Util.getFeetY(self.Humanoid, self.Root)
	local samples: { { center: Vector3, radius: number } } = {
		{ center = pos, radius = Util.getBodyRadius(self.Options.Agent.Radius) },
		{ center = Vector3.new(pos.X, feetY + STUCK_PROBE_KNEE_HEIGHT, pos.Z), radius = STUCK_PROBE_KNEE_RADIUS },
	}
	for _, sample in ipairs(samples) do
		local culprit, at = Diagnostics.findInvisibleAlong(
			params,
			sample.center - dir * STUCK_PROBE_BACK,
			sample.center + dir * STUCK_PROBE_AHEAD,
			sample.radius
		)
		if culprit then
			return culprit, at
		end
	end
	return nil, nil
end

return Agent
end

-- ============================== Compat.luau ==============================
sources["Compat"] = function(script: any, require: any): any
-- Compat.luau
-- Camada de compatibilidade que espelha o PathfindingService.
-- Objetivo: um script existente passa a usar a SmartPath trocando UMA linha, a do require:
--
--   local PathfindingService = game:GetService("PathfindingService")   -- antes
--   local PathfindingService = require(ReplicatedStorage.SmartPath).Service   -- depois
--
-- e tudo o mais (CreatePath, ComputeAsync, Status, GetWaypoints, Blocked) continua igual.
--
-- Aqui NÃO há personagem (só Vector3), então não dá para derivar raio, altura de pulo e
-- velocidade do Humanoid como o nível 0/1 fazem (D-001): usa o raio/altura do CreatePath (ou os
-- defaults dele) e a escada de raio adaptativo, a validação de volume e o filtro de geometria
-- invisível do resto da lib. Extras não oficiais: path.SmartStatus e path.SmartDetails.
--
-- Diferenças conhecidas em relação ao serviço real: WaypointSpacing e Costs são ignorados (as
-- rotas vêm com waypoints só onde a direção muda ou há salto), e AgentCanClimb não tem efeito.

local Types = require(script.Parent.Types)
local Errors = require(script.Parent.Errors)
local Config = require(script.Parent.Config)
local Signal = require(script.Parent.Signal)
local Geometry = require(script.Parent.Geometry)
local RouteSolver = require(script.Parent.RouteSolver)

local Compat = {}
Compat.Service = {}

-- Defaults do PathfindingService:CreatePath.
local DEFAULT_AGENT_RADIUS = 2
local DEFAULT_AGENT_HEIGHT = 5
-- Juntar as partes que surgem em rajada (um personagem nascendo) numa única revalidação.
local BLOCKED_CHECK_DELAY = 0.25

local Path = {}
Path.__index = Path

type PathData = {
	Status: Enum.PathStatus,
	SmartStatus: string?,
	SmartDetails: { [string]: any }?,
	Blocked: any,
	_options: Types.ResolvedOptions,
	_waypoints: { Types.Waypoint },
	_blockedSignal: Signal.Signal?,
	_listening: boolean,
	_watchConn: RBXScriptConnection?,
	_checkScheduled: boolean,
}

type CompatPath = typeof(setmetatable({} :: PathData, Path))

-- SmartStatus -> Enum.PathStatus. Sucesso é sucesso mesmo quando a engine sozinha não acharia a
-- rota: o Status descreve o resultado da SmartPath, não o da engine.
local function statusFor(reason: string?): Enum.PathStatus
	if reason == nil then
		return Enum.PathStatus.Success
	end
	if reason == Errors.GoalUnreachable then
		return Enum.PathStatus.FailFinishNotEmpty
	end
	return Enum.PathStatus.NoPath
end

-- ===== path.Blocked =====
-- Objeto com Connect/Once/Wait, igual ao evento da engine. A observação do mundo só liga
-- quando alguém conecta: quem nunca usa Blocked não paga nada.

local function makeBlocked(path: CompatPath): any
	local blocked = {}
	local function signal(): Signal.Signal
		local s = path._blockedSignal
		if not s then
			s = Signal.new()
			path._blockedSignal = s
		end
		path._listening = true
		path:_startWatching()
		return s :: Signal.Signal
	end
	function blocked.Connect(_, fn: (number) -> ())
		return signal():Connect(fn :: any)
	end
	function blocked.Once(_, fn: (number) -> ())
		return signal():Once(fn :: any)
	end
	function blocked.Wait(_)
		return signal():Wait()
	end
	return blocked
end

function Path._startWatching(self: CompatPath)
	if self._watchConn or #self._waypoints == 0 then
		return
	end
	-- referência fraca: um script que descarta o Path sem desconectar não o mantém vivo, e a
	-- conexão se desfaz sozinha na próxima parte que surgir
	local weak = setmetatable({ path = self }, { __mode = "v" }) :: any
	local conn: RBXScriptConnection
	conn = Geometry.PartAdded:Connect(function(part: BasePart)
		local path = weak.path
		if not path or path._watchConn ~= conn then
			conn:Disconnect()
			return
		end
		path:_onPartAdded(part)
	end)
	self._watchConn = conn
end

function Path._stopWatching(self: CompatPath)
	if self._watchConn then
		self._watchConn:Disconnect()
		self._watchConn = nil
	end
end

function Path._onPartAdded(self: CompatPath, part: BasePart)
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return -- personagens se movem sozinhos e nascem com dezenas de partes
	end
	if self._checkScheduled then
		return
	end
	self._checkScheduled = true
	task.delay(BLOCKED_CHECK_DELAY, function()
		self._checkScheduled = false
		self:_checkBlocked()
	end)
end

function Path._checkBlocked(self: CompatPath)
	if not self._watchConn then
		return
	end
	local clear, _, index = RouteSolver.isRouteClearAt(self._waypoints, self._options, 1, nil)
	if not clear then
		self:_stopWatching() -- como o serviço real: avisa uma vez por cálculo
		local s = self._blockedSignal
		if s then
			s:Fire(index or 1)
		end
	end
end

-- ===== API espelhada =====

-- Bloqueante. Erra com argumentos inválidos, como o serviço real (scripts costumam usar pcall).
function Path.ComputeAsync(self: CompatPath, start: Vector3, finish: Vector3)
	if typeof(start) ~= "Vector3" or typeof(finish) ~= "Vector3" then
		error("SmartPath: Path:ComputeAsync espera dois Vector3", 2)
	end
	self:_stopWatching()
	local waypoints, reason, details = RouteSolver.solvePositions(start, finish, self._options)
	self._waypoints = waypoints or {}
	self.Status = statusFor(if waypoints then nil else (reason or Errors.NoPath))
	self.SmartStatus = if waypoints then nil else (reason or Errors.NoPath)
	self.SmartDetails = details
	if waypoints and self._listening then
		self:_startWatching()
	end
end

-- Cópia a cada chamada, como o serviço real: o script pode mexer na tabela dele.
function Path.GetWaypoints(self: CompatPath): { Types.Waypoint }
	return table.clone(self._waypoints)
end

-- params: os mesmos de PathfindingService:CreatePath (AgentRadius, AgentHeight, AgentCanJump...).
function Compat.Service.CreatePath(_self: any, params: { [string]: any }?): CompatPath
	local p: { [string]: any } = params or {}
	local overrides = {
		Agent = { Radius = p.AgentRadius or DEFAULT_AGENT_RADIUS, Height = p.AgentHeight or DEFAULT_AGENT_HEIGHT },
		Jump = { Enabled = if p.AgentCanJump == nil then true else p.AgentCanJump },
	}
	local self = setmetatable({
		-- antes de ComputeAsync não há rota: NoPath é o estado seguro (Success faria um script
		-- que confere o Status cedo demais achar que já tem waypoints)
		Status = Enum.PathStatus.NoPath,
		SmartStatus = nil,
		SmartDetails = nil,
		Blocked = nil,
		_options = Config.resolve(nil :: any, overrides :: any),
		_waypoints = {},
		_blockedSignal = nil,
		_listening = false,
		_watchConn = nil,
		_checkScheduled = false,
	}, Path) :: any
	self.Blocked = makeBlocked(self)
	return self :: CompatPath
end

return Compat
end

-- ============================== init.luau ==============================
sources["SmartPath"] = function(script: any, require: any): any
-- init.luau
-- Fachada pública da SmartPath (API estável):
--   nível 0 (MoveTo, MoveToAsync, GetRoute): uma linha, sem tabela de opções;
--   nível 1 (new): agente persistente;
--   nível 2 (Predictor, Simplifier, Geometry, Scheduler, Errors, Debug): peças soltas;
--   diagnóstico (Fase 6): explain(reason, details) e Debug (visualização e painel);
--   Service: camada de compatibilidade que espelha o PathfindingService.

local Types = require(script.Types)
local Errors = require(script.Errors)
local Config = require(script.Config)
local Util = require(script.Util)
local Scheduler = require(script.Scheduler)
local Geometry = require(script.Geometry)
local Simplifier = require(script.Simplifier)
local Predictor = require(script.Predictor)
local RouteSolver = require(script.RouteSolver)
local Agent = require(script.Agent)
local Compat = require(script.Compat)
local Diagnostics = require(script.Diagnostics)
local Debug = require(script.Debug)

local SmartPath = {}

SmartPath.Version = "1.0.0"

-- ===== Nível 2 — peças soltas =====
SmartPath.Predictor = Predictor
SmartPath.Simplifier = Simplifier
SmartPath.Geometry = Geometry
SmartPath.Scheduler = Scheduler
SmartPath.Errors = Errors
SmartPath.Debug = Debug

-- ===== Diagnóstico (Fase 6) =====

-- Frase legível para um código de erro e seus details (o que Failed/Await/MoveTo devolvem).
-- Sempre devolve uma string: código desconhecido ou details incompleto não geram erro.
function SmartPath.explain(reason: string?, details: { [string]: any }?): string
	return Diagnostics.explain(reason, details)
end

-- ===== Camada de compatibilidade =====
SmartPath.Service = Compat.Service

-- ===== Nível 1 — agente persistente =====

-- Um agente por personagem, para os níveis 0 e 1 (D-033): dois agentes no mesmo Humanoid brigariam
-- pelo Humanoid:Move. `SmartPath.new` recusa criar um segundo; `SmartPath.MoveTo` reaproveita o
-- que existir (inclusive um criado com `new`).
local agents: { [Humanoid]: Agent.Agent } = setmetatable({}, { __mode = "k" }) :: any
local watching: { [Humanoid]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function register(humanoid: Humanoid, agent: Agent.Agent)
	agents[humanoid] = agent
	if not watching[humanoid] then
		watching[humanoid] = true
		humanoid.Destroying:Connect(function()
			local current = agents[humanoid]
			agents[humanoid] = nil
			watching[humanoid] = nil
			if current then
				current:Destroy()
			end
		end)
	end
end

local function alive(agent: Agent.Agent?): boolean
	return agent ~= nil and not (agent :: any)._destroyed
end

local DUPLICATE_MESSAGE = "SmartPath.new: já existe um agente para este personagem. Use SmartPath.MoveTo (reaproveita "
	.. "o agente) ou chame :Destroy() no anterior antes de criar outro."

function SmartPath.new(characterOrHumanoid: Types.CharacterLike, options: Types.Options?): Agent.Agent
	local before = Util.resolveHumanoid(characterOrHumanoid)
	if before and alive(agents[before]) then
		error(DUPLICATE_MESSAGE, 2)
	end
	local agent = Agent.new(characterOrHumanoid, options)
	local humanoid = agent.Humanoid
	if alive(agents[humanoid]) then
		agent:Destroy() -- o personagem ainda carregava e outra chamada ganhou a corrida
		error(DUPLICATE_MESSAGE, 2)
	end
	register(humanoid, agent)
	return agent
end

-- ===== Nível 0 — uma linha =====

-- Nível 0: um agente por Humanoid, reaproveitado entre chamadas. MoveTo em laço não cria um agente (com
-- suas conexões) a cada chamada, e duas chamadas para o mesmo personagem se cancelam em vez de
-- brigar pelo Move (a antiga devolve false, "cancelled"). Chaves fracas; quando o Humanoid é
-- destruído o agente é destruído junto e a entrada some (o agente referencia o Humanoid, então
-- só a entrada explícita evita que o par se segure mutuamente). O registro é o de SmartPath.new.

local function agentFor(characterLike: Types.CharacterLike, options: Types.Options?): Agent.Agent
	local humanoid = Util.resolveHumanoid(characterLike)
	if not humanoid then
		error("SmartPath: o personagem precisa de um Humanoid", 3)
	end
	local existing = agents[humanoid]
	if existing and alive(existing) then
		if options then
			existing:SetOptions(options)
		end
		return existing
	end
	local created = Agent.new(humanoid, options)
	register(humanoid, created)
	return created
end

-- Move e só retorna quando terminar (bloqueante). target: Vector3 | BasePart | Model.
-- Retorna (true) ao chegar ou (false, motivo, details) — motivo é um código de SmartPath.Errors
-- e details o que SmartPath.explain espera (o terceiro valor não muda quem só lê ok, motivo).
function SmartPath.MoveTo(
	humanoid: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.Options?
): (boolean, string?, { [string]: any }?)
	local agent = agentFor(humanoid, options)
	agent:MoveTo(target)
	return agent:Await()
end

-- Versão não-bloqueante: devolve o agente já em movimento (use :Await(), os sinais, ou :Destroy()).
function SmartPath.MoveToAsync(
	humanoid: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.Options?
): Agent.Agent
	local agent = agentFor(humanoid, options)
	agent:MoveTo(target)
	return agent
end

-- Só calcula, não move. Devolve os waypoints melhorados ou (nil, motivo, details). Bloqueante.
function SmartPath.GetRoute(
	humanoid: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.Options?
): ({ Types.Waypoint }?, string?, { [string]: any }?)
	local resolved = Config.resolve(humanoid, options)
	local waypoints, reason, details = RouteSolver.solve(humanoid, target, resolved)
	if waypoints then
		return waypoints, nil, nil
	end
	return nil, reason, details
end

return SmartPath
end

return load("SmartPath")
