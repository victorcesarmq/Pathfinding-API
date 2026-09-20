--!strict
-- Simplifier.luau
-- STUB -- implementado na Fase 2 (string pulling seguro: valida volume livre E chão
-- contínuo, nunca remove waypoints com Action ≠ Walk — Seção 3.5 da
-- ESPEC_NAVEGACAO_ROBLOX.md).

local Types = require(script.Parent.Types)

local Simplifier = {}

function Simplifier.simplify(waypoints: { Types.Waypoint }, context: { [string]: any }): { Types.Waypoint }
	error("SmartPath: not implemented (Fase 2) — Simplifier.simplify", 2)
end

return Simplifier
