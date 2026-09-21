--!strict
-- Compat.luau
-- Camada de compatibilidade que espelha o PathfindingService (Seção 3.4 do plano, Fase 5).
-- Objetivo: um script existente passa a usar a SmartPath trocando UMA linha, a do require:
--
--   local PathfindingService = game:GetService("PathfindingService")   -- antes
--   local PathfindingService = require(ReplicatedStorage.SmartPath).Service   -- depois
--
-- e tudo o mais (CreatePath, ComputeAsync, Status, GetWaypoints, Blocked) continua igual.
--
-- Aqui NÃO há personagem (só Vector3), então não dá para derivar raio, altura de pulo e
-- velocidade do Humanoid como o nível 0/1 fazem (D-001): usa o raio/altura do CreatePath (ou os
-- defaults dele) e a escada de raio adaptativo, a validação de volume e o filtro de geometria
-- invisível do resto da lib. Extras não oficiais: path.SmartStatus e path.SmartDetails.
--
-- Diferenças conhecidas em relação ao serviço real: WaypointSpacing e Costs são ignorados (as
-- rotas vêm com waypoints só onde a direção muda ou há salto), e AgentCanClimb não tem efeito.

local Types = require(script.Parent.Types)
local Errors = require(script.Parent.Errors)
local Config = require(script.Parent.Config)
local Signal = require(script.Parent.Signal)
local Geometry = require(script.Parent.Geometry)
local RouteSolver = require(script.Parent.RouteSolver)

local Compat = {}
Compat.Service = {}

-- Defaults do PathfindingService:CreatePath.
local DEFAULT_AGENT_RADIUS = 2
local DEFAULT_AGENT_HEIGHT = 5
-- Juntar as partes que surgem em rajada (um personagem nascendo) numa única revalidação.
local BLOCKED_CHECK_DELAY = 0.25

local Path = {}
Path.__index = Path

type PathData = {
	Status: Enum.PathStatus,
	SmartStatus: string?,
	SmartDetails: { [string]: any }?,
	Blocked: any,
	_options: Types.ResolvedOptions,
	_waypoints: { Types.Waypoint },
	_blockedSignal: Signal.Signal?,
	_listening: boolean,
	_watchConn: RBXScriptConnection?,
	_checkScheduled: boolean,
}

export type CompatPath = typeof(setmetatable({} :: PathData, Path))

-- SmartStatus -> Enum.PathStatus. Sucesso é sucesso mesmo quando a engine sozinha não acharia a
-- rota: o Status descreve o resultado da SmartPath, não o da engine.
local function statusFor(reason: string?): Enum.PathStatus
	if reason == nil then
		return Enum.PathStatus.Success
	end
	if reason == Errors.GoalUnreachable then
		return Enum.PathStatus.FailFinishNotEmpty
	end
	return Enum.PathStatus.NoPath
end

-- ===== path.Blocked =====
-- Objeto com Connect/Once/Wait, igual ao evento da engine. A observação do mundo só liga
-- quando alguém conecta: quem nunca usa Blocked não paga nada.

local function makeBlocked(path: CompatPath): any
	local blocked = {}
	local function signal(): Signal.Signal
		local s = path._blockedSignal
		if not s then
			s = Signal.new()
			path._blockedSignal = s
		end
		path._listening = true
		path:_startWatching()
		return s :: Signal.Signal
	end
	function blocked.Connect(_, fn: (number) -> ())
		return signal():Connect(fn :: any)
	end
	function blocked.Once(_, fn: (number) -> ())
		return signal():Once(fn :: any)
	end
	function blocked.Wait(_)
		return signal():Wait()
	end
	return blocked
end

function Path._startWatching(self: CompatPath)
	if self._watchConn or #self._waypoints == 0 then
		return
	end
	-- referência fraca: um script que descarta o Path sem desconectar não o mantém vivo, e a
	-- conexão se desfaz sozinha na próxima parte que surgir
	local weak = setmetatable({ path = self }, { __mode = "v" }) :: any
	local conn: RBXScriptConnection
	conn = Geometry.PartAdded:Connect(function(part: BasePart)
		local path = weak.path
		if not path or path._watchConn ~= conn then
			conn:Disconnect()
			return
		end
		path:_onPartAdded(part)
	end)
	self._watchConn = conn
end

function Path._stopWatching(self: CompatPath)
	if self._watchConn then
		self._watchConn:Disconnect()
		self._watchConn = nil
	end
end

function Path._onPartAdded(self: CompatPath, part: BasePart)
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return -- personagens se movem sozinhos e nascem com dezenas de partes
	end
	if self._checkScheduled then
		return
	end
	self._checkScheduled = true
	task.delay(BLOCKED_CHECK_DELAY, function()
		self._checkScheduled = false
		self:_checkBlocked()
	end)
end

function Path._checkBlocked(self: CompatPath)
	if not self._watchConn then
		return
	end
	local clear, _, index = RouteSolver.isRouteClearAt(self._waypoints, self._options, 1, nil)
	if not clear then
		self:_stopWatching() -- como o serviço real: avisa uma vez por cálculo
		local s = self._blockedSignal
		if s then
			s:Fire(index or 1)
		end
	end
end

-- ===== API espelhada =====

-- Bloqueante. Erra com argumentos inválidos, como o serviço real (scripts costumam usar pcall).
function Path.ComputeAsync(self: CompatPath, start: Vector3, finish: Vector3)
	if typeof(start) ~= "Vector3" or typeof(finish) ~= "Vector3" then
		error("SmartPath: Path:ComputeAsync espera dois Vector3", 2)
	end
	self:_stopWatching()
	local waypoints, reason, details = RouteSolver.solvePositions(start, finish, self._options)
	self._waypoints = waypoints or {}
	self.Status = statusFor(if waypoints then nil else (reason or Errors.NoPath))
	self.SmartStatus = if waypoints then nil else (reason or Errors.NoPath)
	self.SmartDetails = details
	if waypoints and self._listening then
		self:_startWatching()
	end
end

-- Cópia a cada chamada, como o serviço real: o script pode mexer na tabela dele.
function Path.GetWaypoints(self: CompatPath): { Types.Waypoint }
	return table.clone(self._waypoints)
end

-- params: os mesmos de PathfindingService:CreatePath (AgentRadius, AgentHeight, AgentCanJump...).
function Compat.Service.CreatePath(_self: any, params: { [string]: any }?): CompatPath
	local p: { [string]: any } = params or {}
	local overrides = {
		Agent = { Radius = p.AgentRadius or DEFAULT_AGENT_RADIUS, Height = p.AgentHeight or DEFAULT_AGENT_HEIGHT },
		Jump = { Enabled = if p.AgentCanJump == nil then true else p.AgentCanJump },
	}
	local self = setmetatable({
		-- antes de ComputeAsync não há rota: NoPath é o estado seguro (Success faria um script
		-- que confere o Status cedo demais achar que já tem waypoints)
		Status = Enum.PathStatus.NoPath,
		SmartStatus = nil,
		SmartDetails = nil,
		Blocked = nil,
		_options = Config.resolve(nil :: any, overrides :: any),
		_waypoints = {},
		_blockedSignal = nil,
		_listening = false,
		_watchConn = nil,
		_checkScheduled = false,
	}, Path) :: any
	self.Blocked = makeBlocked(self)
	return self :: CompatPath
end

return Compat
