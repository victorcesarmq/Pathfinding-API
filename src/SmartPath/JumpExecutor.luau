--!strict
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
