--!strict
-- RouteCache.luau
-- Cache de rotas por célula.
-- Garante determinismo: mesmas células de origem/destino (e mesmo perfil de agente) devolvem
-- EXATAMENTE a mesma lista de waypoints, por construção e não por torcer pela engine.
-- As listas armazenadas são imutáveis (congeladas): quem consome não pode modificá-las.
--
-- Invalida por TTL, por mudança na versão do Geometry, por invalidateGoal (Blocked/stuck)
-- e por despejo FIFO quando passa de MaxEntries.

local Types = require(script.Parent.Types)

local RouteCache = {}
RouteCache.__index = RouteCache

export type Config = {
	CellSize: number?,
	TTL: number?,
	MaxEntries: number?,
}

type Entry = {
	waypoints: { Types.Waypoint },
	meta: { [string]: any }?,
	time: number,
	goalKey: string,
}

export type RouteCache = typeof(setmetatable(
	{} :: {
		_cell: number,
		_ttl: number,
		_max: number,
		_entries: { [string]: Entry },
		_order: { string },
		_geoVersion: number,
	},
	RouteCache
))

-- Defaults do cache.
RouteCache.DEFAULT_CELL_SIZE = 2
local DEFAULT_TTL = 15
local DEFAULT_MAX_ENTRIES = 128

function RouteCache.quantize(v: Vector3, cell: number): string
	return string.format(
		"%d,%d,%d",
		math.floor(v.X / cell + 0.5),
		math.floor(v.Y / cell + 0.5),
		math.floor(v.Z / cell + 0.5)
	)
end

function RouteCache.new(config: Config?): RouteCache
	local cfg: Config = config or {}
	return setmetatable({
		_cell = cfg.CellSize or RouteCache.DEFAULT_CELL_SIZE,
		_ttl = cfg.TTL or DEFAULT_TTL,
		_max = cfg.MaxEntries or DEFAULT_MAX_ENTRIES,
		_entries = {},
		_order = {}, -- chaves em ordem de inserção (despejo FIFO)
		_geoVersion = -1,
	}, RouteCache)
end

-- `profile` separa rotas de agentes com raio/altura/opções diferentes: o mesmo par de
-- células dá rotas diferentes conforme o tamanho do agente.
function RouteCache._key(self: RouteCache, start: Vector3, goal: Vector3, profile: string): (string, string)
	local goalKey = RouteCache.quantize(goal, self._cell)
	return profile .. "|" .. RouteCache.quantize(start, self._cell) .. "|" .. goalKey, goalKey
end

function RouteCache._remove(self: RouteCache, key: string)
	self._entries[key] = nil
	-- mantém _order sem chaves velhas: senão o despejo FIFO poderia apagar uma entrada nova
	-- que reaproveitou a mesma chave
	local i = table.find(self._order, key)
	if i then
		table.remove(self._order, i)
	end
end

function RouteCache._syncVersion(self: RouteCache, geoVersion: number)
	if geoVersion ~= self._geoVersion then
		self:clear()
		self._geoVersion = geoVersion
	end
end

function RouteCache.get(
	self: RouteCache,
	start: Vector3,
	goal: Vector3,
	profile: string,
	geoVersion: number
): ({ Types.Waypoint }?, { [string]: any }?)
	self:_syncVersion(geoVersion)
	local key = self:_key(start, goal, profile)
	local e = self._entries[key]
	if not e then
		return nil, nil
	end
	if os.clock() - e.time > self._ttl then
		self:_remove(key)
		return nil, nil
	end
	return e.waypoints, e.meta
end

function RouteCache.put(
	self: RouteCache,
	start: Vector3,
	goal: Vector3,
	profile: string,
	waypoints: { Types.Waypoint },
	geoVersion: number,
	meta: { [string]: any }?
)
	self:_syncVersion(geoVersion)
	local key, goalKey = self:_key(start, goal, profile)
	if not self._entries[key] then
		table.insert(self._order, key)
	end
	if not table.isfrozen(waypoints) then
		table.freeze(waypoints)
	end
	self._entries[key] = { waypoints = waypoints, meta = meta, time = os.clock(), goalKey = goalKey }
	while #self._order > self._max do
		self:_remove(self._order[1])
	end
end

-- Remove toda rota que termina na célula do destino (qualquer origem/perfil).
function RouteCache.invalidateGoal(self: RouteCache, goal: Vector3)
	local goalKey = RouteCache.quantize(goal, self._cell)
	for key, e in pairs(table.clone(self._entries)) do
		if e.goalKey == goalKey then
			self:_remove(key)
		end
	end
end

function RouteCache.clear(self: RouteCache)
	table.clear(self._entries)
	table.clear(self._order)
end

function RouteCache.size(self: RouteCache): number
	return #self._order
end

return RouteCache
