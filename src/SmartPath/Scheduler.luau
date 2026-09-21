--!strict
-- Scheduler.luau
-- Fila global de cálculos de rota com orçamento por frame, prioridade numérica,
-- cancelamento e coalescência de pedidos idênticos (plano de execução, Fase 1).
-- Singleton documentado (regra 2 da Seção 5 do plano): existe um por ambiente
-- (cliente/servidor), cada um com sua própria fila.
--
-- Prioridade: número MAIOR = mais urgente (ver D-007 em DECISIONS.md). Em empate, o
-- pedido mais antigo (menor `seq`) vai primeiro, para evitar starvation por ordem.
--
-- O orçamento limita quantos jobs são INICIADOS por frame, não quantos ficam "em voo":
-- ComputeAsync já dá yield sozinho, então o custo que queremos limitar é o de disparar a
-- chamada (voxelização/busca), não o de esperar ela terminar.

local RunService = game:GetService("RunService")
local Signal = require(script.Parent.Signal)

local Scheduler = {}

export type Handle = {
	cancel: (self: Handle) -> (),
	await: (self: Handle) -> ...any,
	isDone: (self: Handle) -> boolean,
	isCancelled: (self: Handle) -> boolean,
}

type Entry = {
	key: string,
	priority: number,
	fn: () -> ...any,
	seq: number,
	waiters: { HandleImpl },
	started: boolean,
}

type HandleImpl = {
	_entry: Entry,
	_cancelled: boolean,
	_done: boolean,
	_results: { any }?,
	_resultsN: number,
	_completed: Signal.Signal,
}

local HandleMeta = {}
HandleMeta.__index = HandleMeta

local queue: { Entry } = {}
local byKey: { [string]: Entry } = {}
local seqCounter = 0
local budget = 4

local function newHandle(entry: Entry): HandleImpl
	return (
		setmetatable({
			_entry = entry,
			_cancelled = false,
			_done = false,
			_results = nil,
			_resultsN = 0,
			_completed = Signal.new(),
		}, HandleMeta) :: any
	) :: HandleImpl
end

function HandleMeta:cancel()
	local this = self :: HandleImpl
	if this._done or this._cancelled then
		return
	end
	this._cancelled = true
	this._completed:Fire() -- libera quem estiver em :await()

	local entry = this._entry
	if entry.started then
		return -- já disparado: não dá pra abortar o fn em voo, só descartar o resultado
	end
	local idx = table.find(entry.waiters, this :: any)
	if idx then
		table.remove(entry.waiters, idx)
	end
	if #entry.waiters == 0 then
		-- ninguém mais espera esse cálculo: some da fila antes de rodar (regra: pedido
		-- cancelado nunca executa)
		local qIdx = table.find(queue, entry)
		if qIdx then
			table.remove(queue, qIdx)
		end
		if byKey[entry.key] == entry then
			byKey[entry.key] = nil
		end
	end
end

function HandleMeta:isDone(): boolean
	return (self :: HandleImpl)._done
end

function HandleMeta:isCancelled(): boolean
	return (self :: HandleImpl)._cancelled
end

function HandleMeta:await(): ...any
	local this = self :: HandleImpl
	if this._done then
		return table.unpack(this._results :: { any }, 1, this._resultsN)
	end
	if this._cancelled then
		return nil, "cancelled"
	end
	this._completed:Wait()
	if this._cancelled then
		return nil, "cancelled"
	end
	return table.unpack(this._results :: { any }, 1, this._resultsN)
end

-- ===== Submissão =====

-- Duas submissões com a mesma `key` enquanto a primeira ainda não rodou viram um único
-- cálculo: a prioridade efetiva é a maior das duas, e cada chamador recebe seu próprio
-- Handle (pode cancelar seu próprio interesse sem afetar o outro chamador).
function Scheduler.submit(key: string, priority: number, fn: () -> ...any): Handle
	local existing = byKey[key]
	if existing and not existing.started then
		existing.priority = math.max(existing.priority, priority)
		local handle = newHandle(existing)
		table.insert(existing.waiters, handle)
		return handle :: any
	end

	seqCounter += 1
	local entry: Entry = {
		key = key,
		priority = priority,
		fn = fn,
		seq = seqCounter,
		waiters = {},
		started = false,
	}
	local handle = newHandle(entry)
	table.insert(entry.waiters, handle)
	table.insert(queue, entry)
	byKey[key] = entry
	return handle :: any
end

-- ===== Configuração do orçamento =====

function Scheduler.setBudget(n: number)
	budget = math.max(1, math.floor(n))
end

function Scheduler.getBudget(): number
	return budget
end

function Scheduler.getQueueLength(): number
	return #queue
end

-- ===== Execução =====

local function popBest(): Entry?
	if #queue == 0 then
		return nil
	end
	local bestIdx = 1
	for i = 2, #queue do
		local a, b = queue[i], queue[bestIdx]
		if a.priority > b.priority or (a.priority == b.priority and a.seq < b.seq) then
			bestIdx = i
		end
	end
	return table.remove(queue, bestIdx)
end

local function runEntry(entry: Entry)
	entry.started = true
	if byKey[entry.key] == entry then
		byKey[entry.key] = nil
	end
	task.spawn(function()
		local ok, packed = pcall(function()
			return table.pack(entry.fn())
		end)
		local results
		if ok then
			results = packed
		else
			-- falha aqui não é rotina de debug: é bug real, por isso não fica atrás de
			-- options.Debug (mesmo padrão do warn em Agent:_compute na ESPEC de referência)
			warn("[SmartPath] Scheduler: job falhou:", packed)
			results = table.pack(nil, "scheduler_job_error")
		end
		for _, handle in ipairs(entry.waiters) do
			if not handle._cancelled then
				handle._results = results
				handle._resultsN = results.n
				handle._done = true
				handle._completed:Fire()
			end
		end
	end)
end

RunService.Heartbeat:Connect(function()
	local processed = 0
	while processed < budget do
		local entry = popBest()
		if not entry then
			break
		end
		if #entry.waiters == 0 then
			continue -- todo mundo cancelou enquanto esperava; não conta orçamento
		end
		processed += 1
		runEntry(entry)
	end
end)

return Scheduler
