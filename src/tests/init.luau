--!strict
-- SmartPathTests (init.luau)
-- Harness de verificação manual dos critérios de aceite de cada fase. NÃO faz parte da
-- biblioteca — não é requerido pelo SmartPath em nenhum momento, é ferramenta de
-- validação para você rodar no Command Bar durante o Play mode: rode os critérios de aceite
-- você mesmo e não aceite "testei e funciona" sem ver o Output.
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

-- A engine é mais tolerante do que se esperava: com raio 2 ela já atravessa 4 studs.
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

-- ===================== Fase 8: endurecimento =====================
-- Uso: require(game.ServerStorage.SmartPathTests).Phase8()          -- casos-limite + 500 agentes (~5 min)
--      require(game.ServerStorage.SmartPathTests).Phase8Soak(10)    -- 20 NPCs por N minutos (padrão 10)
-- Cada caso da checklist da Fase 8 é um teste reproduzível; o resultado inclui o que ficou documentado.

local PlayersService = game:GetService("Players")
local StatsService = game:GetService("Stats")

-- Conta erros que chegaram ao Output (o critério "nenhum caso gera erro não tratado").
local function captureErrors(): ({ string }, () -> ())
	local errors: { string } = {}
	local conn = LogService.MessageOut:Connect(function(message: string, kind: Enum.MessageType)
		if kind == Enum.MessageType.MessageError then
			table.insert(errors, message)
		end
	end)
	return errors, function()
		conn:Disconnect()
	end
end

-- Rig de verdade (R15 ou R6), criado a partir de uma HumanoidDescription vazia. Pode falhar sem rede:
-- devolve nil e o teste se declara pulado.
local function makeRealRig(area: Folder, groundPos: Vector3, rigType: Enum.HumanoidRigType): Model?
	local finished = false
	local model: Model? = nil
	task.spawn(function()
		local ok, result = pcall(function()
			return PlayersService:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), rigType)
		end)
		if ok then
			model = result :: Model
		end
		finished = true
	end)
	waitUntil(function()
		return finished
	end, 8)
	if not model then
		return nil
	end
	model.Name = "Real" .. rigType.Name
	model:PivotTo(CFrame.new(groundPos + Vector3.new(0, 4, 0)))
	model.Parent = area
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = humanoid and humanoid.RootPart
	if root then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
	local t0 = os.clock()
	while humanoid and humanoid.FloorMaterial == Enum.Material.Air and os.clock() - t0 < 4 do
		task.wait()
	end
	return model
end

local function skipped(name: string, why: string): boolean
	info(name, "PULADO — " .. why)
	return true
end

-- Chão liso de 120 x 40 (x de -60 a 60) para os casos que só precisam andar.
local function flatArena(area: Folder)
	addFloor(area, "Floor", 0, 0, 120, 40)
end

-- ----- 1. Personagem morre durante a rota e no ar -----

local function testDeathMidRoute(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local agent = newAgent(rig)
	local st = watch(agent)
	agent:MoveTo(TEST_ORIGIN + Vector3.new(40, 0, 0))
	task.wait(0.7)
	humanoidOf(rig).Health = 0
	local ok, reason, details = agent:Await()
	local done = waitUntil(function()
		return st.failed >= 1
	end, 2)
	agent:Destroy()
	return report(
		"Fase 8: morrer no meio da rota -> character_lost, sem erro",
		ok == false and reason == "character_lost" and done,
		string.format("Await: %s/%s, sinal Failed: %d (%s)", tostring(ok), tostring(reason), st.failed, describe(details))
	)
end

local function testDeathInAir(): boolean
	local area = newArea()
	local start, goal = buildMuretaCourse(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local humanoid = humanoidOf(rig)
	local original = humanoid.JumpHeight
	local agent = newAgent(rig)
	agent:MoveTo(goal)
	local airborne = waitUntil(function()
		return agent:GetState() == "Airborne"
	end, 25)
	humanoid.Health = 0
	local ok, reason = agent:Await()
	task.wait(0.4)
	local restored = humanoid.JumpHeight == original
	agent:Destroy()
	return report(
		"Fase 8: morrer no ar -> character_lost e o JumpHeight volta ao original",
		airborne and ok == false and reason == "character_lost" and restored,
		string.format("chegou a Airborne: %s, Await: %s/%s, JumpHeight restaurado: %s", tostring(airborne), tostring(ok), tostring(reason), tostring(restored))
	)
end

-- ----- 2. Personagem removido (Destroy) com agente ativo -----

local function testCharacterDestroyed(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local agent = newAgent(rig)
	local st = watch(agent)
	agent:MoveTo(TEST_ORIGIN + Vector3.new(40, 0, 0))
	task.wait(0.7)
	rig:Destroy()
	local ok, reason = agent:Await()
	local selfDestroyed = waitUntil(function()
		return agent._destroyed
	end, 3)
	local connections = agent:_liveConnectionCount()
	return report(
		"Fase 8: Destroy do personagem -> character_lost e o agente se destrói sozinho (0 conexões)",
		ok == false and reason == "character_lost" and st.failed == 1 and selfDestroyed and connections == 0,
		string.format("Await: %s/%s, Failed: %d, agente destruído: %s, conexões vivas: %d", tostring(ok), tostring(reason), st.failed, tostring(selfDestroyed), connections)
	)
end

-- ----- 3. WalkSpeed = 0 (e Seated) -----

local function testWalkSpeedZero(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local start = TEST_ORIGIN + Vector3.new(-40, 0, 0)
	local goal = TEST_ORIGIN + Vector3.new(40, 0, 0)
	local rig = makeRig(area, start)
	local humanoid = humanoidOf(rig)
	humanoid.WalkSpeed = 0
	local agent = newAgent(rig)
	local st = watch(agent)
	agent:MoveTo(goal)
	task.wait(8) -- mais que os ~5 s do anti-stuck: sem o guarda, já teria falhado com stuck
	local waitedOk = st.failed == 0 and st.reached == 0 and agent:GetState() == "Following"
	local moved = flatDist(rootOf(rig).Position, start)
	humanoid.WalkSpeed = 16
	local resumed = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 30)
	agent:Destroy()
	return report(
		"Fase 8: WalkSpeed 0 -> o agente espera (não vira stuck) e retoma quando a velocidade volta",
		waitedOk and moved < 1 and resumed and st.reached == 1,
		string.format("esperou sem falhar: %s (moveu %.1f), depois chegou: %s (%s)", tostring(waitedOk), moved, tostring(st.reached == 1), describeStatus(st))
	)
end

local function testWalkSpeedZeroTimeout(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	humanoidOf(rig).WalkSpeed = 0
	local tuning = AgentModule._tuning
	local saved = table.clone(tuning)
	tuning.TimeoutBase, tuning.TimeoutFactor = 3, 0.1
	local answered, ok, reason = moveOutcome(rig, TEST_ORIGIN + Vector3.new(40, 0, 0), nil, 20)
	tuning.TimeoutBase, tuning.TimeoutFactor = saved.TimeoutBase, saved.TimeoutFactor
	return report(
		"Fase 8: WalkSpeed 0 para sempre -> falha com timeout, não fica esperando eternamente",
		answered and ok == false and reason == "timeout",
		string.format("respondeu %s, motivo %s", tostring(answered), tostring(reason))
	)
end

local function testSeated(): boolean
	local area = newArea()
	flatArena(area)
	local seat = Instance.new("Seat")
	seat.Anchored = true
	seat.Size = Vector3.new(4, 1, 4)
	seat.Position = TEST_ORIGIN + Vector3.new(-40, 0.5, 0)
	seat.Parent = area
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-30, 0, 0))
	local humanoid = humanoidOf(rig)
	seat:Sit(humanoid)
	local sat = waitUntil(function()
		return humanoid.Sit
	end, 3)
	local goal = TEST_ORIGIN + Vector3.new(30, 0, 0)
	local agent = newAgent(rig)
	local st = watch(agent)
	agent:MoveTo(goal)
	task.wait(8)
	local waitedOk = st.failed == 0 and agent:GetState() == "Following"
	humanoid.Jump = true -- levanta do assento
	local stood = waitUntil(function()
		return not humanoid.Sit
	end, 4)
	local resumed = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 40)
	agent:Destroy()
	return report(
		"Fase 8: personagem sentado -> o agente espera (não vira stuck) e segue depois de levantar",
		sat and waitedOk and stood and resumed and st.reached == 1,
		string.format("sentou %s, esperou sem falhar %s, levantou %s, %s", tostring(sat), tostring(waitedOk), tostring(stood), describeStatus(st))
	)
end

-- ----- 4. JumpHeight = 0, UseJumpPower = true -----

local function testJumpHeightZero(): boolean
	-- percurso com passagem lateral pela mureta: chega sem saltar
	local area = newArea()
	local start, goal = buildCourse(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local humanoid = humanoidOf(rig)
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = 0
	local agent = newAgent(rig)
	local st = watch(agent)
	agent:MoveTo(goal)
	local done = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 70)
	local route, why = SmartPath.GetRoute(rig, goal, baseOptions() :: any)
	local hasJump = false
	for _, wp in ipairs(route or {}) do
		if wp.SmartAction == "Jump" then
			hasJump = true
		end
	end
	agent:Destroy()
	local first = report(
		"Fase 8: JumpHeight 0 -> a rota não tem saltos e o agente chega pelo desvio",
		done and st.reached == 1 and st.jumps == 0 and route ~= nil and not hasJump,
		string.format("%s; saltos %d; GetRoute com salto: %s (%s)", describeStatus(st), st.jumps, tostring(hasJump), tostring(why))
	)

	-- mureta sem passagem: sem salto, falha com código conhecido
	local area2 = newArea()
	local start2, goal2 = buildMuretaCourse(area2)
	task.wait(NAVMESH_SETTLE)
	local rig2 = makeRig(area2, start2)
	local h2 = humanoidOf(rig2)
	h2.UseJumpPower = false
	h2.JumpHeight = 0
	local answered, ok, reason = moveOutcome(rig2, goal2, nil, 40)
	local second = report(
		"Fase 8: JumpHeight 0 diante de uma mureta sem passagem -> falha com código conhecido",
		answered and ok == false and (reason == "no_path" or reason == "obstacle_too_tall"),
		string.format("respondeu %s, motivo %s", tostring(answered), tostring(reason))
	)
	return first and second
end

local function testUseJumpPower(): boolean
	local area = newArea()
	local start, goal = buildMuretaCourse(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local humanoid = humanoidOf(rig)
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 50
	local agent = newAgent(rig)
	local st = watch(agent)
	agent:MoveTo(goal)
	local done = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 40)
	local powerAfter = humanoid.JumpPower
	agent:Destroy()
	return report(
		"Fase 8: UseJumpPower = true -> salta a mureta e o JumpPower volta ao original",
		done and st.reached == 1 and st.jumps >= 1 and powerAfter == 50,
		string.format("%s; JumpPower depois: %s", describeStatus(st), tostring(powerAfter))
	)
end

-- ----- 5. R6 e R15 reais, sem nenhuma opção -----

local function testRigType(rigType: Enum.HumanoidRigType): boolean
	local name = "Fase 8: rig " .. rigType.Name .. " real, zero configuração, salta a mureta e chega"
	local area = newArea()
	local start, goal = buildMuretaCourse(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRealRig(area, start, rigType)
	if not rig then
		return skipped(name, "não foi possível criar o rig (CreateHumanoidModelFromDescription falhou)")
	end
	local derived = Config.resolve(rig)
	local finished, res = runWithTimeout(50, function()
		return SmartPath.MoveTo(rig, goal) -- nenhuma opção: raio, altura e salto vêm do próprio rig
	end)
	return report(
		name,
		finished and res[1] == true,
		string.format(
			"raio derivado %.2f, altura %.2f, salto máximo %.1f; resultado %s/%s",
			derived.Agent.Radius,
			derived.Agent.Height,
			(derived.Jump.MaxHeight :: number),
			tostring(finished and res[1]),
			tostring(finished and res[2])
		)
	)
end

-- ----- 6. Destino igual à posição, destino a 5000 studs, NaN -----

local function testDestinationSameAsPosition(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(0, 0, 0))
	local root = rootOf(rig)
	local t0 = os.clock()
	local a1, ok1 = moveOutcome(rig, root.Position, {}, 10)
	local e1 = os.clock() - t0
	local a2, ok2 = moveOutcome(rig, root.Position + Vector3.new(0.6, 0, 0.3), {}, 10)
	local finished3, res3 = runWithTimeout(10, function()
		return SmartPath.MoveTo(rig, root) -- o próprio personagem como destino
	end)
	local route, why = SmartPath.GetRoute(rig, root.Position, baseOptions() :: any)
	return report(
		"Fase 8: destino igual à posição (Vector3, quase igual e o próprio personagem) -> chega na hora, sem erro",
		a1 and ok1 == true and e1 < 2 and a2 and ok2 == true and finished3 and res3[1] == true,
		string.format(
			"igual: %s em %.2fs; a 0.7: %s; o próprio root: %s; GetRoute: %s",
			tostring(ok1),
			e1,
			tostring(ok2),
			tostring(finished3 and res3[1]),
			route and (#route .. " waypoints") or tostring(why)
		)
	)
end

local function testNonFiniteDestination(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local answered, ok, reason = moveOutcome(rig, Vector3.new(0 / 0, 0, 0), {}, 10)
	local a2, ok2, reason2 = moveOutcome(rig, Vector3.new(math.huge, 0, 0), {}, 10)
	return report(
		"Fase 8: destino NaN ou infinito -> goal_unreachable, sem propagar NaN",
		answered and ok == false and reason == "goal_unreachable" and a2 and ok2 == false and reason2 == "goal_unreachable",
		string.format("NaN: %s, infinito: %s", tostring(reason), tostring(reason2))
	)
end

local function testFarDestination(): boolean
	local area = newArea()
	flatArena(area)
	-- uma ilha a 5000 studs, sem ligação com o resto
	addFloor(area, "FarIsland", 5000, 0, 60, 60)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local t0 = os.clock()
	local a1, ok1, reason1 = moveOutcome(rig, TEST_ORIGIN + Vector3.new(5000, 0, 0), {}, 40) -- ilha sem ligação
	local e1 = os.clock() - t0
	t0 = os.clock()
	local a2, ok2, reason2 = moveOutcome(rig, TEST_ORIGIN + Vector3.new(5000, 0, 800), {}, 40) -- vazio
	local e2 = os.clock() - t0
	return report(
		"Fase 8: destino a 5000 studs -> no_path (ilha sem ligação) ou goal_unreachable (vazio), rápido e sem erro",
		a1 and ok1 == false and reason1 == "no_path" and a2 and ok2 == false and reason2 == "goal_unreachable",
		string.format("ilha: %s em %.1fs; vazio: %s em %.1fs", tostring(reason1), e1, tostring(reason2), e2)
	)
end

-- ----- 7. Sem nenhum chão sob o agente -----

local function testNoGround(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(0, 0, 0))
	local root = rootOf(rig)
	root.Anchored = true -- parado no vazio, sem cair até a morte durante o teste
	rig:PivotTo(CFrame.new(TEST_ORIGIN + Vector3.new(0, 300, 0)))
	task.wait(0.3)
	local t0 = os.clock()
	local answered, ok, reason, details = moveOutcome(rig, TEST_ORIGIN + Vector3.new(40, 0, 0), {}, 20)
	local elapsed = os.clock() - t0
	local clean, text = explainClean(reason, details)
	info("explain (sem chão)", text)
	return report(
		"Fase 8: sem chão sob o agente -> no_path com noGround, em poucos segundos",
		answered and ok == false and reason == "no_path" and details ~= nil and details.noGround == true and elapsed < 6 and clean,
		string.format("motivo %s em %.1fs, %s", tostring(reason), elapsed, describe(details))
	)
end

-- ----- 8. workspace.Gravity alterado -----

local function testGravity(): boolean
	local original = workspace.Gravity
	local results = {}
	for _, g in ipairs({ 60, 400 }) do
		workspace.Gravity = g
		local area = newArea()
		local start, goal = buildMuretaCourse(area)
		task.wait(NAVMESH_SETTLE)
		local rig = makeRig(area, start)
		local agent = newAgent(rig)
		local st = watch(agent)
		agent:MoveTo(goal)
		local done = waitUntil(function()
			return st.reached > 0 or st.failed > 0
		end, 45)
		table.insert(results, string.format("g=%d: %s (saltos %d)", g, if done and st.reached == 1 then "chegou" else describeStatus(st), st.jumps))
		agent:Destroy()
		cleanupArea()
		if not (done and st.reached == 1) then
			workspace.Gravity = original
			return report("Fase 8: gravidade alterada (60 e 400) -> salta e chega", false, table.concat(results, "; "))
		end
	end
	workspace.Gravity = original
	return report("Fase 8: gravidade alterada (60 e 400) -> salta e chega", true, table.concat(results, "; "))
end

-- ----- 9. Dois agentes no mesmo personagem -----

local function testTwoAgents(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local first = SmartPath.new(rig, baseOptions() :: any)
	local okSecond, message = pcall(function()
		return SmartPath.new(rig)
	end)
	local shared = SmartPath.MoveToAsync(rig, TEST_ORIGIN + Vector3.new(-20, 0, 0)) -- nível 0 reaproveita
	local reused = shared == first
	first:Stop()
	first:Destroy()
	local okThird, third = pcall(function()
		return SmartPath.new(rig)
	end)
	if okThird then
		(third :: any):Destroy()
	end
	local clear = not okSecond and string.find(tostring(message), "já existe um agente", 1, true) ~= nil
	return report(
		"Fase 8: dois agentes no mesmo personagem -> SmartPath.new dá erro claro; MoveTo reaproveita; depois de Destroy pode criar de novo",
		clear and reused and okThird,
		string.format("segundo new: %s (%s), MoveTo reaproveitou: %s, new depois do Destroy: %s", if okSecond then "criou (ruim)" else "erro", tostring(message), tostring(reused), tostring(okThird))
	)
end

-- ----- 10. MoveTo dentro de Reached e de Failed -----

local function testReentrancy(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local agent = newAgent(rig)
	local legs = { TEST_ORIGIN + Vector3.new(-10, 0, 10), TEST_ORIGIN + Vector3.new(20, 0, -10), TEST_ORIGIN + Vector3.new(45, 0, 5) }
	local reached = 0
	agent.Reached:Connect(function()
		reached += 1
		if legs[reached + 1] then
			agent:MoveTo(legs[reached + 1]) -- MoveTo dentro do handler de Reached
		end
	end)
	agent:MoveTo(legs[1])
	local chained = waitUntil(function()
		return reached >= 3
	end, 60)
	local finalDist = flatDist(rootOf(rig).Position, legs[3])

	-- e dentro de Failed: destino impossível, depois um possível
	local failedCount = 0
	local recovered = 0
	agent.Failed:Connect(function()
		failedCount += 1
		if failedCount == 1 then
			agent:MoveTo(TEST_ORIGIN + Vector3.new(0, 0, 0))
		end
	end)
	agent.Reached:Connect(function()
		if failedCount == 1 then
			recovered += 1
		end
	end)
	agent:MoveTo(TEST_ORIGIN + Vector3.new(0, 3, 0) + Vector3.new(4000, 0, 0)) -- no vazio
	local recoveredOk = waitUntil(function()
		return recovered >= 1
	end, 40)
	agent:Destroy()
	return report(
		"Fase 8: MoveTo dentro de Reached (3 trechos encadeados) e dentro de Failed",
		chained and finalDist < 4 and failedCount == 1 and recoveredOk,
		string.format("Reached: %d, a %.1f do último destino; Failed: %d, recuperou: %s", reached, finalDist, failedCount, tostring(recoveredOk))
	)
end

-- ----- 11. StreamingEnabled (região sem geometria) -----

local function testStreamingRegion(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	-- uma região que ainda não chegou ao cliente é, para o solver, um destino sem chão
	local answered, ok, reason, details = moveOutcome(rig, TEST_ORIGIN + Vector3.new(0, 0, 400), {}, 20)
	local streaming = workspace.StreamingEnabled
	return report(
		"Fase 8: destino em região sem geometria carregada -> goal_unreachable, sem erro (no cliente com StreamingEnabled pede o stream antes)",
		answered and ok == false and reason == "goal_unreachable",
		string.format("motivo %s; StreamingEnabled neste place: %s (o pedido RequestStreamAroundAsync só roda no cliente: [VALIDAR]); %s", tostring(reason), tostring(streaming), describe(details))
	)
end

-- ----- 12. Vazamento: 500 agentes -----

local function instanceCount(): number
	local ok, n = pcall(function()
		return StatsService.InstanceCount
	end)
	if ok then
		return n :: number
	end
	return #game:GetDescendants()
end

local function lowestMemoryKb(readings: number): number
	local lowest = math.huge
	for _ = 1, readings do
		lowest = math.min(lowest, gcinfo())
		task.wait(0.5)
	end
	return lowest
end

-- Quantos dos agentes guardados (por referência fraca) ainda existem depois do coletor. Cada leitura
-- de memória do Lua (gcinfo) varia alguns MB conforme o ponto do ciclo do coletor em que cai, então
-- ela não serve de critério (a mesma corrida deu -2 MB e +4.9 MB); reter agentes, que é o vazamento
-- que importa, aparece aqui como ~500 sobreviventes. Gera lixo a cada passo para o coletor andar.
local function survivorsAfterCollection(weak: { [number]: any }, total: number, tolerated: number): number
	local function count(): number
		local n = 0
		for i = 1, total do
			if weak[i] ~= nil then
				n += 1
			end
		end
		return n
	end
	waitUntil(function()
		return count() <= tolerated
	end, 30, function()
		local garbage = {}
		for i = 1, 2000 do
			garbage[i] = { i }
		end
	end)
	return count()
end

local function testLeak500(): boolean
	local area = newArea()
	flatArena(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-40, 0, 0))
	local goal = TEST_ORIGIN + Vector3.new(40, 0, 0)
	-- aquecimento: cria caches e módulos preguiçosos antes de medir
	for _ = 1, 10 do
		SmartPath.new(rig, baseOptions() :: any):Destroy()
	end
	task.wait(1)
	local memBefore = lowestMemoryKb(4)
	local instancesBefore = instanceCount()
	local mbBefore = StatsService:GetTotalMemoryUsageMb()

	local total = 500
	local weak: { [number]: any } = setmetatable({}, { __mode = "v" }) :: any
	for i = 1, total do
		local agent = SmartPath.new(rig, baseOptions() :: any)
		weak[i] = agent
		if i % 4 == 0 then
			agent:MoveTo(goal) -- destruir com um cálculo de rota em andamento
			task.wait()
		end
		agent:Destroy()
		if i % 50 == 0 then
			task.wait(0.1)
		end
	end
	-- o registro guarda o agente mais recente do Humanoid; criar e destruir mais um solta o anterior
	SmartPath.new(rig, baseOptions() :: any):Destroy()
	-- deixa terminar os cálculos pendentes dos agentes já destruídos
	waitUntil(function()
		return SmartPath.Scheduler.getQueueLength() == 0
	end, 20)
	task.wait(1)
	local survivors = survivorsAfterCollection(weak, total, 3)
	local memAfter = lowestMemoryKb(6)
	local instancesAfter = instanceCount()
	local mbAfter = StatsService:GetTotalMemoryUsageMb()
	local queue = SmartPath.Scheduler.getQueueLength()
	local growthKb = memAfter - memBefore
	return report(
		"Fase 8: criar e destruir 500 agentes (parte deles com cálculo em andamento) não vaza",
		survivors <= 3 and growthKb < 20480 and instancesAfter - instancesBefore <= 5 and queue == 0,
		string.format(
			"agentes ainda vivos depois do coletor: %d de %d; memória do Lua %.0f -> %.0f KB (%+.0f KB, só limite grosseiro de 20 MB: varia com o coletor); memória total %.1f -> %.1f MB; instâncias %d -> %d; fila do Scheduler %d",
			survivors,
			total,
			memBefore,
			memAfter,
			growthKb,
			mbBefore,
			mbAfter,
			instancesBefore,
			instancesAfter,
			queue
		)
	)
end

function Tests.Phase8(): boolean
	print("[SmartPathTests] ==== Fase 8: endurecimento ====")
	local errors, stopCapture = captureErrors()
	local results = {
		safe("morrer na rota", testDeathMidRoute),
		safe("morrer no ar", testDeathInAir),
		safe("personagem removido", testCharacterDestroyed),
		safe("WalkSpeed 0", testWalkSpeedZero),
		safe("WalkSpeed 0 com timeout", testWalkSpeedZeroTimeout),
		safe("sentado", testSeated),
		safe("JumpHeight 0", testJumpHeightZero),
		safe("UseJumpPower", testUseJumpPower),
		safe("rig R15 real", function()
			return testRigType(Enum.HumanoidRigType.R15)
		end),
		safe("rig R6 real", function()
			return testRigType(Enum.HumanoidRigType.R6)
		end),
		safe("destino igual à posição", testDestinationSameAsPosition),
		safe("destino NaN", testNonFiniteDestination),
		safe("destino a 5000 studs", testFarDestination),
		safe("sem chão", testNoGround),
		safe("gravidade", testGravity),
		safe("dois agentes", testTwoAgents),
		safe("reentrância", testReentrancy),
		safe("StreamingEnabled", testStreamingRegion),
		safe("500 agentes", testLeak500),
	}
	task.wait(0.5)
	stopCapture()
	local noErrors = report(
		"Fase 8: nenhum erro não tratado chegou ao Output durante os casos-limite",
		#errors == 0,
		if #errors == 0 then "0 erros" else string.format("%d erros; o primeiro: %s", #errors, errors[1])
	)
	local allOk = noErrors
	for _, ok in ipairs(results) do
		allOk = allOk and ok
	end
	print("[SmartPathTests] ==== Resultado: " .. (allOk and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return allOk
end

-- ----- 13. Soak: 20 NPCs por N minutos -----

local SOAK_NPCS = 20
local SOAK_SAMPLE_INTERVAL = 30

function Tests.Phase8Soak(minutes: number?): boolean
	local duration = (minutes or 10) * 60
	print(string.format("[SmartPathTests] ==== Fase 8 (soak): %d NPCs por %.0f min ====", SOAK_NPCS, duration / 60))
	local errors, stopCapture = captureErrors()
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 60)
	for i, p in ipairs({ Vector3.new(-25, 4, -14), Vector3.new(-25, 4, 14), Vector3.new(-5, 4, 0), Vector3.new(15, 4, -14), Vector3.new(15, 4, 14) }) do
		addBlock(area, "Pillar" .. i, p, Vector3.new(4, 8, 4))
	end
	task.wait(NAVMESH_SETTLE)

	-- Rigs mínimos (uma caixa 2x2x1) que se sobrepõem são lançados para cima pela resolução de colisão da
	-- física (visto no primeiro soak: NPCs voando e caindo, ~14% de falhas). O soak mede memória, não
	-- multidão, então os rigs não colidem entre si (grupo próprio, restaurado no fim).
	local groupName = "SmartPathSoakNPCs"
	local PhysicsServiceForSoak = game:GetService("PhysicsService")
	pcall(function()
		PhysicsServiceForSoak:RegisterCollisionGroup(groupName)
	end)
	pcall(function()
		PhysicsServiceForSoak:CollisionGroupSetCollidable(groupName, groupName, false)
	end)

	local rigs: { Model } = {}
	for i = 1, SOAK_NPCS do
		local z = -25 + (i - 1) * (50 / (SOAK_NPCS - 1))
		local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-50, 0, z))
		for _, d in ipairs(rig:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CollisionGroup = groupName
			end
		end
		table.insert(rigs, rig)
	end

	local running = true
	local legsOk, legsFail = 0, 0
	local failReasons: { [string]: number } = {}
	local rng = Random.new(20)
	for i, rig in ipairs(rigs) do
		local west = i % 2 == 0
		task.spawn(function()
			while running do
				west = not west
				local x = if west then -rng:NextNumber(38, 52) else rng:NextNumber(38, 52)
				local goal = TEST_ORIGIN + Vector3.new(x, 0, rng:NextNumber(-24, 24))
				local agent = SmartPath.MoveToAsync(rig, goal, baseOptions() :: any)
				local ok, reason = agent:Await()
				if not running then
					break
				end
				if ok then
					legsOk += 1
				else
					legsFail += 1
					failReasons[tostring(reason)] = (failReasons[tostring(reason)] or 0) + 1
					task.wait(0.5)
				end
			end
		end)
	end

	local samples: { { t: number, lua: number, mb: number, instances: number } } = {}
	local t0 = os.clock()
	local nextSample = 0
	while os.clock() - t0 < duration do
		if os.clock() - t0 >= nextSample then
			nextSample += SOAK_SAMPLE_INTERVAL
			local sample = {
				t = os.clock() - t0,
				lua = gcinfo(),
				mb = StatsService:GetTotalMemoryUsageMb(),
				instances = instanceCount(),
			}
			table.insert(samples, sample)
			print(
				string.format(
					"[SmartPathTests] soak %4.0fs: memória do Lua %.0f KB, total %.1f MB, instâncias %d, trechos %d ok / %d falhas",
					sample.t,
					sample.lua,
					sample.mb,
					sample.instances,
					legsOk,
					legsFail
				)
			)
		end
		task.wait(1)
	end
	running = false
	task.wait(1)
	stopCapture()

	-- compara a média das 3 primeiras amostras depois do aquecimento com a das 3 últimas
	local function avg(from: number, to: number, key: string): number
		local sum, n = 0, 0
		for i = from, to do
			local s = samples[i]
			if s then
				sum += (s :: any)[key]
				n += 1
			end
		end
		return if n > 0 then sum / n else 0
	end
	local firstFrom = math.min(3, #samples)
	local firstTo = math.min(5, #samples)
	local lastFrom = math.max(#samples - 2, 1)
	local luaGrowth = avg(lastFrom, #samples, "lua") - avg(firstFrom, firstTo, "lua")
	local mbGrowth = avg(lastFrom, #samples, "mb") - avg(firstFrom, firstTo, "mb")
	local instanceGrowth = avg(lastFrom, #samples, "instances") - avg(firstFrom, firstTo, "instances")
	local stable = #samples >= 4 and luaGrowth < 2048 and instanceGrowth < 60
	local reasonParts = {}
	for reason, count in pairs(failReasons) do
		table.insert(reasonParts, string.format("%s %d", reason, count))
	end
	table.sort(reasonParts)
	info("motivos das falhas do soak", if #reasonParts > 0 then table.concat(reasonParts, ", ") else "nenhuma")
	cleanupArea()
	local ok = report(
		string.format("Fase 8: %d NPCs por %.0f minutos, memória estável", SOAK_NPCS, duration / 60),
		stable and legsOk > 0 and #errors == 0,
		string.format(
			"memória do Lua %+.0f KB, total %+.1f MB, instâncias %+.0f entre o início e o fim; trechos %d ok / %d falhas; erros no Output: %d",
			luaGrowth,
			mbGrowth,
			instanceGrowth,
			legsOk,
			legsFail,
			#errors
		)
	)
	print("[SmartPathTests] ==== Resultado: " .. (ok and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return ok
end

-- ===================== Curvas (Stability.Curves) =====================
-- Uso: require(game.ServerStorage.SmartPathTests).Curves()
-- A opção é aditiva e desligada por padrão (D-035): estes testes provam as duas coisas, que o padrão não
-- mudou e que, ligada, a trajetória é mais suave sem quebrar saltos, corredores nem GetRoute.

-- Curves(true) liga o Debug dos agentes (rota, raio, saltos) e desenha o rastro de cada trajetória, para
-- VER a diferença. Sem o argumento, nada é desenhado.
local curvesDebug = false

local function curveOptions(extra: { [string]: any }?): { [string]: any }?
	if not curvesDebug then
		return extra
	end
	local merged: { [string]: any } = {}
	for k, v in pairs(extra or {}) do
		merged[k] = v
	end
	merged.Debug = true
	return merged
end

-- pausa para olhar o resultado antes de o cenário ser apagado (só com o debug ligado)
local function lookPause(seconds: number)
	if curvesDebug then
		task.wait(seconds)
	end
end

-- Só com o debug ligado: redesenha a rota com vida longa. O Debug da biblioteca a desenha ao adotar a rota e a
-- apaga em 6 s, e um teste dura mais que isso; sem esta chamada o rastro do NPC ficaria sem os nós da rota.
local function showRoute(rig: Model, goal: Vector3)
	if not curvesDebug then
		return
	end
	local route = SmartPath.GetRoute(rig, goal, baseOptions() :: any)
	if route then
		SmartPath.Debug.route(route, 60)
	end
end

-- Só com o debug ligado: desenha o rastro do NPC (um ponto a cada 0.1 s) enquanto ele anda. Devolve a função
-- que para o desenho.
local function startTrail(rig: Model, color: Color3): () -> ()
	if not curvesDebug then
		return function() end
	end
	local root = rootOf(rig)
	local last = 0
	local conn = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - last >= 0.1 then
			last = now
			SmartPath.Debug.point(root.Position - Vector3.new(0, 2.6, 0), color, 0.5, 60)
		end
	end)
	return function()
		conn:Disconnect()
	end
end

-- Uma parede alta com a volta só por um lado: a rota tem dois cantos de ~65 graus.
local function buildBendCourse(area: Folder): (Vector3, Vector3)
	addFloor(area, "Floor", 0, 0, 120, 60)
	addBlock(area, "Wall", Vector3.new(0, 5, -10), Vector3.new(2, 10, 40)) -- z de -30 a 10
	return TEST_ORIGIN + Vector3.new(-25, 0, -18), TEST_ORIGIN + Vector3.new(25, 0, -18)
end

type Trace = {
	reached: boolean,
	failed: boolean,
	maxTurn: number, -- maior mudança de direção entre amostras de 0.1 s (graus)
	smoothTurn: number, -- o mesmo, com a direção medida em blocos de 0.4 s (menos sensível a ruído)
	cornerCut: number, -- o quanto a trajetória se afasta, no máximo, dos cantos da rota (studs)
	length: number,
	seconds: number,
	jumps: number,
	trail: string,
}

local function flatVec(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Anda até `goal` amostrando a posição a cada 0.1 s. `route` (opcional) são os waypoints da rota, para medir
-- o quanto a trajetória corta os cantos: para cada canto interior, a menor distância que o NPC chegou dele;
-- `cornerCut` é a maior dessas. Uma trajetória reta passa a ~1 stud dos cantos (o raio de chegada é 1.25);
-- uma trajetória em curva os corta, e fica mais longe.
local function traceRun(
	rig: Model,
	goal: Vector3,
	options: { [string]: any }?,
	trail: Color3?,
	route: { any }?
): Trace
	showRoute(rig, goal)
	local agent = newAgent(rig, curveOptions(options))
	local st = watch(agent)
	local root = rootOf(rig)
	local samples: { Vector3 } = { root.Position }
	local last = os.clock()
	local t0 = last
	agent:MoveTo(goal)
	waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 60, function()
		local now = os.clock()
		if now - last >= 0.1 then
			last = now
			table.insert(samples, root.Position)
			if curvesDebug and trail then
				SmartPath.Debug.point(root.Position - Vector3.new(0, 2.6, 0), trail, 0.5, 40)
			end
		end
	end)
	local seconds = os.clock() - t0
	agent:Destroy()

	local maxTurn, length = 0, 0
	local prevHeading: Vector3? = nil
	local prevPos = samples[1]
	local moving: { Vector3 } = { samples[1] }
	for i = 2, #samples do
		local d = flatVec(samples[i] - prevPos)
		if d.Magnitude > 0.5 then
			length += d.Magnitude
			local heading = d.Unit
			if prevHeading then
				maxTurn = math.max(maxTurn, math.deg(math.acos(math.clamp(heading:Dot(prevHeading), -1, 1))))
			end
			prevHeading = heading
			prevPos = samples[i]
			table.insert(moving, samples[i])
		end
	end

	-- direção em blocos de 0.4 s (4 amostras), com passo de 2
	local smoothTurn = 0
	local blockHeadings: { Vector3 } = {}
	for i = 1, #moving - 4, 2 do
		local d = flatVec(moving[i + 4] - moving[i])
		if d.Magnitude > 1 then
			table.insert(blockHeadings, d.Unit)
		end
	end
	for i = 2, #blockHeadings do
		smoothTurn = math.max(smoothTurn, math.deg(math.acos(math.clamp(blockHeadings[i]:Dot(blockHeadings[i - 1]), -1, 1))))
	end

	local cornerCut = 0
	if route then
		for i = 2, #route - 1 do
			local nearest = math.huge
			for _, sample in ipairs(samples) do
				nearest = math.min(nearest, flatVec(sample - (route[i] :: any).Position).Magnitude)
			end
			cornerCut = math.max(cornerCut, nearest)
		end
	end

	local parts = {}
	for i, sample in ipairs(samples) do
		if i % 2 == 1 then
			table.insert(parts, string.format("(%.0f,%.0f)", sample.X - TEST_ORIGIN.X, sample.Z - TEST_ORIGIN.Z))
		end
	end
	return {
		reached = st.reached > 0,
		failed = st.failed > 0,
		maxTurn = maxTurn,
		smoothTurn = smoothTurn,
		cornerCut = cornerCut,
		length = length,
		seconds = seconds,
		jumps = st.jumps,
		trail = table.concat(parts, " "),
	}
end

local function testCurvesDefaultOff(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 40, 40)
	local rig = makeRig(area, TEST_ORIGIN)
	local default = Config.resolve(rig).Stability.Curves
	local explicitOff = Config.resolve(rig, { Stability = { Curves = false } } :: any).Stability.Curves
	local on = Config.resolve(rig, { Stability = { Curves = true } } :: any).Stability.Curves
	local partial = Config.resolve(rig, { Stability = { Cache = false } } :: any).Stability.Curves -- outro campo de Stability não liga
	return report(
		"Curvas: desligadas por padrão; só Stability.Curves = true as liga",
		default == false and explicitOff == false and on == true and partial == false,
		string.format("padrão %s, false %s, true %s, só outro campo de Stability %s", tostring(default), tostring(explicitOff), tostring(on), tostring(partial))
	)
end

local function testCurvesSmoother(): boolean
	local area = newArea()
	local start, goal = buildBendCourse(area)
	task.wait(NAVMESH_SETTLE)

	local rigA = makeRig(area, start)
	local route = SmartPath.GetRoute(rigA, goal, baseOptions() :: any)
	local straight = traceRun(rigA, goal, nil, Color3.fromRGB(255, 70, 70), route) -- rastro vermelho: reta
	rigA:Destroy()
	task.wait(0.3)
	local rigB = makeRig(area, start)
	local curved = traceRun(rigB, goal, { Stability = { Curves = true } }, Color3.fromRGB(70, 255, 90), route) -- verde: curva
	lookPause(4)

	if route then
		local corners = {}
		for i = 2, #route - 1 do
			table.insert(corners, string.format("(%.0f,%.0f)", route[i].Position.X - TEST_ORIGIN.X, route[i].Position.Z - TEST_ORIGIN.Z))
		end
		info("Curvas: cantos da rota", table.concat(corners, " "))
	end
	info("Curvas: trilha da reta", straight.trail)
	info("Curvas: trilha da curva", curved.trail)

	local ok = straight.reached
		and curved.reached
		and curved.length <= straight.length + 1
		and curved.cornerCut >= straight.cornerCut + 0.5
	return report(
		"Curvas: com Curves a trajetória corta os cantos da rota e não fica mais longa",
		ok,
		string.format(
			"afastamento máximo dos cantos: reta %.1f, curva %.1f studs; distância: reta %.1f, curva %.1f; mudança de direção por amostra (0.1 s): reta %.0f, curva %.0f graus; por bloco (0.4 s): reta %.0f, curva %.0f graus; tempo: reta %.1fs, curva %.1fs",
			straight.cornerCut,
			curved.cornerCut,
			straight.length,
			curved.length,
			straight.maxTurn,
			curved.maxTurn,
			straight.smoothTurn,
			curved.smoothTurn,
			straight.seconds,
			curved.seconds
		)
	)
end

local function testCurvesKeepJumpsAndRamp(): boolean
	local area = newArea()
	local start, goal = buildCourse(area) -- corredor, mureta (com passagem), rampa e plataforma
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local result = traceRun(rig, goal, { Stability = { Curves = true } }, Color3.fromRGB(70, 255, 90))
	local dist = flatDist(rootOf(rig).Position, goal)
	lookPause(3)
	return report(
		"Curvas: percurso completo (corredor, mureta, rampa) chega ao destino",
		result.reached and not result.failed and dist < 3,
		string.format("chegou %s em %.1fs, a %.1f do destino, saltos %d, maior mudança de direção %.0f graus", tostring(result.reached), result.seconds, dist, result.jumps, result.maxTurn)
	)
end

local function testCurvesJumpExact(): boolean
	-- mureta sem passagem: a única saída é saltar, e a decolagem tem de acontecer no ponto certo
	local area = newArea()
	local start, goal = buildMuretaCourse(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	local result = traceRun(rig, goal, { Stability = { Curves = true } }, Color3.fromRGB(70, 255, 90))
	lookPause(3)
	return report(
		"Curvas: com salto obrigatório (mureta sem passagem) ainda salta e chega",
		result.reached and result.jumps >= 1,
		string.format("chegou %s, saltos %d, %.1fs", tostring(result.reached), result.jumps, result.seconds)
	)
end

local function testCurvesTightCorridor(): boolean
	local area = newArea()
	addFloor(area, "Floor", 0, 0, 120, 60)
	addBlock(area, "CorridorNorth", Vector3.new(0, 6, 16), Vector3.new(30, 12, 28)) -- corredor de 4 studs
	addBlock(area, "CorridorSouth", Vector3.new(0, 6, -16), Vector3.new(30, 12, 28))
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, TEST_ORIGIN + Vector3.new(-45, 0, 18))
	local goal = TEST_ORIGIN + Vector3.new(45, 0, -18)
	showRoute(rig, goal)
	local stopTrail = startTrail(rig, Color3.fromRGB(70, 255, 90))
	local agent = newAgent(rig, curveOptions({ Stability = { Curves = true } }))
	local st = watch(agent)
	agent:MoveTo(goal)
	local done = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 60)
	local dist = flatDist(rootOf(rig).Position, goal)
	stopTrail()
	lookPause(3)
	agent:Destroy()
	return report(
		"Curvas: corredor de 4 studs com entrada e saída fora do eixo, sem travar nem cortar parede",
		done and st.reached == 1 and st.blocked == 0 and dist < 3,
		describeStatus(st, string.format("a %.1f do destino", dist))
	)
end

local function testCurvesRouteUnchanged(): boolean
	local area = newArea()
	local start, goal = buildBendCourse(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	showRoute(rig, goal)
	local plain = SmartPath.GetRoute(rig, goal, baseOptions() :: any)
	local curved = SmartPath.GetRoute(rig, goal, baseOptions({ Stability = { Curves = true } }) :: any)
	lookPause(3)
	local same = plain ~= nil and curved ~= nil and #plain == #curved
	if same then
		for i, wp in ipairs(plain :: { any }) do
			if ((curved :: { any })[i].Position - wp.Position).Magnitude > 1e-3 then
				same = false
			end
		end
	end
	return report(
		"Curvas: GetRoute devolve os mesmos waypoints com e sem Curves (a curva é só como o agente segue)",
		same,
		string.format("sem: %s waypoints, com: %s waypoints", if plain then tostring(#plain) else "nil", if curved then tostring(#curved) else "nil")
	)
end

local function testCurvesToggleAtRuntime(): boolean
	local area = newArea()
	local start, goal = buildBendCourse(area)
	task.wait(NAVMESH_SETTLE)
	local rig = makeRig(area, start)
	showRoute(rig, goal)
	local stopTrail = startTrail(rig, Color3.fromRGB(70, 255, 90))
	local agent = newAgent(rig, curveOptions(nil))
	local before = agent.Options.Stability.Curves
	agent:SetOptions({ Stability = { Curves = true } })
	local on = agent.Options.Stability.Curves
	local st = watch(agent)
	agent:MoveTo(goal)
	local done = waitUntil(function()
		return st.reached > 0 or st.failed > 0
	end, 60)
	agent:SetOptions({ Stability = { Curves = false } })
	local off = agent.Options.Stability.Curves
	stopTrail()
	lookPause(3)
	agent:Destroy()
	return report(
		"Curvas: SetOptions liga e desliga em tempo de execução e o agente chega",
		before == false and on == true and off == false and done and st.reached == 1,
		string.format("antes %s, depois de ligar %s, depois de desligar %s; %s", tostring(before), tostring(on), tostring(off), describeStatus(st))
	)
end

-- Cada teste começa e termina com a pasta de debug vazia: o que um teste desenha não aparece no seguinte.
local function scoped(name: string, fn: () -> boolean): boolean
	return safe(name, function()
		SmartPath.Debug.clear()
		local ok, result = pcall(fn)
		SmartPath.Debug.clear()
		if not ok then
			error(result, 0)
		end
		return result
	end)
end

function Tests.Curves(debug: boolean?): boolean
	curvesDebug = debug == true
	print("[SmartPathTests] ==== Curvas: Stability.Curves" .. (if curvesDebug then " (com debug: rota, raio e rastros)" else "") .. " ====")
	local results = {
		scoped("padrão desligado", testCurvesDefaultOff),
		scoped("trajetória mais suave", testCurvesSmoother),
		scoped("percurso completo", testCurvesKeepJumpsAndRamp),
		scoped("salto obrigatório", testCurvesJumpExact),
		scoped("corredor apertado", testCurvesTightCorridor),
		scoped("GetRoute igual", testCurvesRouteUnchanged),
		scoped("liga e desliga", testCurvesToggleAtRuntime),
	}
	curvesDebug = false
	local allOk = true
	for _, ok in ipairs(results) do
		allOk = allOk and ok
	end
	print("[SmartPathTests] ==== Resultado: " .. (allOk and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return allOk
end

return Tests
