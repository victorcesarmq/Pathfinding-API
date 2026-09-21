--!strict
-- Config.luau
-- Defaults da API pública (a tabela de opções é estável) + merge profundo + derivação
-- a partir do personagem. `nil` num campo de Options sempre significa "default ou
-- derivado do personagem" (zero configuração obrigatória).

local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

local Config = {}

-- abaixo disto o Humanoid não passa nem de um degrau (Predictor: MIN_OBSTACLE_HEIGHT)
local MIN_JUMP_HEIGHT = 1.2

local Defaults: Types.Options = {
	Indoor = {
		AdaptiveRadius = true,
		MinRadius = 0.5,
		RadiusSteps = { 1.5, 1.0, 0.5 },
	},
	Jump = {
		Enabled = true,
		Mode = "Native",
		DetourRatio = 1.4,
	},
	Stability = {
		Cache = true,
		Smoothing = true,
		Hysteresis = 0.15,
		Curves = false, -- desligado: quem não pede não muda de comportamento (D-035)
	},
	Geometry = {
		AutoFilter = true,
		RequireNameMatch = true,
	},
	Agent = {},
	Scheduler = {
		Priority = 0,
	},
	Debug = false,
}

Config.Defaults = Defaults

-- merge profundo: dicionários mesclam campo a campo; arrays (ex.: RadiusSteps) são
-- substituídos inteiros — misturar índices de arrays de tamanhos diferentes não tem
-- semântica clara aqui.
local function isArray(t: { [any]: any }): boolean
	return #t > 0
end

local function deepMerge(base: { [string]: any }, over: { [string]: any }?): { [string]: any }
	local out: { [string]: any } = {}
	for k, v in pairs(base) do
		local o = over and over[k]
		if type(v) == "table" and not isArray(v) and type(o) == "table" then
			out[k] = deepMerge(v, o)
		elseif o ~= nil then
			out[k] = o
		elseif type(v) == "table" then
			out[k] = table.clone(v)
		else
			out[k] = v
		end
	end
	if over then
		for k, v in pairs(over) do
			if out[k] == nil then
				out[k] = v
			end
		end
	end
	return out
end

function Config.merge(overrides: Types.Options?): { [string]: any }
	return deepMerge(Config.Defaults :: any, overrides :: any)
end

-- Mescla duas camadas de overrides do usuário, sem os defaults no meio: o Agent guarda o
-- que o usuário pediu e re-resolve a cada SetOptions, mantendo `nil` = "derive do personagem".
function Config.overlay(base: Types.Options?, over: Types.Options?): Types.Options
	return deepMerge((base or {}) :: any, over :: any) :: any
end

-- Resolve as opções finais para um personagem específico: aplica os overrides do
-- usuário sobre os defaults e preenche todo campo nil de Agent/Jump com um valor
-- derivado do próprio personagem.
function Config.resolve(character: Types.CharacterLike, overrides: Types.Options?): Types.ResolvedOptions
	local merged = Config.merge(overrides)

	local humanoid = Util.resolveHumanoid(character)
	local model = Util.resolveModel(character)

	local agent = merged.Agent
	if agent.Radius == nil then
		agent.Radius = model and Util.getAgentRadius(model) or 2
	end
	if agent.Height == nil then
		agent.Height = model and Util.getAgentHeight(model) or 5
	end
	if agent.WalkSpeed == nil then
		agent.WalkSpeed = humanoid and humanoid.WalkSpeed or 16
	end

	if merged.Jump.MaxHeight == nil then
		merged.Jump.MaxHeight = humanoid and Util.getMaxJumpHeight(humanoid) or 7.2
	end

	-- Um Humanoid que não salta (JumpHeight 0, JumpPower 0) não pode ganhar rotas com saltos: se o
	-- usuário não decidiu, Jump.Enabled é derivado do personagem (D-033). Vale na criação e no SetOptions.
	local userJump = overrides and overrides.Jump
	if not (userJump and userJump.Enabled ~= nil) and humanoid and Util.getMaxJumpHeight(humanoid) < MIN_JUMP_HEIGHT then
		merged.Jump.Enabled = false
	end

	return merged :: Types.ResolvedOptions
end

return Config
