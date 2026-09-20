--!strict
-- Compat.luau
-- STUB -- implementado na Fase 5 (camada de compatibilidade que espelha
-- PathfindingService — CreatePath/ComputeAsync/GetWaypoints/Status/Blocked, mais
-- SmartStatus/SmartDetails — Seção 3.4 do plano de execução).

local Compat = {}

Compat.Service = {}

function Compat.Service:CreatePath(options: { [string]: any }?)
	error("SmartPath: not implemented (Fase 5) — Service:CreatePath", 2)
end

return Compat
