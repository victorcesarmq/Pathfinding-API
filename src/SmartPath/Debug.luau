--!strict
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

export type Panel = {
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
