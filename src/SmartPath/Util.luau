--!strict
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
