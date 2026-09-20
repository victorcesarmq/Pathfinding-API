--!strict
-- Agent.luau
-- STUB -- implementado na Fase 4 (máquina de estados do nível 1 da API: Idle/Following/
-- DirectJump/Airborne/Failed — Seção 3.2 do plano de execução / Seção 7 da
-- ESPEC_NAVEGACAO_ROBLOX.md).

local Types = require(script.Parent.Types)

local Agent = {}
Agent.__index = Agent

function Agent.new(characterOrHumanoid: Types.CharacterLike, options: Types.Options?)
	error("SmartPath: not implemented (Fase 4) — Agent.new", 2)
end

return Agent
