--!strict
-- init.luau
-- Fachada pública da SmartPath (Seção 3 do plano de execução, CONGELADA). Cada nível é
-- implementado nas fases seguintes; aqui só o contrato existe, para que
-- `require(ReplicatedStorage.SmartPath)` já funcione desde a Fase 0.

local Types = require(script.Types)
local Errors = require(script.Errors)
local Scheduler = require(script.Scheduler)
local Geometry = require(script.Geometry)
local Simplifier = require(script.Simplifier)
local Predictor = require(script.Predictor)
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

-- ===== Nível 0 — uma linha (Seção 3.1) =====

function SmartPath.MoveTo(humanoid: Types.CharacterLike, target: Types.TargetLike, options: Types.Options?): (boolean, string?)
	error("SmartPath: not implemented (Fase 4) — MoveTo", 2)
end

function SmartPath.MoveToAsync(humanoid: Types.CharacterLike, target: Types.TargetLike, options: Types.Options?)
	error("SmartPath: not implemented (Fase 4) — MoveToAsync", 2)
end

function SmartPath.GetRoute(humanoid: Types.CharacterLike, target: Types.TargetLike, options: Types.Options?): ({ Types.Waypoint }?, string?)
	error("SmartPath: not implemented (Fase 2) — GetRoute", 2)
end

-- ===== Nível 1 — agente persistente (Seção 3.2) =====

function SmartPath.new(characterOrHumanoid: Types.CharacterLike, options: Types.Options?)
	return Agent.new(characterOrHumanoid, options)
end

return SmartPath
