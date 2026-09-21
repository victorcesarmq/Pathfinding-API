--!strict
-- RouteSolver.luau
-- Escada de raio adaptativo + validação por Spherecast no raio físico.
-- Transforma o NoPath do PathfindingService em rota utilizável em ambientes fechados, sem
-- nunca recomendar uma rota onde o corpo não cabe (D-002).
--
-- Fluxo (algoritmo da Fase 2):
--   1. origem aterrada: ponto do chão sob o root (+ offset); aguarda aterrar se no ar;
--   2. destino normalizado: projetado para o chão; dentro de geometria = goal_unreachable;
--   3. ComputeAsync com o raio configurado, depois com cada degrau da escada (RadiusSteps);
--   4. toda rota obtida é validada por Spherecast no raio físico do corpo (D-002, D-011);
--   5. sem rota: tenta AgentCanJump = false, depois um destino aproximado;
--   6. se tudo falhar, devolve o erro diagnóstico mais específico possível.
--
-- Todo ComputeAsync passa pelo Scheduler. `solve` DÁ YIELD (é bloqueante).
-- Toda falha sai por `fail` (Fase 6): se a causa é uma parte invisível colidível, o código vira
-- invisible_collider.

local PathfindingService = game:GetService("PathfindingService")

local Types = require(script.Parent.Types)
local Errors = require(script.Parent.Errors)
local Util = require(script.Parent.Util)
local Geometry = require(script.Parent.Geometry)
local Scheduler = require(script.Parent.Scheduler)
local RouteCache = require(script.Parent.RouteCache)
local Simplifier = require(script.Parent.Simplifier)
local Diagnostics = require(script.Parent.Diagnostics)
local Debug = require(script.Parent.Debug)

local RouteSolver = {}

local UP = Vector3.yAxis
local WALK = Enum.PathWaypointAction.Walk

-- ===== Constantes (origem indicada em cada uma) =====

-- Origem = chão + este offset.
local START_HEIGHT_OFFSET = 1
-- Espera máxima para aterrar antes de calcular.
local MAX_GROUNDED_WAIT = 1.5
-- O raio do chão sob o root tem alcance Height + 6.
local GROUND_PROBE_EXTRA = 6
-- WaypointSpacing = math.huge -> só waypoints essenciais (estabilidade).
local WAYPOINT_SPACING = math.huge

-- Normalização do destino. O raio de projeção parte um pouco acima do destino para não
-- nascer dentro do piso; o alcance cobre destinos flutuando (alvo pulando, por exemplo).
local GOAL_LIFT = 2
local GOAL_SNAP_DISTANCE = 100
-- "Dentro de geometria": esfera pequena um pouco acima do destino, para que um destino
-- exatamente sobre a superfície do piso não conte como dentro dele.
local GOAL_INSIDE_PROBE_HEIGHT = 0.5
local GOAL_INSIDE_PROBE_RADIUS = 0.25

-- Busca do ponto válido mais próximo: anéis crescentes com direções fixas (determinístico).
local NEAREST_SEARCH_MAX = 16
local NEAREST_SEARCH_STEP = 1
local NEAREST_SEARCH_DIRECTIONS = 16
local NEAREST_RAY_LIFT = 2
local NEAREST_RAY_DROP = 20
local MIN_WALKABLE_NORMAL_Y = 0.7 -- cos(~45°): mais íngreme que isso não é chão de pé
local STAND_CENTER_HEIGHT = 2.5 -- centro do volume do corpo em pé (= PROBE_HEIGHT do Simplifier)
-- Destino aproximado (passo 6): só vale a pena se for diferente do destino original.
local APPROX_GOAL_RADIUS = 8
local APPROX_MIN_DISTANCE = 1

-- Validação de volume: bisseção do maior raio que cabe ao longo da rota.
local FIT_BISECT_ITERATIONS = 7
local MIN_CAST_RADIUS = 0.05 -- Spherecast com raio ~0 é instável

-- Varredura de validação que acompanha o terreno (D-020): passo horizontal, e de quanto acima
-- e abaixo do ponto interpolado se procura o chão (cobre rampas de até ~3 studs de erro).
local SWEEP_STEP = 2 -- mesmo espaçamento das amostras de chão do Simplifier
local SWEEP_GROUND_LIFT = 3
local SWEEP_GROUND_DROP = 9

-- Relaxamento de waypoints (D-018). Valores próprios, a validar no Studio.
local RELAX_DIRECTIONS = 8 -- raios horizontais ao redor do waypoint
local RELAX_ITERATIONS = 4
local RELAX_STEP = 0.8 -- fração do empurrão aplicada por iteração
local RELAX_MAX_SHIFT = 1.5 -- quanto um waypoint pode se afastar do original
local RELAX_CLEARANCE_FACTOR = 1.25 -- folga alvo = raio do corpo x este fator
-- Os raios do relaxamento partem um pouco ATRÁS do waypoint: a engine põe cantos exatamente sobre a
-- face da parede (medido no cenário 5 do demo, x = -1.0 numa parede com face em x = -1), e um raio
-- que começa numa superfície não a acerta, então o waypoint nunca era empurrado.
local RELAX_RAY_BACK = 0.3
-- Reparo (D-031): quantos waypoints de desvio se inserem, no máximo, e a folga extra além da do corpo.
local REPAIR_MAX_INSERTIONS = 8
local REPAIR_MARGIN = 0.3

-- Diagnóstico de parte invisível colidível (Fase 6, D-024): raio da busca em volta do ponto de
-- estrangulamento de um corredor estreito.
local INVISIBLE_PROBE_RADIUS = 0.5

-- Cache compartilhado entre chamadas (D-008). Agentes podem passar o seu próprio.
local sharedCache = RouteCache.new()

type Context = {
	options: Types.ResolvedOptions,
	agentRadius: number,
	agentHeight: number,
	bodyRadius: number,
	params: RaycastParams,
	overlapParams: OverlapParams,
	simplifyCtx: Simplifier.Context,
	start: Vector3,
	startGround: Vector3,
	ladder: { number },
	tried: { number },
	jumpEnabled: boolean,
}

type LadderResult = {
	route: { Types.Waypoint }?,
	radius: number?,
	path: Path?,
	narrowFit: number?,
	narrowAt: Vector3?,
	narrowRoute: { Types.Waypoint }?,
	finishBlocked: boolean,
}

function RouteSolver.getSharedCache(): RouteCache.RouteCache
	return sharedCache
end

-- ===== Utilidades =====

local function round2(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end

local function convertWaypoints(pathWaypoints: { PathWaypoint }): { Types.Waypoint }
	local out: { Types.Waypoint } = {}
	for _, wp in ipairs(pathWaypoints) do
		local smart: Types.SmartAction = "Walk"
		if wp.Action == Enum.PathWaypointAction.Jump then
			smart = "Jump"
		elseif wp.Action == Enum.PathWaypointAction.Custom then
			smart = "Link"
		end
		table.insert(
			out,
			table.freeze({
				Position = wp.Position,
				Action = wp.Action,
				Label = wp.Label,
				SmartAction = smart,
			})
		)
	end
	return out
end

local function buildOverlapParams(rayParams: RaycastParams): OverlapParams
	local p = OverlapParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = rayParams.FilterDescendantsInstances
	p.RespectCanCollide = true
	return p
end

-- Modelos com Humanoid junto de um ponto (a origem de um solve sem personagem). Excluí-los dos
-- raycasts impede que o corpo de quem pediu a rota conte como obstáculo dela.
local CHARACTER_EXCLUDE_RADIUS = 4

local function charactersNear(pos: Vector3): { Instance }
	local found: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(pos, CHARACTER_EXCLUDE_RADIUS)) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not seen[model] and model:FindFirstChildOfClass("Humanoid") then
			seen[model] = true
			table.insert(found, model)
		end
	end
	return found
end

-- D-006: Geometry é global; o último solve a chamar decide AutoFilter/RequireNameMatch.
local function ensureGeometry(options: Types.ResolvedOptions)
	Geometry.setAutoFilter(options.Geometry.AutoFilter)
	Geometry.setRequireNameMatch(options.Geometry.RequireNameMatch)
	Geometry.start()
end

-- Degraus da escada: o raio configurado primeiro, depois cada RadiusSteps menor que ele e
-- não menor que MinRadius; por fim o raio de sonda (D-010), metade de MinRadius.
local function buildLadder(
	agentRadius: number,
	indoor: { AdaptiveRadius: boolean, MinRadius: number, RadiusSteps: { number } }
): { number }
	local ladder = { agentRadius }
	if not indoor.AdaptiveRadius then
		return ladder
	end
	local steps = table.clone(indoor.RadiusSteps)
	table.sort(steps, function(a, b)
		return a > b
	end)
	for _, step in ipairs(steps) do
		if step < ladder[#ladder] and step >= indoor.MinRadius then
			table.insert(ladder, step)
		end
	end
	local probe = indoor.MinRadius / 2
	if probe > 0 and probe < ladder[#ladder] then
		table.insert(ladder, probe)
	end
	return ladder
end

-- ===== Origem e destino =====

local function isInsideSolid(point: Vector3, ctx: Context): boolean
	local parts = workspace:GetPartBoundsInRadius(
		point + UP * GOAL_INSIDE_PROBE_HEIGHT,
		GOAL_INSIDE_PROBE_RADIUS,
		ctx.overlapParams
	)
	return #parts > 0
end

local function isStandable(groundPos: Vector3, ctx: Context): boolean
	local parts =
		workspace:GetPartBoundsInRadius(groundPos + UP * STAND_CENTER_HEIGHT, ctx.bodyRadius, ctx.overlapParams)
	return #parts == 0
end

-- Ponto de chão em que o corpo cabe, o mais próximo de `center` dentro de `maxRadius`.
local function findNearestStandable(center: Vector3, ctx: Context, maxRadius: number): Vector3?
	local d = NEAREST_SEARCH_STEP
	while d <= maxRadius do
		local best: Vector3? = nil
		local bestDist = math.huge
		for k = 0, NEAREST_SEARCH_DIRECTIONS - 1 do
			local angle = (k / NEAREST_SEARCH_DIRECTIONS) * 2 * math.pi
			local origin =
				Vector3.new(center.X + math.cos(angle) * d, center.Y + NEAREST_RAY_LIFT, center.Z + math.sin(angle) * d)
			local hit = workspace:Raycast(origin, -UP * (NEAREST_RAY_LIFT + NEAREST_RAY_DROP), ctx.params)
			if hit and hit.Normal.Y >= MIN_WALKABLE_NORMAL_Y and isStandable(hit.Position, ctx) then
				local dist = (hit.Position - center).Magnitude
				if dist < bestDist then
					best, bestDist = hit.Position, dist
				end
			end
		end
		if best then
			return best
		end
		d += NEAREST_SEARCH_STEP
	end
	return nil
end

-- Retorna (goal normalizado) ou (nil, nearestValid) quando o destino não existe na malha.
local function normalizeGoal(goal: Vector3, ctx: Context): (Vector3?, Vector3?)
	if isInsideSolid(goal, ctx) then
		return nil, findNearestStandable(goal, ctx, NEAREST_SEARCH_MAX)
	end
	local hit = workspace:Raycast(goal + UP * GOAL_LIFT, -UP * (GOAL_LIFT + GOAL_SNAP_DISTANCE), ctx.params)
	if not hit then
		return nil, findNearestStandable(goal, ctx, NEAREST_SEARCH_MAX)
	end
	return hit.Position, nil
end

-- ===== ComputeAsync via Scheduler =====

local function computeOnce(
	radius: number,
	height: number,
	canJump: boolean,
	start: Vector3,
	goal: Vector3
): ({ Types.Waypoint }?, any, Path?)
	local ok, result = pcall(function()
		local path = PathfindingService:CreatePath({
			AgentRadius = radius,
			AgentHeight = height,
			AgentCanJump = canJump,
			AgentCanClimb = false,
			WaypointSpacing = WAYPOINT_SPACING,
		})
		path:ComputeAsync(start, goal)
		return path
	end)
	if not ok then
		return nil, "compute_error", nil
	end
	local path = result :: Path
	if path.Status ~= Enum.PathStatus.Success then
		return nil, path.Status, nil
	end
	return convertWaypoints(path:GetWaypoints()), path.Status, path
end

local function compute(ctx: Context, radius: number, canJump: boolean, start: Vector3, goal: Vector3)
	-- pedidos com a mesma chave pendentes viram um único cálculo (coalescência do Scheduler)
	local cell = RouteCache.DEFAULT_CELL_SIZE
	local key = string.format(
		"route|%.2f|%.2f|%d|%s|%s",
		radius,
		ctx.agentHeight,
		canJump and 1 or 0,
		RouteCache.quantize(start, cell),
		RouteCache.quantize(goal, cell)
	)
	local handle = Scheduler.submit(key, ctx.options.Scheduler.Priority, function()
		return computeOnce(radius, ctx.agentHeight, canJump, start, goal)
	end)
	return handle:await()
end

-- ===== Validação de volume (D-002) =====

-- Ponto sobre o chão, na vertical de `p`. Sem chão embaixo (borda, vão), fica como está.
local function groundedPoint(p: Vector3, ctx: Context): Vector3
	local hit = workspace:Raycast(p + UP * SWEEP_GROUND_LIFT, -UP * (SWEEP_GROUND_LIFT + SWEEP_GROUND_DROP), ctx.params)
	if hit then
		return Vector3.new(p.X, hit.Position.Y, p.Z)
	end
	return p
end

-- (livre?, onde bateu, segmento, normal da superfície). O ponto de batida vira `blockedAt` no erro.
local function routeClear(
	waypoints: { Types.Waypoint },
	radius: number,
	ctx: Context
): (boolean, Vector3?, number?, Vector3?)
	for i = 1, #waypoints - 1 do
		local a, b = waypoints[i], waypoints[i + 1]
		-- O waypoint Jump é o DESTINO do salto (D-019): o segmento que chega nele é o voo por
		-- cima do obstáculo, não caminhada, e não se valida com o corpo no chão. O mesmo vale
		-- para o segmento que parte de um link (Custom).
		if b.Action == WALK and a.Action ~= Enum.PathWaypointAction.Custom then
			local delta = b.Position - a.Position
			if delta.Magnitude > 0.05 then
				-- A varredura segue o terreno (D-020): a engine só devolve waypoints nos cantos,
				-- então numa rampa a reta 3D entre dois waypoints corta o corpo da rampa por
				-- baixo. Em passos horizontais, cada ponto intermediário é projetado no chão.
				local steps = math.max(1, math.ceil(Util.flat(delta).Magnitude / SWEEP_STEP))
				local prev = a.Position
				for s = 1, steps do
					local nextPos = b.Position
					if s < steps then
						nextPos = groundedPoint(a.Position:Lerp(b.Position, s / steps), ctx)
					end
					local d = nextPos - prev
					if d.Magnitude > 0.01 then
						local hit = workspace:Spherecast(prev + UP * ctx.simplifyCtx.probeHeight, radius, d, ctx.params)
						if hit then
							return false, hit.Position, i, hit.Normal
						end
					end
					prev = nextPos
				end
			end
		end
	end
	return true, nil
end

-- (cabe?, maior raio que cabe, onde o corpo bate). O segundo valor alimenta o `requiredRadius`.
local function measureFit(waypoints: { Types.Waypoint }, ctx: Context): (boolean, number, Vector3?)
	local clear, blockedAt = routeClear(waypoints, ctx.bodyRadius, ctx)
	if clear then
		return true, ctx.bodyRadius, nil
	end
	local lo, hi = 0, ctx.bodyRadius
	for _ = 1, FIT_BISECT_ITERATIONS do
		local mid = (lo + hi) / 2
		if routeClear(waypoints, math.max(mid, MIN_CAST_RADIUS), ctx) then
			lo = mid
		else
			hi = mid
		end
	end
	return false, lo, blockedAt
end

-- Relaxamento: a rota da engine vem com waypoints de canto encostados na parede (D-018). Cada
-- waypoint interior é empurrado para longe das paredes que estão mais perto que a folga alvo,
-- medidas por raios horizontais na altura do tronco. Só roda quando a rota não cabe; a
-- validação decide depois se o resultado serve. Não move waypoints de ação nem origem/destino.
local function relaxRoute(route: { Types.Waypoint }, ctx: Context): { Types.Waypoint }
	local wps = table.clone(route)
	local clearance = ctx.bodyRadius * RELAX_CLEARANCE_FACTOR
	local sctx = ctx.simplifyCtx
	for i = 2, #wps - 1 do
		local wp = wps[i]
		if wp.Action == WALK then
			local origin = wp.Position
			local pos = origin
			for _ = 1, RELAX_ITERATIONS do
				local push = Vector3.zero
				for k = 0, RELAX_DIRECTIONS - 1 do
					local angle = (k / RELAX_DIRECTIONS) * 2 * math.pi
					local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
					local hit = workspace:Raycast(
						pos + UP * sctx.probeHeight - dir * RELAX_RAY_BACK,
						dir * (clearance + RELAX_RAY_BACK),
						ctx.params
					)
					if hit then
						push -= dir * (clearance - (hit.Distance - RELAX_RAY_BACK))
					end
				end
				if push.Magnitude < 0.01 then
					break
				end
				local candidate = pos + push * RELAX_STEP
				local shift = candidate - origin
				if shift.Magnitude > RELAX_MAX_SHIFT then
					candidate = origin + shift.Unit * RELAX_MAX_SHIFT
				end
				-- o novo ponto precisa ter chão parecido: relaxar não pode levar a rota para um buraco
				local ground = workspace:Raycast(
					candidate + UP * sctx.groundProbeUp,
					-UP * (sctx.groundProbeUp + sctx.maxFloorDelta),
					ctx.params
				)
				if not ground or math.abs(ground.Position.Y - pos.Y) > sctx.maxFloorDelta then
					break
				end
				pos = Vector3.new(candidate.X, ground.Position.Y, candidate.Z)
			end
			if pos ~= origin then
				wps[i] = table.freeze({
					Position = pos,
					Action = wp.Action,
					Label = wp.Label,
					SmartAction = wp.SmartAction,
				})
			end
		end
	end
	return table.freeze(wps)
end

-- Reparo (D-031): a engine é tolerante e devolve a reta que passa a 0.6 stud da quina de um pilar
-- (medido no cenário 8 do demo). A rota tem 2 waypoints, então não há o que relaxar. Aqui, a cada
-- batida do corpo, entra um waypoint de desvio no lado livre da superfície (a normal da batida),
-- a uma folga do corpo, e a rota é medida de novo. Só roda quando a rota não cabe.
local function repairRoute(route: { Types.Waypoint }, ctx: Context): { Types.Waypoint }
	local wps = table.clone(route)
	local clearance = ctx.bodyRadius * RELAX_CLEARANCE_FACTOR + REPAIR_MARGIN
	for _ = 1, REPAIR_MAX_INSERTIONS do
		local clear, at, segment, normal = routeClear(wps, ctx.bodyRadius, ctx)
		if clear or not at or not segment or not normal then
			break
		end
		local away = Util.flat(normal)
		if away.Magnitude < 0.05 then
			break -- batida em superfície horizontal: desviar de lado não resolve
		end
		local detour = groundedPoint(at + away.Unit * clearance, ctx)
		table.insert(
			wps,
			segment + 1, -- o segmento i vai de wps[i] a wps[i + 1]
			table.freeze({ Position = detour, Action = WALK, Label = "", SmartAction = "Walk" } :: Types.Waypoint)
		)
	end
	return table.freeze(wps)
end

-- ===== Escada =====

-- Origem de volta ao chão + suavização, e só então a rota é validada (D-012). A rota crua da
-- engine tem cantos deslocados da linha central (ela trabalha numa grade); o string pulling
-- já checa o corpo, então endireitar antes de validar não aceita nada que não caiba.
local function prepareRoute(ctx: Context, route: { Types.Waypoint }): { Types.Waypoint }
	local wps = table.clone(route)
	-- o primeiro waypoint é a origem que passamos (chão + offset); volta para o chão para
	-- que toda a rota seja feita de pontos de piso. A guarda evita mexer se a engine não
	-- devolveu a origem como primeiro ponto.
	local first = wps[1]
	if first and (first.Position - ctx.start).Magnitude < 1.5 then
		wps[1] = table.freeze({
			Position = ctx.startGround,
			Action = first.Action,
			Label = first.Label,
			SmartAction = first.SmartAction,
		})
	end
	if ctx.options.Stability.Smoothing then
		wps = Simplifier.simplify(wps, ctx.simplifyCtx)
	end
	return table.freeze(wps)
end

local function runLadder(ctx: Context, canJump: boolean, goal: Vector3): LadderResult
	local result: LadderResult =
		{ route = nil, radius = nil, path = nil, narrowFit = nil, narrowAt = nil, narrowRoute = nil, finishBlocked = false }
	for _, radius in ipairs(ctx.ladder) do
		if not table.find(ctx.tried, radius) then
			table.insert(ctx.tried, radius)
		end
		local raw, status, path = compute(ctx, radius, canJump, ctx.start, goal)
		if raw then
			-- toda rota é validada, inclusive a de raio cheio (D-011): a engine aceitou um
			-- corredor de 2 studs com AgentRadius 2, então o raio dela não garante que o
			-- corpo cabe
			local route = prepareRoute(ctx, raw)
			local fits, maxFit, blockedAt = measureFit(route, ctx)
			if not fits then
				-- rescue (D-018, D-030): waypoints encostados na parede reprovam rotas que caberiam.
				-- Primeiro relaxa os cantos CRUS da engine e suaviza de novo: o suavizador aceita
				-- atalhos a partir de um canto sobre a parede (o Spherecast ignora o que sobrepõe a
				-- origem), e um atalho assim atravessa a parede e não tem conserto depois.
				local relaxed = prepareRoute(ctx, relaxRoute(raw, ctx))
				local relaxedFits, relaxedFit, relaxedAt = measureFit(relaxed, ctx)
				if not relaxedFits then
					-- segunda tentativa: relaxar a rota já suavizada
					local second = relaxRoute(route, ctx)
					local secondFits, secondFit, secondAt = measureFit(second, ctx)
					if secondFits or secondFit > relaxedFit then
						relaxed, relaxedFits, relaxedFit, relaxedAt = second, secondFits, secondFit, secondAt
					end
				end
				if not relaxedFits then
					-- última tentativa: inserir waypoints de desvio onde o corpo bate (D-031)
					local repaired = repairRoute(route, ctx)
					local repairedFits, repairedFit, repairedAt = measureFit(repaired, ctx)
					if repairedFits or repairedFit > relaxedFit then
						relaxed, relaxedFits, relaxedFit, relaxedAt = repaired, repairedFits, repairedFit, repairedAt
					end
				end
				if relaxedFits then
					route, fits = relaxed, true
				elseif relaxedFit > maxFit then
					maxFit, blockedAt = relaxedFit, relaxedAt
				end
			end
			if fits then
				result.route, result.radius, result.path = route, radius, path
				return result
			end
			-- a engine achou rota, mas o corpo não cabe: registra e tenta o próximo degrau
			-- (um raio diferente pode achar outro caminho)
			if result.narrowFit == nil or maxFit > result.narrowFit then
				result.narrowFit, result.narrowAt, result.narrowRoute = maxFit, blockedAt, route
			end
		elseif status == Enum.PathStatus.FailFinishNotEmpty then
			result.finishBlocked = true
		end
	end
	return result
end

-- ===== API =====

-- Revalida uma rota já aceita, a partir do segmento `fromIndex`, com a MESMA varredura que a
-- aceitou. O Agent usa quando uma parte nova surge no mundo (D-021): se a rota ainda cabe, nada
-- mudou para ele; se não, foi bloqueada. Retorna (livre?, onde bateu, índice do waypoint em que o
-- segmento bloqueado termina, na numeração de `route`).
local function checkRoute(
	params: RaycastParams,
	route: { Types.Waypoint },
	options: Types.ResolvedOptions,
	fromIndex: number
): (boolean, Vector3?, number?)
	local from = math.max(1, fromIndex)
	local slice: { Types.Waypoint } = {}
	for i = from, #route do
		table.insert(slice, route[i])
	end
	-- só params e simplifyCtx são usados por routeClear
	local ctx = { params = params, simplifyCtx = Simplifier.buildContext(params, options.Agent.Radius) }
	local clear, at, segment = routeClear(slice, Util.getBodyRadius(options.Agent.Radius), ctx :: any)
	if clear then
		return true, nil, nil
	end
	return false, at, if segment then from + segment else nil -- o segmento i termina no waypoint i + 1
end

function RouteSolver.isRouteClear(
	character: Types.CharacterLike,
	route: { Types.Waypoint },
	options: Types.ResolvedOptions,
	fromIndex: number?,
	target: Types.TargetLike?
): (boolean, Vector3?, number?)
	local root = Util.resolveRoot(character)
	if not root then
		return true, nil, nil
	end
	local extra: { Instance } = { Util.resolveModel(character) or root }
	if target and typeof(target) == "Instance" then
		table.insert(extra, target)
	end
	return checkRoute(Geometry.buildRaycastParams(extra), route, options, fromIndex or 1)
end

-- Igual, mas sem personagem: exclui os modelos com Humanoid junto do início da rota.
function RouteSolver.isRouteClearAt(
	route: { Types.Waypoint },
	options: Types.ResolvedOptions,
	fromIndex: number?,
	target: Types.TargetLike?
): (boolean, Vector3?, number?)
	local first = route[1]
	local extra: { Instance } = if first then charactersNear(first.Position) else {}
	if target and typeof(target) == "Instance" then
		table.insert(extra, target)
	end
	return checkRoute(Geometry.buildRaycastParams(extra), route, options, fromIndex or 1)
end

-- Fase 6 (D-024): toda falha passa por aqui antes de sair do solver. Se a causa é uma parte
-- invisível colidível que a lib não filtrou, o código vira invisible_collider (com a parte em
-- details.instance) e o código original vai em details.underlying. Com Debug ligado, marca o ponto.
local function fail(
	ctx: Context,
	code: string,
	details: { [string]: any },
	goalRaw: Vector3,
	goal: Vector3?
): (nil, string, { [string]: any })
	local culprit: BasePart? = nil
	local at: Vector3? = nil
	if code == Errors.CorridorTooNarrow then
		local blockedAt = details.blockedAt
		if typeof(blockedAt) == "Vector3" then
			culprit = Diagnostics.findInvisibleAt(blockedAt, INVISIBLE_PROBE_RADIUS, ctx.overlapParams)
			at = blockedAt
		end
	elseif code == Errors.GoalUnreachable and not goal then
		-- destino dentro de uma parede: era invisível?
		local inside = goalRaw + UP * GOAL_INSIDE_PROBE_HEIGHT
		at = inside
		culprit = Diagnostics.findInvisibleAt(inside, GOAL_INSIDE_PROBE_RADIUS, ctx.overlapParams)
	elseif code == Errors.NoPath or code == Errors.GoalUnreachable then
		local lift = UP * STAND_CENTER_HEIGHT
		local target = goal or goalRaw
		culprit, at =
			Diagnostics.findInvisibleAlong(ctx.params, ctx.startGround + lift, target + lift, ctx.bodyRadius)
	end
	if culprit then
		details = table.clone(details)
		details.underlying = code
		details.instance = culprit
		details.position = at
		code = Errors.InvisibleCollider
	end
	if ctx.options.Debug then
		Util.debugPrint(true, "sem rota:", code, Diagnostics.explain(code, details))
		Debug.failure(code, details)
	end
	return nil, code, details
end

-- Núcleo do solver: tudo o que só precisa de posições (origem no chão, destino, filtro de
-- raycast). `solve` (com personagem) e `solvePositions` (só Vector3, para a camada de
-- compatibilidade) preparam esses três e chamam esta função.
local function solveFrom(
	params: RaycastParams,
	target: Types.TargetLike,
	goalRaw: Vector3,
	startGround: Vector3,
	options: Types.ResolvedOptions,
	cache: RouteCache.RouteCache?
): ({ Types.Waypoint }?, string?, { [string]: any }?)
	local agentRadius = options.Agent.Radius
	local agentHeight = options.Agent.Height
	local start = startGround + UP * START_HEIGHT_OFFSET

	local ctx: Context = {
		options = options,
		agentRadius = agentRadius,
		agentHeight = agentHeight,
		bodyRadius = Util.getBodyRadius(agentRadius),
		params = params,
		overlapParams = buildOverlapParams(params),
		simplifyCtx = Simplifier.buildContext(params, agentRadius),
		start = start,
		startGround = startGround,
		ladder = buildLadder(agentRadius, options.Indoor),
		tried = {},
		jumpEnabled = options.Jump.Enabled,
	}

	local goal, nearestValid = normalizeGoal(goalRaw, ctx)
	if not goal then
		return fail(ctx, Errors.GoalUnreachable, { nearestValid = nearestValid, requestedGoal = goalRaw }, goalRaw, nil)
	end

	local rc: RouteCache.RouteCache = cache or sharedCache
	local useCache = options.Stability.Cache
	local profile = string.format(
		"r%.2f|h%.2f|j%d|%s",
		agentRadius,
		agentHeight,
		ctx.jumpEnabled and 1 or 0,
		table.concat(ctx.ladder, ",")
	)
	local geoVersion = Geometry.getVersion()
	if useCache then
		local cached, meta = rc:get(start, goal, profile, geoVersion)
		if cached then
			local details = table.clone(meta or {})
			details.cached = true
			return cached, nil, details
		end
	end

	local result = runLadder(ctx, ctx.jumpEnabled, goal)

	-- passo 6a: AgentCanJump = false às vezes destrava malhas estranhas
	if not result.route and ctx.jumpEnabled then
		local retry = runLadder(ctx, false, goal)
		if retry.route then
			result = retry
		else
			result.narrowFit = if retry.narrowFit or result.narrowFit
				then math.max(retry.narrowFit or 0, result.narrowFit or 0)
				else nil
			result.finishBlocked = result.finishBlocked or retry.finishBlocked
		end
	end

	-- passo 6b: destino aproximado, só quando o problema foi de conectividade (se uma rota
	-- existiu mas o corpo não coube, mudar o destino não resolve)
	local effectiveGoal = goal
	local approximated = false
	if not result.route and result.narrowFit == nil then
		local approx = findNearestStandable(goal, ctx, APPROX_GOAL_RADIUS)
		if approx and (approx - goal).Magnitude > APPROX_MIN_DISTANCE then
			local retry = runLadder(ctx, ctx.jumpEnabled, approx)
			if retry.route then
				result = retry
				effectiveGoal = approx
				approximated = true
			end
		end
	end

	local route = result.route
	if not route then
		if result.narrowFit ~= nil then
			return fail(ctx, Errors.CorridorTooNarrow, {
				requiredRadius = round2(result.narrowFit / Util.BODY_RADIUS_RATIO),
				agentRadius = agentRadius,
				bodyRadius = ctx.bodyRadius,
				blockedAt = result.narrowAt,
				rejectedRoute = result.narrowRoute, -- a rota que não coube (Debug a desenha em vermelho)
				triedRadii = ctx.tried,
			}, goalRaw, goal)
		end
		if result.finishBlocked then
			return fail(ctx, Errors.GoalUnreachable, {
				nearestValid = findNearestStandable(goal, ctx, NEAREST_SEARCH_MAX),
				requestedGoal = goalRaw,
			}, goalRaw, goal)
		end
		return fail(ctx, Errors.NoPath, { triedRadii = ctx.tried }, goalRaw, goal)
	end

	-- a rota já vem preparada (origem no chão, suavizada e congelada) de runLadder
	local wps = route

	local usedRadius = result.radius or agentRadius
	local details = {
		radius = usedRadius,
		agentRadius = agentRadius,
		reduced = usedRadius < agentRadius,
		cached = false,
		approximated = approximated,
		goal = effectiveGoal,
		-- destino normalizado usado como chave do cache: quem quiser invalidar a rota
		-- (RouteCache.invalidateGoal) precisa dele, não do destino bruto
		cacheGoal = goal,
		triedRadii = ctx.tried,
		path = result.path,
	}

	-- só guarda no cache se a geometria não mudou durante o cálculo. O Path fica junto: o
	-- Path.Blocked dispara para qualquer um que o segure, então quem receber esta rota do
	-- cache também é avisado quando algo bloqueia o caminho.
	if useCache and Geometry.getVersion() == geoVersion then
		rc:put(start, goal, profile, wps, geoVersion, table.clone(details))
	end

	Util.debugPrint(
		options.Debug,
		string.format("rota com %d waypoints (raio %.2f de %.2f)", #wps, usedRadius, agentRadius)
	)
	return wps, nil, details
end

-- Retorna (waypoints, nil, details) em sucesso ou (nil, código de erro, details) em falha.
-- `options` deve vir de Config.resolve. `cache` é opcional (default: cache compartilhado).
-- `startGroundOverride` calcula a partir de um ponto de chão em vez da posição do personagem
-- (o Agent usa para validar a rota a partir do ponto de pouso de um salto): pula a espera
-- por aterrar e a projeção da origem.
function RouteSolver.solve(
	character: Types.CharacterLike,
	target: Types.TargetLike,
	options: Types.ResolvedOptions,
	cache: RouteCache.RouteCache?,
	startGroundOverride: Vector3?
): ({ Types.Waypoint }?, string?, { [string]: any }?)
	local humanoid = Util.resolveHumanoid(character)
	local root = Util.resolveRoot(character)
	if not humanoid or not root or humanoid.Health <= 0 then
		return nil, Errors.CharacterLost, {}
	end
	local model = Util.resolveModel(character)

	local goalRaw = Util.resolveTargetPosition(target)
	if not goalRaw then
		error("SmartPath: RouteSolver.solve: destino inválido (esperado Vector3, BasePart ou Model)", 2)
	end

	ensureGeometry(options)

	-- exclui o próprio personagem e o alvo dos raycasts/overlaps (o alvo não pode contar
	-- como "geometria" que bloqueia o destino dele mesmo)
	local extra: { Instance } = { model or root }
	if typeof(target) == "Instance" then
		table.insert(extra, target)
	end
	local params = Geometry.buildRaycastParams(extra)

	local startGround: Vector3
	if startGroundOverride then
		startGround = startGroundOverride
	else
		-- (estabilização nº1) nunca calcular com o agente no ar
		local t0 = os.clock()
		while humanoid.FloorMaterial == Enum.Material.Air and os.clock() - t0 < MAX_GROUNDED_WAIT do
			task.wait()
		end
		if humanoid.Health <= 0 or not root.Parent then
			return nil, Errors.CharacterLost, {}
		end
		local groundHit = Util.groundBelow(root.Position, options.Agent.Height + GROUND_PROBE_EXTRA, params)
		if not groundHit and humanoid.FloorMaterial == Enum.Material.Air then
			-- ainda no ar depois de esperar aterrar e sem chão embaixo (queda infinita, fora do mapa):
			-- nenhuma rota sai de um ponto no vazio, então nem chama a engine (D-033)
			return nil, Errors.NoPath, { triedRadii = {}, noGround = true }
		end
		startGround = groundHit and groundHit.Position or root.Position
	end
	return solveFrom(params, target, goalRaw, startGround, options, cache)
end

-- Variante sem personagem, para quem só tem coordenadas (a camada de compatibilidade,
-- D-001/D-022). Sem um personagem para excluir dos raycasts, exclui os modelos com Humanoid
-- que estão junto da origem (quem chama costuma ser um deles).
function RouteSolver.solvePositions(
	startPos: Vector3,
	target: Types.TargetLike,
	options: Types.ResolvedOptions,
	cache: RouteCache.RouteCache?
): ({ Types.Waypoint }?, string?, { [string]: any }?)
	local goalRaw = Util.resolveTargetPosition(target)
	if not goalRaw then
		error("SmartPath: RouteSolver.solvePositions: destino inválido (esperado Vector3, BasePart ou Model)", 2)
	end

	ensureGeometry(options)

	local extra = charactersNear(startPos)
	if typeof(target) == "Instance" then
		table.insert(extra, target)
	end
	local params = Geometry.buildRaycastParams(extra)

	-- a origem pode vir de um personagem no ar ou no meio do corpo: projeta no chão sob ela
	local groundHit = workspace:Raycast(
		startPos + UP,
		-UP * (options.Agent.Height + GROUND_PROBE_EXTRA + 1),
		params
	)
	local startGround = groundHit and groundHit.Position or startPos
	return solveFrom(params, target, goalRaw, startGround, options, cache)
end

return RouteSolver
