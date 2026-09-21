--!strict
-- Predictor.luau
-- Predição balística de salto.
-- Diz se o agente, com o JumpHeight REAL que tem (qualquer valor, não o limite interno
-- fixo da malha do PathfindingService), consegue saltar o obstáculo entre ele e o alvo, de
-- que altura, a que distância da parede decolar e onde pousa.
--
-- Etapas: (1) direção, (2) parede na altura do joelho, (3) alto demais?, (4) topo do
-- obstáculo, (5) profundidade e ponto de pouso, (6) balística e (7) corredor aéreo. A ordem
-- de 6 e 7 é invertida em relação à implementação de referência: o corredor precisa da altura do apex e do ponto
-- de decolagem, que só existem depois da balística (ver D-014).
--
-- Retorna (plano, "ok") ou (nil, motivo, dados?). Todo retorno negativo traz o motivo:
-- no_obstacle, not_a_wall, target_too_close, jump_too_weak, too_tall, top_not_found, no_landing,
-- drop_too_high, insufficient_jump, too_deep, air_blocked, ceiling. Os que medem algo trazem
-- também `dados` (Fase 6): too_tall e insufficient_jump { height, maxJump }, no_landing e
-- drop_too_high { drop }, todos com `at` (onde está a parede); `atLeast = true` quando o valor é um
-- mínimo (o raio só prova que há algo ali). O Agent os converte em obstacle_too_tall e no_landing.

local Util = require(script.Parent.Util)

local Predictor = {}
local UP = Vector3.yAxis

export type Context = {
	root: BasePart,
	humanoid: Humanoid,
	targetPos: Vector3,
	params: RaycastParams,
	agentRadius: number?,
	agentHeight: number?,
	walkSpeed: number?,
	maxJumpHeight: number?,
	-- até onde à frente procurar o obstáculo (default PROBE_DISTANCE); o diagnóstico de falha passa
	-- math.huge para achar o primeiro obstáculo da linha inteira até o destino
	probeDistance: number?,
}

export type Plan = {
	direction: Vector3,
	wallPoint: Vector3,
	wallInstance: Instance,
	obstacleHeight: number,
	obstacleDepth: number?,
	isPlatform: boolean,
	landingPoint: Vector3,
	jumpHeight: number,
	takeoffDistance: number,
	tUp: number,
	tDown: number,
}

-- Constantes de referência. Os valores marcados [VALIDAR]
-- dependem do rig e das animações do jogo e precisam ser confirmados no Studio.
local DEFAULT_AGENT_RADIUS = 2
local DEFAULT_AGENT_HEIGHT = 5
local PROBE_DISTANCE = 10 -- até onde à frente procuramos o obstáculo
local MIN_TARGET_DISTANCE = 1.5
local MIN_OBSTACLE_HEIGHT = 1.2 -- abaixo disso o Humanoid sobe sozinho (degrau) [VALIDAR]
local MAX_WALL_NORMAL_Y = 0.35 -- |normal.Y| acima disso é rampa, não parede
local HEIGHT_SAFETY_MARGIN = 0.4
local TOP_PROBE_CLEARANCE = 1
local TOP_PROBE_INSETS = { 0.3, 0.12, 0.04 } -- quanto "entrar" no topo, para paredes finas
local LANDING_SCAN_STEP = 0.5
local LANDING_SEARCH_MAX = 8 -- mais fundo que isso é plataforma: pousa em cima
local LANDING_MARGIN = 1
local MAX_SAFE_DROP = 14
local AIR_CLEARANCE = 0.5 -- folga entre os pés e o topo do obstáculo [VALIDAR]
local APEX_EXTRA = 0.6 -- altura extra mínima acima do necessário [VALIDAR]
local TAKEOFF_MARGIN = 0.4 -- [VALIDAR]
-- as esferas do corredor aéreo são um pouco menores que o corpo para não brigar com a borda
local BODY_CAST_SHRINK = 0.9

-- distância plana do centro do agente até a face do obstáculo, ao longo da direção do plano
function Predictor.wallDistance(plan: Plan, rootPos: Vector3): number
	return Util.flat(plan.wallPoint - rootPos):Dot(plan.direction)
end

-- Topo do MESMO objeto que o raio do joelho acertou. Se houver uma laje/viga sobre o
-- obstáculo, um raio vindo de cima acertaria a laje e confundiria teto com topo.
local function findTop(
	wallHit: RaycastResult,
	dir: Vector3,
	highY: number,
	feetY: number,
	fallback: RaycastParams
): number?
	local include = RaycastParams.new()
	include.FilterType = Enum.RaycastFilterType.Include
	include.FilterDescendantsInstances = { wallHit.Instance }
	for _, filter in ipairs({ include, fallback }) do
		for _, inset in ipairs(TOP_PROBE_INSETS) do
			local p = wallHit.Position + dir * inset
			local r = workspace:Raycast(Vector3.new(p.X, highY, p.Z), -UP * (highY - feetY + 0.5), filter)
			if r and (r.Position.Y - feetY) >= MIN_OBSTACLE_HEIGHT * 0.5 then
				return r.Position.Y
			end
		end
	end
	return nil
end

function Predictor.analyze(ctx: Context): (Plan?, string, { [string]: any }?)
	local root = ctx.root
	local humanoid = ctx.humanoid
	local rootPos = root.Position
	local feetY = Util.getFeetY(humanoid, root)
	local agentRadius = ctx.agentRadius or DEFAULT_AGENT_RADIUS
	local agentHeight = ctx.agentHeight or DEFAULT_AGENT_HEIGHT
	local bodyRadius = Util.getBodyRadius(agentRadius)
	local speed = ctx.walkSpeed or humanoid.WalkSpeed
	local maxJump = ctx.maxJumpHeight or Util.getMaxJumpHeight(humanoid)
	local g = workspace.Gravity

	-- 1) direção
	local toTarget = Util.flat(ctx.targetPos - rootPos)
	local dist = toTarget.Magnitude
	if dist < MIN_TARGET_DISTANCE then
		return nil, "target_too_close"
	end
	local dir = toTarget.Unit
	local probeDist = math.min(ctx.probeDistance or PROBE_DISTANCE, dist)

	local usable = maxJump - HEIGHT_SAFETY_MARGIN
	if usable <= MIN_OBSTACLE_HEIGHT then
		return nil, "jump_too_weak"
	end

	-- 2) parede na altura do joelho
	local kneeOrigin = Vector3.new(rootPos.X, feetY + MIN_OBSTACLE_HEIGHT, rootPos.Z)
	local wallHit = workspace:Raycast(kneeOrigin, dir * probeDist, ctx.params)
	if not wallHit then
		return nil, "no_obstacle"
	end
	if math.abs(wallHit.Normal.Y) > MAX_WALL_NORMAL_Y then
		return nil, "not_a_wall"
	end

	-- 3) alto demais? (raio à altura máxima útil + folga: se bate, o obstáculo passa disso)
	local highY = feetY + usable + TOP_PROBE_CLEARANCE
	local highHit =
		workspace:Raycast(Vector3.new(rootPos.X, highY, rootPos.Z), dir * (wallHit.Distance + 0.5), ctx.params)
	if highHit then
		-- o raio só diz que há algo naquela altura: a altura real é essa ou maior (atLeast)
		return nil, "too_tall", { height = highY - feetY, maxJump = maxJump, atLeast = true, at = wallHit.Position }
	end

	-- 4) topo do obstáculo
	local topY = findTop(wallHit, dir, highY, feetY, ctx.params)
	if not topY then
		return nil, "top_not_found"
	end
	local obstacleHeight = topY - feetY
	if obstacleHeight > usable then
		return nil, "too_tall", { height = obstacleHeight, maxJump = maxJump, at = wallHit.Position }
	end

	-- 5) profundidade e ponto de pouso
	local scanDrop = 0.5 + obstacleHeight + MAX_SAFE_DROP
	local depth: number? = nil
	local k = 0
	while k < LANDING_SEARCH_MAX do
		k += LANDING_SCAN_STEP
		local s = wallHit.Position + dir * k
		local r = workspace:Raycast(Vector3.new(s.X, topY + 0.5, s.Z), -UP * scanDrop, ctx.params)
		if not r or r.Position.Y < topY - 0.5 then
			depth = k -- fim do obstáculo; se não há chão, o pouso é validado logo abaixo
			break
		end
	end

	local isPlatform = depth == nil
	local landing: Vector3
	if isPlatform then
		-- obstáculo largo: pousa EM CIMA dele
		local p = wallHit.Position + dir * (agentRadius + LANDING_MARGIN)
		landing = Vector3.new(p.X, topY, p.Z)
	else
		local p = wallHit.Position + dir * ((depth :: number) + agentRadius + LANDING_MARGIN)
		local floor = workspace:Raycast(Vector3.new(p.X, topY + 0.5, p.Z), -UP * scanDrop, ctx.params)
		if not floor then
			-- sem chão em todo o alcance da varredura: a queda é essa ou maior (atLeast)
			return nil, "no_landing", { drop = obstacleHeight + MAX_SAFE_DROP, atLeast = true, at = wallHit.Position }
		end
		if topY - floor.Position.Y > MAX_SAFE_DROP then
			return nil, "drop_too_high", { drop = topY - floor.Position.Y, at = wallHit.Position }
		end
		landing = floor.Position
	end

	-- 6) balística. Em vez da altura mínima da implementação de referência (clareza + APEX_EXTRA), o apex é o menor
	-- que dá tempo ACIMA do obstáculo para o corpo cruzar a profundidade inteira: os pés
	-- precisam ficar acima do topo enquanto o centro percorre profundidade + 2 raios (a frente
	-- do corpo passa a face, a traseira passa a borda de trás). Tempo acima da clareza para um
	-- apex h acima dela: t = 2*sqrt(2h/g), logo h = g*t²/8.
	local clearH = obstacleHeight + AIR_CLEARANCE
	if clearH > maxJump then
		return nil, "insufficient_jump", { height = obstacleHeight, maxJump = maxJump, at = wallHit.Position }
	end
	local jumpH = clearH + APEX_EXTRA
	if not isPlatform then
		if speed <= 0 then
			return nil, "too_deep"
		end
		local travel = (depth :: number) + 2 * bodyRadius + TAKEOFF_MARGIN
		local t = travel / speed
		jumpH = clearH + math.max(APEX_EXTRA, g * t * t / 8)
		if jumpH > maxJump then
			return nil, "too_deep"
		end
	end
	jumpH = math.min(jumpH, maxJump) -- plataforma: basta alcançar o topo, o apex pode ser menor

	local v = math.sqrt(2 * g * jumpH)
	local sq = math.sqrt(math.max(v * v - 2 * g * clearH, 0))
	local tUp = (v - sq) / g -- quando o corpo cruza a altura de clareza, subindo
	local tDown = (v + sq) / g -- e descendo
	-- o centro decola a esta distância da face: a frente do corpo (centro + raio) chega na
	-- parede já na altura de clareza
	local takeoffDistance = speed * tUp + bodyRadius + TAKEOFF_MARGIN

	-- 7) corredor aéreo: o corpo ocupa uma coluna, dos pés (na altura de voo sobre o
	-- obstáculo) até a cabeça no apex. Duas esferas (pés e cabeça) deixam um vão vertical onde
	-- uma laje ou viga passa despercebida, então varremos esferas empilhadas cobrindo a coluna
	-- inteira, da decolagem até o pouso. A de baixo bloqueada é o "corpo no ar" (air_blocked);
	-- as de cima são teto (ceiling).
	local castRadius = bodyRadius * BODY_CAST_SHRINK
	local takeoffPoint = wallHit.Position - dir * takeoffDistance
	local flightLen = Util.flat(landing - takeoffPoint).Magnitude
	local baseY = topY + AIR_CLEARANCE + bodyRadius
	local topCenterY = math.max(feetY + jumpH + agentHeight - bodyRadius, baseY)
	-- Spherecast ignora tudo o que já sobrepõe a esfera na origem, então uma laje que começa
	-- antes do ponto de decolagem (teto sobre a aproximação, o caso comum) nunca seria vista
	-- pela varredura. Por isso cada nível também checa a sobreposição na origem.
	local overlap = OverlapParams.new()
	overlap.FilterType = ctx.params.FilterType
	overlap.FilterDescendantsInstances = ctx.params.FilterDescendantsInstances
	overlap.RespectCanCollide = true
	local y = baseY
	while true do
		local center = Vector3.new(takeoffPoint.X, y, takeoffPoint.Z)
		local blocked = #workspace:GetPartBoundsInRadius(center, castRadius, overlap) > 0
			or workspace:Spherecast(center, castRadius, dir * flightLen, ctx.params) ~= nil
		if blocked then
			return nil, if y == baseY then "air_blocked" else "ceiling"
		end
		if y >= topCenterY then
			break
		end
		y = math.min(y + castRadius, topCenterY) -- passo de um raio: as esferas se sobrepõem
	end

	return {
		direction = dir,
		wallPoint = wallHit.Position,
		wallInstance = wallHit.Instance,
		obstacleHeight = obstacleHeight,
		obstacleDepth = depth,
		isPlatform = isPlatform,
		landingPoint = landing,
		jumpHeight = jumpH,
		takeoffDistance = takeoffDistance,
		tUp = tUp,
		tDown = tDown,
	},
		"ok"
end

return Predictor
