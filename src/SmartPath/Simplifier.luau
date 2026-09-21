--!strict
-- Simplifier.luau
-- 1) remove duplicatas; 2) string pulling guloso com validação de volume livre E de chão
-- contínuo (Seção 3.5 da ESPEC_NAVEGACAO_ROBLOX.md, Fase 2 do plano).
-- Nunca remove waypoints cuja Action ≠ Walk e nunca atravessa um deles num atalho.
--
-- Custo: O(n²) em raycasts no pior caso. Com WaypointSpacing = math.huge o n é pequeno
-- (tipicamente < 15) e o resultado vai para o RouteCache, então o custo é pago uma vez
-- por par de células.

local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

local Simplifier = {}
local UP = Vector3.yAxis
local WALK = Enum.PathWaypointAction.Walk

export type Context = {
	params: RaycastParams,
	probeRadius: number,
	probeHeight: number,
	floorStep: number,
	maxFloorDelta: number,
	groundProbeUp: number,
}

-- Constantes da ESPEC de referência (NavConfig.Defaults.Stabilizer).
local DEDUP_DISTANCE = 0.5 -- waypoints Walk mais próximos que isso são o mesmo ponto
local PROBE_HEIGHT = 2.5 -- altura acima do chão onde a esfera viaja (tronco)
local FLOOR_STEP = 2 -- espaçamento das amostras de chão ao longo do segmento
local MAX_FLOOR_DELTA = 1.2 -- variação máxima de altura do piso num atalho
local GROUND_PROBE_UP = 2 -- os raios de chão partem daqui, acima do ponto amostrado

-- O raio da sonda é o raio FÍSICO do corpo (Util.getBodyRadius), não o Agent.Radius
-- inflado usado no CreatePath: string pulling não deve cortar onde o corpo não cabe, mas
-- também não deve recusar atalhos que o corpo faz de verdade.
function Simplifier.buildContext(params: RaycastParams, agentRadius: number): Context
	return {
		params = params,
		probeRadius = Util.getBodyRadius(agentRadius),
		probeHeight = PROBE_HEIGHT,
		floorStep = FLOOR_STEP,
		maxFloorDelta = MAX_FLOOR_DELTA,
		groundProbeUp = GROUND_PROBE_UP,
	}
end

local function canWalkStraight(a: Vector3, b: Vector3, ctx: Context): boolean
	local delta = b - a
	local flatDist = Util.flat(delta).Magnitude
	if flatDist < 0.1 then
		return true
	end

	-- (1) volume livre: esfera viajando na altura do tronco
	local hit = workspace:Spherecast(a + UP * ctx.probeHeight, ctx.probeRadius, delta, ctx.params)
	if hit then
		return false
	end

	-- (2) chão contínuo: amostras para baixo ao longo do segmento (evita cortar por cima
	-- de buracos, que o Spherecast na altura do tronco não vê)
	local n = math.max(1, math.ceil(flatDist / ctx.floorStep))
	for i = 1, n - 1 do
		local p = a:Lerp(b, i / n)
		local r =
			workspace:Raycast(p + UP * ctx.groundProbeUp, -UP * (ctx.groundProbeUp + ctx.maxFloorDelta), ctx.params)
		if not r then
			return false -- buraco
		end
		if math.abs(r.Position.Y - p.Y) > ctx.maxFloorDelta then
			return false -- degrau ou queda
		end
	end
	return true
end

local function innerAllWalk(wps: { Types.Waypoint }, i: number, j: number): boolean
	for k = i + 1, j - 1 do
		if wps[k].Action ~= WALK then
			return false
		end
	end
	return true
end

function Simplifier.simplify(waypoints: { Types.Waypoint }, ctx: Context): { Types.Waypoint }
	-- 1) deduplicação
	local dedup: { Types.Waypoint } = {}
	for _, wp in ipairs(waypoints) do
		local last = dedup[#dedup]
		if
			last
			and wp.Action == WALK
			and last.Action == WALK
			and (wp.Position - last.Position).Magnitude < DEDUP_DISTANCE
		then
			continue
		end
		table.insert(dedup, wp)
	end
	if #dedup <= 2 then
		return dedup
	end

	-- 2) string pulling guloso (do waypoint mais distante para o mais próximo)
	local result: { Types.Waypoint } = { dedup[1] }
	local anchor = 1
	while anchor < #dedup do
		local furthest = anchor + 1
		-- segmento que COMEÇA num waypoint de ação (salto/link) nunca é encurtado
		if dedup[anchor].Action == WALK then
			for j = #dedup, anchor + 2, -1 do
				if
					innerAllWalk(dedup, anchor, j)
					and canWalkStraight(dedup[anchor].Position, dedup[j].Position, ctx)
				then
					furthest = j
					break
				end
			end
		end
		table.insert(result, dedup[furthest])
		anchor = furthest
	end
	return result
end

return Simplifier
