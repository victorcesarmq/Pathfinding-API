--!strict
-- SmartPathTests (init.luau)
-- Harness de verificação manual dos critérios de aceite de cada fase. NÃO faz parte da
-- biblioteca — não é requerido pelo SmartPath em nenhum momento, é ferramenta de
-- validação para você rodar no Command Bar durante o Play mode (Seção 8 do
-- SMARTPATH_PLANO_DE_EXECUCAO.md: "rode os critérios de aceite você mesmo, não aceite
-- 'testei e funciona' sem ver").
--
-- Uso (Command Bar, em Play mode, no servidor):
--   require(game.ServerStorage.SmartPathTests).Phase1()

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PathfindingService = game:GetService("PathfindingService")

local SmartPath = require(ReplicatedStorage.SmartPath)
local Scheduler = SmartPath.Scheduler
local Geometry = SmartPath.Geometry
local Config = require(ReplicatedStorage.SmartPath.Config)
local RouteSolver = require(ReplicatedStorage.SmartPath.RouteSolver)
local Simplifier = require(ReplicatedStorage.SmartPath.Simplifier)
local Predictor = require(ReplicatedStorage.SmartPath.Predictor)
local JumpExecutor = require(ReplicatedStorage.SmartPath.JumpExecutor)

local Tests = {}

local function report(name: string, ok: boolean, detail: string?): boolean
	print(
		string.format("[SmartPathTests] %s %s%s", ok and "PASS" or "FAIL", name, detail and (" — " .. detail) or "")
	)
	return ok
end

local function makePart(props: { [string]: any }): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = Vector3.new(4, 4, 4)
	p.Position = Vector3.new(0, 200, 0) -- alto, fora do caminho de qualquer coisa no place
	for k, v in pairs(props) do
		(p :: any)[k] = v
	end
	p.Parent = workspace
	return p
end

-- ===== Scheduler =====

local function testSchedulerBudget(): boolean
	Scheduler.setBudget(4)
	local startedCount = 0
	for i = 1, 50 do
		Scheduler.submit("budget-test-" .. i, 0, function()
			startedCount += 1
			return true
		end)
	end

	local maxStartedInOneFrame = 0
	for _ = 1, 20 do
		local before = startedCount
		RunService.Heartbeat:Wait()
		local delta = startedCount - before
		maxStartedInOneFrame = math.max(maxStartedInOneFrame, delta)
	end

	return report(
		"Scheduler: 50 pedidos não passam do orçamento por frame",
		maxStartedInOneFrame <= 4,
		"máximo observado por frame: " .. maxStartedInOneFrame .. ", processados: " .. startedCount
	)
end

local function testSchedulerCancel(): boolean
	local ran = false
	local h = Scheduler.submit("cancel-test", 0, function()
		ran = true
	end)
	h:cancel()
	for _ = 1, 10 do
		RunService.Heartbeat:Wait()
	end
	return report("Scheduler: pedido cancelado nunca executa", ran == false)
end

local function testSchedulerCoalescing(): boolean
	local callCount = 0
	local h1 = Scheduler.submit("coalesce-test", 0, function()
		callCount += 1
		return "resultado-unico"
	end)
	local h2 = Scheduler.submit("coalesce-test", 5, function()
		callCount += 1
		return "nao deveria rodar"
	end)

	local r1 = { h1:await() }
	local r2 = { h2:await() }

	local sameResult = r1[1] == "resultado-unico" and r2[1] == "resultado-unico"
	return report(
		"Scheduler: dois pedidos idênticos pendentes viram um só cálculo",
		callCount == 1 and sameResult,
		"callCount=" .. callCount
	)
end

-- ===== Geometry =====

local function testGeometryAutoDetect(): boolean
	Geometry.start()
	local part = makePart({ Name = "ZoneTrigger", Transparency = 1, CanCollide = true })
	task.wait() -- DescendantAdded é tratado com task.defer

	local hasModifier = part:FindFirstChildWhichIsA("PathfindingModifier") ~= nil
	part:Destroy()
	task.wait()

	return report("Geometry: invisível colidível com nome suspeito recebe PassThrough", hasModifier)
end

local function testGeometryNavSolidPrecedence(): boolean
	local part = makePart({ Name = "zone_wall_hitbox", Transparency = 1, CanCollide = true })
	CollectionService:AddTag(part, "NavSolid")
	task.wait()

	local hasModifier = part:FindFirstChildWhichIsA("PathfindingModifier") ~= nil
	part:Destroy()
	task.wait()

	return report("Geometry: tag NavSolid nunca recebe modifier, mesmo com nome suspeito", not hasModifier)
end

local function testGeometryAudit(): boolean
	local part = makePart({ Name = "UnclassifiedThing", Transparency = 1, CanCollide = true })
	task.wait()

	local suspects = Geometry.audit()
	local found = table.find(suspects, part) ~= nil
	part:Destroy()
	task.wait()

	return report("Geometry: audit() lista invisível colidível não classificada", found)
end

local function testGeometryVersionOnRemoval(): boolean
	local part = makePart({ Name = "ZoneRemovalTest", Transparency = 1, CanCollide = true })
	task.wait()
	local before = Geometry.getVersion()
	local countBefore = Geometry.getIgnoredCount()

	part:Destroy()
	task.wait()

	local after = Geometry.getVersion()
	local countAfter = Geometry.getIgnoredCount()

	return report(
		"Geometry: remover parte decrementa a lista e incrementa a versão",
		after > before and countAfter < countBefore,
		"version " .. before .. " -> " .. after .. ", count " .. countBefore .. " -> " .. countAfter
	)
end

local function testGeometryAutoFilterToggleNoResidue(): boolean
	local auto = makePart({ Name = "ZoneAutoToggle", Transparency = 1, CanCollide = true })
	local tagged = makePart({ Name = "TaggedIgnoreToggle", Transparency = 1, CanCollide = true })
	CollectionService:AddTag(tagged, "NavIgnore")
	task.wait()

	local autoMarkedBefore = auto:FindFirstChildWhichIsA("PathfindingModifier") ~= nil
	local taggedMarkedBefore = tagged:FindFirstChildWhichIsA("PathfindingModifier") ~= nil

	Geometry.setAutoFilter(false)
	task.wait()

	local autoMarkedAfter = auto:FindFirstChildWhichIsA("PathfindingModifier") ~= nil
	local taggedMarkedAfter = tagged:FindFirstChildWhichIsA("PathfindingModifier") ~= nil

	Geometry.setAutoFilter(true) -- devolve o estado global ao normal para o resto do place
	auto:Destroy()
	tagged:Destroy()
	task.wait()

	return report(
		"Geometry: desligar AutoFilter remove modifiers automáticos sem afetar tags explícitas",
		autoMarkedBefore and not autoMarkedAfter and taggedMarkedBefore and taggedMarkedAfter
	)
end

function Tests.Phase1(): boolean
	print("[SmartPathTests] ==== Fase 1: Scheduler + Geometry ====")
	local results = {
		testSchedulerBudget(),
		testSchedulerCancel(),
		testSchedulerCoalescing(),
		testGeometryAutoDetect(),
		testGeometryNavSolidPrecedence(),
		testGeometryAudit(),
		testGeometryVersionOnRemoval(),
		testGeometryAutoFilterToggleNoResidue(),
	}
	local allOk = true
	for _, ok in ipairs(results) do
		allOk = allOk and ok
	end
	print("[SmartPathTests] ==== Resultado: " .. (allOk and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return allOk
end

-- ===================== Fase 2: RouteSolver / RouteCache / Simplifier =====================
-- Cada cenário monta sua própria geometria numa área isolada (longe do Baseplate), cria um
-- rig mínimo (root + Humanoid) e destrói tudo no fim.
-- Uso: require(game.ServerStorage.SmartPathTests).Phase2()

local AREA_NAME = "SmartPathTestArea"
local TEST_ORIGIN = Vector3.new(2000, 0, 0)
local NAVMESH_SETTLE = 2 -- a navmesh leva um instante para incluir a geometria recém-criada

local function info(name: string, detail: string)
	print(string.format("[SmartPathTests] INFO %s — %s", name, detail))
end

local function cleanupArea()
	local old = workspace:FindFirstChild(AREA_NAME)
	if old then
		old:Destroy()
	end
end

local function newArea(): Folder
	cleanupArea()
	local f = Instance.new("Folder")
	f.Name = AREA_NAME
	f.Parent = workspace
	return f
end

local function addBlock(area: Folder, name: string, relCenter: Vector3, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = TEST_ORIGIN + relCenter
	p.Material = Enum.Material.Concrete
	p.Parent = area
	return p
end

-- piso com o topo em y = 0 (relativo à origem)
local function addFloor(area: Folder, name: string, cx: number, cz: number, sx: number, sz: number): Part
	return addBlock(area, name, Vector3.new(cx, -0.5, cz), Vector3.new(sx, 1, sz))
end

-- Duas salas ligadas por um único corredor de largura `width` (eixo X). Os blocos vão além
-- da borda do piso (z = ±30), então o corredor é o único caminho.
local function buildCorridor(area: Folder, width: number): (Vector3, Vector3)
	addFloor(area, "Floor", 0, 0, 100, 60)
	addBlock(area, "CorridorNorth", Vector3.new(0, 5, width / 2 + 15), Vector3.new(40, 10, 30))
	addBlock(area, "CorridorSouth", Vector3.new(0, 5, -(width / 2 + 15)), Vector3.new(40, 10, 30))
	-- ±34.7 e não ±35: 35 cai exatamente na borda de uma célula de 2 studs do cache, e um
	-- desvio de 0.001 do rig trocava de célula (era o "18/19 cache hits")
	return TEST_ORIGIN + Vector3.new(-34.7, 0, 0), TEST_ORIGIN + Vector3.new(34.7, 0, 0)
end

-- Rig mínimo: HumanoidRootPart 2x2x1 + Humanoid R15 (sem membros), solto no chão.
local function makeRig(area: Folder, groundPos: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "SmartPathTestRig"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Position = groundPos + Vector3.new(0, 3.2, 0)
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = 2
	humanoid.RequiresNeck = false
	root.Parent = model
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = area
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	local t0 = os.clock()
	while humanoid.FloorMaterial == Enum.Material.Air and os.clock() - t0 < 3 do
		task.wait()
	end
	return model
end

-- raio 2 / altura 5: os valores do critério de aceite ("agente de raio 2")
local function resolveFor(rig: Model, extra: { [string]: any }?)
	local overrides: { [string]: any } = { Agent = { Radius = 2, Height = 5 } }
	if extra then
		for k, v in pairs(extra) do
			overrides[k] = v
		end
	end
	return Config.resolve(rig, overrides :: any)
end

local function describe(details: { [string]: any }?): string
	if not details then
		return ""
	end
	local parts = {}
	for k, v in pairs(details) do
		if k ~= "path" then
			local text: string
			if typeof(v) == "table" then
				local items = {}
				for _, x in ipairs(v) do
					table.insert(items, tostring(x))
				end
				text = "{" .. table.concat(items, ",") .. "}"
			else
				text = tostring(v)
			end
			table.insert(parts, k .. "=" .. text)
		end
	end
	table.sort(parts)
	return table.concat(parts, " ")
end

local function routeKey(wps: { any }): string
	local parts = {}
	for _, wp in ipairs(wps) do
		table.insert(
			parts,
			string.format("%.2f,%.2f,%.2f,%s", wp.Position.X, wp.Position.Y, wp.Position.Z, wp.Action.Name)
		)
	end
	return table.concat(parts, ";")
end

local function baselineStatus(start: Vector3, goal: Vector3): string
	local ok, status = pcall(function()
		local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
		path:ComputeAsync(start + Vector3.new(0, 1, 0), goal)
		return path.Status
	end)
	return ok and tostring(status) or ("erro: " .. tostring(status))
end

-- Roda o solver num corredor de `width` studs com agente de raio 2. Devolve o resultado do
-- solver e o status do PathfindingService puro (para comparar).
local function runCorridor(width: number)
	local area = newArea()
	local start, goal = buildCorridor(area, width)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local baseline = baselineStatus(start, goal)
	local wps, reason, details = RouteSolver.solve(rig, goal, resolveFor(rig))
	return wps, reason, details, baseline, start, goal
end

local function describeResult(wps: { any }?, reason: string?, details: { [string]: any }?, baseline: string): string
	local text = "PathfindingService puro: " .. baseline .. ", SmartPath: "
	if wps then
		return text .. string.format("%d waypoints, %s", #wps, describe(details))
	end
	return text .. tostring(reason) .. " " .. describe(details)
end

-- A engine é mais tolerante que o plano supunha: com raio 2 ela já atravessa 4 studs.
-- Por isso testamos 4 e 3 (onde a engine falha de fato, o cenário discrimina).
local function testCorridorPasses(width: number): boolean
	local wps, reason, details, baseline, start, goal = runCorridor(width)
	local ok = wps ~= nil and (wps[1].Position - start).Magnitude < 3 and (wps[#wps].Position - goal).Magnitude < 3
	local detail = describeResult(wps, reason, details, baseline)
	if baseline == "Enum.PathStatus.Success" then
		detail ..= " (AVISO: a engine achou rota sozinha, o cenário não discrimina)"
	end
	return report(string.format("Rota: corredor de %d studs com agente de raio 2", width), ok, detail)
end

-- Vão que o corpo (raio físico 1.2) não atravessa: rota falsa é o pior resultado possível.
local function testCorridorTooNarrow(width: number, requireDiagnosis: boolean): boolean
	local wps, reason, details, baseline = runCorridor(width)
	local noFalseRoute = wps == nil
	local diagnosed = reason == "corridor_too_narrow" and details ~= nil and typeof(details.requiredRadius) == "number"
	local detail = describeResult(wps, reason, details, baseline)
	if noFalseRoute and reason == "no_path" then
		detail ..= " (a engine não achou rota em nenhum degrau, nem no de sonda; ver D-010)"
	end
	local name = string.format(
		"Rota: corredor de %s studs %s",
		tostring(width),
		requireDiagnosis and "devolve corridor_too_narrow e nenhuma rota falsa" or "não devolve rota falsa"
	)
	return report(name, noFalseRoute and (diagnosed or not requireDiagnosis), detail)
end

local function testDeterminism(): boolean
	local area = newArea()
	local start, goal = buildCorridor(area, 4)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local options = resolveFor(rig)

	local firstKey: string? = nil
	local identical = true
	local cachedHits = 0
	for _ = 1, 20 do
		local wps, _, details = RouteSolver.solve(rig, goal, options)
		if not wps then
			return report("Rota: 20 chamadas iguais dão waypoints idênticos", false, "solve devolveu nil")
		end
		if details and details.cached then
			cachedHits += 1
		end
		local key = routeKey(wps)
		if firstKey == nil then
			firstKey = key
		elseif key ~= firstKey then
			identical = false
		end
	end

	-- informativo: sem cache, a engine sozinha é estável para entradas idênticas?
	local noCache = resolveFor(rig, { Stability = { Cache = false, Smoothing = true, Hysteresis = 0.15 } })
	local stableWithoutCache = true
	for _ = 1, 5 do
		local wps = RouteSolver.solve(rig, goal, noCache)
		if not wps or routeKey(wps) ~= firstKey then
			stableWithoutCache = false
		end
	end
	info(
		"Rota: sem cache, 5 chamadas iguais",
		stableWithoutCache and "idênticas" or "DIFERENTES (o cache é o que garante o determinismo)"
	)

	return report(
		"Rota: 20 chamadas iguais dão waypoints idênticos",
		identical,
		"cache hits: " .. cachedHits .. "/19"
	)
end

local function testNoCutOverHole(): boolean
	local area = newArea()
	-- vão de 20 studs: largo demais até para a engine pular (com 4 studs ela atravessou o
	-- vão em linha reta com um salto, o que invalidava o teste)
	addFloor(area, "FloorA", -25, 0, 30, 60)
	addFloor(area, "FloorB", 25, 0, 30, 60)
	addFloor(area, "Bridge", 0, 25, 20, 10) -- única ligação entre os pisos, longe da linha reta
	local start = TEST_ORIGIN + Vector3.new(-30, 0, -20)
	local goal = TEST_ORIGIN + Vector3.new(30, 0, -20)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)

	local wps, reason, details = RouteSolver.solve(rig, goal, resolveFor(rig))
	if not wps then
		return report(
			"Simplifier: string pulling nunca corta por cima de um vão",
			false,
			"sem rota: " .. tostring(reason) .. " " .. describe(details)
		)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rig }
	local gapAt: string? = nil
	local actions = {}
	for _, w in ipairs(wps) do
		table.insert(actions, w.Action.Name)
	end
	for i = 1, #wps - 1 do
		local a, b = wps[i].Position, wps[i + 1].Position
		local steps = math.max(1, math.ceil((b - a).Magnitude))
		-- segmento que parte de um Jump/Custom é voo, não caminhada: chão contínuo não se aplica
		for s = 0, wps[i].Action == Enum.PathWaypointAction.Walk and steps or -1 do
			local p = a:Lerp(b, s / steps)
			if not workspace:Raycast(p + Vector3.new(0, 3, 0), Vector3.new(0, -8, 0), params) then
				gapAt = string.format(
					"segmento %d->%d, ponto (%.1f, %.1f)",
					i,
					i + 1,
					p.X - TEST_ORIGIN.X,
					p.Z - TEST_ORIGIN.Z
				)
				break
			end
		end
		if gapAt then
			break
		end
	end

	local crossesBridge = false
	for i = 1, #wps - 1 do
		local ax, bx = wps[i].Position.X - TEST_ORIGIN.X, wps[i + 1].Position.X - TEST_ORIGIN.X
		if ax ~= bx and ax * bx <= 0 then
			local t = -ax / (bx - ax)
			local z = wps[i].Position.Z + t * (wps[i + 1].Position.Z - wps[i].Position.Z) - TEST_ORIGIN.Z
			if z >= 19 then
				crossesBridge = true
			end
		end
	end

	return report(
		"Simplifier: string pulling nunca corta por cima de um vão",
		gapAt == nil and crossesBridge,
		(gapAt and ("vão cortado em " .. gapAt) or "chão contínuo em todos os segmentos")
			.. ", atravessa pela ponte: "
			.. tostring(crossesBridge)
			.. ", "
			.. #wps
			.. " waypoints ("
			.. table.concat(actions, ",")
			.. ")"
	)
end

local function testSimplifierKeepsActions(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 100, 40)

	local function wp(x: number, action: Enum.PathWaypointAction)
		return table.freeze({
			Position = TEST_ORIGIN + Vector3.new(x, 0, 0),
			Action = action,
			Label = "",
			SmartAction = "Walk",
		})
	end
	local W, J, C = Enum.PathWaypointAction.Walk, Enum.PathWaypointAction.Jump, Enum.PathWaypointAction.Custom
	local input = { wp(-30, W), wp(-20, W), wp(-10, W), wp(0, J), wp(10, W), wp(20, C), wp(30, W) }

	local ctx = Simplifier.buildContext(RaycastParams.new(), 2)
	local out = Simplifier.simplify(input :: any, ctx)

	local jumpKept, customKept = false, false
	for _, w in ipairs(out) do
		if w.Action == J then
			jumpKept = true
		elseif w.Action == C then
			customKept = true
		end
	end
	local walkRemoved = #input - #out
	return report(
		"Simplifier: waypoints com Action ≠ Walk nunca são removidos",
		jumpKept and customKept and walkRemoved >= 2,
		"entrada "
			.. #input
			.. " -> saída "
			.. #out
			.. ", Jump mantido: "
			.. tostring(jumpKept)
			.. ", Custom mantido: "
			.. tostring(customKept)
	)
end

local function testGoalInsideWall(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 100, 100)
	addBlock(area, "Wall", Vector3.new(0, 5, 0), Vector3.new(10, 10, 10)) -- x,z em [-5,5], y em [0,10]
	local start = TEST_ORIGIN + Vector3.new(-30, 0, 0)
	local goalInWall = TEST_ORIGIN + Vector3.new(0, 5, 0)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local options = resolveFor(rig)

	local wps, reason, details = RouteSolver.solve(rig, goalInWall, options)
	local nearest = details and details.nearestValid
	local flagged = wps == nil and reason == "goal_unreachable" and typeof(nearest) == "Vector3"
	if not flagged then
		return report(
			"Destino dentro de uma parede: goal_unreachable com nearestValid utilizável",
			false,
			"obtido: " .. tostring(reason) .. " " .. describe(details)
		)
	end

	local rel = (nearest :: Vector3) - TEST_ORIGIN
	local outside = math.max(math.abs(rel.X), math.abs(rel.Z)) > 5
	local usable = false
	if outside then
		local route = RouteSolver.solve(rig, nearest :: Vector3, options)
		usable = route ~= nil
	end
	return report(
		"Destino dentro de uma parede: goal_unreachable com nearestValid utilizável",
		outside and usable,
		string.format(
			"nearestValid a (%.1f, %.1f, %.1f) da origem, fora da parede: %s, rota até ele: %s",
			rel.X,
			rel.Y,
			rel.Z,
			tostring(outside),
			tostring(usable)
		)
	)
end

local function safe(name: string, fn: () -> boolean): boolean
	RouteSolver.getSharedCache():clear() -- o cache não conhece a geometria dos cenários anteriores
	local ok, res = pcall(fn)
	cleanupArea()
	if not ok then
		return report(name, false, "erro inesperado: " .. tostring(res))
	end
	return res
end

-- A engine (tolerante) devolve a reta que passa a menos de um raio de corpo da quina de um pilar. O
-- reparo insere um desvio: a rota tem de existir e passar pela validação de volume (D-031).
local function testGrazingCorner(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 60)
	addBlock(area, "Pillar", Vector3.new(0, 4, 0), Vector3.new(4, 8, 4)) -- x e z em [-2, 2]
	local start = TEST_ORIGIN + Vector3.new(-40, 0, -4)
	local goal = TEST_ORIGIN + Vector3.new(40, 0, 9.4) -- a reta passa a ~0.4 da quina (-2, 2)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local options = resolveFor(rig)
	local wps, reason, details = RouteSolver.solve(rig, goal, options)
	local clear = false
	if wps then
		clear = RouteSolver.isRouteClear(rig, wps, options, 1, nil)
	end
	return report(
		"Rota: reta que roça a quina de um pilar é reparada e cabe",
		wps ~= nil and clear,
		string.format(
			"%s, %d waypoints, validação de volume: %s, %s",
			wps and "rota" or tostring(reason),
			wps and #wps or 0,
			tostring(clear),
			describe(details)
		)
	)
end

function Tests.Phase2(): boolean
	print("[SmartPathTests] ==== Fase 2: RouteSolver + RouteCache + Simplifier ====")
	local results = {
		safe("corredor de 4 studs", function()
			return testCorridorPasses(4)
		end),
		safe("corredor de 3 studs", function()
			return testCorridorPasses(3)
		end),
		safe("corredor de 2 studs", function()
			return testCorridorTooNarrow(2, true)
		end),
		safe("corredor de 1 stud", function()
			return testCorridorTooNarrow(1, false)
		end),
		safe("determinismo", testDeterminism),
		safe("vão no chão", testNoCutOverHole),
		safe("ações do Simplifier", testSimplifierKeepsActions),
		safe("destino dentro da parede", testGoalInsideWall),
		safe("quina de pilar", testGrazingCorner),
	}
	local allOk = true
	for _, ok in ipairs(results) do
		allOk = allOk and ok
	end
	print("[SmartPathTests] ==== Resultado: " .. (allOk and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return allOk
end

-- ===================== Fase 3: Predictor / JumpExecutor =====================
-- Uso: require(game.ServerStorage.SmartPathTests).Phase3()

local function humanoidOf(rig: Model): Humanoid
	return rig:FindFirstChildOfClass("Humanoid") :: Humanoid
end

-- Cena de salto no eixo X: o agente em x = -7, o obstáculo com a face em x = 0 e
-- `depth` studs de profundidade, o alvo do outro lado. `abyss` tira o chão de trás do
-- obstáculo; `ceiling` põe uma laje sobre ele.
local function buildJumpScene(area: Folder, height: number, depth: number, abyss: boolean?, ceiling: boolean?)
	addFloor(area, "FloorFront", -20, 0, 40, 60)
	if not abyss then
		addFloor(area, "FloorBack", depth + 20, 0, 40, 60)
	end
	addBlock(area, "Obstacle", Vector3.new(depth / 2, height / 2, 0), Vector3.new(depth, height, 20))
	if ceiling then
		-- laje de 1 stud com a face de baixo em 6.5: sobre uma mureta de 3 sobra espaço para o
		-- corpo em pé, mas não para o apex do salto
		addBlock(area, "Ceiling", Vector3.new(depth / 2 + 3, 7, 0), Vector3.new(depth + 12, 1, 20))
	end
	return TEST_ORIGIN + Vector3.new(-7, 0, 0), TEST_ORIGIN + Vector3.new(depth + 6, 0, 0)
end

local function analyzeScene(rig: Model, target: Vector3, walkSpeed: number?)
	local humanoid = humanoidOf(rig)
	local exclude: { Instance } = { rig }
	return Predictor.analyze({
		root = rig.PrimaryPart :: BasePart,
		humanoid = humanoid,
		targetPos = target,
		params = Geometry.buildRaycastParams(exclude),
		agentRadius = 2,
		agentHeight = 5,
		walkSpeed = walkSpeed,
	})
end

local function describePlan(plan: any): string
	return string.format(
		"altura %.2f, profundidade %s, plataforma %s, apex %.2f, decola a %.2f da face, pousa a (%.1f, %.1f)",
		plan.obstacleHeight,
		plan.obstacleDepth and string.format("%.1f", plan.obstacleDepth) or "-",
		tostring(plan.isPlatform),
		plan.jumpHeight,
		plan.takeoffDistance,
		plan.landingPoint.X - TEST_ORIGIN.X,
		plan.landingPoint.Y
	)
end

-- Monta a cena, roda o Predictor e devolve (plano, motivo, rig).
local function runPredictor(height: number, depth: number, jumpHeight: number, abyss: boolean?, ceiling: boolean?)
	local area = newArea()
	local start, target = buildJumpScene(area, height, depth, abyss, ceiling)
	task.wait(NAVMESH_SETTLE / 2)
	local rig = makeRig(area, start)
	local humanoid = humanoidOf(rig)
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = jumpHeight
	local plan, reason = analyzeScene(rig, target)
	return plan, reason
end

local function testPredictorValid(height: number, depth: number, name: string): boolean
	local plan, reason = runPredictor(height, depth, 7.2)
	return report(name, plan ~= nil, plan and describePlan(plan) or ("motivo: " .. reason))
end

local function testPredictorRejects(
	height: number,
	depth: number,
	expected: { string },
	name: string,
	abyss: boolean?,
	ceiling: boolean?
): boolean
	local plan, reason = runPredictor(height, depth, 7.2, abyss, ceiling)
	return report(
		name,
		plan == nil and table.find(expected, reason) ~= nil,
		"motivo: " .. reason .. (plan and (" (plano: " .. describePlan(plan) .. ")") or "")
	)
end

-- O cenário-vitrine: com JumpHeight 30, a lib salta um obstáculo que o PathfindingService puro
-- jamais subiria (o limite interno da malha ignora o JumpHeight do Humanoid).
local function testPredictorHighJump(): boolean
	local plan, reason = runPredictor(20, 12, 30)
	return report(
		"Predictor: JumpHeight 30 salta um obstáculo de 20 studs",
		plan ~= nil and plan.isPlatform and plan.jumpHeight >= 20.5,
		plan and describePlan(plan) or ("motivo: " .. reason)
	)
end

-- ===== JumpExecutor =====

local function makeGroundedRig(): (Model, Humanoid, Folder)
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 100, 60)
	local rig = makeRig(area, TEST_ORIGIN)
	return rig, humanoidOf(rig), area
end

local function testNativeRestore(useJumpPower: boolean): boolean
	local rig, humanoid = makeGroundedRig()
	local root = rig.PrimaryPart :: BasePart
	local original: number
	if useJumpPower then
		humanoid.UseJumpPower = true
		humanoid.JumpPower = 50
		original = 50
	else
		humanoid.UseJumpPower = false
		humanoid.JumpHeight = 7.2
		original = humanoid.JumpHeight -- lido de volta: o Roblox guarda float32 (7.2 vira 7.19999981)
	end
	local function current(): number
		return if useJumpPower then humanoid.JumpPower else humanoid.JumpHeight
	end

	local ok, why = JumpExecutor.execute("Native", humanoid, root, 4, Vector3.xAxis)
	if not ok then
		return report(
			"JumpExecutor: Native restaura o valor original",
			false,
			"execute recusou: " .. tostring(why) .. ", estado " .. humanoid:GetState().Name
		)
	end
	local changed = current() ~= original
	local t0 = os.clock()
	while JumpExecutor.isRestorePending(humanoid) and os.clock() - t0 < 2 do
		task.wait()
	end
	return report(
		"JumpExecutor: Native restaura exatamente o " .. (useJumpPower and "JumpPower" or "JumpHeight"),
		changed and current() == original and not JumpExecutor.isRestorePending(humanoid),
		string.format(
			"alterou durante o salto: %s, valor depois: %s (original %s), restaurou em %.2fs",
			tostring(changed),
			tostring(current()),
			tostring(original),
			os.clock() - t0
		)
	)
end

local function testNativeRestoreOnDeath(): boolean
	local rig, humanoid = makeGroundedRig()
	local root = rig.PrimaryPart :: BasePart
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = 7.2
	local original = humanoid.JumpHeight -- float32: 7.2 vira 7.19999981
	local ok, why = JumpExecutor.execute("Native", humanoid, root, 4, Vector3.xAxis)
	if not ok then
		return report(
			"JumpExecutor: Native restaura se o personagem morre no ar",
			false,
			"execute recusou: " .. tostring(why)
		)
	end
	local changed = humanoid.JumpHeight ~= original
	humanoid.Health = 0
	task.wait()
	return report(
		"JumpExecutor: Native restaura se o personagem morre no ar",
		changed and humanoid.JumpHeight == original and not JumpExecutor.isRestorePending(humanoid),
		"JumpHeight depois da morte: " .. tostring(humanoid.JumpHeight)
	)
end

local function testNativeRestoreOnRemoval(): boolean
	local rig, humanoid = makeGroundedRig()
	local root = rig.PrimaryPart :: BasePart
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = 7.2
	local original = humanoid.JumpHeight
	local ok, why = JumpExecutor.execute("Native", humanoid, root, 4, Vector3.xAxis)
	if not ok then
		return report(
			"JumpExecutor: Native restaura se o personagem é removido",
			false,
			"execute recusou: " .. tostring(why)
		)
	end
	local changed = humanoid.JumpHeight ~= original
	rig:Destroy()
	task.wait()
	return report(
		"JumpExecutor: Native restaura se o personagem é removido",
		changed and humanoid.JumpHeight == original and not JumpExecutor.isRestorePending(humanoid),
		"JumpHeight depois do Destroy: " .. tostring(humanoid.JumpHeight)
	)
end

-- Dois saltos encadeados (o segundo antes do primeiro restaurar): o segundo não pode
-- capturar como "original" o valor que o primeiro deixou.
local function testNativeChained(): boolean
	local _, humanoid = makeGroundedRig()
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = 7.2
	local original = humanoid.JumpHeight
	JumpExecutor.jumpNative(humanoid, 3)
	JumpExecutor.jumpNative(humanoid, 5)
	local during = humanoid.JumpHeight
	local t0 = os.clock()
	while JumpExecutor.isRestorePending(humanoid) and os.clock() - t0 < 2.5 do
		task.wait()
	end
	return report(
		"JumpExecutor: dois saltos Native encadeados restauram o original",
		during == 5 and humanoid.JumpHeight == original and not JumpExecutor.isRestorePending(humanoid),
		"durante o segundo salto: " .. tostring(during) .. ", no fim: " .. tostring(humanoid.JumpHeight)
	)
end

local function testInjectedNeverReduces(): boolean
	local cases = {
		{ cur = Vector3.new(40, 0, 0), name = "dash de 40 na direção do salto" },
		{ cur = Vector3.new(5, 0, 0), name = "parado quase" },
		{ cur = Vector3.new(-30, 0, 0), name = "indo de costas rápido" },
		{ cur = Vector3.new(3, 0, 10), name = "dash lateral" },
		{ cur = Vector3.new(0, -20, 0), name = "só caindo" },
	}
	local allOk = true
	local details = {}
	for _, c in ipairs(cases) do
		local out = JumpExecutor.injectedVelocity(c.cur, Vector3.xAxis, 16, 25)
		local before = Vector3.new(c.cur.X, 0, c.cur.Z).Magnitude
		local after = Vector3.new(out.X, 0, out.Z).Magnitude
		local ok = after >= before - 1e-6 and out.Y == 25
		allOk = allOk and ok
		table.insert(details, string.format("%s: %.1f -> %.1f", c.name, before, after))
	end
	return report("JumpExecutor: Injected nunca reduz a velocidade horizontal", allOk, table.concat(details, "; "))
end

local function testInjectedLeavesJumpProperties(): boolean
	local rig, humanoid = makeGroundedRig()
	local root = rig.PrimaryPart :: BasePart
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = 7.2
	local original = humanoid.JumpHeight
	local ok, why = JumpExecutor.execute("Injected", humanoid, root, 4, Vector3.xAxis)
	if not ok then
		return report("JumpExecutor: Injected não altera JumpHeight", false, "execute recusou: " .. tostring(why))
	end
	task.wait(0.3)
	return report(
		"JumpExecutor: Injected não altera JumpHeight",
		humanoid.JumpHeight == original and not JumpExecutor.isRestorePending(humanoid),
		"JumpHeight: " .. tostring(humanoid.JumpHeight)
	)
end

function Tests.Phase3(): boolean
	print("[SmartPathTests] ==== Fase 3: Predictor + JumpExecutor ====")
	local results = {
		safe("mureta 3", function()
			return testPredictorValid(3, 2, "Predictor: mureta de 3 studs com JumpHeight 7.2 dá plano válido")
		end),
		safe("mureta 3 rasa", function()
			return testPredictorValid(3, 1.5, "Predictor: mureta de 3 studs e 1.5 de profundidade dá plano válido")
		end),
		safe("mureta 9", function()
			return testPredictorRejects(9, 2, { "too_tall" }, "Predictor: mureta de 9 studs devolve too_tall")
		end),
		safe("profunda", function()
			return testPredictorRejects(
				3,
				6,
				{ "too_deep" },
				"Predictor: mureta de 3 studs e 6 de profundidade devolve too_deep"
			)
		end),
		safe("abismo", function()
			return testPredictorRejects(
				3,
				2,
				{ "no_landing" },
				"Predictor: abismo atrás da mureta devolve no_landing",
				true
			)
		end),
		safe("teto", function()
			return testPredictorRejects(
				3,
				2,
				{ "ceiling", "air_blocked" },
				"Predictor: teto baixo sobre a mureta devolve ceiling/air_blocked",
				false,
				true
			)
		end),
		safe("salto alto", testPredictorHighJump),
		safe("native jumpheight", function()
			return testNativeRestore(false)
		end),
		safe("native jumppower", function()
			return testNativeRestore(true)
		end),
		safe("morte", testNativeRestoreOnDeath),
		safe("remoção", testNativeRestoreOnRemoval),
		safe("encadeado", testNativeChained),
		safe("injected puro", testInjectedNeverReduces),
		safe("injected props", testInjectedLeavesJumpProperties),
	}
	local allOk = true
	for _, ok in ipairs(results) do
		allOk = allOk and ok
	end
	print("[SmartPathTests] ==== Resultado: " .. (allOk and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return allOk
end

-- ===================== Fase 4: Agent =====================
-- Uso: require(game.ServerStorage.SmartPathTests).Phase4()
-- Cada cenário monta a geometria, cria rigs com Humanoid e agentes de verdade (SmartPath.new) e
-- observa o comportamento pelos sinais e pela posição do rig. Leva alguns minutos.

local function waitUntil(cond: () -> boolean, timeout: number, onTick: (() -> ())?): boolean
	local t0 = os.clock()
	while not cond() do
		if os.clock() - t0 > timeout then
			return false
		end
		if onTick then
			onTick()
		end
		task.wait()
	end
	return true
end

local function newAgent(rig: Model, extra: { [string]: any }?): any
	local options: { [string]: any } = { Agent = { Radius = 2, Height = 5 } }
	if extra then
		for k, v in pairs(extra) do
			options[k] = v
		end
	end
	return SmartPath.new(rig, options :: any)
end

-- contadores dos sinais do agente (as conexões morrem junto com agent:Destroy())
local function watch(agent: any)
	local st = {
		reached = 0,
		failed = 0,
		reason = nil :: string?,
		details = nil :: any,
		jumps = 0,
		blocked = 0,
		firstBlocked = nil :: number?,
	}
	agent.Reached:Connect(function()
		st.reached += 1
	end)
	agent.Failed:Connect(function(reason: string, details: any)
		st.failed += 1
		st.reason, st.details = reason, details
	end)
	agent.Jumped:Connect(function()
		st.jumps += 1
	end)
	agent.Blocked:Connect(function()
		st.blocked += 1
		st.firstBlocked = st.firstBlocked or os.clock()
	end)
	return st
end

local function rootOf(rig: Model): BasePart
	return rig.PrimaryPart :: BasePart
end

local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function describeStatus(st: any, extra: string?): string
	return string.format(
		"chegadas %d, falhas %d (%s%s), saltos %d, Blocked %d%s",
		st.reached,
		st.failed,
		tostring(st.reason),
		st.details and (" " .. describe(st.details)) or "",
		st.jumps,
		st.blocked,
		extra and (", " .. extra) or ""
	)
end

-- Percurso completo: corredor de 4 studs, mureta (com passagem pelo lado) e rampa até uma plataforma.
-- Percurso reutilizado pelos testes do Agent e da camada de compatibilidade. Devolve (início,
-- destino).
local function buildCourse(area: Folder): (Vector3, Vector3)
	addFloor(area, "Floor", 25, 0, 130, 40)
	addBlock(area, "WallN", Vector3.new(25, 6, 21), Vector3.new(132, 12, 2))
	addBlock(area, "WallS", Vector3.new(25, 6, -21), Vector3.new(132, 12, 2))
	addBlock(area, "WallW", Vector3.new(-41, 6, 0), Vector3.new(2, 12, 44))
	addBlock(area, "WallE", Vector3.new(91, 6, 0), Vector3.new(2, 12, 44))
	addBlock(area, "CorridorN", Vector3.new(0, 6, 11), Vector3.new(20, 12, 18))
	addBlock(area, "CorridorS", Vector3.new(0, 6, -11), Vector3.new(20, 12, 18))
	addBlock(area, "Mureta", Vector3.new(25, 1.5, -3), Vector3.new(2, 3, 34))
	local rise, run = 4, 20
	local theta = math.atan2(rise, run)
	local ramp = addBlock(area, "Ramp", Vector3.zero, Vector3.new(math.sqrt(run * run + rise * rise), 1, 40))
	ramp.CFrame = CFrame.new(TEST_ORIGIN + Vector3.new(50 + 0.5 * math.sin(theta), 2 - 0.5 * math.cos(theta), 0))
		* CFrame.Angles(0, 0, theta)
	addBlock(area, "Platform", Vector3.new(75, 2, 0), Vector3.new(30, 4, 40))
	return TEST_ORIGIN + Vector3.new(-30, 0, 0), TEST_ORIGIN + Vector3.new(75, 4, 0)
end

local function testAgentCourse(): boolean
	local area = newArea()
	local start, goal = buildCourse(area)
	task.wait(NAVMESH_SETTLE)

	local rig = makeRig(area, start)
	local agent = newAgent(rig)
	local st = watch(agent)
	local t0 = os.clock()
	agent:MoveTo(goal)
	local done = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 60)
	local dist = flatDist(rootOf(rig).Position, goal)
	agent:Destroy()
	return report(
		"Agent: percurso com corredor, mureta e rampa sem intervenção",
		done and st.reached == 1 and dist < 3,
		describeStatus(st, string.format("%.1fs, a %.1f do destino", os.clock() - t0, dist))
	)
end

-- Mureta de 3 studs de ponta a ponta, sem passagem: a única saída é saltar.
local function testAgentJumpsMureta(): boolean
	local area = newArea()
	addFloor(area, "Floor", 5, 0, 70, 40)
	addBlock(area, "Mureta", Vector3.new(1, 1.5, 0), Vector3.new(2, 3, 80))
	task.wait(NAVMESH_SETTLE)

	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-6, 0, 0))
	local goal = TEST_ORIGIN + Vector3.new(14, 0, 0)
	local agent = newAgent(rig)
	local st = watch(agent)
	agent:MoveTo(goal)
	local done = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 30)
	local dist = flatDist(rootOf(rig).Position, goal)
	agent:Destroy()
	return report(
		"Agent: salta a mureta e chega ao destino",
		done and st.reached == 1 and st.jumps >= 1 and dist < 3,
		describeStatus(st, string.format("a %.1f do destino", dist))
	)
end

local function testAgentDestinationChange(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 80)
	task.wait(NAVMESH_SETTLE)

	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-30, 0, 0))
	local goalA = TEST_ORIGIN + Vector3.new(30, 0, -25)
	local goalB = TEST_ORIGIN + Vector3.new(30, 0, 25)
	local agent = newAgent(rig)
	local st = watch(agent)

	local firstOk: boolean? = nil
	local firstReason: string? = nil
	agent:MoveTo(goalA)
	task.spawn(function()
		firstOk, firstReason = agent:Await()
	end)
	task.wait() -- o cálculo do destino A está em voo
	agent:MoveTo(goalB)

	local minDistToA = math.huge
	local done = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 40, function()
		minDistToA = math.min(minDistToA, flatDist(rootOf(rig).Position, goalA))
	end)
	local dist = flatDist(rootOf(rig).Position, goalB)
	agent:Destroy()
	return report(
		"Agent: destino trocado no meio do cálculo usa o novo, sem rota fantasma",
		done and st.reached == 1 and dist < 3 and minDistToA > 10 and firstOk == false and firstReason == "cancelled",
		describeStatus(
			st,
			string.format("a %.1f de B, mais perto de A: %.1f, Await do 1º MoveTo: %s/%s", dist, minDistToA, tostring(firstOk), tostring(firstReason))
		)
	)
end

local function testAgentBlocked(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 200, 50)
	task.wait(NAVMESH_SETTLE)

	-- longe e devagar: a malha do PathfindingService leva alguns segundos para incluir a parede
	-- nova, então o agente precisa demorar a chegar nela para o evento Blocked ter tempo de
	-- disparar antes do anti-stuck (a versão anterior deu ~1.5s de margem e o agente desistiu).
	local start = TEST_ORIGIN + Vector3.new(-60, 0, 0)
	local goal = TEST_ORIGIN + Vector3.new(60, 0, 0)
	local rig = makeRig(area, start)
	humanoidOf(rig).WalkSpeed = 10
	local agent = newAgent(rig)
	local st = watch(agent)
	agent:MoveTo(goal)

	-- quando o agente já está a caminho, uma parede cai sobre a rota
	waitUntil(function()
		return rootOf(rig).Position.X > start.X + 8
	end, 20)
	local dropTime = os.clock()
	addBlock(area, "DroppedWall", Vector3.new(0, 5, 0), Vector3.new(2, 10, 16))

	-- O agente fica suspenso (rota mantida) até o evento Blocked chegar, para medir a latência do
	-- evento sem correr contra o anti-stuck. Sem o evento em 40s, o mecanismo não funciona.
	agent:SetSuspended(true)
	local gotBlocked = waitUntil(function()
		return st.blocked > 0
	end, 40)
	if st.firstBlocked then
		info("Agent (blocked): latência do evento Blocked após a parede cair", string.format("%.1fs", st.firstBlocked - dropTime))
	else
		info("Agent (blocked): o Blocked não disparou em 40s", "nem a detecção própria por Geometry.PartAdded funcionou")
	end
	agent:SetSuspended(false)

	-- a rota nova só existe quando a malha do PathfindingService inclui a parede (mais de 10s
	-- medidos); até lá o agente espera parado em vez de falhar
	local resumeTime = os.clock()
	local done = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 90)
	info("Agent (blocked): tempo de retomada até chegar", string.format("%.1fs", os.clock() - resumeTime))
	local dist = flatDist(rootOf(rig).Position, goal)

	-- diagnóstico: depois de tudo isso, a malha do PathfindingService enxerga a parede? Se a rota
	-- crua ainda for reta, ela nunca soube da parede (e por isso Blocked não disparou).
	local rootPos = rootOf(rig).Position
	local navOk, navInfo = pcall(function()
		local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = math.huge })
		path:ComputeAsync(Vector3.new(TEST_ORIGIN.X - 20, 1, TEST_ORIGIN.Z), goal)
		local maxDetour = 0
		for _, wp in ipairs(path:GetWaypoints()) do
			maxDetour = math.max(maxDetour, math.abs(wp.Position.Z - TEST_ORIGIN.Z))
		end
		return string.format("%s, %d waypoints, desvio máximo em Z: %.1f", tostring(path.Status), #path:GetWaypoints(), maxDetour)
	end)
	info("Agent (blocked): malha do PathfindingService após a parede", navOk and navInfo or tostring(navInfo))
	info("Agent (blocked): posição final do agente", string.format("x %.1f z %.1f", rootPos.X - TEST_ORIGIN.X, rootPos.Z - TEST_ORIGIN.Z))
	agent:Destroy()
	return report(
		"Agent: parte surge sobre a rota, Blocked, replan e conclui",
		gotBlocked and done and st.reached == 1 and st.blocked >= 1 and dist < 3,
		describeStatus(st, string.format("a %.1f do destino", dist))
	)
end

-- Uma parede colidível marcada NavIgnore: a malha a atravessa, o corpo não. É um "encurralado"
-- que o pathfinding não enxerga.
local function testAgentStuck(): boolean
	Geometry.start()
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 80, 60)
	local wall = addBlock(area, "InvisibleToNav", Vector3.new(1, 5, 0), Vector3.new(2, 10, 60))
	CollectionService:AddTag(wall, "NavIgnore")
	task.wait(NAVMESH_SETTLE + 1)

	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-10, 0, 0))
	local agent = newAgent(rig)
	local st = watch(agent)
	local t0 = os.clock()
	agent:MoveTo(TEST_ORIGIN + Vector3.new(12, 0, 0))
	local done = waitUntil(function()
		return st.failed > 0 or st.reached > 0
	end, 30)
	local strikes = st.details and st.details.strikes
	agent:Destroy()
	return report(
		"Agent: encurralado tenta escape, replan e falha com stuck",
		done and st.reason == "stuck" and st.reached == 0,
		describeStatus(st, string.format("strikes %s em %.1fs, saltos de escape %d", tostring(strikes), os.clock() - t0, st.jumps))
	)
end

local function testAgentSuspend(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 40)
	task.wait(NAVMESH_SETTLE)

	local start = TEST_ORIGIN + Vector3.new(-40, 0, 0)
	local goal = TEST_ORIGIN + Vector3.new(40, 0, 0)
	local rig = makeRig(area, start)
	local agent = newAgent(rig)
	local st = watch(agent)
	agent:MoveTo(goal)
	waitUntil(function()
		return rootOf(rig).Position.X > start.X + 12
	end, 20)

	agent:SetSuspended(true)
	task.wait(0.4) -- deixa o Humanoid frear
	local p1 = rootOf(rig).Position
	task.wait(1)
	local p2 = rootOf(rig).Position
	local held = flatDist(p1, p2) < 0.5
	local keptRoute = agent:GetRoute() ~= nil and agent:GetState() == "Following"

	agent:SetSuspended(false)
	local done = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 30)
	local dist = flatDist(rootOf(rig).Position, goal)
	agent:Destroy()
	return report(
		"Agent: SetSuspended para sem perder a rota e retoma no waypoint certo",
		held and keptRoute and done and st.reached == 1 and dist < 3,
		describeStatus(st, string.format("parado: %s (moveu %.2f), rota mantida: %s, a %.1f do destino", tostring(held), flatDist(p1, p2), tostring(keptRoute), dist))
	)
end

local function testAgentDestroy20(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 160)
	task.wait(NAVMESH_SETTLE)

	local rigs, agents = {}, {}
	for i = 1, 20 do
		local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-30, 0, -57 + (i - 1) * 6))
		table.insert(rigs, rig)
		local agent = newAgent(rig)
		table.insert(agents, agent)
		agent:MoveTo(TEST_ORIGIN + Vector3.new(30, 0, -57 + (i - 1) * 6))
	end
	task.wait(1.5)
	local moving = 0
	for i, rig in ipairs(rigs) do
		if rootOf(rig).Position.X > TEST_ORIGIN.X - 30 + 3 then
			moving += 1
		end
	end

	local liveBefore = 0
	for _, agent in ipairs(agents) do
		liveBefore += agent:_liveConnectionCount()
	end
	for _, agent in ipairs(agents) do
		agent:Destroy()
	end
	local liveAfter, notIdle = 0, 0
	for _, agent in ipairs(agents) do
		liveAfter += agent:_liveConnectionCount()
		if agent:GetState() ~= "Idle" then
			notIdle += 1
		end
	end
	local awaitOk, awaitReason = agents[1]:Await()

	task.wait(0.4) -- inércia
	local p0 = {}
	for i, rig in ipairs(rigs) do
		p0[i] = rootOf(rig).Position
	end
	task.wait(1.5)
	local stillMoving = 0
	for i, rig in ipairs(rigs) do
		if flatDist(p0[i], rootOf(rig).Position) > 2 then
			stillMoving += 1
		end
	end

	return report(
		"Agent: Destroy() de 20 agentes não deixa conexões nem movimento",
		moving >= 15 and liveBefore > 0 and liveAfter == 0 and notIdle == 0 and stillMoving == 0 and awaitOk == false and awaitReason == "cancelled",
		string.format("andando antes: %d/20, conexões antes %d -> depois %d, fora de Idle %d, ainda andando %d, Await: %s/%s", moving, liveBefore, liveAfter, notIdle, stillMoving, tostring(awaitOk), tostring(awaitReason))
	)
end

local function testAgentBasics(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 60, 60)
	local rig = makeRig(area, TEST_ORIGIN)
	local agent = newAgent(rig)
	local idle = agent:GetState() == "Idle" and agent:GetRoute() == nil
	local okAwait, reasonAwait = agent:Await()
	agent:Stop()
	local stopOk = agent:GetState() == "Idle"
	agent:SetOptions({ Debug = false, Jump = { Enabled = false } })
	agent:Destroy()
	agent:Destroy() -- idempotente
	return report(
		"Agent: estado inicial, Await sem MoveTo, Stop, SetOptions e Destroy repetido",
		idle and okAwait == false and reasonAwait == "cancelled" and stopOk,
		string.format("Await sem MoveTo: %s/%s", tostring(okAwait), tostring(reasonAwait))
	)
end

function Tests.Phase4(): boolean
	print("[SmartPathTests] ==== Fase 4: Agent ====")
	local results = {
		safe("básico", testAgentBasics),
		safe("percurso", testAgentCourse),
		safe("mureta", testAgentJumpsMureta),
		safe("destino trocado", testAgentDestinationChange),
		safe("blocked", testAgentBlocked),
		safe("stuck", testAgentStuck),
		safe("suspend", testAgentSuspend),
		safe("destroy 20", testAgentDestroy20),
	}
	local allOk = true
	for _, ok in ipairs(results) do
		allOk = allOk and ok
	end
	print("[SmartPathTests] ==== Resultado: " .. (allOk and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return allOk
end

-- ===================== Fase 5: fachada e camada de compatibilidade =====================
-- Uso: require(game.ServerStorage.SmartPathTests).Phase5()

local function makeTargetPart(area: Folder, relPos: Vector3): Part
	local p = addBlock(area, "TargetPart", relPos, Vector3.new(2, 2, 2))
	p.CanCollide = false -- um alvo não pode bloquear o caminho até ele mesmo
	p.Transparency = 0.5
	return p
end

-- Roda `fn` em outra thread e espera até `timeout`; devolve (terminou, resultados de fn).
local function runWithTimeout(timeout: number, fn: () -> ...any): (boolean, { any })
	local finished = false
	local results: { any } = {}
	task.spawn(function()
		results = table.pack(fn())
		finished = true
	end)
	local done = waitUntil(function()
		return finished
	end, timeout)
	return done, results
end

-- MoveTo sem tabela de opções, com Vector3, BasePart e Model como destino.
local function testFacadeTargets(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 60)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-30, 0, 0))
	local humanoid = humanoidOf(rig)

	local part = makeTargetPart(area, Vector3.new(10, 1, 10))
	local model = Instance.new("Model")
	model.Name = "TargetModel"
	local modelPart = makeTargetPart(area, Vector3.new(30, 1, -10))
	modelPart.Parent = model
	model.PrimaryPart = modelPart
	model.Parent = area

	local cases = {
		{ label = "Vector3", target = TEST_ORIGIN + Vector3.new(-10, 0, -10) :: any, pos = TEST_ORIGIN + Vector3.new(-10, 0, -10) },
		{ label = "BasePart", target = part :: any, pos = part.Position },
		{ label = "Model", target = model :: any, pos = modelPart.Position },
	}
	local details = {}
	local allOk = true
	for _, c in ipairs(cases) do
		local done, res = runWithTimeout(30, function()
			return SmartPath.MoveTo(humanoid, c.target)
		end)
		local dist = flatDist(rootOf(rig).Position, c.pos)
		local ok = done and res[1] == true and dist < 3.5
		allOk = allOk and ok
		table.insert(details, string.format("%s: %s (a %.1f)", c.label, ok and "ok" or ("FALHOU " .. tostring(res[2])), dist))
	end
	return report("Fachada: MoveTo sem opções aceita Vector3, BasePart e Model", allOk, table.concat(details, "; "))
end

local function testFacadeAsyncAndRoute(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 60)
	addBlock(area, "Wall", Vector3.new(0, 5, 15), Vector3.new(10, 10, 10))
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-30, 0, 0))
	local humanoid = humanoidOf(rig)

	local goal = TEST_ORIGIN + Vector3.new(20, 0, -10)
	local wps, reason = SmartPath.GetRoute(humanoid, goal)
	local routeOk = wps ~= nil and reason == nil and #wps >= 2
	local none, noneReason = SmartPath.GetRoute(humanoid, TEST_ORIGIN + Vector3.new(0, 5, 15))
	local wallOk = none == nil and noneReason == "goal_unreachable"

	local startPos = rootOf(rig).Position
	local agent = SmartPath.MoveToAsync(humanoid, goal)
	local asyncReturned = agent ~= nil and agent:GetState() ~= "Idle"
	local done, res = runWithTimeout(30, function()
		return agent:Await()
	end)
	local dist = flatDist(rootOf(rig).Position, goal)
	local moved = flatDist(startPos, rootOf(rig).Position) > 20
	return report(
		"Fachada: GetRoute só calcula, MoveToAsync devolve o agente em movimento",
		routeOk and wallOk and asyncReturned and done and res[1] == true and dist < 3.5 and moved,
		string.format(
			"GetRoute: %s (%d waypoints), destino na parede: %s, agente em movimento: %s, chegou a %.1f",
			tostring(reason),
			wps and #wps or 0,
			tostring(noneReason),
			tostring(asyncReturned),
			dist
		)
	)
end

-- O alvo se desloca 50 studs enquanto o agente o persegue; o agente termina junto dele.
local function testFacadeChase(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 160, 80)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local humanoid = humanoidOf(rig)
	local part = makeTargetPart(area, Vector3.new(20, 1, -25))
	local endZ = TEST_ORIGIN.Z + 25

	local moving = true
	local conn = RunService.Heartbeat:Connect(function(dt)
		if moving then
			local p = part.Position
			local nz = math.min(p.Z + 8 * dt, endZ)
			part.Position = Vector3.new(p.X, p.Y, nz)
			if nz >= endZ then
				moving = false
			end
		end
	end)

	local agent = SmartPath.MoveToAsync(humanoid, part)
	local done, res = runWithTimeout(60, function()
		return agent:Await()
	end)
	conn:Disconnect()
	local dist = flatDist(rootOf(rig).Position, part.Position)
	return report(
		"Fachada: destino BasePart em movimento é perseguido",
		done and res[1] == true and dist < 4 and not moving,
		string.format("o alvo andou 50 studs, o agente parou a %.1f dele (para a 3, segue se o alvo estiver além de 3.5)", dist)
	)
end

-- O script clássico do PathfindingService, escrito UMA vez: só o objeto `PathfindingService`
-- que ele recebe muda (é o equivalente a trocar a linha do require).
local function classicFollow(PathfindingService: any, character: Model, destination: Vector3): (boolean, string)
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = character.PrimaryPart :: BasePart
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local success = pcall(function()
		path:ComputeAsync(root.Position, destination)
	end)
	if not success or path.Status ~= Enum.PathStatus.Success then
		return false, "sem rota (" .. tostring(path.Status) .. ")"
	end
	local waypoints = path:GetWaypoints()
	local blockedConnection = path.Blocked:Connect(function(_blockedWaypointIndex: number) end)
	for _, waypoint in ipairs(waypoints) do
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end
		humanoid:MoveTo(waypoint.Position)
		if not humanoid.MoveToFinished:Wait() then
			blockedConnection:Disconnect()
			return false, "MoveTo estourou o tempo"
		end
	end
	blockedConnection:Disconnect()
	return true, string.format("%d waypoints", #waypoints)
end

local function testCompatClassicScript(): boolean
	local outcomes = {}
	for _, entry in ipairs({
		{ label = "PathfindingService puro", service = game:GetService("PathfindingService") :: any },
		{ label = "SmartPath.Service", service = SmartPath.Service :: any },
	}) do
		local area = newArea()
		local start, goal = buildCourse(area)
		task.wait(NAVMESH_SETTLE)
		local rig = makeRig(area, start)
		local t0 = os.clock()
		local done, res = runWithTimeout(90, function()
			return classicFollow(entry.service, rig, goal)
		end)
		local dist = flatDist(rootOf(rig).Position, goal)
		outcomes[entry.label] = {
			ok = done and res[1] == true and dist < 3.5,
			text = string.format("%s em %.1fs, a %.1f do destino (%s)", done and tostring(res[2]) or "TEMPO ESGOTADO", os.clock() - t0, dist, done and (res[1] and "chegou" or "não chegou") or "?"),
		}
		cleanupArea()
	end
	info("Script clássico com o serviço da engine", outcomes["PathfindingService puro"].text)
	return report(
		"Compat: o mesmo script clássico funciona trocando só o serviço",
		outcomes["SmartPath.Service"].ok,
		"SmartPath.Service: " .. outcomes["SmartPath.Service"].text
	)
end

local function isValidStatus(status: any): boolean
	return typeof(status) == "EnumItem" and status.EnumType == Enum.PathStatus
end

local function testCompatStatus(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 60)
	addBlock(area, "Wall", Vector3.new(0, 5, 15), Vector3.new(10, 10, 10))
	task.wait(NAVMESH_SETTLE)
	local service: any = SmartPath.Service
	local start = TEST_ORIGIN + Vector3.new(-30, 0, 0)

	local path = service:CreatePath({ AgentRadius = 2, AgentHeight = 5 })
	local before = path.Status
	path:ComputeAsync(start, TEST_ORIGIN + Vector3.new(30, 0, -10))
	local a = path.Status == Enum.PathStatus.Success and path.SmartStatus == nil and #path:GetWaypoints() >= 2
	local list = path:GetWaypoints()
	table.clear(list)
	local copyOk = #path:GetWaypoints() >= 2 -- mexer na tabela devolvida não afeta o Path

	local wall = service:CreatePath()
	wall:ComputeAsync(start, TEST_ORIGIN + Vector3.new(0, 5, 15))
	local b = isValidStatus(wall.Status)
		and wall.Status ~= Enum.PathStatus.Success
		and wall.SmartStatus == "goal_unreachable"
		and typeof(wall.SmartDetails and wall.SmartDetails.nearestValid) == "Vector3"

	local argsRejected = not pcall(function()
		path:ComputeAsync("x", "y")
	end)

	return report(
		"Compat: Status é sempre um Enum.PathStatus válido e há SmartStatus/SmartDetails",
		isValidStatus(before) and a and copyOk and b and argsRejected,
		string.format(
			"antes do cálculo: %s, sucesso: %s (SmartStatus %s), destino na parede: %s/%s, argumento inválido rejeitado: %s",
			tostring(before),
			tostring(path.Status),
			tostring(path.SmartStatus),
			tostring(wall.Status),
			tostring(wall.SmartStatus),
			tostring(argsRejected)
		)
	)
end

-- Corredores com o raio do CreatePath: 2 studs de largura o corpo não atravessa; 6 com AgentRadius
-- 4 a engine sozinha tende a recusar (o raio dela é maior que o corredor), mas o corpo cabe.
local function testCompatCorridors(): boolean
	local service: any = SmartPath.Service

	local area = newArea()
	local start, goal = buildCorridor(area, 2)
	task.wait(NAVMESH_SETTLE)
	local narrow = service:CreatePath({ AgentRadius = 2, AgentHeight = 5 })
	narrow:ComputeAsync(start, goal)
	local narrowOk = narrow.Status == Enum.PathStatus.NoPath
		and narrow.SmartStatus == "corridor_too_narrow"
		and narrow.SmartDetails ~= nil
		and typeof(narrow.SmartDetails.requiredRadius) == "number"
		and #narrow:GetWaypoints() == 0

	local area6 = newArea()
	start, goal = buildCorridor(area6, 6)
	task.wait(NAVMESH_SETTLE)
	local baselineOk, baseline = pcall(function()
		local p = PathfindingService:CreatePath({ AgentRadius = 4, AgentHeight = 5, AgentCanJump = true })
		p:ComputeAsync(start + Vector3.new(0, 1, 0), goal)
		return tostring(p.Status)
	end)
	baseline = baselineOk and baseline or ("erro: " .. tostring(baseline))
	local wide = service:CreatePath({ AgentRadius = 4, AgentHeight = 5 })
	wide:ComputeAsync(start, goal)
	local wideOk = wide.Status == Enum.PathStatus.Success and #wide:GetWaypoints() >= 2

	return report(
		"Compat: corredor estreito devolve NoPath com diagnóstico; AgentRadius grande ainda acha rota",
		narrowOk and wideOk,
		string.format(
			"2 studs: %s/%s; 6 studs com AgentRadius 4 (PathfindingService puro: %s): %s, raio usado %s",
			tostring(narrow.Status),
			tostring(narrow.SmartStatus),
			baseline,
			tostring(wide.Status),
			tostring(wide.SmartDetails and wide.SmartDetails.radius)
		)
	)
end

-- 10 chamadas por segundo por 8s: o Scheduler segura, o jogo não trava.
local function testCompatLoop(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 60)
	task.wait(NAVMESH_SETTLE)
	local service: any = SmartPath.Service
	local goal = TEST_ORIGIN + Vector3.new(40, 0, 0)

	local maxDt, frames = 0, 0
	local conn = RunService.Heartbeat:Connect(function(dt)
		maxDt = math.max(maxDt, dt)
		frames += 1
	end)
	local calls, okCount = 0, 0
	local t0 = os.clock()
	local nextAt = t0
	while os.clock() - t0 < 8 do
		-- origens diferentes: sem isso o cache respondia tudo e o teste não exercitaria o Scheduler
		local start = TEST_ORIGIN + Vector3.new(-50 + (calls * 0.9) % 40, 0, -20 + (calls * 1.3) % 40)
		local path = service:CreatePath({ AgentRadius = 2, AgentHeight = 5 })
		path:ComputeAsync(start, goal)
		calls += 1
		if path.Status == Enum.PathStatus.Success then
			okCount += 1
		end
		nextAt += 0.1
		local wait = nextAt - os.clock()
		if wait > 0 then
			task.wait(wait)
		end
	end
	local elapsed = os.clock() - t0
	conn:Disconnect()
	local fps = frames / elapsed
	return report(
		"Compat: 10 chamadas por segundo não travam o jogo",
		okCount == calls and maxDt < 0.25 and fps >= 30,
		string.format("%d chamadas em %.1fs (%.1f/s), todas Success: %s, FPS médio %.0f, pior frame %.0fms, fila final %d", calls, elapsed, calls / elapsed, tostring(okCount == calls), fps, maxDt * 1000, SmartPath.Scheduler.getQueueLength())
	)
end

local function testCompatBlocked(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 200, 50)
	task.wait(NAVMESH_SETTLE)
	local service: any = SmartPath.Service
	local path = service:CreatePath({ AgentRadius = 2, AgentHeight = 5 })
	path:ComputeAsync(TEST_ORIGIN + Vector3.new(-60, 0, 0), TEST_ORIGIN + Vector3.new(60, 0, 0))

	local fired, firedIndex = 0, nil :: number?
	local connection = path.Blocked:Connect(function(index: number)
		fired += 1
		firedIndex = index
	end)
	local computedOk = path.Status == Enum.PathStatus.Success
	addBlock(area, "DroppedWall", Vector3.new(0, 5, 0), Vector3.new(2, 10, 16))
	waitUntil(function()
		return fired > 0
	end, 8)
	connection:Disconnect()
	return report(
		"Compat: path.Blocked dispara com o índice do waypoint quando uma parte cai sobre a rota",
		computedOk and fired == 1 and typeof(firedIndex) == "number" and (firedIndex :: number) >= 1,
		string.format("disparos: %d, índice: %s", fired, tostring(firedIndex))
	)
end

function Tests.Phase5(): boolean
	print("[SmartPathTests] ==== Fase 5: fachada e compatibilidade ====")
	local results = {
		safe("alvos", testFacadeTargets),
		safe("async e rota", testFacadeAsyncAndRoute),
		safe("perseguição", testFacadeChase),
		safe("script clássico", testCompatClassicScript),
		safe("status", testCompatStatus),
		safe("corredores", testCompatCorridors),
		safe("laço 10/s", testCompatLoop),
		safe("blocked", testCompatBlocked),
	}
	local allOk = true
	for _, ok in ipairs(results) do
		allOk = allOk and ok
	end
	print("[SmartPathTests] ==== Resultado: " .. (allOk and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return allOk
end

-- ===================== Fase 6: diagnóstico e debug visual =====================
-- Uso: require(game.ServerStorage.SmartPathTests).Phase6()
-- Um cenário reproduzível por código de erro (a lista dos nomes sai no Output como "cenário <código>"),
-- mais os testes do explain, do Debug desligado, do Debug ligado e do painel. Leva alguns minutos.

local LogService = game:GetService("LogService")
local ServerStorage = game:GetService("ServerStorage")
local AgentModule = require(ReplicatedStorage.SmartPath.Agent)
local SmartDebug = SmartPath.Debug

local function baseOptions(extra: { [string]: any }?): { [string]: any }
	local options: { [string]: any } = { Agent = { Radius = 2, Height = 5 } }
	if extra then
		for k, v in pairs(extra) do
			options[k] = v
		end
	end
	return options
end

-- MoveTo bloqueante de nível 0 com limite de tempo: (respondeu, ok, motivo, details)
local function moveOutcome(
	rig: Model,
	target: Vector3,
	extra: { [string]: any }?,
	timeout: number?
): (boolean, boolean?, string?, { [string]: any }?)
	local finished, res = runWithTimeout(timeout or 45, function()
		return SmartPath.MoveTo(rig, target, baseOptions(extra) :: any)
	end)
	if not finished then
		return false, nil, nil, nil
	end
	return true, res[1], res[2], res[3]
end

-- "details preenchidos": o texto de explain não pode ter o "?" que marca dado ausente
local function explainClean(reason: string?, details: { [string]: any }?): (boolean, string)
	local text = SmartPath.explain(reason, details)
	return #text > 0 and not string.find(text, "?", 1, true), text
end

local function checkFailure(
	title: string,
	code: string,
	answered: boolean,
	ok: boolean?,
	reason: string?,
	details: { [string]: any }?,
	extraOk: boolean?
): boolean
	local clean, text = explainClean(reason, details)
	info("cenário " .. code, title)
	info("explain", text)
	return report(
		string.format("Fase 6: %s -> %s", title, code),
		answered and ok == false and reason == code and clean and extraOk ~= false,
		string.format(
			"respondeu %s, motivo %s, texto limpo %s, %s",
			tostring(answered),
			tostring(reason),
			tostring(clean),
			describe(details)
		)
	)
end

-- ----- um cenário por código -----

local function testCodeNoPath(): boolean
	local area = newArea()
	addFloor(area, "FloorA", -20, 0, 60, 40)
	addFloor(area, "Island", 60, 0, 30, 40)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-30, 0, 0))
	local answered, ok, reason, details = moveOutcome(rig, TEST_ORIGIN + Vector3.new(60, 0, 0))
	local tried = details and details.triedRadii
	return checkFailure(
		"ilha separada por um vão de 35 studs",
		"no_path",
		answered,
		ok,
		reason,
		details,
		typeof(tried) == "table" and #(tried :: { any }) >= 1
	)
end

local function testCodeCorridorTooNarrow(): boolean
	local area = newArea()
	local start, goal = buildCorridor(area, 2)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local answered, ok, reason, details = moveOutcome(rig, goal)
	local required = details and details.requiredRadius
	local agentRadius = details and details.agentRadius
	return checkFailure(
		"corredor de 2 studs para um agente de raio 2",
		"corridor_too_narrow",
		answered,
		ok,
		reason,
		details,
		typeof(required) == "number" and typeof(agentRadius) == "number" and required < agentRadius
	)
end

local function testCodeObstacleTooTall(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 60)
	-- recinto de 16x16 com paredes de 30 studs: o destino está lá dentro
	addBlock(area, "PenN", Vector3.new(30, 15, 9), Vector3.new(20, 30, 2))
	addBlock(area, "PenS", Vector3.new(30, 15, -9), Vector3.new(20, 30, 2))
	addBlock(area, "PenW", Vector3.new(21, 15, 0), Vector3.new(2, 30, 20))
	addBlock(area, "PenE", Vector3.new(39, 15, 0), Vector3.new(2, 30, 20))
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-20, 0, 0))
	local answered, ok, reason, details = moveOutcome(rig, TEST_ORIGIN + Vector3.new(30, 0, 0))
	local height = details and details.height
	local maxJump = details and details.maxJump
	return checkFailure(
		"recinto com paredes de 30 studs",
		"obstacle_too_tall",
		answered,
		ok,
		reason,
		details,
		typeof(height) == "number" and typeof(maxJump) == "number" and height > maxJump
	)
end

local function testCodeNoLanding(): boolean
	local area = newArea()
	addFloor(area, "FloorA", -25, 0, 50, 40)
	addBlock(area, "Lip", Vector3.new(1, 2, 0), Vector3.new(2, 4, 40)) -- muro saltável de 4 studs
	addFloor(area, "Island", 60, 0, 30, 40) -- e depois do muro só há vazio até a ilha
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-20, 0, 0))
	local answered, ok, reason, details = moveOutcome(rig, TEST_ORIGIN + Vector3.new(60, 0, 0))
	local drop = details and details.drop
	return checkFailure(
		"muro de 4 studs e vazio do outro lado",
		"no_landing",
		answered,
		ok,
		reason,
		details,
		typeof(drop) == "number" and drop >= 14
	)
end

local function testCodeGoalUnreachable(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 80, 60)
	addBlock(area, "Rock", Vector3.new(20, 3, 0), Vector3.new(8, 6, 8))
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-20, 0, 0))
	local answered, ok, reason, details = moveOutcome(rig, TEST_ORIGIN + Vector3.new(20, 3, 0))
	return checkFailure(
		"destino dentro de uma rocha",
		"goal_unreachable",
		answered,
		ok,
		reason,
		details,
		details ~= nil and typeof(details.nearestValid) == "Vector3"
	)
end

-- Parede invisível e colidível sem nome de gatilho (a lib não a filtra): a malha a vê, o corredor
-- fica sem rota e a causa é a parte. Com tag NavSolid é intenção do desenvolvedor: nada de aviso.
local function buildInvisibleWall(area: Folder, name: string): Part
	addFloor(area, "Floor", 0, 0, 100, 60)
	local wall = addBlock(area, name, Vector3.new(0, 5, 0), Vector3.new(2, 10, 60))
	wall.Transparency = 1
	return wall
end

local function testCodeInvisibleCollider(): boolean
	local area = newArea()
	local wall = buildInvisibleWall(area, "MapEdge")
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-20, 0, 0))
	local goal = TEST_ORIGIN + Vector3.new(20, 0, 0)
	local answered, ok, reason, details = moveOutcome(rig, goal)
	local first = checkFailure(
		"parede invisível colidível entre o agente e o destino",
		"invisible_collider",
		answered,
		ok,
		reason,
		details,
		details ~= nil and details.instance == wall and details.underlying == "no_path"
	)

	-- a mesma parede com NavSolid é limite de mapa declarado: a rota falha, mas sem apontar a parte
	CollectionService:AddTag(wall, "NavSolid")
	task.wait(0.2)
	local route, why = SmartPath.GetRoute(rig, goal, baseOptions() :: any)
	local second = report(
		"Fase 6: parede invisível com tag NavSolid não vira invisible_collider",
		route == nil and why ~= "invisible_collider",
		"motivo: " .. tostring(why)
	)
	return first and second
end

-- Gatilho invisível que a lib filtra (nome "TriggerZone": a malha o atravessa) mas o corpo bate:
-- o agente trava, e ao esgotar o anti-stuck a causa é apontada em vez de um "stuck" genérico.
local function testCodeInvisibleColliderStuck(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 100, 60)
	local trigger = addBlock(area, "TriggerZone", Vector3.new(1, 5, 0), Vector3.new(2, 10, 60))
	trigger.Transparency = 1
	task.wait(NAVMESH_SETTLE + 1)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-10, 0, 0))
	local answered, ok, reason, details = moveOutcome(rig, TEST_ORIGIN + Vector3.new(14, 0, 0), nil, 60)
	return checkFailure(
		"gatilho invisível filtrado pela lib, mas sólido para o corpo",
		"invisible_collider",
		answered,
		ok,
		reason,
		details,
		details ~= nil and details.instance == trigger and details.underlying == "stuck"
	)
end

local function testCodeStuck(): boolean
	Geometry.start()
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 80, 60)
	local wall = addBlock(area, "InvisibleToNav", Vector3.new(1, 5, 0), Vector3.new(2, 10, 60))
	CollectionService:AddTag(wall, "NavIgnore") -- a malha atravessa, o corpo não
	task.wait(NAVMESH_SETTLE + 1)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-10, 0, 0))
	local answered, ok, reason, details = moveOutcome(rig, TEST_ORIGIN + Vector3.new(12, 0, 0), nil, 60)
	return checkFailure(
		"parede visível marcada NavIgnore",
		"stuck",
		answered,
		ok,
		reason,
		details,
		details ~= nil and typeof(details.position) == "Vector3" and typeof(details.strikes) == "number"
	)
end

local function testCodeCancelled(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 40)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local agent = SmartPath.MoveToAsync(rig, TEST_ORIGIN + Vector3.new(40, 0, 0), baseOptions() :: any)
	task.wait(0.6)
	agent:Stop()
	local ok, reason, details = agent:Await()
	agent:Destroy()
	return checkFailure("Stop() no meio do caminho", "cancelled", true, ok, reason, details)
end

local function testCodeCharacterLost(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 40)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local agent = SmartPath.MoveToAsync(rig, TEST_ORIGIN + Vector3.new(40, 0, 0), baseOptions() :: any)
	task.wait(0.6)
	local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.Health = 0
	local ok, reason, details = agent:Await()
	agent:Destroy()
	return checkFailure("o personagem morre durante a rota", "character_lost", true, ok, reason, details)
end

-- O orçamento (45 s + 4x o tempo ideal) é longo demais para um teste: encurta o orçamento e deixa o
-- agente lento (WalkSpeed 4: 60 studs levariam 15 s).
local function testCodeTimeout(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 40)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-30, 0, 0))
	local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.WalkSpeed = 4

	local tuning = AgentModule._tuning
	local saved = table.clone(tuning)
	tuning.TimeoutBase, tuning.TimeoutFactor = 2, 0.1
	local pcallOk, err = pcall(function()
		local answered, ok, reason, details = moveOutcome(rig, TEST_ORIGIN + Vector3.new(30, 0, 0), nil, 30)
		local elapsed = details and details.elapsed
		local passed = checkFailure(
			"agente lento demais para o orçamento de tempo",
			"timeout",
			answered,
			ok,
			reason,
			details,
			typeof(elapsed) == "number" and elapsed >= 2 and elapsed < 10
		)
		tuning.TimeoutBase, tuning.TimeoutFactor = saved.TimeoutBase, saved.TimeoutFactor
		return passed
	end)
	tuning.TimeoutBase, tuning.TimeoutFactor = saved.TimeoutBase, saved.TimeoutFactor
	if not pcallOk then
		error(err)
	end
	return err :: any
end

-- ----- explain -----

local function testExplain(): boolean
	local sampleInstance = Instance.new("Part")
	sampleInstance.Name = "ParedeInvisivel"
	local samples: { [string]: { [string]: any } } = {
		no_path = { triedRadii = { 2, 1, 0.5 } },
		corridor_too_narrow = { requiredRadius = 0.8, agentRadius = 2.0 },
		obstacle_too_tall = { height = 12, maxJump = 7.2 },
		no_landing = { drop = 20 },
		goal_unreachable = { nearestValid = Vector3.new(1, 2, 3) },
		invisible_collider = { instance = sampleInstance },
		stuck = { position = Vector3.new(4, 5, 6), strikes = 4 },
		cancelled = {},
		character_lost = {},
		timeout = { elapsed = 45.2 },
	}
	local failures = {}
	for _, code in ipairs(SmartPath.Errors.All) do
		local details = samples[code]
		if not details then
			table.insert(failures, code .. ": sem amostra no teste")
		else
			local clean, text = explainClean(code, details)
			if not clean then
				table.insert(failures, code .. ": texto vazio ou com '?' -> " .. text)
			end
		end
	end
	local corridor = SmartPath.explain("corridor_too_narrow", samples.corridor_too_narrow)
	local exampleOk = string.find(corridor, "0.8", 1, true) ~= nil
		and string.find(corridor, "2.0", 1, true) ~= nil
		and string.find(corridor, "raio", 1, true) ~= nil
	info("explain corridor_too_narrow", corridor)

	-- nunca erra: details ausente, incompleto ou de tipo errado, código desconhecido ou nil
	local robust = pcall(function()
		for _, code in ipairs(SmartPath.Errors.All) do
			SmartPath.explain(code, nil)
			SmartPath.explain(code, {})
			SmartPath.explain(code, { height = "x", position = "y", instance = 5, triedRadii = 3 } :: any)
		end
		assert(type(SmartPath.explain(nil, nil)) == "string")
		assert(string.find(SmartPath.explain("codigo_novo", nil), "codigo_novo", 1, true))
	end)
	sampleInstance:Destroy()
	return report(
		"Fase 6: explain gera uma frase para cada um dos 10 códigos e nunca erra",
		#SmartPath.Errors.All == 10 and #failures == 0 and exampleOk and robust,
		string.format("falhas: %s, exemplo do corredor %s, robusto %s", table.concat(failures, "; "), tostring(exampleOk), tostring(robust))
	)
end

-- ----- Debug desligado e ligado -----

local function captureSmartPathLog(): ({ string }, () -> ())
	local lines: { string } = {}
	local conn = LogService.MessageOut:Connect(function(message: string)
		if string.find(message, "[SmartPath]", 1, true) then
			table.insert(lines, message)
		end
	end)
	return lines, function()
		conn:Disconnect()
	end
end

-- Mureta de 3 studs sem passagem: o agente salta, então rota, salto e chegada são exercitados.
local function buildMuretaCourse(area: Folder): (Vector3, Vector3)
	addFloor(area, "Floor", 5, 0, 70, 40)
	addBlock(area, "Mureta", Vector3.new(1, 1.5, 0), Vector3.new(2, 3, 80))
	return TEST_ORIGIN + Vector3.new(-6, 0, 0), TEST_ORIGIN + Vector3.new(14, 0, 0)
end

local function testDebugOff(): boolean
	SmartDebug.clear()
	cleanupArea()
	task.wait()
	local before = #workspace:GetDescendants()
	local lines, stopLog = captureSmartPathLog()

	local area = newArea()
	local start, goal = buildMuretaCourse(area)
	addBlock(area, "Rock", Vector3.new(30, 3, 0), Vector3.new(8, 6, 8))
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local answered, ok = moveOutcome(rig, goal, nil, 40) -- chega (com salto)
	local _, _, failReason = moveOutcome(rig, TEST_ORIGIN + Vector3.new(30, 3, 0), nil, 40) -- e uma falha
	local folderExists = SmartDebug.peekFolder() ~= nil

	cleanupArea()
	task.wait(0.5)
	stopLog()
	local after = #workspace:GetDescendants()
	return report(
		"Fase 6: Debug desligado não cria instância nem imprime",
		answered and ok == true and failReason == "goal_unreachable" and not folderExists and after == before and #lines == 0,
		string.format(
			"chegou %s, falha %s, pasta de debug %s, instâncias do workspace %d -> %d, linhas [SmartPath]: %d%s",
			tostring(ok),
			tostring(failReason),
			tostring(folderExists),
			before,
			after,
			#lines,
			#lines > 0 and (" (" .. lines[1] .. ")") or ""
		)
	)
end

-- a cor lida de volta de uma Part pode diferir do Color3 original na última casa
local function sameColor(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) < 0.01 and math.abs(a.G - b.G) < 0.01 and math.abs(a.B - b.B) < 0.01
end

local function testDebugOn(): boolean
	SmartDebug.clear()
	local area = newArea()
	local start, goal = buildMuretaCourse(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local lines, stopLog = captureSmartPathLog()
	-- primeiro um trecho plano (rota da malha e disco do raio), depois a mureta (salto)
	local answeredWalk, okWalk = moveOutcome(rig, start + Vector3.new(-8, 0, 0), { Debug = true }, 40)
	local answeredJump, okJump = moveOutcome(rig, goal, { Debug = true }, 40)
	local answered, ok = answeredWalk and answeredJump, okWalk == true and okJump == true
	task.wait(0.3)
	stopLog()

	local folder = SmartDebug.peekFolder()
	local total, bad, cylinders, jumpRoute, landings, walkPoints = 0, 0, 0, 0, 0, 0
	if folder then
		for _, d in ipairs(folder:GetDescendants()) do
			if d:IsA("BasePart") then
				total += 1
				if d.CanCollide or d.CanQuery or d.CanTouch or not d.Anchored then
					bad += 1
				end
				if d:IsA("Part") and d.Shape == Enum.PartType.Cylinder then
					cylinders += 1
				end
				if d:IsA("Part") and d.Shape == Enum.PartType.Ball then
					if sameColor(d.Color, SmartDebug.Colors.Landing) then
						landings += 1
					elseif sameColor(d.Color, SmartDebug.Colors.Walk) then
						walkPoints += 1
					elseif sameColor(d.Color, SmartDebug.Colors.Jump) then
						jumpRoute += 1
					end
				end
			end
		end
	end

	-- a pasta é excluída dos RaycastParams da lib, e um raio comum não a enxerga (CanQuery = false)
	local params = Geometry.buildRaycastParams()
	local excluded = folder ~= nil and table.find(params.FilterDescendantsInstances, folder) ~= nil
	local probe = if folder and total > 0 then folder:FindFirstChildWhichIsA("BasePart", true) else nil
	local rayHitsDebug = false
	if probe and folder then
		local hit = workspace:Raycast(probe.Position + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0))
		rayHitsDebug = hit ~= nil and hit.Instance:IsDescendantOf(folder)
	end
	SmartDebug.clear()
	return report(
		"Fase 6: Debug ligado desenha rota, raio efetivo e salto, com partes sem colisão nem consulta",
		answered
			and ok
			and total > 0
			and bad == 0
			and cylinders >= 1
			and walkPoints >= 1
			and landings >= 1
			and excluded
			and not rayHitsDebug
			and #lines >= 1,
		string.format(
			"partes %d (fora da regra %d), discos de raio %d, pontos de andar %d, de salto %d, de pouso %d, pasta nos RaycastParams %s, raio atinge o debug %s, linhas [SmartPath] %d",
			total,
			bad,
			cylinders,
			walkPoints,
			jumpRoute,
			landings,
			tostring(excluded),
			tostring(rayHitsDebug),
			#lines
		)
	)
end

local function testDebugFailureMarker(): boolean
	SmartDebug.clear()
	local area = newArea()
	local wall = buildInvisibleWall(area, "MapEdge")
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-20, 0, 0))
	local lines, stopLog = captureSmartPathLog()
	local answered, _, reason = moveOutcome(rig, TEST_ORIGIN + Vector3.new(20, 0, 0), { Debug = true })
	task.wait(0.3)
	stopLog()

	local folder = SmartDebug.peekFolder()
	local boxAdornee: Instance? = nil
	if folder then
		local box = folder:FindFirstChildWhichIsA("SelectionBox", true)
		boxAdornee = box and box.Adornee
	end
	local printedCause = false
	for _, line in ipairs(lines) do
		if string.find(line, "invisible_collider", 1, true) then
			printedCause = true
		end
	end
	SmartDebug.clear()
	return report(
		"Fase 6: Debug ligado marca a parte invisível que bloqueou a rota e imprime a explicação",
		answered and reason == "invisible_collider" and boxAdornee == wall and printedCause,
		string.format(
			"motivo %s, moldura na parte certa %s, causa impressa %s",
			tostring(reason),
			tostring(boxAdornee == wall),
			tostring(printedCause)
		)
	)
end

local function testDebugPanel(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 40)
	addBlock(area, "Rock", Vector3.new(30, 3, 20), Vector3.new(8, 6, 8))
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local agent = SmartPath.MoveToAsync(rig, TEST_ORIGIN + Vector3.new(40, 0, 0), baseOptions() :: any)
	-- no servidor não há PlayerGui: o painel é montado num pai qualquer para verificar o conteúdo
	local panel = SmartDebug.showPanel(agent, ServerStorage)
	local followingText = panel.GetText()
	local hasCalc = waitUntil(function()
		return agent._lastCalcTime ~= nil
	end, 10)
	panel.Refresh()
	local calcText = (panel.Gui:FindFirstChildWhichIsA("TextLabel") :: TextLabel).Text
	agent:Stop()

	-- uma falha aparece com o motivo e a frase
	local answered, _, reason = moveOutcome(rig, TEST_ORIGIN + Vector3.new(30, 3, 20), nil, 40)
	panel.Refresh()
	local failText = panel.GetText()

	panel.Destroy()
	local gone = panel.Gui.Parent == nil
	local refreshAfterDestroy = pcall(panel.Refresh)
	agent:Destroy()
	local noServerGui = pcall(function()
		SmartDebug.showPanel(agent) -- sem parent e sem LocalPlayer: erro claro, sem criar nada
	end)
	return report(
		"Fase 6: painel mostra estado, rota, raio, tempo de cálculo, fila do Scheduler e último erro",
		string.find(followingText, "Following", 1, true) ~= nil
			and string.find(followingText, "Fila do Scheduler: ", 1, true) ~= nil
			and hasCalc
			and string.find(calcText, "ms", 1, true) ~= nil
			and string.find(calcText, "Raio: ", 1, true) ~= nil
			and answered
			and reason == "goal_unreachable"
			and string.find(failText, "Último erro: goal_unreachable", 1, true) ~= nil
			and gone
			and refreshAfterDestroy
			and not noServerGui,
		string.format(
			"estado %s, cálculo %s, erro %s, painel removido %s",
			tostring(string.find(followingText, "Following", 1, true) ~= nil),
			tostring(string.find(calcText, "ms", 1, true) ~= nil),
			tostring(string.find(failText, "Último erro", 1, true) ~= nil),
			tostring(gone)
		)
	)
end

function Tests.Phase6(): boolean
	print("[SmartPathTests] ==== Fase 6: diagnóstico e debug visual ====")
	local results = {
		safe("explain", testExplain),
		safe("no_path", testCodeNoPath),
		safe("corridor_too_narrow", testCodeCorridorTooNarrow),
		safe("obstacle_too_tall", testCodeObstacleTooTall),
		safe("no_landing", testCodeNoLanding),
		safe("goal_unreachable", testCodeGoalUnreachable),
		safe("invisible_collider", testCodeInvisibleCollider),
		safe("invisible_collider (travou)", testCodeInvisibleColliderStuck),
		safe("stuck", testCodeStuck),
		safe("cancelled", testCodeCancelled),
		safe("character_lost", testCodeCharacterLost),
		safe("timeout", testCodeTimeout),
		safe("debug desligado", testDebugOff),
		safe("debug ligado", testDebugOn),
		safe("debug: marca da falha", testDebugFailureMarker),
		safe("painel", testDebugPanel),
	}
	SmartDebug.clear()
	local allOk = true
	for _, ok in ipairs(results) do
		allOk = allOk and ok
	end
	print("[SmartPathTests] ==== Resultado: " .. (allOk and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return allOk
end

return Tests
