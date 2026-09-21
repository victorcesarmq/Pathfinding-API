--!strict
-- Geometry.luau
-- Filtro de geometria invisível colidível (Seção 5 da ESPEC_NAVEGACAO_ROBLOX.md, Fase 1
-- do plano de execução). Duas "vítimas" diferentes, dois remédios: PathfindingModifier
-- com PassThrough para a navmesh do PathfindingService, e RaycastParams filtrado para os
-- raycasts da própria SmartPath (predição, suavização, chão).
--
-- Singleton documentado (regra 2 da Seção 5 do plano): existe um por ambiente (cliente ou
-- servidor) — cada um requer sua própria cópia do módulo e mantém sua própria lista.
--
-- AutoFilter/RequireNameMatch são globais ao ambiente, não por agente: ver D-006 em
-- DECISIONS.md sobre por que isso é assim, mesmo a Options.Geometry (Seção 3.5) sendo
-- lida por agente em fases futuras.

local CollectionService = game:GetService("CollectionService")

local Geometry = {}

-- Constantes internas de classificação (Seção 5.1 da ESPEC). Não fazem parte da tabela de
-- Options pública porque afetam o mapa inteiro, não um agente específico.
local IGNORE_TAG = "NavIgnore"
local SOLID_TAG = "NavSolid"
local INVISIBLE_THRESHOLD = 0.95
local NAME_PATTERNS = { "zone", "trigger", "hitbox", "region", "bounds", "sensor", "detector", "area" }
local MODIFIER_NAME = "SmartPathAutoPassThrough"
local MODIFIER_LABEL = "SmartPathIgnored"

export type ClassifyReason = "tag" | "auto"

type Entry = {
	reason: ClassifyReason,
}

local ignored: { [BasePart]: Entry } = {}
local ignoredList: { BasePart } = {}
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

-- Classificação (ordem de precedência, Seção 5.1 da ESPEC):
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

local function refresh(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	local shouldIgnore, reason = classify(inst)
	if shouldIgnore and reason then
		mark(inst, reason)
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
	end
	descendantConn = workspace.DescendantAdded:Connect(function(d)
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

-- Desliga completamente e desfaz 100% do resíduo no mapa (regra 4 do plano + critério de
-- aceite da Fase 1: desligar não pode deixar efeito residual).
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

-- RaycastParams para os raycasts da própria SmartPath. `extra` = instâncias adicionais a
-- excluir (tipicamente o personagem do próprio agente e a pasta de debug).
function Geometry.buildRaycastParams(extra: { Instance }?): RaycastParams
	local list = table.clone(ignoredList) :: { Instance }
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
-- Nunca alteramos CanCollide sozinhos (regra 4 e D-005): quem decide é o desenvolvedor.
function Geometry.audit(): { BasePart }
	local suspects = {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if
			d:IsA("BasePart")
			and d.CanCollide
			and d.Transparency >= INVISIBLE_THRESHOLD
			and not ignored[d]
			and not hasTagInAncestry(d, SOLID_TAG)
		then
			table.insert(suspects, d)
		end
	end
	return suspects
end

return Geometry
