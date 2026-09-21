--!strict
-- Rigs.luau
-- NPCs do demo: um rig R15 de verdade (criado uma vez e clonado) ou, se a criação falhar (sem
-- rede, por exemplo), um rig mínimo (root + Humanoid) igual ao dos testes. Os dois lados de um
-- cenário recebem rigs idênticos; só o destaque colorido muda.

local Players = game:GetService("Players")

local Rigs = {}

-- animações padrão do R15 (as mesmas do script Animate do Roblox)
local ANIMATIONS = {
	idle = "rbxassetid://507766666",
	walk = "rbxassetid://507777826",
	jump = "rbxassetid://507765000",
}

local template: Model? = nil
local templateTried = false

local function buildMinimal(): Model
	local model = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Material = Enum.Material.SmoothPlastic
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = 2
	humanoid.RequiresNeck = false
	root.Parent = model
	humanoid.Parent = model
	model.PrimaryPart = root
	return model
end

-- CreateHumanoidModelFromDescription busca os assets do rig na rede e pode ficar bloqueada sem
-- nunca falhar. Roda numa thread própria com limite de tempo; passado o limite, o demo segue com o
-- rig mínimo (root + Humanoid) e a thread que sobrou é ignorada.
local INIT_TIMEOUT = 6

-- Chamar uma vez antes de spawnar (pode dar yield por até INIT_TIMEOUT).
function Rigs.init()
	if templateTried then
		return
	end
	templateTried = true
	local result: Model? = nil
	local finished = false
	task.spawn(function()
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(
				Instance.new("HumanoidDescription"),
				Enum.HumanoidRigType.R15
			)
		end)
		if ok and model and (model :: Model):FindFirstChildOfClass("Humanoid") then
			result = model :: Model
		end
		finished = true
	end)
	local t0 = os.clock()
	while not finished and os.clock() - t0 < INIT_TIMEOUT do
		task.wait(0.1)
	end
	template = result or buildMinimal()
	print(
		string.format(
			"[SmartPathDemo] rig dos NPCs: %s",
			if result then "R15 completo" else "mínimo (a criação do R15 falhou ou passou de " .. INIT_TIMEOUT .. "s)"
		)
	)
end

function Rigs.isMinimal(): boolean
	return template ~= nil and template:FindFirstChild("UpperTorso") == nil
end

-- Animações simples (parado, andando, saltando). Falhar em carregar não impede o NPC de andar.
local function animate(humanoid: Humanoid)
	local animator: Animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid
	local tracks: { [string]: AnimationTrack } = {}
	for name, id in pairs(ANIMATIONS) do
		local ok, track = pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = id
			return animator:LoadAnimation(anim)
		end)
		if ok then
			tracks[name] = track :: AnimationTrack
		end
	end
	local idle, walk, jump = tracks.idle, tracks.walk, tracks.jump
	if idle then
		idle.Looped = true
		idle:Play()
	end
	if walk then
		walk.Looped = true
	end
	humanoid.Running:Connect(function(speed: number)
		if walk then
			if speed > 0.5 then
				if not walk.IsPlaying then
					walk:Play()
				end
				walk:AdjustSpeed(speed / 14.5)
			else
				walk:Stop()
			end
		end
	end)
	humanoid.Jumping:Connect(function(active: boolean)
		if active and jump then
			jump:Play()
		end
	end)
end

-- Rigs.init pode estar em andamento em outra thread (o Runner o chama por último)
local function waitTemplate(): Model
	while true do
		local ready = template
		if ready then
			return ready
		end
		task.wait()
	end
end

-- `position` é o ponto do chão. O rig nasce olhando para +X (a direção de todos os cenários).
function Rigs.spawn(parent: Instance, position: Vector3, name: string, color: Color3): Model
	Rigs.init()
	local rig = waitTemplate():Clone()
	rig.Name = name
	local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.DisplayName = name
	humanoid.WalkSpeed = 16
	rig:PivotTo(CFrame.lookAt(position + Vector3.new(0, 3.2, 0), position + Vector3.new(1, 3.2, 0)))

	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.FillTransparency = 0.55
	highlight.OutlineColor = color
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = rig

	rig.Parent = parent
	local root = humanoid.RootPart
	if root then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
	if not Rigs.isMinimal() then
		animate(humanoid)
	end
	return rig
end

-- espera o rig aterrar (a malha e a validação partem do chão)
function Rigs.waitGrounded(rig: Model, timeout: number)
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local t0 = os.clock()
	while humanoid.FloorMaterial == Enum.Material.Air and os.clock() - t0 < timeout do
		task.wait()
	end
end

return Rigs
