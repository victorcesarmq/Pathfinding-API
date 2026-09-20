--!strict
-- RouteSolver.luau
-- STUB -- implementado na Fase 2 (escada de raio adaptativo + validação por Spherecast
-- no raio real — algoritmo descrito na Fase 2 do plano de execução).

local Types = require(script.Parent.Types)

local RouteSolver = {}

function RouteSolver.solve(
	character: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.ResolvedOptions
): ({ Types.Waypoint }?, string?)
	error("SmartPath: not implemented (Fase 2) — RouteSolver.solve", 2)
end

return RouteSolver
