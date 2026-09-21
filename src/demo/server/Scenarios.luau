--!strict
-- Scenarios.luau
-- Os 8 cenários do place de demonstração. Cada cenário tem UMA função de geometria (`build`),
-- chamada duas vezes com origens diferentes: o lado esquerdo (PathfindingService puro) e o
-- direito (SmartPath) recebem geometria idêntica ao stud.
--
-- Coordenadas locais: origem no centro da pista, chão com o topo em y = 0, percurso no sentido +X,
-- pista de 120 x 60 (x de -60 a 60, z de -30 a 30).

local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

local Scenarios = {}

export type BuildContext = {
	lane: Folder,
	origin: Vector3,
	-- true na pista do PathfindingService puro. A SmartPath mexe no mapa inteiro (Geometry é global:
	-- põe PassThrough em gatilhos invisíveis), o que ajudaria o baseline. A tag NavSolid diz à
	-- SmartPath "não toque nisto"; para o PathfindingService ela não significa nada.
	baseline: boolean,
}

export type HazardContext = {
	lane: Folder,
	origin: Vector3,
	rig: Model,
	cancelled: () -> boolean,
}

export type Scenario = {
	id: number,
	name: string,
	description: string,
	kind: "normal" | "boundary" | "crowd",
	build: (ctx: BuildContext) -> (),
	start: Vector3,
	goal: Vector3,
	timeLimit: number,
	-- opções da SmartPath deste cenário (o lado clássico não tem equivalente)
	setupRig: ((humanoid: Humanoid) -> ())?,
	hazard: ((ctx: HazardContext) -> ())?,
	-- só cenário 6: nome da parede que os dois lados não podem atravessar
	boundaryName: string?,
	-- pares de pontos (locais) cuja conectividade `Runner.diagnose` testa com o PathfindingService
	probes: { { from: Vector3, to: Vector3 } }?,
}

Scenarios.TRIGGER_GROUP = "SmartPathDemoTriggers"
Scenarios.LANE_HALF_WIDTH = 30

-- ===== helpers de geometria =====

local function block(ctx: BuildContext, name: string, center: Vector3, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = ctx.origin + center
	p.Material = Enum.Material.Concrete
	p.Color = Color3.fromRGB(150, 150, 155)
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if ctx.baseline then
		CollectionService:AddTag(p, "NavSolid")
	end
	p.Parent = ctx.lane
	return p
end

-- piso e paredes de vidro (visíveis: Transparency 0.7 < 0.95, logo nunca "invisíveis" para a
-- SmartPath) que fecham a pista
local function arena(ctx: BuildContext)
	local floor = block(ctx, "Floor", Vector3.new(0, -0.5, 0), Vector3.new(120, 1, 60))
	floor.Color = Color3.fromRGB(95, 110, 95)
	floor.Material = Enum.Material.Grass
	local edges: { { name: string, pos: Vector3, size: Vector3 } } = {
		{ name = "EdgeN", pos = Vector3.new(0, 6, 31), size = Vector3.new(124, 12, 2) },
		{ name = "EdgeS", pos = Vector3.new(0, 6, -31), size = Vector3.new(124, 12, 2) },
		{ name = "EdgeW", pos = Vector3.new(-61, 6, 0), size = Vector3.new(2, 12, 64) },
		{ name = "EdgeE", pos = Vector3.new(61, 6, 0), size = Vector3.new(2, 12, 64) },
	}
	for _, edge in ipairs(edges) do
		local wall = block(ctx, edge.name, edge.pos, edge.size)
		wall.Material = Enum.Material.Glass
		wall.Transparency = 0.7
	end
end

local function marker(ctx: BuildContext, name: string, localPos: Vector3, color: Color3)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.2, 5, 5)
	p.CFrame = CFrame.new(ctx.origin + localPos + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = 0.4
	p.CanCollide = false -- só marca o destino; não entra na malha
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = ctx.lane
end

-- ===== 1. Corredor de 4 studs =====
-- Duas salas ligadas por um corredor de 4 studs e 30 de comprimento. Início e destino ficam
-- fora do eixo do corredor: o agente precisa fazer a curva de entrada e a de saída.

local function buildCorridor(ctx: BuildContext)
	arena(ctx)
	block(ctx, "CorridorNorth", Vector3.new(0, 6, 16), Vector3.new(30, 12, 28))
	block(ctx, "CorridorSouth", Vector3.new(0, 6, -16), Vector3.new(30, 12, 28))
	marker(ctx, "Goal", Vector3.new(45, 0, -18), Color3.fromRGB(80, 255, 120))
end

-- ===== 2. Sala com porta estreita e mobília =====
-- Parede com uma porta de 3 studs; a frente da porta é um corredor de 3.2 studs entre um armário e
-- uma estante (altos demais para pular), e há mais mobília na sala do destino.

local function buildRoom(ctx: BuildContext)
	arena(ctx)
	block(ctx, "WallSouth", Vector3.new(0, 5, -11.75), Vector3.new(2, 10, 36.5)) -- z de -30 a 6.5
	block(ctx, "WallNorth", Vector3.new(0, 5, 19.75), Vector3.new(2, 10, 20.5)) -- z de 9.5 a 30
	-- Mobília ALTA (6 a 8 studs): com 3 studs a engine e a SmartPath simplesmente pulavam por cima da
	-- mesa (medido no demo), e o cenário deixava de testar a porta estreita.
	local wardrobe = block(ctx, "Wardrobe", Vector3.new(-8, 3.5, 3.2), Vector3.new(8, 7, 6.4))
	wardrobe.Material = Enum.Material.Wood
	wardrobe.Color = Color3.fromRGB(150, 105, 60)
	local shelf = block(ctx, "Bookshelf", Vector3.new(-8, 4, 11.8), Vector3.new(8, 8, 4.4))
	shelf.Material = Enum.Material.Wood
	shelf.Color = Color3.fromRGB(110, 75, 45)
	local cabinet = block(ctx, "Cabinet", Vector3.new(8, 3.5, 14), Vector3.new(6, 7, 3))
	cabinet.Color = Color3.fromRGB(120, 60, 60)
	local dresser = block(ctx, "Dresser", Vector3.new(6, 3, 3), Vector3.new(4, 6, 4))
	dresser.Material = Enum.Material.Wood
	dresser.Color = Color3.fromRGB(150, 105, 60)
	marker(ctx, "Goal", Vector3.new(45, 0, 8), Color3.fromRGB(80, 255, 120))
end

-- ===== 3. Mureta de 3 studs com desvio longo =====
-- A mureta atravessa a pista inteira, menos os 6 studs do fim (z de 24 a 30): o desvio dá ~30 studs.

local function buildLowWall(ctx: BuildContext)
	arena(ctx)
	block(ctx, "Mureta", Vector3.new(0, 1.5, -3), Vector3.new(2, 3, 54))
	marker(ctx, "Goal", Vector3.new(30, 0, 0), Color3.fromRGB(80, 255, 120))
end

-- ===== 4. Plataforma de 18 studs, JumpHeight = 25 =====

local function buildPlatform(ctx: BuildContext)
	arena(ctx)
	local platform = block(ctx, "Platform", Vector3.new(25, 9, 0), Vector3.new(30, 18, 30))
	platform.Color = Color3.fromRGB(120, 130, 160)
	marker(ctx, "Goal", Vector3.new(25, 18, 0), Color3.fromRGB(80, 255, 120))
end

-- ===== 5. Labirinto com gatilho invisível colidível =====
-- Três paredes em serpentina. A passagem da segunda tem um gatilho invisível e colidível
-- ("DoorTrigger"), de um grupo de colisão que não colide com personagens: o corpo atravessa, mas
-- para a malha do PathfindingService é uma parede.

local function buildMaze(ctx: BuildContext)
	arena(ctx)
	block(ctx, "MazeWall1", Vector3.new(-30, 6, -6), Vector3.new(2, 12, 48)) -- passagem em z de 18 a 30
	block(ctx, "MazeWall2", Vector3.new(0, 6, 6), Vector3.new(2, 12, 48)) -- passagem em z de -30 a -18
	block(ctx, "MazeWall3", Vector3.new(30, 6, -6), Vector3.new(2, 12, 48)) -- passagem em z de 18 a 30
	local trigger = block(ctx, "DoorTrigger", Vector3.new(0, 6, -24), Vector3.new(2, 12, 12))
	trigger.Transparency = 1
	trigger.CanCollide = true
	trigger.CollisionGroup = Scenarios.TRIGGER_GROUP
	marker(ctx, "Goal", Vector3.new(50, 0, 0), Color3.fromRGB(80, 255, 120))
end

-- ===== 6. Parede invisível de limite de mapa (NavSolid) =====
-- Teste de segurança: o destino fica do outro lado de um limite de mapa declarado com NavSolid.
-- O nome ("MapBoundsZone") é de propósito o de um gatilho, para que só a tag o proteja.

local BOUNDARY_NAME = "MapBoundsZone"

local function buildBoundary(ctx: BuildContext)
	arena(ctx)
	local wall = block(ctx, BOUNDARY_NAME, Vector3.new(0, 20, 0), Vector3.new(2, 40, 62))
	wall.Transparency = 1
	wall.CanCollide = true
	CollectionService:AddTag(wall, "NavSolid") -- nas duas pistas: é intenção do desenvolvedor do mapa
	marker(ctx, "Goal", Vector3.new(40, 0, 0), Color3.fromRGB(255, 80, 80))
end

-- ===== 7. Obstáculo dinâmico =====
-- Uma parede com duas passagens: a do meio (8 studs) e a do fim (z de 22 a 30). Quando o NPC
-- chega perto, um bloco cai e fecha a do meio.

local function buildDynamic(ctx: BuildContext)
	arena(ctx)
	block(ctx, "WallSouth", Vector3.new(0, 5, -17), Vector3.new(2, 10, 26)) -- z de -30 a -4
	block(ctx, "WallNorth", Vector3.new(0, 5, 13), Vector3.new(2, 10, 18)) -- z de 4 a 22
	marker(ctx, "Goal", Vector3.new(40, 0, 0), Color3.fromRGB(80, 255, 120))
end

local function dropBlock(ctx: HazardContext)
	local root = ctx.rig:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	-- o bloco leva 0.9 s para cair, e o NPC anda ~14 studs nesse tempo: soltar quando ele está a
	-- 30 studs da parede deixa o bloco no lugar ~16 studs antes de o NPC chegar à passagem
	while root.Parent and (root.Position.X - ctx.origin.X) < -30 do
		if ctx.cancelled() then
			return
		end
		task.wait(0.1)
	end
	if ctx.cancelled() then
		return
	end
	print(
		string.format(
			"[SmartPathDemo] cenário 7: bloco cai com o NPC em x=%.1f (%s)",
			root.Position.X - ctx.origin.X,
			ctx.rig.Name
		)
	)
	local rock = Instance.new("Part")
	rock.Name = "FallingBlock"
	rock.Anchored = true
	rock.Size = Vector3.new(7, 10, 7)
	rock.Color = Color3.fromRGB(230, 120, 40)
	rock.Material = Enum.Material.Slate
	rock.Position = ctx.origin + Vector3.new(0, 55, 0)
	rock.Parent = ctx.lane
	local tween =
		TweenService:Create(rock, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = ctx.origin + Vector3.new(0, 5, 0),
		})
	tween:Play()
end

-- ===== 8. 20 NPCs simultâneos =====

local function buildCrowd(ctx: BuildContext)
	arena(ctx)
	for i, p in ipairs({
		Vector3.new(-25, 4, -14),
		Vector3.new(-25, 4, 14),
		Vector3.new(-5, 4, 0),
		Vector3.new(15, 4, -14),
		Vector3.new(15, 4, 14),
		Vector3.new(30, 4, 0),
	}) do
		local pillar = block(ctx, "Pillar" .. i, p, Vector3.new(4, 8, 4))
		pillar.Color = Color3.fromRGB(130, 130, 150)
	end
	block(ctx, "HalfWall", Vector3.new(5, 5, -19), Vector3.new(2, 10, 22)) -- z de -30 a -8
end

-- ===== lista =====

Scenarios.list = {
	{
		id = 1,
		name = "Corredor de 4 studs",
		description = "Duas salas ligadas por um corredor de 4 studs. Início e destino fora do eixo: é preciso curvar na entrada e na saída.",
		kind = "normal",
		build = buildCorridor,
		start = Vector3.new(-45, 0, 18),
		goal = Vector3.new(45, 0, -18),
		timeLimit = 45,
	},
	{
		id = 2,
		name = "Sala com porta estreita e mobília",
		description = "Porta de 3 studs precedida por um corredor de 3.2 entre armário e estante (altos demais para pular).",
		kind = "normal",
		build = buildRoom,
		start = Vector3.new(-45, 0, -15),
		goal = Vector3.new(45, 0, 8),
		timeLimit = 45,
	},
	{
		id = 3,
		name = "Mureta de 3 studs, desvio de 30",
		description = "A mureta cobre a pista, menos o fim. Pular economiza ~30 studs de desvio.",
		kind = "normal",
		build = buildLowWall,
		start = Vector3.new(-8, 0, 0),
		goal = Vector3.new(30, 0, 0),
		timeLimit = 45,
	},
	{
		id = 4,
		name = "Plataforma de 18 studs (JumpHeight 25)",
		description = "O destino está no topo de uma plataforma de 18 studs, sem rampa. O NPC salta 25 studs; a malha da engine não sabe.",
		kind = "normal",
		build = buildPlatform,
		start = Vector3.new(3, 0, 0),
		goal = Vector3.new(25, 18, 0),
		timeLimit = 45,
		setupRig = function(humanoid: Humanoid)
			humanoid.UseJumpPower = false
			humanoid.JumpHeight = 25
		end,
	},
	{
		id = 5,
		name = "Labirinto com gatilho invisível",
		description = "Serpentina de três paredes; a passagem do meio tem um gatilho invisível e colidível (DoorTrigger).",
		kind = "normal",
		build = buildMaze,
		start = Vector3.new(-50, 0, 0),
		goal = Vector3.new(50, 0, 0),
		timeLimit = 60,
		probes = {
			{ from = Vector3.new(-15, 0, 0), to = Vector3.new(-15, 0, -15) },
			{ from = Vector3.new(-28, 0, 10), to = Vector3.new(-3, 0, -10) },
			{ from = Vector3.new(-15, 0, 15), to = Vector3.new(-3, 0, -15) },
			{ from = Vector3.new(-15, 0, -22), to = Vector3.new(15, 0, -22) },
		},
	},
	{
		id = 6,
		name = "Limite de mapa invisível (NavSolid)",
		description = "Teste de segurança: o destino está além de um limite de mapa com tag NavSolid. Os DOIS lados devem respeitar a parede.",
		kind = "boundary",
		build = buildBoundary,
		start = Vector3.new(-40, 0, 0),
		goal = Vector3.new(40, 0, 0),
		timeLimit = 25,
		boundaryName = BOUNDARY_NAME,
	},
	{
		id = 7,
		name = "Obstáculo caindo sobre a rota",
		description = "Um bloco cai e fecha a passagem do meio quando o NPC se aproxima. A outra passagem é mais longa.",
		kind = "normal",
		build = buildDynamic,
		start = Vector3.new(-40, 0, 0),
		goal = Vector3.new(40, 0, 0),
		timeLimit = 70,
		hazard = dropBlock,
	},
	{
		id = 8,
		name = "20 NPCs simultâneos",
		description = "Pilares e meia-parede. 20 NPCs por lado vão e voltam por 30 s; um lado de cada vez, para comparar FPS.",
		kind = "crowd",
		build = buildCrowd,
		start = Vector3.new(-50, 0, 0),
		goal = Vector3.new(50, 0, 0),
		timeLimit = 90,
	},
} :: { Scenario }

return Scenarios
