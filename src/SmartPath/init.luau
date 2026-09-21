--!strict
-- init.luau
-- Fachada pública da SmartPath (Seção 3 do plano de execução, CONGELADA):
--   nível 0 (MoveTo, MoveToAsync, GetRoute): uma linha, sem tabela de opções;
--   nível 1 (new): agente persistente;
--   nível 2 (Predictor, Simplifier, Geometry, Scheduler, Errors): peças soltas;
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

local SmartPath = {}

SmartPath.Version = "0.1.0"

-- ===== Nível 2 — peças soltas (Seção 3.3) =====
SmartPath.Predictor = Predictor
SmartPath.Simplifier = Simplifier
SmartPath.Geometry = Geometry
SmartPath.Scheduler = Scheduler
SmartPath.Errors = Errors

-- ===== Camada de compatibilidade (Seção 3.4) =====
SmartPath.Service = Compat.Service

-- ===== Nível 1 — agente persistente (Seção 3.2) =====

function SmartPath.new(characterOrHumanoid: Types.CharacterLike, options: Types.Options?): Agent.Agent
	return Agent.new(characterOrHumanoid, options)
end

-- ===== Nível 0 — uma linha (Seção 3.1) =====

-- Um agente por Humanoid, reaproveitado entre chamadas: MoveTo em laço não cria um agente (com
-- suas conexões) a cada chamada, e duas chamadas para o mesmo personagem se cancelam em vez de
-- brigar pelo Move (a antiga devolve false, "cancelled"). Chaves fracas; quando o Humanoid é
-- destruído o agente é destruído junto e a entrada some (o agente referencia o Humanoid, então
-- só a entrada explícita evita que o par se segure mutuamente).
local agents: { [Humanoid]: Agent.Agent } = setmetatable({}, { __mode = "k" }) :: any
local watching: { [Humanoid]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function agentFor(characterLike: Types.CharacterLike, options: Types.Options?): Agent.Agent
	local humanoid = Util.resolveHumanoid(characterLike)
	if not humanoid then
		error("SmartPath: o personagem precisa de um Humanoid", 3)
	end
	local agent: Agent.Agent? = agents[humanoid]
	if agent and (agent :: any)._destroyed then
		agent = nil
	end
	if not agent then
		agent = Agent.new(humanoid, options)
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
	elseif options then
		agent:SetOptions(options)
	end
	return agent :: Agent.Agent
end

-- Move e só retorna quando terminar (bloqueante). target: Vector3 | BasePart | Model.
-- Retorna (true) ao chegar ou (false, motivo) — motivo é um código de SmartPath.Errors.
function SmartPath.MoveTo(
	humanoid: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.Options?
): (boolean, string?)
	local agent = agentFor(humanoid, options)
	agent:MoveTo(target)
	local ok, reason = agent:Await()
	return ok, reason
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

-- Só calcula, não move. Devolve os waypoints melhorados ou (nil, motivo). Bloqueante.
function SmartPath.GetRoute(
	humanoid: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.Options?
): ({ Types.Waypoint }?, string?)
	local resolved = Config.resolve(humanoid, options)
	local waypoints, reason = RouteSolver.solve(humanoid, target, resolved)
	return waypoints, reason
end

return SmartPath
