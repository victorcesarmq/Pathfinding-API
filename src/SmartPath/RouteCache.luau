--!strict
-- RouteCache.luau
-- STUB -- implementado na Fase 2 (cache de rotas por célula, TTL, invalidação por
-- Blocked/versão de geometria/anti-stuck — Seção 3.4 da ESPEC_NAVEGACAO_ROBLOX.md).

local RouteCache = {}
RouteCache.__index = RouteCache

function RouteCache.new(config: { [string]: any })
	error("SmartPath: not implemented (Fase 2) — RouteCache.new", 2)
end

return RouteCache
