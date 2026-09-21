--!strict
-- Main.server.luau
-- Ponto de entrada do place de demonstração: monta os 11 cenários e liga os botões do HUD.
--
-- Comandos sem HUD. A Command Bar do Studio NÃO compartilha os módulos do servidor (um require dela
-- devolve uma cópia vazia do Runner), então os comandos passam por um atributo desta pasta:
--   game.ServerScriptService.SmartPathDemo:SetAttribute("Command", "runReport")
--   game.ServerScriptService.SmartPathDemo:SetAttribute("Command", "run:8")  -- só o cenário 8
--   game.ServerScriptService.SmartPathDemo:SetAttribute("Command", "checkClean:3")
--   game.ServerScriptService.SmartPathDemo:SetAttribute("Command", "diagnose:5")  -- rotas, sem mover ninguém
-- O resultado sai no Output com o prefixo [SmartPathDemo].

local Runner = require(script.Parent.Runner)

local folder = script.Parent

folder:GetAttributeChangedSignal("Command"):Connect(function()
	local command = folder:GetAttribute("Command")
	if typeof(command) ~= "string" or command == "" then
		return
	end
	folder:SetAttribute("Command", nil) -- permite repetir o mesmo comando
	task.spawn(function()
		if command == "runReport" then
			Runner.runReport()
		else
			local runId = string.match(command, "^run:(%d+)$")
			local diagId = string.match(command, "^diagnose:(%d+)$")
			local id = string.match(command, "^checkClean:(%d+)$")
			if runId then
				Runner.runReport(tonumber(runId))
			elseif diagId then
				Runner.diagnose(tonumber(diagId) :: number)
			elseif id then
				local ok, detail = Runner.checkCleanRestart(tonumber(id) :: number)
				print(string.format("[SmartPathDemo] reinício limpo (cenário %s): %s — %s", id, ok and "SIM" or "NÃO", detail))
			else
				warn("[SmartPathDemo] comando desconhecido: " .. command)
			end
		end
	end)
end)

Runner.init()
