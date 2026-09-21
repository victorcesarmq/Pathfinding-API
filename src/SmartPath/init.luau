--!strict
-- init.luau
-- Fachada pública da SmartPath (API estável):
--   nível 0 (MoveTo, MoveToAsync, GetRoute): uma linha, sem tabela de opções;
--   nível 1 (new): agente persistente;
--   nível 2 (Predictor, Simplifier, Geometry, Scheduler, Errors, Debug): peças soltas;
--   diagnóstico (Fase 6): explain(reason, details) e Debug (visualização e painel);
--   Service: camada de compatibilidade que espelha o PathfindingService.

local Types = require(script.Types)
local Errors = require(script.Errors)
local Config = require(script.Config)
local Util = require(script.Util)
local Scheduler = require(script.Scheduler)
local Geometry = require(script.Geometry)
local Simplifier = require(script.Simplifier)
local Predictor = require(script.Predictor)
local RouteSolver = require(script.RouteSolver)
local Agent = require(script.Agent)
local Compat = require(script.Compat)
local Diagnostics = require(script.Diagnostics)
local Debug = require(script.Debug)

local SmartPath = {}

SmartPath.Version = "1.0.0"

-- ===== Nível 2 — peças soltas =====
SmartPath.Predictor = Predictor
SmartPath.Simplifier = Simplifier
SmartPath.Geometry = Geometry
SmartPath.Scheduler = Scheduler
SmartPath.Errors = Errors
SmartPath.Debug = Debug

-- ===== Diagnóstico (Fase 6) =====

-- Frase legível para um código de erro e seus details (o que Failed/Await/MoveTo devolvem).
-- Sempre devolve uma string: código desconhecido ou details incompleto não geram erro.
function SmartPath.explain(reason: string?, details: { [string]: any }?): string
	return Diagnostics.explain(reason, details)
end

-- ===== Camada de compatibilidade =====
SmartPath.Service = Compat.Service

-- ===== Nível 1 — agente persistente =====

-- Um agente por personagem, para os níveis 0 e 1 (D-033): dois agentes no mesmo Humanoid brigariam
-- pelo Humanoid:Move. `SmartPath.new` recusa criar um segundo; `SmartPath.MoveTo` reaproveita o
-- que existir (inclusive um criado com `new`).
local agents: { [Humanoid]: Agent.Agent } = setmetatable({}, { __mode = "k" }) :: any
local watching: { [Humanoid]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function register(humanoid: Humanoid, agent: Agent.Agent)
	agents[humanoid] = agent
	if not watching[humanoid] then
		watching[humanoid] = true
		humanoid.Destroying:Connect(function()
			local current = agents[humanoid]
			agents[humanoid] = nil
			watching[humanoid] = nil
			if current then
				current:Destroy()
			end
		end)
	end
end

local function alive(agent: Agent.Agent?): boolean
	return agent ~= nil and not (agent :: any)._destroyed
end

local DUPLICATE_MESSAGE = "SmartPath.new: já existe um agente para este personagem. Use SmartPath.MoveTo (reaproveita "
	.. "o agente) ou chame :Destroy() no anterior antes de criar outro."

function SmartPath.new(characterOrHumanoid: Types.CharacterLike, options: Types.Options?): Agent.Agent
	local before = Util.resolveHumanoid(characterOrHumanoid)
	if before and alive(agents[before]) then
		error(DUPLICATE_MESSAGE, 2)
	end
	local agent = Agent.new(characterOrHumanoid, options)
	local humanoid = agent.Humanoid
	if alive(agents[humanoid]) then
		agent:Destroy() -- o personagem ainda carregava e outra chamada ganhou a corrida
		error(DUPLICATE_MESSAGE, 2)
	end
	register(humanoid, agent)
	return agent
end

-- ===== Nível 0 — uma linha =====

-- Nível 0: um agente por Humanoid, reaproveitado entre chamadas. MoveTo em laço não cria um agente (com
-- suas conexões) a cada chamada, e duas chamadas para o mesmo personagem se cancelam em vez de
-- brigar pelo Move (a antiga devolve false, "cancelled"). Chaves fracas; quando o Humanoid é
-- destruído o agente é destruído junto e a entrada some (o agente referencia o Humanoid, então
-- só a entrada explícita evita que o par se segure mutuamente). O registro é o de SmartPath.new.

local function agentFor(characterLike: Types.CharacterLike, options: Types.Options?): Agent.Agent
	local humanoid = Util.resolveHumanoid(characterLike)
	if not humanoid then
		error("SmartPath: o personagem precisa de um Humanoid", 3)
	end
	local existing = agents[humanoid]
	if existing and alive(existing) then
		if options then
			existing:SetOptions(options)
		end
		return existing
	end
	local created = Agent.new(humanoid, options)
	register(humanoid, created)
	return created
end

-- Move e só retorna quando terminar (bloqueante). target: Vector3 | BasePart | Model.
-- Retorna (true) ao chegar ou (false, motivo, details) — motivo é um código de SmartPath.Errors
-- e details o que SmartPath.explain espera (o terceiro valor não muda quem só lê ok, motivo).
function SmartPath.MoveTo(
	humanoid: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.Options?
): (boolean, string?, { [string]: any }?)
	local agent = agentFor(humanoid, options)
	agent:MoveTo(target)
	return agent:Await()
end

-- Versão não-bloqueante: devolve o agente já em movimento (use :Await(), os sinais, ou :Destroy()).
function SmartPath.MoveToAsync(
	humanoid: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.Options?
): Agent.Agent
	local agent = agentFor(humanoid, options)
	agent:MoveTo(target)
	return agent
end

-- Só calcula, não move. Devolve os waypoints melhorados ou (nil, motivo, details). Bloqueante.
function SmartPath.GetRoute(
	humanoid: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.Options?
): ({ Types.Waypoint }?, string?, { [string]: any }?)
	local resolved = Config.resolve(humanoid, options)
	local waypoints, reason, details = RouteSolver.solve(humanoid, target, resolved)
	if waypoints then
		return waypoints, nil, nil
	end
	return nil, reason, details
end

return SmartPath
