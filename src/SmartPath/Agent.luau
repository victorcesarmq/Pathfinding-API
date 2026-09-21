--!strict
-- Agent.luau
-- Agente persistente (nível 1 da API) e máquina de estados que junta o RouteSolver, o
-- Predictor e o JumpExecutor.
--
-- Estados: Idle -> Following -> (DirectJump ->) Airborne -> Following ... -> Idle | Failed.
--   Following : segue os waypoints com Humanoid:Move, sonda reativa de salto, anti-stuck.
--   DirectJump: corre em direção fixa até o ponto de decolagem de um atalho por salto.
--   Airborne  : durante TODO o voo continua chamando Move rumo ao pouso. Parar de chamar Move
--               é a causa nº 1 de "cair antes do obstáculo" (o Humanoid perde o momento).
--
-- Nunca usa Humanoid:MoveTo (timeout de 8s): só Humanoid:Move, todo frame.
-- Fase 6: toda falha traz código + details (ver Diagnostics.explain); o Agent produz stuck,
-- timeout, obstacle_too_tall, no_landing e invisible_collider (as causas de "travou").
-- O passo roda em PreSimulation, e não em Heartbeat: o ControlModule do jogador chama Move em
-- RenderStepped, que vem ANTES da física; um Move dado só no Heartbeat (depois da física)
-- seria sobrescrito por ele no frame seguinte [VALIDAR no cliente].

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Types = require(script.Parent.Types)
local Errors = require(script.Parent.Errors)
local Config = require(script.Parent.Config)
local Util = require(script.Parent.Util)
local Signal = require(script.Parent.Signal)
local Geometry = require(script.Parent.Geometry)
local RouteSolver = require(script.Parent.RouteSolver)
local Predictor = require(script.Parent.Predictor)
local JumpExecutor = require(script.Parent.JumpExecutor)
local Diagnostics = require(script.Parent.Diagnostics)
local Debug = require(script.Parent.Debug)

local Agent = {}
Agent.__index = Agent

local WALK = Enum.PathWaypointAction.Walk
local JUMP = Enum.PathWaypointAction.Jump
local CUSTOM = Enum.PathWaypointAction.Custom

-- Constantes internas (valores de referência). Não fazem parte da tabela de Options pública,
-- que é estável.
local ARRIVE_RADIUS = 1.25 -- distância plana para considerar um waypoint alcançado
local STUCK_TIME = 1.0 -- sem progresso por este tempo = uma tentativa de anti-stuck
local STUCK_MIN_PROGRESS = 0.6 -- deslocamento que conta como progresso
local MAX_STUCK_STRIKES = 3 -- salto de escape, replan, replan; a seguinte falha com "stuck"
local MIN_REPLAN_INTERVAL = 0.5
-- Detecção própria de bloqueio (D-021): o Path.Blocked da engine não dispara para partes
-- inseridas em runtime. Uma parte nova só marca a rota como "suja"; a revalidação roda no
-- máximo a cada ROUTE_CHECK_INTERVAL, seja quantas partes surjam (ex.: um personagem nascendo).
local ROUTE_CHECK_INTERVAL = 0.25
-- Uma parte que já estava no mundo e SE MOVE para dentro da rota (bloco que cai, porta) não dispara
-- Geometry.PartAdded. Enquanto segue, o agente revalida a rota a cada ROUTE_RECHECK_INTERVAL (D-030).
local ROUTE_RECHECK_INTERVAL = 1
-- Depois de um bloqueio a malha da engine demora a incluir o obstáculo (medido: mais de 10s), e
-- nesse intervalo o replan não acha rota. Em vez de falhar, o agente espera e tenta de novo.
local BLOCKED_RETRY_WINDOW = 30
local BLOCKED_RETRY_INTERVAL = 1.5
-- Alvo móvel (BasePart/Model como destino): a posição dele é conferida a cada
-- TARGET_CHECK_INTERVAL e a rota é refeita quando ele se afasta mais que TARGET_MOVE_THRESHOLD
-- do destino do último cálculo. O limiar evita replanejar a cada passo do alvo (custo e
-- zigue-zague); consequência: o agente termina a no máximo ~esse limiar de um alvo que parou.
local TARGET_CHECK_INTERVAL = 0.25
local TARGET_MOVE_THRESHOLD = 4
-- Chegada perto de um alvo móvel. O último waypoint conta como alcançado a TARGET_STOP_DISTANCE:
-- um alvo que é outro personagem colide com o agente a ~2 studs, então exigir o ARRIVE_RADIUS
-- (1.25) do ponto dele faria o agente empurrá-lo até cair no anti-stuck. E ao chegar, se o alvo
-- ainda está além de TARGET_RESUME_DISTANCE (ele andou depois do último cálculo), o agente segue
-- em vez de declarar chegada; assim termina a no máximo essa distância dele.
local TARGET_STOP_DISTANCE = 3
local TARGET_RESUME_DISTANCE = 3.5
local PROBE_INTERVAL = 0.1 -- frequência da sonda reativa de salto
local JUMP_COOLDOWN = 0.35
local MIN_AIR_TIME = 0.15 -- antes disso um FloorMaterial ~= Air ainda é o chão da decolagem
local MAX_AIR_TIME = 3
local DIRECT_TIMEOUT = 4 -- tempo máximo correndo até a decolagem de um atalho
local MIN_GAIN_RATIO = 0.2 -- o atalho por salto precisa encurtar o trajeto em ≥ 20%
local START_INDEX_LOOKAHEAD = 5
local JUMP_LINK_LABEL = "JumpLink" -- Label de PathfindingLink tratado como salto (v2)
local DEBUG_LIFETIME = 6
local LOAD_TIMEOUT = 5 -- espera por Humanoid/HumanoidRootPart de um personagem ainda carregando
-- Curvas (Stability.Curves, D-035): o agente mira num ponto adiante NA ROTA, em vez de virar de uma vez
-- em cada canto. A distância é WalkSpeed x este tempo, limitada; [VALIDAR] no rig do jogo.
local CURVE_LOOKAHEAD_TIME = 0.3
local CURVE_MIN_LOOKAHEAD = 3
local CURVE_MAX_LOOKAHEAD = 8
local CURVE_VALIDATE_ATTEMPTS = 3 -- quantas vezes a distância é reduzida à metade até o corpo caber
-- Endurecimento (Fase 8, D-033)
-- Personagem removido do jogo: o agente falha com character_lost e se destrói depois deste atraso, para
-- que os handlers de Failed rodem antes (o BindableEvent entrega no ciclo seguinte).
local REMOVED_DESTROY_DELAY = 0.5
-- Destino já ao alcance: não há o que calcular (MoveTo até onde se está).
local ALREADY_THERE_HEIGHT_TOLERANCE = 6
-- StreamingEnabled no cliente: pede a região do destino só se ele está longe o bastante para ainda
-- não ter sido enviada, e espera no máximo isto.
local STREAM_REQUEST_MIN_DISTANCE = 100
local STREAM_REQUEST_TIMEOUT = 2
-- Diagnóstico de travamento (Fase 6): ao esgotar o anti-stuck, procura à frente uma parte
-- invisível colidível. Parte de um pouco atrás para que uma parede encostada no corpo não fique
-- na origem do Spherecast (que ignora o que sobrepõe a origem, D-014).
local STUCK_PROBE_BACK = 1.5
local STUCK_PROBE_AHEAD = 3
local STUCK_PROBE_KNEE_HEIGHT = 1
local STUCK_PROBE_KNEE_RADIUS = 0.5
-- códigos de falha que o Agent produz (o solver imprime e desenha os seus)
local DRAWN_BY_AGENT: { [string]: boolean } = {
	[Errors.Stuck] = true,
	[Errors.ObstacleTooTall] = true,
	[Errors.NoLanding] = true,
	[Errors.InvisibleCollider] = true,
	[Errors.Timeout] = true,
}

-- Tempo máximo de uma movimentação (código `timeout`). Não é opção pública (a tabela de opções é estável):
-- orçamento = BASE + FACTOR x (maior rota adotada) / WalkSpeed. BASE cobre a janela de espera
-- por bloqueio (30 s) com folga; FACTOR tolera um agente bem mais lento que o ideal. Exposto em
-- Agent._tuning só para os testes encurtarem.
Agent._tuning = { TimeoutBase = 45, TimeoutFactor = 4 }

type Session = {
	done: boolean,
	ok: boolean?,
	reason: string?,
	details: { [string]: any }?,
	waiters: { thread },
}

type StuckData = {
	lastPos: Vector3?,
	lastTime: number,
	strikes: number,
}

type AgentData = {
	Character: Model?,
	Humanoid: Humanoid,
	Root: BasePart,
	Options: Types.ResolvedOptions,
	Reached: Signal.Signal,
	Failed: Signal.Signal,
	Blocked: Signal.Signal,
	Jumped: Signal.Signal,
	CustomWaypoint: Signal.Signal,
	_userOptions: Types.Options,
	_state: Types.AgentState,
	_target: Types.TargetLike?,
	_goal: Vector3?,
	_cacheGoal: Vector3?,
	_route: { Types.Waypoint }?,
	_index: number,
	_planning: boolean,
	_replanRequested: boolean,
	_generation: number,
	_forceAdopt: boolean,
	_lastPlanTime: number,
	_lastProbe: number,
	_lastJump: number,
	_jumpPlan: Predictor.Plan?,
	_directStart: number,
	_airStart: number,
	_airTarget: Vector3?,
	_airDir: Vector3?,
	_suspended: boolean,
	_suspendedAt: number,
	_stuck: StuckData,
	_params: RaycastParams?,
	_paramsVersion: number,
	_connections: { RBXScriptConnection },
	_blockedConn: RBXScriptConnection?,
	_session: Session?,
	_destroyed: boolean,
	_routeDirty: boolean,
	_lastRouteCheck: number,
	_routeFromSolver: boolean,
	_blockedRetryUntil: number,
	_plannedGoal: Vector3?,
	_lastTargetCheck: number,
	_sessionStart: number,
	_maxRouteLen: number,
	_lastCalcTime: number?,
	_lastDetails: { [string]: any }?,
	_lastFailure: { reason: string, details: { [string]: any } }?,
	_curveLimit: number,
	_lastCurveCheck: number,
}

export type Agent = typeof(setmetatable({} :: AgentData, Agent))

-- ===================== Sessão (Await) =====================
-- Uma sessão por MoveTo. Await é implementado com threads em vez de BindableEvent: sem
-- instância para vazar e sem depender da ordem de entrega do sinal ao destruir o agente.

local function newSession(): Session
	return { done = false, ok = nil, reason = nil, details = nil, waiters = {} }
end

local function finishSession(self: Agent, ok: boolean, reason: string?, details: { [string]: any }?)
	local s = self._session
	if not s or s.done then
		return
	end
	s.done, s.ok, s.reason, s.details = true, ok, reason, details
	local waiters = s.waiters
	s.waiters = {}
	for _, thread in ipairs(waiters) do
		task.spawn(thread, ok, reason, details)
	end
end

local function fire(self: Agent, signal: Signal.Signal, ...: any)
	if not self._destroyed then
		signal:Fire(...)
	end
end

-- ===================== Criação =====================

-- Pode dar yield por até LOAD_TIMEOUT se o personagem ainda estiver carregando.
function Agent.new(characterOrHumanoid: Types.CharacterLike, options: Types.Options?): Agent
	local model = Util.resolveModel(characterOrHumanoid)
	local humanoid = Util.resolveHumanoid(characterOrHumanoid)
	if not humanoid and model then
		humanoid = model:WaitForChild("Humanoid", LOAD_TIMEOUT) :: Humanoid?
	end
	local root = Util.resolveRoot(characterOrHumanoid)
	if not root and model then
		local found = model:WaitForChild("HumanoidRootPart", LOAD_TIMEOUT)
		root = if found and found:IsA("BasePart") then found else nil
	end
	if not humanoid or not root then
		error("SmartPath: Agent.new: o personagem precisa de um Humanoid e um HumanoidRootPart", 2)
	end

	local userOptions = Config.overlay({}, options)
	local self = (
		setmetatable({
			Character = model,
			Humanoid = humanoid,
			Root = root,
			Options = Config.resolve(humanoid, userOptions),
			Reached = Signal.new(),
			Failed = Signal.new(),
			Blocked = Signal.new(),
			Jumped = Signal.new(),
			CustomWaypoint = Signal.new(),
			_userOptions = userOptions,
			_state = "Idle",
			_target = nil,
			_goal = nil,
			_cacheGoal = nil,
			_route = nil,
			_index = 1,
			_planning = false,
			_replanRequested = false,
			_generation = 0,
			_forceAdopt = false,
			_lastPlanTime = 0,
			_lastProbe = 0,
			_lastJump = 0,
			_jumpPlan = nil,
			_directStart = 0,
			_airStart = 0,
			_airTarget = nil,
			_airDir = nil,
			_suspended = false,
			_suspendedAt = 0,
			_stuck = { lastPos = nil, lastTime = 0, strikes = 0 },
			_params = nil,
			_paramsVersion = -1,
			_connections = {},
			_blockedConn = nil,
			_session = nil,
			_destroyed = false,
			_routeDirty = false,
			_lastRouteCheck = 0,
			_routeFromSolver = false,
			_blockedRetryUntil = 0,
			_plannedGoal = nil,
			_lastTargetCheck = 0,
			_sessionStart = 0,
			_maxRouteLen = 0,
			_lastCalcTime = nil,
			_lastDetails = nil,
			_lastFailure = nil,
			_curveLimit = math.huge,
			_lastCurveCheck = 0,
		}, Agent) :: any
	) :: Agent

	table.insert(
		self._connections,
		RunService.PreSimulation:Connect(function()
			self:_step()
		end)
	)
	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			self:_onCharacterLost()
		end)
	)
	table.insert(
		self._connections,
		Geometry.PartAdded:Connect(function(part: BasePart)
			self:_onPartAdded(part)
		end)
	)
	local function onRemoved(_, parent: Instance?)
		if not parent then
			self:_onCharacterLost()
			task.delay(REMOVED_DESTROY_DELAY, function()
				if not self._destroyed then
					self:Destroy()
				end
			end)
		end
	end
	table.insert(self._connections, humanoid.AncestryChanged:Connect(onRemoved))
	table.insert(self._connections, root.AncestryChanged:Connect(onRemoved))

	-- NPC no servidor: a física fica sempre no servidor (sem troca de dono no meio do salto)
	if RunService:IsServer() and not (model and Players:GetPlayerFromCharacter(model)) then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
	return self
end

-- ===================== API pública =====================

-- Não bloqueia. Um MoveTo novo cancela o anterior (o Await do anterior devolve
-- false, "cancelled").
function Agent.MoveTo(self: Agent, target: Types.TargetLike)
	if self._destroyed then
		error("SmartPath: Agent:MoveTo chamado num agente destruído", 2)
	end
	local goal = Util.resolveTargetPosition(target)
	if not goal then
		error("SmartPath: Agent:MoveTo: destino inválido (esperado Vector3, BasePart ou Model)", 2)
	end

	finishSession(self, false, Errors.Cancelled, {})
	self._session = newSession()

	self._generation += 1 -- invalida qualquer cálculo em voo do destino anterior
	self._target = target
	self._goal = goal
	self._cacheGoal = nil
	self._route = nil
	self._index = 1
	self._jumpPlan = nil
	self._state = "Following"
	self._forceAdopt = true
	self._stuck = { lastPos = nil, lastTime = 0, strikes = 0 }
	self._routeFromSolver = false
	self._routeDirty = false
	self._blockedRetryUntil = 0
	self._plannedGoal = nil
	self._lastFailure = nil
	self:_restartBudget()
	self:_watchPath(nil)

	if self.Humanoid.Health <= 0 or not self.Root.Parent then
		self:_fail(Errors.CharacterLost, {})
		return
	end
	-- NaN ou infinito vindo de um cálculo do jogo: não é um lugar; falha em vez de propagar NaN
	local m = goal.X + goal.Y + goal.Z
	if m ~= m or math.abs(m) == math.huge then
		self:_fail(Errors.GoalUnreachable, { requestedGoal = goal })
		return
	end
	self:_requestPlan(true)
end

-- Yield até chegar ou falhar. Retorna (true) ou (false, motivo, details).
function Agent.Await(self: Agent): (boolean, string?, { [string]: any }?)
	local s = self._session
	if not s then
		return false, Errors.Cancelled, {}
	end
	if s.done then
		return s.ok :: boolean, s.reason, s.details
	end
	table.insert(s.waiters, coroutine.running())
	return coroutine.yield()
end

function Agent.Stop(self: Agent)
	self:_halt()
	finishSession(self, false, Errors.Cancelled, {})
end

-- Pausa sem perder a rota (cutscene, dash, stun). Ao retomar, continua do waypoint certo.
function Agent.SetSuspended(self: Agent, suspended: boolean)
	if self._suspended == suspended or self._destroyed then
		return
	end
	self._suspended = suspended
	if suspended then
		self._suspendedAt = os.clock()
		-- Move é persistente: sem zerar, o Humanoid continuaria andando na última direção
		if self.Humanoid.Parent then
			self.Humanoid:Move(Vector3.zero, false)
		end
	else
		-- a pausa não conta para os timeouts de salto
		local paused = os.clock() - self._suspendedAt
		self._directStart += paused
		self._airStart += paused
		self._sessionStart += paused
		self._stuck.lastPos = nil
		if self._route and self._state == "Following" then
			self._index = self:_selectStartIndex(self._route, self._index)
		end
	end
end

function Agent.GetState(self: Agent): Types.AgentState
	return self._state
end

function Agent.GetRoute(self: Agent): { Types.Waypoint }?
	return self._route
end

-- Aceita um subconjunto de opções; o resto continua como estava. A rota atual não é refeita.
function Agent.SetOptions(self: Agent, partial: Types.Options)
	self._userOptions = Config.overlay(self._userOptions, partial)
	self.Options = Config.resolve(self.Humanoid, self._userOptions)
end

function Agent.Destroy(self: Agent)
	if self._destroyed then
		return
	end
	self:_halt()
	finishSession(self, false, Errors.Cancelled, {})
	self._destroyed = true
	for _, c in ipairs(self._connections) do
		if c.Connected then
			c:Disconnect()
		end
	end
	table.clear(self._connections)
	self.Reached:Destroy()
	self.Failed:Destroy()
	self.Blocked:Destroy()
	self.Jumped:Destroy()
	self.CustomWaypoint:Destroy()
end

-- Só para testes: quantas conexões do agente ainda estão vivas (deve ser 0 após Destroy).
function Agent._liveConnectionCount(self: Agent): number
	local n = 0
	for _, c in ipairs(self._connections) do
		if c.Connected then
			n += 1
		end
	end
	if self._blockedConn and self._blockedConn.Connected then
		n += 1
	end
	return n
end

-- ===================== Interno: parada e falha =====================

-- Para tudo sem resolver a sessão (quem chama decide: Stop cancela, _arrive conclui).
function Agent._halt(self: Agent)
	self._generation += 1
	self._state = "Idle"
	self._goal = nil
	self._target = nil
	self._cacheGoal = nil
	self._route = nil
	self._jumpPlan = nil
	self._airTarget = nil
	self._airDir = nil
	self:_watchPath(nil)
	if self.Humanoid.Parent then
		self.Humanoid:Move(Vector3.zero, false)
	end
end

function Agent._fail(self: Agent, reason: string, details: { [string]: any }?)
	local d: { [string]: any } = details or {}
	self._lastFailure = { reason = reason, details = d }
	-- invisible_collider vindo do solver já foi impresso e desenhado lá; só o que nasce de stuck é daqui
	local fromSolver = reason == Errors.InvisibleCollider and d.underlying ~= Errors.Stuck
	if self.Options.Debug and DRAWN_BY_AGENT[reason] and not fromSolver then
		Util.debugPrint(true, "falha:", reason, Diagnostics.explain(reason, d))
		Debug.failure(reason, d, DEBUG_LIFETIME)
	end
	self:_halt()
	self._state = "Failed"
	finishSession(self, false, reason, d)
	fire(self, self.Failed, reason, d)
end

function Agent._arrive(self: Agent)
	local target = self._target
	if target and typeof(target) == "Instance" then
		local pos = Util.resolveTargetPosition(target)
		if pos and Util.flat(pos - self.Root.Position).Magnitude > TARGET_RESUME_DISTANCE then
			-- o alvo andou depois do último cálculo: segue em vez de declarar chegada. Sem rota, o
			-- passo não chama _arrive de novo enquanto o replan não termina.
			self._goal = pos
			self._route = nil
			self._forceAdopt = true
			self:_restartBudget()
			if self.Humanoid.Parent then
				self.Humanoid:Move(Vector3.zero, false) -- Move é persistente
			end
			self:_requestPlan(true)
			return
		end
	end
	self:_halt()
	finishSession(self, true, nil, nil)
	-- por último: um MoveTo chamado dentro do handler de Reached começa uma sessão nova sem
	-- ser atropelado por este código
	fire(self, self.Reached)
end

function Agent._onCharacterLost(self: Agent)
	if self._destroyed or self._state == "Idle" or self._state == "Failed" then
		return
	end
	self:_fail(Errors.CharacterLost, {})
end

-- A rota atual foi bloqueada, avisada pela engine (Path.Blocked) ou detectada por nós
-- (_checkRoute). Para o agente para não empurrar o obstáculo, descarta a rota e replaneja.
function Agent._onBlocked(self: Agent)
	if not self._goal or self._destroyed then
		return
	end
	fire(self, self.Blocked)
	RouteSolver.getSharedCache():invalidateGoal(self._cacheGoal or self._goal)
	self._route = nil
	self._routeFromSolver = false
	self._blockedRetryUntil = os.clock() + BLOCKED_RETRY_WINDOW
	self._forceAdopt = true
	if self.Humanoid.Parent then
		self.Humanoid:Move(Vector3.zero, false) -- Move é persistente
	end
	self:_requestPlan(true)
end

-- Uma parte colidível entrou no workspace: a rota pode ter sido bloqueada. Personagens (que se
-- movem sozinhos e nascem com dezenas de partes) não contam.
function Agent._onPartAdded(self: Agent, part: BasePart)
	if self._destroyed or self._state == "Idle" or self._state == "Failed" then
		return
	end
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return
	end
	self._routeDirty = true
end

-- Revalida os segmentos restantes da rota com a mesma varredura que a aceitou.
function Agent._checkRoute(self: Agent)
	local now = os.clock()
	if now - self._lastRouteCheck < ROUTE_CHECK_INTERVAL then
		return -- continua suja; tenta no próximo frame elegível
	end
	local route = self._route
	if self._planning or self._state ~= "Following" or not route or not self._routeFromSolver then
		-- sem rota validada para checar (calculando, no ar, ou rota que não veio do solver): a
		-- rota nova, quando chegar, já foi validada contra o mundo atual
		if not self._planning then
			self._routeDirty = false
		end
		return
	end
	self._routeDirty = false
	self._lastRouteCheck = now
	local clear = RouteSolver.isRouteClear(self.Humanoid, route, self.Options, math.max(1, self._index - 1), self._target)
	if not clear then
		self:_onBlocked()
	end
end

-- Path.Blocked pertence ao objeto Path da rota atual; troca a conexão a cada rota nova.
function Agent._watchPath(self: Agent, path: Path?)
	if self._blockedConn then
		self._blockedConn:Disconnect()
		self._blockedConn = nil
	end
	if path then
		self._blockedConn = path.Blocked:Connect(function()
			self:_onBlocked()
		end)
	end
end

-- ===================== Interno: planejamento =====================

function Agent._getParams(self: Agent): RaycastParams
	local v = Geometry.getVersion()
	local params = self._params
	if not params or v ~= self._paramsVersion then
		local exclude: { Instance } = { self.Character or self.Root }
		params = Geometry.buildRaycastParams(exclude)
		self._params = params
		self._paramsVersion = v
	end
	return params :: RaycastParams
end

-- Orçamento de tempo da movimentação atual (código `timeout`). Recomeça quando o alvo se move.
function Agent._restartBudget(self: Agent)
	self._sessionStart = os.clock()
	self._maxRouteLen = 0
end

function Agent._checkTimeout(self: Agent)
	local userSpeed = self._userOptions.Agent and self._userOptions.Agent.WalkSpeed
	local speed = math.max(userSpeed or self.Humanoid.WalkSpeed, 1)
	local budget = Agent._tuning.TimeoutBase + Agent._tuning.TimeoutFactor * self._maxRouteLen / speed
	local elapsed = os.clock() - self._sessionStart
	if elapsed > budget then
		self:_fail(Errors.Timeout, { elapsed = math.floor(elapsed * 10 + 0.5) / 10 })
	end
end

function Agent._requestPlan(self: Agent, force: boolean)
	if self._destroyed then
		return
	end
	if self._planning then
		self._replanRequested = true
		return
	end
	if not force and os.clock() - self._lastPlanTime < MIN_REPLAN_INTERVAL then
		return
	end
	self._planning = true
	task.spawn(self._plan, self)
end

-- Alvo móvel: refaz a rota quando o alvo se afasta do destino do último cálculo.
function Agent._checkTarget(self: Agent)
	local target = self._target
	if not target or typeof(target) ~= "Instance" then
		return
	end
	local now = os.clock()
	if now - self._lastTargetCheck < TARGET_CHECK_INTERVAL then
		return
	end
	self._lastTargetCheck = now
	local pos = Util.resolveTargetPosition(target)
	local planned = self._plannedGoal
	if pos and planned and (pos - planned).Magnitude > TARGET_MOVE_THRESHOLD then
		self._goal = pos
		self._forceAdopt = true -- o destino mudou: a histerese não pode manter a rota velha
		self:_restartBudget() -- perseguir um alvo que se move não estoura o tempo máximo
		self:_requestPlan(true)
	end
end

function Agent._plan(self: Agent)
	local gen = self._generation
	local target = self._target
	if not target then
		self._planning = false
		return
	end
	self._lastPlanTime = os.clock()
	if typeof(target) == "Instance" then
		-- o solver relê a posição do alvo; o Agent guarda a mesma para arrival, salto direto e
		-- para saber a partir de quanto o alvo "se moveu"
		self._goal = Util.resolveTargetPosition(target) or self._goal
	end
	self._plannedGoal = self._goal

	-- destino igual à posição (ou a menos de um raio de chegada): já chegou, sem calcular rota
	local here = self.Root.Position
	local plannedGoal = self._goal
	if
		plannedGoal
		and Util.flat(plannedGoal - here).Magnitude <= ARRIVE_RADIUS
		and math.abs(plannedGoal.Y - here.Y) <= math.max(self.Options.Agent.Height, ALREADY_THERE_HEIGHT_TOLERANCE)
	then
		self._planning = false
		self:_arrive()
		return
	end

	-- StreamingEnabled: no cliente, a geometria perto do destino pode nem existir ainda
	if
		plannedGoal
		and workspace.StreamingEnabled
		and RunService:IsClient()
		and (plannedGoal - here).Magnitude > STREAM_REQUEST_MIN_DISTANCE
	then
		local player = Players.LocalPlayer
		if player then
			pcall(function()
				player:RequestStreamAroundAsync(plannedGoal, STREAM_REQUEST_TIMEOUT)
			end)
		end
	end

	local t0 = os.clock()
	local wps, reason, details = RouteSolver.solve(self.Humanoid, target, self.Options)
	self._lastCalcTime = os.clock() - t0

	if self._destroyed then
		return
	end
	if gen ~= self._generation or not self._goal then
		-- o destino mudou (ou houve Stop) durante o cálculo: descarta a rota, sem rota fantasma
		self._planning = false
		self._replanRequested = false
		if self._goal then
			self:_requestPlan(true)
		end
		return
	end

	if wps then
		self:_adoptRoute(wps, details or {}, gen)
	else
		self:_handleNoRoute(reason or Errors.NoPath, details or {})
	end

	self._planning = false
	if self._replanRequested then
		self._replanRequested = false
		task.delay(MIN_REPLAN_INTERVAL, function()
			if self._goal and not self._destroyed then
				self:_requestPlan(true)
			end
		end)
	end
end

function Agent._adoptRoute(self: Agent, wps: { Types.Waypoint }, details: { [string]: any }, gen: number)
	local rootPos = self.Root.Position
	local newLen = Util.pathLength(wps, rootPos, 2)

	-- histerese: uma rota nova só substitui a atual se for pelo menos `Hysteresis` mais curta,
	-- exceto em replan forçado (bloqueio, stuck, destino novo). Evita a troca de lado que gera o
	-- zigue-zague lateral.
	if not self._forceAdopt and self._route and self._state == "Following" then
		local curLen = Util.pathLength(self._route, rootPos, self._index)
		if newLen > curLen * (1 - self.Options.Stability.Hysteresis) then
			return
		end
	end
	self._forceAdopt = false
	self._route = wps
	self._lastDetails = details
	self._curveLimit = math.huge
	self._maxRouteLen = math.max(self._maxRouteLen, newLen)
	self._routeFromSolver = true
	self._blockedRetryUntil = 0
	self._index = self:_selectStartIndex(wps, 1)
	if self._state ~= "Airborne" then
		self._state = "Following"
	end
	self._cacheGoal = details.cacheGoal
	self:_watchPath(details.path)

	if self.Options.Debug then
		Debug.route(wps, DEBUG_LIFETIME)
		local used, full = details.radius, details.agentRadius
		if typeof(used) == "number" and typeof(full) == "number" and wps[1] then
			Debug.radius(wps[1].Position, used, full, DEBUG_LIFETIME)
		end
	end

	self:_considerDirectJump(newLen, gen)
end

function Agent._analyzeToward(
	self: Agent,
	targetPos: Vector3,
	probeDistance: number?
): (Predictor.Plan?, string, { [string]: any }?)
	local userMax = self._userOptions.Jump and self._userOptions.Jump.MaxHeight
	local userSpeed = self._userOptions.Agent and self._userOptions.Agent.WalkSpeed
	return Predictor.analyze({
		root = self.Root,
		humanoid = self.Humanoid,
		targetPos = targetPos,
		params = self:_getParams(),
		agentRadius = self.Options.Agent.Radius,
		agentHeight = self.Options.Agent.Height,
		-- vivos: o jogo pode mudar WalkSpeed/JumpHeight depois que o agente foi criado
		walkSpeed = userSpeed or self.Humanoid.WalkSpeed,
		maxJumpHeight = userMax,
		probeDistance = probeDistance,
	})
end

-- Atalho por salto (predição proativa): se a rota dá uma volta grande, analisa a linha reta até
-- o destino; se há obstáculo saltável, valida uma rota a partir do ponto de pouso. Só adota o
-- salto se (decolagem->pouso) + (pouso->destino) for bem mais curto que o desvio: isso impede
-- saltar para um beco.
function Agent._considerDirectJump(self: Agent, pathLen: number, gen: number)
	if not self.Options.Jump.Enabled then
		return
	end
	local goal, target = self._goal, self._target
	if not goal or not target then
		return
	end
	local rootPos = self.Root.Position
	local straight = Util.flat(goal - rootPos).Magnitude
	if straight < 1 or pathLen / straight < self.Options.Jump.DetourRatio then
		return
	end

	local plan = self:_analyzeToward(goal)
	if not plan then
		return
	end

	local after = RouteSolver.solve(self.Humanoid, target, self.Options, nil, plan.landingPoint)
	if self._destroyed or gen ~= self._generation or not after then
		return
	end
	local afterLen = Util.pathLength(after, plan.landingPoint, 2)
	local viaJump = Util.flat(plan.landingPoint - rootPos).Magnitude + afterLen
	if viaJump >= pathLen * (1 - MIN_GAIN_RATIO) then
		return
	end

	self._jumpPlan = plan
	self._route = after
	self._index = 1
	self._state = "DirectJump"
	self._directStart = os.clock()
end

-- Sem rota: o destino pode estar atrás de um obstáculo que a malha não sabe saltar (a engine
-- ignora o JumpHeight real do Humanoid). Tenta o salto direto antes de desistir.
function Agent._handleNoRoute(self: Agent, reason: string, details: { [string]: any })
	local goal = self._goal
	if goal and self.Options.Jump.Enabled then
		local plan = self:_analyzeToward(goal)
		if plan then
			self._jumpPlan = plan
			local goalWp: Types.Waypoint = { Position = goal, Action = WALK, Label = "", SmartAction = "Walk" }
			table.freeze(goalWp)
			local route = { goalWp }
			self._route = route
			if self.Options.Debug then
				Debug.route(route, DEBUG_LIFETIME)
			end
			self._routeFromSolver = false
			self._index = 1
			self._state = "DirectJump"
			self._directStart = os.clock()
			return
		end
	end
	if os.clock() < self._blockedRetryUntil then
		-- a malha ainda não incluiu o obstáculo que bloqueou a rota: espera e tenta de novo
		task.delay(BLOCKED_RETRY_INTERVAL, function()
			if self._goal and not self._destroyed and os.clock() < self._blockedRetryUntil then
				self._forceAdopt = true
				self:_requestPlan(true)
			end
		end)
		return
	end
	-- Diagnóstico (Fase 6): sem rota e sem salto possível, o primeiro obstáculo da linha reta até o
	-- destino pode ser a explicação. Olha a linha inteira, não só os 10 studs da sonda normal.
	if goal and reason == Errors.NoPath and self.Options.Jump.Enabled then
		local _, why, info = self:_analyzeToward(goal, math.huge)
		local code, refined = Diagnostics.refineJumpFailure(reason, details, why, info)
		if code and refined then
			self:_fail(code, refined)
			return
		end
	end
	self:_fail(reason, details)
end

-- `afterLanding`: chamado ao pousar de um salto. O waypoint Jump é o DESTINO do salto (D-019) e o
-- agente costuma pousar um pouco além dele; se já passou dele, avança em vez de voltar até lá.
function Agent._selectStartIndex(self: Agent, wps: { Types.Waypoint }, hint: number, afterLanding: boolean?): number
	local rootPos = self.Root.Position
	local from = math.max(1, hint)
	local best, bestD = from, math.huge
	for i = from, math.min(#wps, from + START_INDEX_LOOKAHEAD) do
		local d = Util.flat(wps[i].Position - rootPos).Magnitude
		if d < bestD then
			best, bestD = i, d
		end
	end
	-- se o mais próximo já ficou para trás (e é Walk, ou o destino de um salto que acabou de
	-- acontecer), avança
	local nxt = wps[best + 1]
	if nxt and (wps[best].Action == WALK or (afterLanding and wps[best].Action == JUMP)) then
		local seg = Util.flat(nxt.Position - wps[best].Position)
		if seg.Magnitude > 1e-3 and Util.flat(rootPos - wps[best].Position):Dot(seg) > 0 then
			best += 1
		end
	end
	return best
end

-- ===================== Interno: execução por frame =====================

function Agent._step(self: Agent)
	if self._destroyed then
		return
	end
	if
		not self._routeDirty
		and self._state == "Following"
		and self._routeFromSolver
		and os.clock() - self._lastRouteCheck >= ROUTE_RECHECK_INTERVAL
	then
		self._routeDirty = true
	end
	-- antes do return de suspenso: um agente pausado também precisa saber que a rota foi bloqueada
	if self._routeDirty then
		self:_checkRoute()
	end
	if self._suspended then
		return
	end
	local st = self._state
	if st == "Idle" or st == "Failed" then
		return
	end
	self:_checkTimeout()
	if self._state == "Failed" then
		return
	end
	self:_checkTarget()
	if st == "Airborne" then
		self:_stepAirborne()
	elseif st == "DirectJump" then
		self:_stepDirectJump()
	else
		self:_stepFollowing()
	end
end

-- ===== Curvas (Stability.Curves, D-035) =====

-- Um waypoint "duro" precisa ser alcançado de verdade: o que antecede um salto ou um link (a decolagem é
-- feita ali), o próprio Jump/Custom, e o último. Os demais ("macios") podem ser cortados em curva.
local function isHardWaypoint(wps: { Types.Waypoint }, i: number): boolean
	local wp, nxt = wps[i], wps[i + 1]
	return wp.Action ~= WALK or nxt == nil or nxt.Action ~= WALK
end

-- O agente já passou de um waypoint macio: está além dele, na direção do segmento seguinte.
local function passedSoftWaypoint(wps: { Types.Waypoint }, i: number, rootPos: Vector3): boolean
	if isHardWaypoint(wps, i) then
		return false
	end
	local seg = Util.flat(wps[i + 1].Position - wps[i].Position)
	return seg.Magnitude > 1e-3 and Util.flat(rootPos - wps[i].Position):Dot(seg) > 0
end

-- Ponto a `distance` studs adiante na poligonal [rootPos, waypoints...], parando no primeiro waypoint
-- duro (nunca passa dele).
local function pointAlongRoute(wps: { Types.Waypoint }, index: number, rootPos: Vector3, distance: number): Vector3
	local remaining = distance
	local from = rootPos
	local i = index
	while true do
		local wp = wps[i]
		local len = Util.flat(wp.Position - from).Magnitude
		if len >= remaining or isHardWaypoint(wps, i) or not wps[i + 1] then
			if len < 1e-3 then
				return wp.Position
			end
			return from:Lerp(wp.Position, math.min(remaining, len) / len)
		end
		remaining -= len
		from = wp.Position
		i += 1
	end
end

-- Para onde o agente mira. Sem Curves é o waypoint atual (comportamento de sempre). Com Curves, um
-- ponto adiante na rota, na maior distância (até o máximo) em que o corpo ainda cabe na reta até ele:
-- a validação é a mesma varredura de volume da rota, refeita a cada PROBE_INTERVAL.
function Agent._aimPoint(self: Agent, wps: { Types.Waypoint }, rootPos: Vector3): Vector3
	local wp = wps[self._index]
	if not self.Options.Stability.Curves then
		return wp.Position
	end
	local now = os.clock()
	local wanted = math.clamp(self.Humanoid.WalkSpeed * CURVE_LOOKAHEAD_TIME, CURVE_MIN_LOOKAHEAD, CURVE_MAX_LOOKAHEAD)
	if now - self._lastCurveCheck >= PROBE_INTERVAL then
		self._lastCurveCheck = now
		local bodyRadius = Util.getBodyRadius(self.Options.Agent.Radius)
		local origin = Vector3.new(rootPos.X, Util.getFeetY(self.Humanoid, self.Root) + 2.5, rootPos.Z)
		local distance = wanted
		local fits = false
		for _ = 1, CURVE_VALIDATE_ATTEMPTS do
			local aim = pointAlongRoute(wps, self._index, rootPos, distance)
			local delta = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
			if delta.Magnitude < 1e-3 or not workspace:Spherecast(origin, bodyRadius, delta, self:_getParams()) then
				fits = true
				break
			end
			distance /= 2
		end
		self._curveLimit = if fits then distance else 0
	end
	local distance = math.min(wanted, self._curveLimit)
	if distance <= 0 then
		return wp.Position
	end
	return pointAlongRoute(wps, self._index, rootPos, distance)
end

function Agent._stepFollowing(self: Agent)
	local wps = self._route
	if not wps then
		return -- aguardando cálculo
	end
	local rootPos = self.Root.Position

	local wp = wps[self._index]
	if not wp then
		return self:_arrive()
	end

	local arriveRadius = ARRIVE_RADIUS
	if self._index == #wps and typeof(self._target) == "Instance" then
		arriveRadius = TARGET_STOP_DISTANCE -- perseguindo um alvo: não empurra o corpo dele
	end
	if
		Util.flat(wp.Position - rootPos).Magnitude <= arriveRadius
		or (self.Options.Stability.Curves and passedSoftWaypoint(wps, self._index, rootPos))
	then
		local nextWp = wps[self._index + 1]
		if nextWp and nextWp.Action == JUMP and self.Options.Jump.Enabled then
			-- o waypoint Jump é o destino do salto (D-019): decola daqui, do waypoint anterior.
			-- Se ainda não deu (cooldown, no ar), fica e tenta no próximo frame.
			if not self:_jumpToward(nextWp.Position) then
				self:_checkStuck()
				return
			end
		elseif wp.Action == CUSTOM then
			self:_handleCustom(wp, nextWp)
		end
		self._index += 1
		wp = wps[self._index]
		if not wp then
			return self:_arrive()
		end
		if self._state ~= "Following" then
			return -- o waypoint disparou um salto
		end
	end

	local aim = self:_aimPoint(wps, rootPos) -- sem Curves, é o próprio waypoint
	local dir = Util.flat(aim - rootPos)
	if dir.Magnitude > 1e-3 then
		self.Humanoid:Move(dir.Unit, false)
	end

	-- predição reativa: sonda o segmento atual (cobre o que o pathfinding não previu)
	if self.Options.Jump.Enabled then
		local now = os.clock()
		if now - self._lastProbe >= PROBE_INTERVAL then
			self._lastProbe = now
			local plan = self:_analyzeToward(aim)
			if plan and Predictor.wallDistance(plan, rootPos) <= plan.takeoffDistance then
				if self:_executeJump(plan.jumpHeight, plan.direction, plan.landingPoint, plan) then
					return
				end
			end
		end
	end

	self:_checkStuck()
end

function Agent._stepDirectJump(self: Agent)
	local plan = self._jumpPlan
	if not plan then
		self._state = "Following"
		return
	end
	self.Humanoid:Move(plan.direction, false)

	if Predictor.wallDistance(plan, self.Root.Position) <= plan.takeoffDistance then
		self:_executeJump(plan.jumpHeight, plan.direction, plan.landingPoint, plan)
		return
	end
	if os.clock() - self._directStart > DIRECT_TIMEOUT then
		-- não conseguiu decolar: volta à navegação normal com replan forçado
		self._jumpPlan = nil
		self._state = "Following"
		self._forceAdopt = true
		RouteSolver.getSharedCache():invalidateGoal(self._cacheGoal or self._goal or self.Root.Position)
		self:_requestPlan(true)
	end
end

function Agent._stepAirborne(self: Agent)
	local rootPos = self.Root.Position
	local toLanding = self._airTarget and Util.flat(self._airTarget - rootPos) or nil
	if toLanding and toLanding.Magnitude > 0.3 then
		self._airDir = toLanding.Unit
	end
	-- sincronia de momento: continua comandando o movimento durante TODO o voo
	if self._airDir then
		self.Humanoid:Move(self._airDir, false)
	end

	local elapsed = os.clock() - self._airStart
	if elapsed > MIN_AIR_TIME and self.Humanoid.FloorMaterial ~= Enum.Material.Air then
		self._state = "Following"
		self._airTarget = nil
		self._jumpPlan = nil
		self._stuck.lastPos = nil
		if self._route then
			self._index = self:_selectStartIndex(self._route, self._index, true)
		end
	elseif elapsed > MAX_AIR_TIME then
		self._state = "Following"
		self._forceAdopt = true
		self:_requestPlan(true)
	end
end

-- ===================== Interno: saltos =====================

function Agent._executeJump(
	self: Agent,
	height: number,
	dir: Vector3?,
	landing: Vector3?,
	plan: Predictor.Plan?
): boolean
	if os.clock() - self._lastJump < JUMP_COOLDOWN then
		return false
	end
	local ok = JumpExecutor.execute(self.Options.Jump.Mode, self.Humanoid, self.Root, height, dir)
	if not ok then
		return false
	end
	if self.Options.Debug then
		Debug.jump((plan or { landingPoint = landing, direction = dir }) :: any, DEBUG_LIFETIME)
	end
	self._lastJump = os.clock()
	self._airTarget = landing
	self._airDir = dir
	self._state = "Airborne"
	self._airStart = os.clock()
	-- salto sem análise do Predictor (waypoint Jump da engine): plano sintético
	fire(self, self.Jumped, plan or { direction = dir, landingPoint = landing, jumpHeight = height, synthetic = true })
	return true
end

-- Salto pedido pelo pathfinding (Action = Jump), por link ou pelo anti-stuck: altura precisa se
-- o Predictor entende o obstáculo, senão o máximo que o Humanoid alcança.
-- Retorna true se o salto foi disparado.
function Agent._jumpToward(self: Agent, target: Vector3): boolean
	if not self.Options.Jump.Enabled then
		return false
	end
	local plan = self:_analyzeToward(target)
	if plan then
		return self:_executeJump(plan.jumpHeight, plan.direction, plan.landingPoint, plan)
	end
	local userMax = self._userOptions.Jump and self._userOptions.Jump.MaxHeight
	local dir = Util.flat(target - self.Root.Position)
	local maxHeight = userMax or Util.getMaxJumpHeight(self.Humanoid)
	if maxHeight <= 0 then
		return false -- JumpHeight 0: pedir um salto não faz nada
	end
	return self:_executeJump(
		maxHeight,
		if dir.Magnitude > 1e-3 then dir.Unit else nil,
		target,
		nil
	)
end

function Agent._handleCustom(self: Agent, wp: Types.Waypoint, nextWp: Types.Waypoint?)
	if wp.Label == JUMP_LINK_LABEL then
		self:_jumpToward(nextWp and nextWp.Position or wp.Position)
	else
		fire(self, self.CustomWaypoint, wp.Label, wp, nextWp)
	end
end

-- ===================== Interno: robustez =====================

function Agent._checkStuck(self: Agent)
	local now = os.clock()
	local pos = self.Root.Position
	local s = self._stuck
	-- WalkSpeed 0, sentado ou em PlatformStand: o corpo não anda de propósito (stun, veículo). Isso
	-- não é "travado": o agente espera, e o orçamento de tempo (timeout) é a rede de segurança.
	local h = self.Humanoid
	if h.WalkSpeed <= 0 or h.Sit or h.PlatformStand then
		s.lastPos = nil
		return
	end
	if not s.lastPos then
		s.lastPos, s.lastTime = pos, now
		return
	end
	if (pos - s.lastPos).Magnitude >= STUCK_MIN_PROGRESS then
		s.lastPos, s.lastTime, s.strikes = pos, now, 0
		return
	end
	if now - s.lastTime < STUCK_TIME then
		return
	end

	s.strikes += 1
	s.lastPos, s.lastTime = pos, now
	if s.strikes == 1 and self.Options.Jump.Enabled then
		-- 1ª tentativa: salto de escape
		local route = self._route
		local wp = route and route[self._index]
		if wp then
			self:_jumpToward(wp.Position)
		end
	elseif s.strikes <= MAX_STUCK_STRIKES then
		RouteSolver.getSharedCache():invalidateGoal(self._cacheGoal or self._goal or pos)
		self._forceAdopt = true
		self:_requestPlan(true)
	else
		local culprit, at = self:_findInvisibleAhead()
		if culprit then
			self:_fail(Errors.InvisibleCollider, {
				instance = culprit,
				position = at,
				underlying = Errors.Stuck,
				strikes = s.strikes,
			})
		else
			self:_fail(Errors.Stuck, { position = pos, strikes = s.strikes })
		end
	end
end

-- O que travou o agente pode ser uma parte invisível colidível que a malha não vê (marcada
-- NavIgnore, ou filtrada pela lib por parecer um gatilho) mas o corpo bate. Por isso o
-- Spherecast NÃO usa o filtro da lib: só exclui o próprio personagem. Devolve (parte, ponto).
function Agent._findInvisibleAhead(self: Agent): (BasePart?, Vector3?)
	local route = self._route
	local wp = route and route[self._index]
	if not wp then
		return nil, nil
	end
	local pos = self.Root.Position
	local flat = Util.flat(wp.Position - pos)
	if flat.Magnitude < 1e-3 then
		return nil, nil
	end
	local dir = flat.Unit
	local exclude: { Instance } = { self.Character or self.Root }
	local dbg = Debug.peekFolder()
	if dbg then
		table.insert(exclude, dbg)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true

	local feetY = Util.getFeetY(self.Humanoid, self.Root)
	local samples: { { center: Vector3, radius: number } } = {
		{ center = pos, radius = Util.getBodyRadius(self.Options.Agent.Radius) },
		{ center = Vector3.new(pos.X, feetY + STUCK_PROBE_KNEE_HEIGHT, pos.Z), radius = STUCK_PROBE_KNEE_RADIUS },
	}
	for _, sample in ipairs(samples) do
		local culprit, at = Diagnostics.findInvisibleAlong(
			params,
			sample.center - dir * STUCK_PROBE_BACK,
			sample.center + dir * STUCK_PROBE_AHEAD,
			sample.radius
		)
		if culprit then
			return culprit, at
		end
	end
	return nil, nil
end

return Agent
