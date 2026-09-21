--!strict
-- Errors.luau
-- Códigos de erro diagnósticos da SmartPath.
-- CONGELADO: mudar uma chave aqui é mudança de contrato público, exige autorização.

export type ErrorCode =
	"no_path"
	| "corridor_too_narrow"
	| "obstacle_too_tall"
	| "no_landing"
	| "goal_unreachable"
	| "invisible_collider"
	| "stuck"
	| "cancelled"
	| "character_lost"
	| "timeout"

local Errors = {
	NoPath = "no_path" :: ErrorCode,
	CorridorTooNarrow = "corridor_too_narrow" :: ErrorCode,
	ObstacleTooTall = "obstacle_too_tall" :: ErrorCode,
	NoLanding = "no_landing" :: ErrorCode,
	GoalUnreachable = "goal_unreachable" :: ErrorCode,
	InvisibleCollider = "invisible_collider" :: ErrorCode,
	Stuck = "stuck" :: ErrorCode,
	Cancelled = "cancelled" :: ErrorCode,
	CharacterLost = "character_lost" :: ErrorCode,
	Timeout = "timeout" :: ErrorCode,
}

Errors.All = {
	Errors.NoPath,
	Errors.CorridorTooNarrow,
	Errors.ObstacleTooTall,
	Errors.NoLanding,
	Errors.GoalUnreachable,
	Errors.InvisibleCollider,
	Errors.Stuck,
	Errors.Cancelled,
	Errors.CharacterLost,
	Errors.Timeout,
} :: { ErrorCode }

function Errors.isValid(code: string): boolean
	for _, c in ipairs(Errors.All) do
		if c == code then
			return true
		end
	end
	return false
end

return Errors
