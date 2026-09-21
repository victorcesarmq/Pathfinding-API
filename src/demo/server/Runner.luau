--!strict
-- Runner.luau
-- Monta os cenários (uma "célula" por cenário, com a pista do PathfindingService puro à esquerda e a
-- da SmartPath à direita), roda os dois NPCs, conta sucessos e falhas, e publica o estado para o HUD.
--
-- Uma célula reinicia do zero: um "token" invalida qualquer NPC/thread da rodada anterior, a
-- geometria das duas pistas é destruída e refeita, o cache de rotas é limpo.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local PhysicsService = game:GetService("PhysicsService")

local SmartPath = require(ReplicatedStorage.SmartPath)
local RouteSolver = require(ReplicatedStorage.SmartPath.RouteSolver)
local Scenarios = require(script.Parent.Scenarios)
local Rigs = require(script.Parent.Rigs)
local Classic = require(script.Parent.Classic)

local Runner = {}

-- ===== Constantes =====

local WORLD_ORIGIN = Vector3.new(0, 0, 6000) -- longe de qualquer baseplate
local CELL_SPACING = 160
local LANE_Z = 40 -- a pista clássica fica em -LANE_Z (esquerda), a da SmartPath em +LANE_Z (direita)
-- a malha do PathfindingService leva um instante para incluir a geometria recém-criada, e os
-- PathfindingModifier que a SmartPath põe nos gatilhos também
local NAVMESH_SETTLE = 3
local SUCCESS_RADIUS = 5
local CROWD_SIZE = 20
local CROWD_DURATION = 30
local CROWD_IDLE_BASELINE = 5
local STATE_INTERVAL = 0.25

local CLASSIC_COLOR = Color3.fromRGB(235, 70, 70)
local SMART_COLOR = Color3.fromRGB(60, 210, 110)

-- ===== Tipos =====

type Side = string -- "L" (PathfindingService puro) ou "R" (SmartPath)
local SIDES: { Side } = { "L", "R" }

type LaneResult = {
	ok: boolean,
	text: string,
	explain: string?,
	reason: string,
	elapsed: number,
	distance: number,
}

type Stats = { ok: number, fail: number }

type Crowd = {
	reasons: string,
	samples: { string },
	avgFps: number,
	worstFrameMs: number,
	legsOk: number,
	legsFail: number,
	queuePeak: number,
}

type Cell = {
	id: number,
	scenario: Scenarios.Scenario,
	center: Vector3,
	folder: Folder,
	lanes: { [Side]: Folder },
	token: number,
	status: string,
	stats: { [Side]: Stats },
	last: { [Side]: string },
	results: { [Side]: LaneResult? },
	crowd: { [Side]: Crowd? },
	agents: { any },
}

local cells: { Cell } = {}
local worldFolder: Folder
local stateValue: StringValue
local serverFps = 60
local started = false

-- ===== Utilidades =====

local function laneOrigin(cell: Cell, side: Side): Vector3
	return cell.center + Vector3.new(0, 0, if side == "L" then -LANE_Z else LANE_Z)
end

local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function scheduler(): any
	return SmartPath.Scheduler
end

local function sideName(side: Side): string
	return if side == "L" then "Clássico" else "SmartPath"
end

-- ===== Publicação do estado para o HUD =====

local function publish()
	local list = {}
	for _, cell in ipairs(cells) do
		local entry = {
			id = cell.id,
			name = cell.scenario.name,
			description = cell.scenario.description,
			status = cell.status,
			L = { ok = cell.stats.L.ok, fail = cell.stats.L.fail, text = cell.last.L },
			R = { ok = cell.stats.R.ok, fail = cell.stats.R.fail, text = cell.last.R },
		}
		table.insert(list, entry)
	end
	stateValue.Value = HttpService:JSONEncode({
		fps = serverFps,
		queue = scheduler().getQueueLength(),
		scenarios = list,
	})
end

-- ===== Geometria =====

local function clearFolder(folder: Folder)
	for _, child in ipairs(folder:GetChildren()) do
		child:Destroy()
	end
end

local function addLabel(lane: Folder, origin: Vector3, title: string, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name = "Label"
	anchor.Anchored = true
	anchor.Transparency = 1
	anchor.CanCollide = false -- não entra na malha nem em nenhum raycast
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Size = Vector3.one
	anchor.Position = origin + Vector3.new(0, 16, 0)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(360, 60)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 300
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextSize = 24
	text.TextColor3 = color
	text.TextStrokeTransparency = 0.3
	text.Text = title
	text.Parent = gui
	gui.Parent = anchor
	anchor.Parent = lane
end

-- Refaz a geometria das duas pistas do zero.
local function buildCell(cell: Cell)
	for _, side in ipairs(SIDES) do
		local lane = cell.lanes[side]
		clearFolder(lane)
		local origin = laneOrigin(cell, side)
		cell.scenario.build({ lane = lane, origin = origin, baseline = side == "L" })
		addLabel(
			lane,
			origin + Vector3.new(-40, 0, 0),
			string.format("%d. %s", cell.id, if side == "L" then "PathfindingService puro" else "SmartPath"),
			if side == "L" then CLASSIC_COLOR else SMART_COLOR
		)
	end
end

local function buildAisle(cell: Cell)
	local aisle = Instance.new("Part")
	aisle.Name = "Aisle"
	aisle.Anchored = true
	aisle.Size = Vector3.new(140, 1, 20)
	aisle.Position = cell.center + Vector3.new(0, -0.5, 0)
	aisle.Material = Enum.Material.SmoothPlastic
	aisle.Color = Color3.fromRGB(60, 60, 70)
	aisle.Parent = cell.folder
end

-- ===== Rodada de um cenário normal =====

local function newStats(): Stats
	return { ok = 0, fail = 0 }
end

local function stopAgents(cell: Cell)
	for _, agent in ipairs(cell.agents) do
		pcall(function()
			agent:Stop()
		end)
	end
	table.clear(cell.agents)
end

local function record(cell: Cell, side: Side, result: LaneResult)
	cell.results[side] = result
	if result.ok then
		cell.stats[side].ok += 1
	else
		cell.stats[side].fail += 1
	end
	cell.last[side] = result.text
	publish()
end

-- distância percorrida (no plano) entre dois instantes, amostrada a cada frame
local function trackDistance(rig: Model): () -> number
	local root = rig:FindFirstChild("HumanoidRootPart") :: BasePart?
	local total = 0
	local last = if root then root.Position else Vector3.zero
	local conn = RunService.Heartbeat:Connect(function()
		if root and root.Parent then
			total += flatDist(root.Position, last)
			last = root.Position
		end
	end)
	rig.Destroying:Connect(function()
		conn:Disconnect()
	end)
	return function()
		conn:Disconnect()
		return total
	end
end

-- Um dos motivos que a SmartPath devolve quando o destino é inalcançável sem "brigar" com o mundo.
-- stuck ou invisible_collider num limite NavSolid significaria que ela tentou atravessá-lo.
local CLEAN_REFUSALS = { no_path = true, goal_unreachable = true, obstacle_too_tall = true, no_landing = true }

local function evaluate(
	cell: Cell,
	side: Side,
	rig: Model,
	ok: boolean,
	reason: string,
	timedOut: boolean,
	elapsed: number,
	distance: number
): LaneResult
	local sc = cell.scenario
	local root = rig:FindFirstChild("HumanoidRootPart") :: BasePart?
	local goal = laneOrigin(cell, side) + sc.goal
	local near = root ~= nil and flatDist(root.Position, goal) <= SUCCESS_RADIUS and math.abs(root.Position.Y - goal.Y - 3) < 6
	local shownReason = if timedOut then "tempo esgotado" else reason

	if sc.kind == "boundary" then
		local origin = laneOrigin(cell, side)
		local wall = cell.lanes[side]:FindFirstChild(sc.boundaryName or "")
		local hasModifier = wall ~= nil and wall:FindFirstChildWhichIsA("PathfindingModifier") ~= nil
		local crossed = root ~= nil and (root.Position.X - origin.X) > 0
		local respected = not near and not crossed and not ok and not hasModifier
		if side == "R" and not timedOut and not CLEAN_REFUSALS[reason] then
			respected = false -- tentou atravessar (stuck) ou considerou a parede um gatilho
		end
		local text
		if respected then
			text = string.format("respeitou o limite (%s), sem PathfindingModifier na parede", shownReason)
		elseif crossed or near or ok then
			text = "BUG CRÍTICO: atravessou o limite de mapa"
		elseif hasModifier then
			text = "BUG CRÍTICO: a parede recebeu PathfindingModifier"
		else
			text = string.format("não respeitou de forma limpa (%s)", shownReason)
		end
		return { ok = respected, text = text, reason = reason, elapsed = elapsed, distance = distance }
	end

	local success = ok and near
	local text
	if success then
		text = string.format("chegou em %.1fs (%.0f studs andados)", elapsed, distance)
	else
		text = string.format("falhou: %s (%.1fs, %.0f studs andados)", shownReason, elapsed, distance)
	end
	return { ok = success, text = text, reason = reason, elapsed = elapsed, distance = distance }
end

local function runNormal(cell: Cell, token: number)
	local sc = cell.scenario
	local timedOut = false
	local function cancelled(): boolean
		return cell.token ~= token or timedOut
	end
	local rigs: { [string]: Model } = {}

	for _, side in ipairs(SIDES) do
		local origin = laneOrigin(cell, side)
		local rig = Rigs.spawn(
			cell.lanes[side],
			origin + sc.start,
			sideName(side),
			if side == "L" then CLASSIC_COLOR else SMART_COLOR
		)
		local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
		if sc.setupRig then
			sc.setupRig(humanoid)
		end
		rigs[side] = rig
	end
	for _, rig in pairs(rigs) do
		Rigs.waitGrounded(rig, 3)
	end
	if cancelled() then
		return
	end

	-- as duas threads começam juntas
	for _, side in ipairs(SIDES) do
		local rig = rigs[side]
		local goal = laneOrigin(cell, side) + sc.goal
		task.spawn(function()
			local t0 = os.clock()
			local stopTracking = trackDistance(rig)
			local ok, reason = false, "?"
			local details: { [string]: any }? = nil
			local events = 0 -- recálculos do clássico (Path.Blocked) ou avisos Blocked da SmartPath
			if side == "L" then
				ok, reason, events = Classic.follow(rig, goal, cancelled)
			else
				local agent = SmartPath.MoveToAsync(rig, goal, { Agent = { Radius = 2, Height = 5 }, Debug = true })
				agent.Blocked:Connect(function()
					events += 1
				end)
				table.insert(cell.agents, agent)
				local agentOk, agentReason, agentDetails = agent:Await()
				ok, reason, details = agentOk, agentReason or "ok", agentDetails
			end
			local distance = stopTracking()
			if cell.token ~= token then
				return -- rodada antiga: descarta, o estado já é de outra
			end
			local result = evaluate(cell, side, rig, ok, reason, timedOut, os.clock() - t0, distance)
			if events > 0 then
				result.text ..= string.format(" [%s %d]", if side == "L" then "rotas refeitas" else "Blocked", events)
			end
			if not ok and details then
				result.explain = SmartPath.explain(reason, details)
			end
			record(cell, side, result)
		end)
		if sc.hazard then
			local hazard = sc.hazard
			task.spawn(function()
				hazard({ lane = cell.lanes[side], origin = laneOrigin(cell, side), rig = rig, cancelled = cancelled })
			end)
		end
	end

	local t0 = os.clock()
	while cell.token == token and (cell.results.L == nil or cell.results.R == nil) and os.clock() - t0 < sc.timeLimit do
		task.wait(0.1)
	end
	if cell.token ~= token then
		return
	end
	if cell.results.L == nil or cell.results.R == nil then
		timedOut = true
		stopAgents(cell)
		local waited = os.clock()
		while cell.token == token and (cell.results.L == nil or cell.results.R == nil) and os.clock() - waited < 3 do
			task.wait(0.1)
		end
	end
	if cell.token == token then
		cell.status = "done"
		publish()
	end
end

-- ===== Rodada do cenário 8 (multidão) =====

local function runCrowdLane(cell: Cell, token: number, side: Side): Crowd
	local sc = cell.scenario
	local origin = laneOrigin(cell, side)
	local rigs: { Model } = {}
	local rng = Random.new(8)
	for i = 1, CROWD_SIZE do
		local z = -25 + (i - 1) * (50 / (CROWD_SIZE - 1))
		local rig = Rigs.spawn(
			cell.lanes[side],
			origin + Vector3.new(sc.start.X, 0, z),
			sideName(side) .. i,
			if side == "L" then CLASSIC_COLOR else SMART_COLOR
		)
		table.insert(rigs, rig)
	end
	for _, rig in ipairs(rigs) do
		Rigs.waitGrounded(rig, 3)
	end

	local active = true
	local legsOk, legsFail = 0, 0
	local reasonCounts: { [string]: number } = {}
	local samples: { string } = {} -- as primeiras falhas da SmartPath, com o ponto onde a rota não coube
	local function cancelled(): boolean
		return not active or cell.token ~= token
	end
	for i, rig in ipairs(rigs) do
		local westward = i % 2 == 0
		task.spawn(function()
			while not cancelled() do
				westward = not westward
				local x = if westward then -rng:NextNumber(38, 52) else rng:NextNumber(38, 52)
				local goal = origin + Vector3.new(x, 0, rng:NextNumber(-24, 24))
				local ok, reason = false, "?"
				local details: { [string]: any }? = nil
				local from = (rig:FindFirstChild("HumanoidRootPart") :: BasePart).Position - origin
				if side == "L" then
					ok, reason = Classic.follow(rig, goal, cancelled)
				else
					local agent = SmartPath.MoveToAsync(rig, goal, { Agent = { Radius = 2, Height = 5 } })
					table.insert(cell.agents, agent)
					local agentOk, agentReason, agentDetails = agent:Await()
					ok, reason, details = agentOk, agentReason or "?", agentDetails
				end
				if cancelled() then
					break
				end
				if ok then
					legsOk += 1
				else
					legsFail += 1
					reasonCounts[reason] = (reasonCounts[reason] or 0) + 1
					if details and #samples < 8 then
						local at = details.blockedAt
						local route = details.rejectedRoute
						local pts = {}
						if typeof(route) == "table" then
							for _, wp in ipairs(route :: { any }) do
								if typeof((wp :: any).Position) == "Vector3" then
									local p = (wp :: any).Position - origin
									table.insert(pts, string.format("(%.1f,%.1f)", p.X, p.Z))
								end
							end
						end
						table.insert(
							samples,
							string.format(
								"%s: de (%.1f,%.1f) para (%.1f,%.1f) | fit=%s | bateu em %s | rota %s",
								reason,
								from.X,
								from.Z,
								goal.X - origin.X,
								goal.Z - origin.Z,
								tostring(details.requiredRadius),
								if typeof(at) == "Vector3"
									then string.format("(%.1f,%.1f)", (at :: Vector3).X - origin.X, (at :: Vector3).Z - origin.Z)
									else "?",
								table.concat(pts, " ")
							)
						)
					end
					task.wait(0.5)
				end
			end
		end)
	end

	-- amostra de frames do servidor durante a janela de medição
	local frames, worst, queuePeak = 0, 0, 0
	local conn = RunService.Heartbeat:Connect(function(dt: number)
		frames += 1
		worst = math.max(worst, dt)
		queuePeak = math.max(queuePeak, scheduler().getQueueLength())
	end)
	local t0 = os.clock()
	while cell.token == token and os.clock() - t0 < CROWD_DURATION do
		task.wait(0.25)
	end
	local elapsed = os.clock() - t0
	conn:Disconnect()
	active = false
	stopAgents(cell)
	for _, rig in ipairs(rigs) do
		rig:Destroy()
	end
	local parts = {}
	for reason, count in pairs(reasonCounts) do
		table.insert(parts, string.format("%s %d", reason, count))
	end
	table.sort(parts)
	return {
		samples = samples,
		reasons = if #parts > 0 then table.concat(parts, ", ") else "nenhuma",
		avgFps = frames / math.max(elapsed, 1e-3),
		worstFrameMs = worst * 1000,
		legsOk = legsOk,
		legsFail = legsFail,
		queuePeak = queuePeak,
	}
end

local function measureIdleFps(cell: Cell, token: number): number
	local frames = 0
	local conn = RunService.Heartbeat:Connect(function()
		frames += 1
	end)
	local t0 = os.clock()
	while cell.token == token and os.clock() - t0 < CROWD_IDLE_BASELINE do
		task.wait(0.25)
	end
	conn:Disconnect()
	return frames / math.max(os.clock() - t0, 1e-3)
end

local function runCrowd(cell: Cell, token: number)
	cell.last.L, cell.last.R = "medindo o FPS sem NPCs...", "aguardando"
	publish()
	local idle = measureIdleFps(cell, token)
	for _, side in ipairs(SIDES) do
		if cell.token ~= token then
			return
		end
		cell.last[side] = string.format("%d NPCs correndo por %ds...", CROWD_SIZE, CROWD_DURATION)
		publish()
		local crowd = runCrowdLane(cell, token, side)
		if cell.token ~= token then
			return
		end
		cell.crowd[side] = crowd
		cell.stats[side].ok += crowd.legsOk
		cell.stats[side].fail += crowd.legsFail
		cell.last[side] = string.format(
			"%.0f FPS (sem NPCs: %.0f), pior frame %.0f ms, trechos %d ok / %d falhas (%s), fila máx. %d",
			crowd.avgFps,
			idle,
			crowd.worstFrameMs,
			crowd.legsOk,
			crowd.legsFail,
			crowd.reasons,
			crowd.queuePeak
		)
		publish()
	end
	cell.status = "done"
	publish()
end

-- ===== API =====

-- Reinicia um cenário do zero e roda. Não bloqueia; `Runner.startAndWait` bloqueia.
function Runner.start(id: number)
	local cell = cells[id]
	if not cell then
		return
	end
	cell.token += 1
	local token = cell.token
	stopAgents(cell)
	cell.results = {}
	cell.crowd = {}
	cell.last = { L = "preparando a malha de navegação...", R = "preparando a malha de navegação..." }
	cell.status = "preparing"
	buildCell(cell)
	RouteSolver.getSharedCache():clear()
	SmartPath.Geometry.start()
	publish()

	task.spawn(function()
		local t0 = os.clock()
		while cell.token == token and os.clock() - t0 < NAVMESH_SETTLE do
			task.wait(0.1)
		end
		if cell.token ~= token then
			return
		end
		cell.last = { L = "correndo...", R = "correndo..." }
		cell.status = "running"
		publish()
		if cell.scenario.kind == "crowd" then
			runCrowd(cell, token)
		else
			runNormal(cell, token)
		end
	end)
end

function Runner.isDone(id: number): boolean
	local cell = cells[id]
	return cell ~= nil and cell.status == "done"
end

function Runner.startAndWait(id: number)
	local cell = cells[id]
	if not cell then
		error("SmartPathDemo: o Runner ainda não montou os cenários (Runner.init não terminou)", 2)
	end
	Runner.start(id)
	local token = cell.token
	while cell.token == token and cell.status ~= "done" do
		task.wait(0.25)
	end
end

function Runner.clearStats()
	for _, cell in ipairs(cells) do
		cell.stats = { L = newStats(), R = newStats() }
	end
	publish()
end

-- Linhas de resultado de um cenário, para o relatório no Output.
local function reportLines(cell: Cell): { string }
	local lines = {}
	for _, side in ipairs(SIDES) do
		table.insert(lines, string.format("  %-10s %s", sideName(side), cell.last[side]))
		local result = cell.results[side]
		if result and result.explain then
			table.insert(lines, "             -> " .. result.explain)
		end
	end
	return lines
end

-- Roda todos os cenários em sequência e imprime o resultado, lado a lado. Bloqueia (~8 minutos).
function Runner.runReport(only: number?): { [number]: { L: boolean, R: boolean } }
	if #cells == 0 then
		error("SmartPathDemo: o Runner ainda não montou os cenários; espere o print \"pronto\" no Output", 2)
	end
	local summary: { [number]: { L: boolean, R: boolean } } = {}
	print(string.format("[SmartPathDemo] ==== relatório: %d cenários, PathfindingService puro x SmartPath ====", #cells))
	for _, cell in ipairs(cells) do
		if only and cell.id ~= only then
			continue
		end
		Runner.startAndWait(cell.id)
		local L, R = cell.results.L, cell.results.R
		if cell.scenario.kind == "crowd" then
			local cl, cr = cell.crowd.L, cell.crowd.R
			summary[cell.id] = { L = cl ~= nil, R = cr ~= nil and (cl == nil or cr.avgFps >= cl.avgFps - 2) }
		else
			summary[cell.id] = { L = L ~= nil and L.ok, R = R ~= nil and R.ok }
		end
		print(string.format("[SmartPathDemo] Cenário %d — %s", cell.id, cell.scenario.name))
		for _, line in ipairs(reportLines(cell)) do
			print("[SmartPathDemo] " .. line)
		end
		local crowd = cell.crowd.R
		if crowd then
			for _, sample in ipairs(crowd.samples) do
				print("[SmartPathDemo]     falha: " .. sample)
			end
		end
	end
	print("[SmartPathDemo] ==== fim do relatório ====")
	return summary
end

-- Confere que reiniciar não deixa resíduo: roda o cenário `id` duas vezes e, depois de cada rodada,
-- refaz a geometria e compara a contagem de instâncias das pistas e de partes que a SmartPath
-- classificou (Geometry.getIgnoredCount). Não serve para o cenário 8 (leva ~70 s por rodada).
function Runner.checkCleanRestart(id: number): (boolean, string)
	local cell = cells[id]
	local function snapshot(): (number, number)
		stopAgents(cell)
		buildCell(cell)
		task.wait(0.5) -- a classificação da Geometry é adiada (task.defer)
		return #cell.lanes.L:GetDescendants() + #cell.lanes.R:GetDescendants(), SmartPath.Geometry.getIgnoredCount()
	end
	Runner.startAndWait(id)
	local instances1, ignored1 = snapshot()
	Runner.startAndWait(id)
	local instances2, ignored2 = snapshot()
	return instances1 == instances2 and ignored1 == ignored2,
		string.format(
			"instâncias %d -> %d, partes classificadas pela SmartPath %d -> %d",
			instances1,
			instances2,
			ignored1,
			ignored2
		)
end

-- Diagnóstico de rota de um cenário: monta, espera a malha e imprime, para cada lado, a rota que o
-- PathfindingService devolve e a que a SmartPath devolve (em coordenadas locais da pista), sem
-- mover ninguém. Serve para entender POR QUE um cenário falha.
function Runner.diagnose(id: number)
	local cell = cells[id]
	if not cell then
		error("SmartPathDemo: cenário inexistente", 2)
	end
	local sc = cell.scenario
	cell.token += 1
	stopAgents(cell)
	buildCell(cell)
	SmartPath.Geometry.start()
	RouteSolver.getSharedCache():clear()
	task.wait(NAVMESH_SETTLE + 1)
	local PathfindingService = game:GetService("PathfindingService")
	local function fmt(origin: Vector3, p: Vector3): string
		return string.format("(%.1f, %.1f, %.1f)", p.X - origin.X, p.Y - origin.Y, p.Z - origin.Z)
	end
	print(string.format("[SmartPathDemo] ==== diagnóstico do cenário %d: %s ====", id, sc.name))
	for _, side in ipairs(SIDES) do
		local origin = laneOrigin(cell, side)
		local rig = Rigs.spawn(cell.lanes[side], origin + sc.start, sideName(side), Color3.new(1, 1, 1))
		Rigs.waitGrounded(rig, 3)
		local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
		if sc.setupRig then
			sc.setupRig(humanoid)
		end
		local goal = origin + sc.goal
		local root = humanoid.RootPart :: BasePart
		local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
		pcall(function()
			path:ComputeAsync(root.Position, goal)
		end)
		local parts = {}
		if path.Status == Enum.PathStatus.Success then
			for _, wp in ipairs(path:GetWaypoints()) do
				local jump = if wp.Action == Enum.PathWaypointAction.Jump then "J" else ""
				table.insert(parts, fmt(origin, wp.Position) .. jump)
			end
			if side == "R" then
				-- fica 2 minutos na pista para ser olhada no Studio
				local folder = workspace:FindFirstChild("SmartPathDemoDiagnose") or Instance.new("Folder")
				folder.Name = "SmartPathDemoDiagnose"
				folder.Parent = workspace
				for _, wp in ipairs(path:GetWaypoints()) do
					local dot = Instance.new("Part")
					dot.Shape = Enum.PartType.Ball
					dot.Size = Vector3.one * 1.2
					dot.Anchored = true
					dot.CanCollide = false
					dot.CanQuery = false
					dot.CanTouch = false
					dot.Material = Enum.Material.Neon
					dot.Color = Color3.fromRGB(255, 255, 0)
					dot.Position = wp.Position + Vector3.new(0, 1, 0)
					dot.Parent = folder
					game:GetService("Debris"):AddItem(dot, 120)
				end
			end
		end
		print(
			string.format(
				"[SmartPathDemo] %s | engine: %s | %s",
				sideName(side),
				tostring(path.Status),
				table.concat(parts, " -> ")
			)
		)
		if side == "R" then
			local wps, reason, details = SmartPath.GetRoute(rig, goal, { Agent = { Radius = 2, Height = 5 } })
			if wps then
				local sp = {}
				for _, wp in ipairs(wps) do
					local jump = if wp.SmartAction == "Jump" then "J" else ""
					table.insert(sp, fmt(origin, wp.Position) .. jump)
				end
				print("[SmartPathDemo] SmartPath | rota: " .. table.concat(sp, " -> "))
			else
				local extra = {}
				if details then
					for k, v in pairs(details) do
						local text: string
						if typeof(v) == "Vector3" then
							text = fmt(origin, v)
						elseif typeof(v) == "Instance" then
							text = (v :: Instance):GetFullName()
						elseif typeof(v) == "table" then
							local items = {}
							for _, item in ipairs(v :: { any }) do
								if typeof(item) == "table" and typeof((item :: any).Position) == "Vector3" then
									table.insert(items, fmt(origin, (item :: any).Position))
								else
									table.insert(items, tostring(item))
								end
							end
							text = "{" .. table.concat(items, ",") .. "}"
						else
							text = tostring(v)
						end
						table.insert(extra, string.format("%s=%s", tostring(k), text))
					end
					table.sort(extra)
				end
				print(string.format("[SmartPathDemo] SmartPath | %s | %s", tostring(reason), table.concat(extra, " ")))
				print("[SmartPathDemo]   " .. SmartPath.explain(reason, details))
			end
		end
		rig:Destroy()
	end
	-- conectividade da malha (pista da SmartPath, a que tem os PathfindingModifier)
	if sc.probes then
		local origin = laneOrigin(cell, "R")
		for _, probe in ipairs(sc.probes) do
			local p = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
			local from, to = origin + probe.from + Vector3.new(0, 1, 0), origin + probe.to + Vector3.new(0, 1, 0)
			pcall(function()
				p:ComputeAsync(from, to)
			end)
			local count = if p.Status == Enum.PathStatus.Success then #p:GetWaypoints() else 0
			print(
				string.format(
					"[SmartPathDemo] sonda %s -> %s: %s, %d waypoints",
					fmt(origin, from - Vector3.new(0, 1, 0)),
					fmt(origin, to - Vector3.new(0, 1, 0)),
					tostring(p.Status),
					count
				)
			)
		end
	end
	print("[SmartPathDemo] ==== fim do diagnóstico ====")
end

-- ===== Inicialização =====

local function teleportToCell(player: Player, id: number)
	local cell = cells[id]
	local character = player.Character
	if cell and character then
		character:PivotTo(CFrame.new(cell.center + Vector3.new(0, 4, 0)))
	end
end

function Runner.init()
	if started then
		return
	end
	started = true

	pcall(function()
		PhysicsService:RegisterCollisionGroup(Scenarios.TRIGGER_GROUP)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(Scenarios.TRIGGER_GROUP, "Default", false)
	end)

	worldFolder = Instance.new("Folder")
	worldFolder.Name = "SmartPathDemoWorld"
	worldFolder.Parent = workspace

	local stateFolder = Instance.new("Folder")
	stateFolder.Name = "SmartPathDemoState"
	stateValue = Instance.new("StringValue")
	stateValue.Name = "State"
	stateValue.Parent = stateFolder
	local actions = Instance.new("RemoteEvent")
	actions.Name = "Actions"
	actions.Parent = stateFolder

	for i, scenario in ipairs(Scenarios.list) do
		local folder = Instance.new("Folder")
		folder.Name = string.format("Scenario%d", i)
		folder.Parent = worldFolder
		local laneL, laneR = Instance.new("Folder"), Instance.new("Folder")
		laneL.Name, laneR.Name = "Classic", "SmartPath"
		laneL.Parent, laneR.Parent = folder, folder
		local cell: Cell = {
			id = i,
			scenario = scenario,
			center = WORLD_ORIGIN + Vector3.new((i - 1) * CELL_SPACING, 0, 0),
			folder = folder,
			lanes = { L = laneL, R = laneR },
			token = 0,
			status = "idle",
			stats = { L = newStats(), R = newStats() },
			last = { L = "aperte Reiniciar", R = "aperte Reiniciar" },
			results = {},
			crowd = {},
			agents = {},
		}
		table.insert(cells, cell)
		buildAisle(cell)
		buildCell(cell)
	end

	-- ponto de nascimento dos jogadores: o corredor do cenário 1
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "DemoSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.Position = cells[1].center + Vector3.new(-55, 0.5, 0)
	spawn.Transparency = 0.6
	spawn.Parent = worldFolder
	local function place(player: Player)
		player.RespawnLocation = spawn
	end
	Players.PlayerAdded:Connect(place)
	for _, player in ipairs(Players:GetPlayers()) do
		place(player)
	end

	local allRunning = false
	actions.OnServerEvent:Connect(function(player: Player, action: any, id: any)
		if action == "start" and typeof(id) == "number" then
			Runner.start(id)
		elseif action == "view" and typeof(id) == "number" then
			teleportToCell(player, id)
		elseif action == "clearStats" then
			Runner.clearStats()
		elseif action == "startAll" and not allRunning then
			allRunning = true
			task.spawn(function()
				for _, cell in ipairs(cells) do
					Runner.startAndWait(cell.id)
				end
				allRunning = false
			end)
		end
	end)

	-- FPS do servidor (janela de 0.5 s) e atualização periódica do estado
	local frames, windowStart, lastPublish = 0, os.clock(), 0
	RunService.Heartbeat:Connect(function()
		frames += 1
		local now = os.clock()
		if now - windowStart >= 0.5 then
			serverFps = frames / (now - windowStart)
			frames, windowStart = 0, now
		end
		if now - lastPublish >= STATE_INTERVAL then
			lastPublish = now
			publish()
		end
	end)

	stateFolder.Parent = ReplicatedStorage
	publish()
	print(string.format("[SmartPathDemo] %d cenários montados", #cells))
	-- por último: pode demorar (rede)
	Rigs.init()
	print("[SmartPathDemo] pronto: use o HUD ou o atributo Command (ver Main.server.luau)")
end

return Runner
