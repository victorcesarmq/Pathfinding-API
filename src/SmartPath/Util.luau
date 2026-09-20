--!strict
-- Util.luau
-- Geometria, física e normalização de personagem usadas pelo resto da SmartPath.
-- Números mágicos ficam em Config; aqui só fórmulas e leitura de estado do jogo
-- (Seção 1.3 e 3.3 da ESPEC_NAVEGACAO_ROBLOX.md).

local Debris = game:GetService("Debris")
local Types = require(script.Parent.Types)

local Util = {}
local UP = Vector3.yAxis

-- ===== Normalização de personagem (regra 11: aceitar Model, Humanoid ou BasePart) =====

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
		return 2 -- default do NavConfig de referência (R15 ≈ 1.5–2)
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

-- ===== Física de salto (Seção 1.3 da ESPEC) =====

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

-- ===== Debug (regra 10: só sob options.Debug, sempre prefixado) =====

function Util.debugPrint(enabled: boolean, ...: any)
	if not enabled then
		return
	end
	print("[SmartPath]", ...)
end

local debugFolder: Folder? = nil
function Util.getDebugFolder(): Folder
	if debugFolder and debugFolder.Parent then
		return debugFolder
	end
	local f = Instance.new("Folder")
	f.Name = "SmartPathDebug"
	f.Parent = workspace
	debugFolder = f
	return f
end

function Util.drawPoint(pos: Vector3, color: Color3, size: number?, lifetime: number?)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.one * (size or 0.6)
	p.Anchored = true
	p.CanCollide = false -- nunca poluir a navmesh nem os próprios raycasts da lib
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Position = pos
	p.Parent = Util.getDebugFolder()
	Debris:AddItem(p, lifetime or 6)
end

function Util.drawRoute(waypoints: { Types.Waypoint }, lifetime: number?)
	for _, wp in ipairs(waypoints) do
		local color = Color3.fromRGB(80, 200, 255) -- Walk: azul
		if wp.Action == Enum.PathWaypointAction.Jump then
			color = Color3.fromRGB(255, 200, 0) -- Jump: amarelo
		elseif wp.Action == Enum.PathWaypointAction.Custom then
			color = Color3.fromRGB(255, 0, 200) -- Custom: magenta
		end
		Util.drawPoint(wp.Position, color, 0.6, lifetime)
	end
end

return Util
