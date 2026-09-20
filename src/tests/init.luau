--!strict
-- SmartPathTests (init.luau)
-- Harness de verificação manual dos critérios de aceite de cada fase. NÃO faz parte da
-- biblioteca — não é requerido pelo SmartPath em nenhum momento, é ferramenta de
-- validação para você rodar no Command Bar durante o Play mode (Seção 8 do
-- SMARTPATH_PLANO_DE_EXECUCAO.md: "rode os critérios de aceite você mesmo, não aceite
-- 'testei e funciona' sem ver").
--
-- Uso (Command Bar, em Play mode, no servidor):
--   require(game.ServerStorage.SmartPathTests).Phase1()

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SmartPath = require(ReplicatedStorage.SmartPath)
local Scheduler = SmartPath.Scheduler
local Geometry = SmartPath.Geometry

local Tests = {}

local function report(name: string, ok: boolean, detail: string?): boolean
	print(string.format("[SmartPathTests] %s %s%s", ok and "PASS" or "FAIL", name, detail and (" — " .. detail) or ""))
	return ok
end

local function makePart(props: { [string]: any }): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = Vector3.new(4, 4, 4)
	p.Position = Vector3.new(0, 200, 0) -- alto, fora do caminho de qualquer coisa no place
	for k, v in pairs(props) do
		(p :: any)[k] = v
	end
	p.Parent = workspace
	return p
end

-- ===== Scheduler =====

local function testSchedulerBudget(): boolean
	Scheduler.setBudget(4)
	local startedCount = 0
	for i = 1, 50 do
		Scheduler.submit("budget-test-" .. i, 0, function()
			startedCount += 1
			return true
		end)
	end

	local maxStartedInOneFrame = 0
	for _ = 1, 20 do
		local before = startedCount
		RunService.Heartbeat:Wait()
		local delta = startedCount - before
		maxStartedInOneFrame = math.max(maxStartedInOneFrame, delta)
	end

	return report(
		"Scheduler: 50 pedidos não passam do orçamento por frame",
		maxStartedInOneFrame <= 4,
		"máximo observado por frame: " .. maxStartedInOneFrame .. ", processados: " .. startedCount
	)
end

local function testSchedulerCancel(): boolean
	local ran = false
	local h = Scheduler.submit("cancel-test", 0, function()
		ran = true
	end)
	h:cancel()
	for _ = 1, 10 do
		RunService.Heartbeat:Wait()
	end
	return report("Scheduler: pedido cancelado nunca executa", ran == false)
end

local function testSchedulerCoalescing(): boolean
	local callCount = 0
	local h1 = Scheduler.submit("coalesce-test", 0, function()
		callCount += 1
		return "resultado-unico"
	end)
	local h2 = Scheduler.submit("coalesce-test", 5, function()
		callCount += 1
		return "nao deveria rodar"
	end)

	local r1 = { h1:await() }
	local r2 = { h2:await() }

	local sameResult = r1[1] == "resultado-unico" and r2[1] == "resultado-unico"
	return report(
		"Scheduler: dois pedidos idênticos pendentes viram um só cálculo",
		callCount == 1 and sameResult,
		"callCount=" .. callCount
	)
end

-- ===== Geometry =====

local function testGeometryAutoDetect(): boolean
	Geometry.start()
	local part = makePart({ Name = "ZoneTrigger", Transparency = 1, CanCollide = true })
	task.wait() -- DescendantAdded é tratado com task.defer

	local hasModifier = part:FindFirstChildWhichIsA("PathfindingModifier") ~= nil
	part:Destroy()
	task.wait()

	return report("Geometry: invisível colidível com nome suspeito recebe PassThrough", hasModifier)
end

local function testGeometryNavSolidPrecedence(): boolean
	local part = makePart({ Name = "zone_wall_hitbox", Transparency = 1, CanCollide = true })
	CollectionService:AddTag(part, "NavSolid")
	task.wait()

	local hasModifier = part:FindFirstChildWhichIsA("PathfindingModifier") ~= nil
	part:Destroy()
	task.wait()

	return report("Geometry: tag NavSolid nunca recebe modifier, mesmo com nome suspeito", not hasModifier)
end

local function testGeometryAudit(): boolean
	local part = makePart({ Name = "UnclassifiedThing", Transparency = 1, CanCollide = true })
	task.wait()

	local suspects = Geometry.audit()
	local found = table.find(suspects, part) ~= nil
	part:Destroy()
	task.wait()

	return report("Geometry: audit() lista invisível colidível não classificada", found)
end

local function testGeometryVersionOnRemoval(): boolean
	local part = makePart({ Name = "ZoneRemovalTest", Transparency = 1, CanCollide = true })
	task.wait()
	local before = Geometry.getVersion()
	local countBefore = Geometry.getIgnoredCount()

	part:Destroy()
	task.wait()

	local after = Geometry.getVersion()
	local countAfter = Geometry.getIgnoredCount()

	return report(
		"Geometry: remover parte decrementa a lista e incrementa a versão",
		after > before and countAfter < countBefore,
		"version " .. before .. " -> " .. after .. ", count " .. countBefore .. " -> " .. countAfter
	)
end

local function testGeometryAutoFilterToggleNoResidue(): boolean
	local auto = makePart({ Name = "ZoneAutoToggle", Transparency = 1, CanCollide = true })
	local tagged = makePart({ Name = "TaggedIgnoreToggle", Transparency = 1, CanCollide = true })
	CollectionService:AddTag(tagged, "NavIgnore")
	task.wait()

	local autoMarkedBefore = auto:FindFirstChildWhichIsA("PathfindingModifier") ~= nil
	local taggedMarkedBefore = tagged:FindFirstChildWhichIsA("PathfindingModifier") ~= nil

	Geometry.setAutoFilter(false)
	task.wait()

	local autoMarkedAfter = auto:FindFirstChildWhichIsA("PathfindingModifier") ~= nil
	local taggedMarkedAfter = tagged:FindFirstChildWhichIsA("PathfindingModifier") ~= nil

	Geometry.setAutoFilter(true) -- devolve o estado global ao normal para o resto do place
	auto:Destroy()
	tagged:Destroy()
	task.wait()

	return report(
		"Geometry: desligar AutoFilter remove modifiers automáticos sem afetar tags explícitas",
		autoMarkedBefore and not autoMarkedAfter and taggedMarkedBefore and taggedMarkedAfter
	)
end

function Tests.Phase1(): boolean
	print("[SmartPathTests] ==== Fase 1: Scheduler + Geometry ====")
	local results = {
		testSchedulerBudget(),
		testSchedulerCancel(),
		testSchedulerCoalescing(),
		testGeometryAutoDetect(),
		testGeometryNavSolidPrecedence(),
		testGeometryAudit(),
		testGeometryVersionOnRemoval(),
		testGeometryAutoFilterToggleNoResidue(),
	}
	local allOk = true
	for _, ok in ipairs(results) do
		allOk = allOk and ok
	end
	print("[SmartPathTests] ==== Resultado: " .. (allOk and "TUDO PASSOU" or "HÁ FALHAS ACIMA") .. " ====")
	return allOk
end

return Tests
