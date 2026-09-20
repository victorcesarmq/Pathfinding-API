--!strict
-- Signal.luau
-- Wrapper leve sobre BindableEvent (:Connect, :Fire, :Wait, :Destroy). Existe para que
-- :Destroy() em qualquer objeto da lib desconecte 100% das conexões a partir de um único
-- ponto (regra 3 do plano) sem expor o BindableEvent bruto — quem consome um sinal público
-- não deve poder chamar :Fire() nele por engano.

local Signal = {}
Signal.__index = Signal

export type Signal = typeof(setmetatable(
	{} :: {
		_bindable: BindableEvent,
		_connections: { RBXScriptConnection },
	},
	Signal
))

function Signal.new(): Signal
	local self = setmetatable({
		_bindable = Instance.new("BindableEvent"),
		_connections = {},
	}, Signal)
	return self
end

function Signal.Connect(self: Signal, fn: (...any) -> ()): RBXScriptConnection
	local conn = self._bindable.Event:Connect(fn)
	table.insert(self._connections, conn)
	return conn
end

function Signal.Once(self: Signal, fn: (...any) -> ()): RBXScriptConnection
	local conn: RBXScriptConnection
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal.Wait(self: Signal): ...any
	return self._bindable.Event:Wait()
end

function Signal.Fire(self: Signal, ...: any)
	self._bindable:Fire(...)
end

function Signal.Destroy(self: Signal)
	for _, conn in ipairs(self._connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)
	self._bindable:Destroy()
end

return Signal
