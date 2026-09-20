--!strict
-- JumpExecutor.luau
-- STUB -- implementado na Fase 3 (execução do salto nos modos Native e Injected, com
-- restauração garantida das propriedades do Humanoid — Seção 6 da
-- ESPEC_NAVEGACAO_ROBLOX.md).

local JumpExecutor = {}

function JumpExecutor.canJump(humanoid: Humanoid): boolean
	error("SmartPath: not implemented (Fase 3) — JumpExecutor.canJump", 2)
end

function JumpExecutor.execute(mode: string, humanoid: Humanoid, root: BasePart, height: number, direction: Vector3?)
	error("SmartPath: not implemented (Fase 3) — JumpExecutor.execute", 2)
end

return JumpExecutor
