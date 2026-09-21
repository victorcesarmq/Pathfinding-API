--!strict
-- Classic.luau
-- O lado "esquerdo" dos cenários: PathfindingService puro, do jeito que a documentação da
-- Roblox ensina (CreatePath -> ComputeAsync -> Humanoid:MoveTo em cada waypoint, pulo quando o
-- waypoint pede, recálculo quando Path.Blocked avisa). Sem nenhuma ajuda da SmartPath: é o
-- baseline honesto contra o qual a biblioteca é comparada.

local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")

local Classic = {}

-- os valores mais comuns nos exemplos (raio 2, altura 5); a SmartPath recebe os mesmos
local AGENT_PARAMS = {
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = true,
}
local MAX_RECOMPUTES = 10
local MOVE_TIMEOUT_POLL = 0.05

local function draw(waypoints: { PathWaypoint })
	local folder = workspace:FindFirstChild("SmartPathDemoClassicRoute")
	if not folder then
		local created = Instance.new("Folder")
		created.Name = "SmartPathDemoClassicRoute"
		created.Parent = workspace
		folder = created
	end
	for _, wp in ipairs(waypoints) do
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.one * 0.7
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Material = Enum.Material.Neon
		p.Color = if wp.Action == Enum.PathWaypointAction.Jump then Color3.fromRGB(255, 200, 0) else Color3.fromRGB(255, 70, 70)
		p.Position = wp.Position
		p.Parent = folder
		Debris:AddItem(p, 8)
	end
end

-- Segue `goal` como a documentação. Retorna (chegou, motivo, recálculos): "no_path", "timeout" (o
-- MoveTo de 8 s da engine venceu), "cancelled" ou "recompute_limit". `recálculos` conta quantas
-- vezes o Path.Blocked mandou refazer a rota.
function Classic.follow(rig: Model, goal: Vector3, cancelled: () -> boolean): (boolean, string, number)
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local root = humanoid and humanoid.RootPart
	if not humanoid or not root then
		return false, "no_character", 0
	end

	local recomputes = 0
	for attempt = 1, MAX_RECOMPUTES do
		recomputes = attempt - 1
		local path = PathfindingService:CreatePath(AGENT_PARAMS)
		local computed = pcall(function()
			path:ComputeAsync(root.Position, goal)
		end)
		if cancelled() then
			return false, "cancelled", recomputes
		end
		if not computed or path.Status ~= Enum.PathStatus.Success then
			return false, "no_path", recomputes
		end

		local waypoints = path:GetWaypoints()
		draw(waypoints)
		local nextIndex = 2
		local blocked = false
		local blockedConn = path.Blocked:Connect(function(index: number)
			if index >= nextIndex then
				blocked = true
			end
		end)

		local failure: string? = nil
		while nextIndex <= #waypoints and not blocked and not failure do
			local wp = waypoints[nextIndex]
			if wp.Action == Enum.PathWaypointAction.Jump then
				humanoid.Jump = true
			end
			local finished, reached = false, false
			local conn = humanoid.MoveToFinished:Connect(function(r: boolean)
				finished, reached = true, r
			end)
			humanoid:MoveTo(wp.Position)
			while not finished and not blocked and not cancelled() do
				task.wait(MOVE_TIMEOUT_POLL)
			end
			conn:Disconnect()
			if cancelled() then
				failure = "cancelled"
			elseif not blocked then
				if reached then
					nextIndex += 1
				else
					failure = "timeout"
				end
			end
		end
		blockedConn:Disconnect()

		if failure then
			humanoid:Move(Vector3.zero, false)
			return false, failure, recomputes
		end
		if not blocked then
			return true, "ok", recomputes
		end
		-- Path.Blocked avisou: recalcula a partir de onde está (o laço externo)
	end
	return false, "recompute_limit", recomputes
end

return Classic
