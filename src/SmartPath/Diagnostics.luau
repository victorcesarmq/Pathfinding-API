--!strict
-- Diagnostics.luau
-- Fase 6: transforma falhas em causas que o desenvolvedor consegue agir sobre.
--   explain          código de erro + details -> frase legível (SmartPath.explain);
--   findInvisible*   procura a parte invisível colidível que bloqueia uma rota (invisible_collider);
--   refineJumpFailure converte um no_path em obstacle_too_tall / no_landing quando o Predictor
--                     explica por que o salto até o destino é impossível.
-- Só funções puras e consultas de leitura ao workspace; não guarda estado.

local Errors = require(script.Parent.Errors)
local Geometry = require(script.Parent.Geometry)

local Diagnostics = {}

type Details = { [string]: any }

-- ===== explain =====

local function num(v: any, decimals: number?): string
	if typeof(v) ~= "number" then
		return "?"
	end
	return string.format("%." .. (decimals or 1) .. "f", v)
end

local function vec(v: any): string
	if typeof(v) ~= "Vector3" then
		return "?"
	end
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

local function nameOf(inst: any): string
	if typeof(inst) ~= "Instance" then
		return "uma parte desconhecida"
	end
	local ok, full = pcall(function()
		return inst:GetFullName()
	end)
	return if ok then full else inst.Name
end

local function radiiList(list: any): string
	if typeof(list) ~= "table" or #list == 0 then
		return "nenhum"
	end
	local parts = {}
	for _, r in ipairs(list) do
		table.insert(parts, num(r, 2))
	end
	return table.concat(parts, ", ")
end

local function atLeast(d: Details): string
	return if d.atLeast then "pelo menos " else ""
end

-- Uma função por código. Cada uma tolera details incompleto: explain nunca pode errar.
local explainers: { [string]: (d: Details) -> string } = {
	[Errors.NoPath] = function(d)
		if d.noGround then
			return "O agente não tem chão sob os pés (está em queda ou fora do mapa), então não há de onde "
				.. "calcular uma rota."
		end
		return string.format(
			"Não existe rota até o destino, nem depois de tentar os raios %s. Confira se há chão contínuo entre "
				.. "os dois pontos e se algum obstáculo fechado isola o destino.",
			radiiList(d.triedRadii)
		)
	end,
	[Errors.CorridorTooNarrow] = function(d)
		local text = string.format(
			"O corredor só comporta um agente de raio até %s, mas o agente tem %s. Reduza Agent.Radius ou alargue "
				.. "a passagem.",
			num(d.requiredRadius),
			num(d.agentRadius)
		)
		if typeof(d.blockedAt) == "Vector3" then
			text ..= " O ponto mais apertado fica perto de " .. vec(d.blockedAt) .. "."
		end
		return text
	end,
	[Errors.ObstacleTooTall] = function(d)
		return string.format(
			"Há um obstáculo de %s%s studs no caminho e o agente salta no máximo %s. Aumente o JumpHeight, "
				.. "reduza o obstáculo ou abra um desvio.",
			atLeast(d),
			num(d.height),
			num(d.maxJump)
		)
	end,
	[Errors.NoLanding] = function(d)
		return string.format(
			"O agente conseguiria saltar o obstáculo, mas não há chão seguro do outro lado (queda de %s%s studs). "
				.. "Coloque chão depois do obstáculo ou abra outra passagem.",
			atLeast(d),
			num(d.drop)
		)
	end,
	[Errors.GoalUnreachable] = function(d)
		if typeof(d.nearestValid) == "Vector3" then
			return "O destino está fora da malha de navegação (dentro de uma parede ou no ar). O ponto válido mais "
				.. "próximo é "
				.. vec(d.nearestValid)
				.. "."
		end
		return "O destino está fora da malha de navegação (dentro de uma parede ou no ar) e não há ponto válido "
			.. "por perto."
	end,
	[Errors.InvisibleCollider] = function(d)
		return string.format(
			"A rota está bloqueada por uma parte invisível e colidível: %s. Se for um gatilho, dê a ela a tag "
				.. "NavIgnore (ou um nome como \"Trigger\"); se for um limite de mapa, dê a tag NavSolid; se não "
				.. "deveria colidir, desligue CanCollide.",
			nameOf(d.instance)
		)
	end,
	[Errors.Stuck] = function(d)
		return string.format(
			"O agente travou perto de %s depois de %s tentativas de sair. Algo que a malha de navegação não "
				.. "enxerga (uma parte com tag NavIgnore, um modelo sem colisão correta) está no caminho.",
			vec(d.position),
			if typeof(d.strikes) == "number" then tostring(d.strikes) else "?"
		)
	end,
	[Errors.Cancelled] = function(_)
		return "A movimentação foi cancelada por Stop() ou por um novo MoveTo."
	end,
	[Errors.CharacterLost] = function(_)
		return "O personagem morreu ou foi removido durante a movimentação."
	end,
	[Errors.Timeout] = function(d)
		return string.format(
			"O agente passou de %s s sem chegar ao destino. Ele pode estar preso repetindo a mesma tentativa, "
				.. "ou o destino se afastando dele.",
			num(d.elapsed)
		)
	end,
}

-- Devolve sempre uma string. `details` pode ser nil ou incompleto.
function Diagnostics.explain(reason: string?, details: Details?): string
	if reason == nil then
		return "Nenhum motivo informado."
	end
	local fn = explainers[reason]
	if not fn then
		return "Motivo desconhecido: " .. tostring(reason) .. "."
	end
	local d: Details = if typeof(details) == "table" then details else {}
	local ok, text = pcall(fn, d)
	if ok then
		return text
	end
	return "Falha (" .. reason .. ") com dados que a SmartPath não soube descrever."
end

-- ===== Causa: parte invisível colidível =====

-- Primeira parte invisível colidível que toca um ponto (o "onde bateu" de um corredor estreito,
-- ou o destino dentro de uma parede).
function Diagnostics.findInvisibleAt(position: Vector3, radius: number, overlap: OverlapParams): BasePart?
	local ok, parts = pcall(function()
		return workspace:GetPartBoundsInRadius(position, radius, overlap)
	end)
	if not ok then
		return nil
	end
	for _, part in ipairs(parts :: { BasePart }) do
		if Geometry.isInvisibleCollider(part) then
			return part
		end
	end
	return nil
end

-- A primeira coisa que o corpo (esfera de `radius`) bate no caminho reto de `from` até `to`: se for
-- uma parte invisível colidível, é ela. Só a PRIMEIRA batida conta: uma parede visível antes dela
-- pode ser a causa de verdade, e apontar a parte invisível de trás seria palpite.
function Diagnostics.findInvisibleAlong(params: RaycastParams, from: Vector3, to: Vector3, radius: number): (BasePart?, Vector3?)
	local delta = to - from
	if delta.Magnitude < 1e-3 then
		return nil, nil
	end
	local ok, hit = pcall(function()
		return workspace:Spherecast(from, radius, delta, params)
	end)
	if not ok or not hit then
		return nil, nil
	end
	local inst = (hit :: RaycastResult).Instance
	if inst and Geometry.isInvisibleCollider(inst) then
		return inst :: BasePart, (hit :: RaycastResult).Position
	end
	return nil, nil
end

-- ===== Causa: salto impossível =====

-- `why`/`info` vêm do Predictor.analyze feito em direção ao destino. Só converte no_path: se a
-- malha achou rota mas o corpo não coube (corridor_too_narrow) ou o destino não existe
-- (goal_unreachable), o problema não é um obstáculo a saltar. Retorna (código, details) ou nil.
function Diagnostics.refineJumpFailure(reason: string, details: Details, why: string?, info: Details?): (string?, Details?)
	if reason ~= Errors.NoPath or not info then
		return nil, nil
	end
	if why == "too_tall" or why == "insufficient_jump" then
		return Errors.ObstacleTooTall,
			{
				height = info.height,
				maxJump = info.maxJump,
				atLeast = info.atLeast,
				blockedAt = info.at,
				triedRadii = details.triedRadii,
			}
	end
	if why == "no_landing" or why == "drop_too_high" then
		return Errors.NoLanding,
			{ drop = info.drop, atLeast = info.atLeast, blockedAt = info.at, triedRadii = details.triedRadii }
	end
	return nil, nil
end

return Diagnostics
