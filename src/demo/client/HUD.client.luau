--!strict
-- HUD.client.luau
-- HUD do place de demonstração: FPS (cliente e servidor), fila do Scheduler, e por cenário os
-- botões Reiniciar/Ver, o contador de sucesso/falha de cada lado e o último resultado.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local stateFolder = ReplicatedStorage:WaitForChild("SmartPathDemoState")
local stateValue = stateFolder:WaitForChild("State") :: StringValue
local actions = stateFolder:WaitForChild("Actions") :: RemoteEvent

local CLASSIC_COLOR = Color3.fromRGB(255, 120, 120)
local SMART_COLOR = Color3.fromRGB(110, 235, 150)
local PANEL_BG = Color3.fromRGB(22, 24, 30)
local ROW_BG = Color3.fromRGB(34, 37, 46)
local TEXT = Color3.fromRGB(235, 235, 240)
local MUTED = Color3.fromRGB(160, 165, 180)

local gui = Instance.new("ScreenGui")
gui.Name = "SmartPathDemoHUD"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100

local function label(parent: Instance, text: string, size: UDim2, position: UDim2, color: Color3?, textSize: number?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = position
	l.Font = Enum.Font.Gotham
	l.TextSize = textSize or 13
	l.TextColor3 = color or TEXT
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.Text = text
	l.Parent = parent
	return l
end

local function button(parent: Instance, text: string, position: UDim2, width: number, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(width, 24)
	b.Position = position
	b.BackgroundColor3 = Color3.fromRGB(60, 90, 160)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.AutoButtonColor = true
	b.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = b
	b.Activated:Connect(onClick)
	return b
end

-- ===== barra do topo =====

local top = Instance.new("Frame")
top.Size = UDim2.new(0, 460, 0, 64)
top.Position = UDim2.fromOffset(10, 10)
top.BackgroundColor3 = PANEL_BG
top.BackgroundTransparency = 0.1
top.Parent = gui
local topCorner = Instance.new("UICorner")
topCorner.Parent = top
local stats = label(top, "", UDim2.new(1, -16, 0, 22), UDim2.fromOffset(8, 6), TEXT, 14)
button(top, "Rodar todos", UDim2.fromOffset(8, 32), 110, function()
	actions:FireServer("startAll")
end)
button(top, "Zerar contadores", UDim2.fromOffset(126, 32), 130, function()
	actions:FireServer("clearStats")
end)

-- ===== lista de cenários =====

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(0, 460, 1, -94)
list.Position = UDim2.fromOffset(10, 84)
list.BackgroundColor3 = PANEL_BG
list.BackgroundTransparency = 0.1
list.BorderSizePixel = 0
list.ScrollBarThickness = 6
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = gui
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = list
local padding = Instance.new("UIPadding")
padding.PaddingTop, padding.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)
padding.Parent = list

type Row = {
	frame: Frame,
	title: TextLabel,
	status: TextLabel,
	left: TextLabel,
	right: TextLabel,
}
local rows: { [number]: Row } = {}

local STATUS_TEXT = {
	idle = "parado",
	preparing = "preparando a malha...",
	running = "rodando",
	done = "concluído",
}

local function buildRow(id: number, name: string, description: string): Row
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 152)
	frame.BackgroundColor3 = ROW_BG
	frame.LayoutOrder = id
	frame.Parent = list
	local corner = Instance.new("UICorner")
	corner.Parent = frame

	local title = label(frame, string.format("%d. %s", id, name), UDim2.new(1, -190, 0, 20), UDim2.fromOffset(8, 6), TEXT, 15)
	title.Font = Enum.Font.GothamBold
	button(frame, "Reiniciar", UDim2.new(1, -172, 0, 6), 80, function()
		actions:FireServer("start", id)
	end)
	button(frame, "Ver", UDim2.new(1, -86, 0, 6), 70, function()
		actions:FireServer("view", id)
	end)
	label(frame, description, UDim2.new(1, -16, 0, 34), UDim2.fromOffset(8, 30), MUTED, 12)
	local status = label(frame, "", UDim2.new(1, -16, 0, 16), UDim2.fromOffset(8, 66), MUTED, 12)
	local left = label(frame, "", UDim2.new(1, -16, 0, 34), UDim2.fromOffset(8, 84), CLASSIC_COLOR, 12)
	local right = label(frame, "", UDim2.new(1, -16, 0, 34), UDim2.fromOffset(8, 118), SMART_COLOR, 12)
	return { frame = frame, title = title, status = status, left = left, right = right }
end

local function lane(name: string, data: any): string
	return string.format("%s  ✔ %d  ✘ %d — %s", name, data.ok, data.fail, data.text)
end

local function apply(state: any)
	for _, s in ipairs(state.scenarios) do
		local row = rows[s.id]
		if not row then
			row = buildRow(s.id, s.name, s.description)
			rows[s.id] = row
		end
		row.status.Text = STATUS_TEXT[s.status] or s.status
		row.left.Text = lane("PathfindingService", s.L)
		row.right.Text = lane("SmartPath", s.R)
	end
end

-- ===== atualização =====

local clientFps = 60
local frames, windowStart = 0, os.clock()
RunService.RenderStepped:Connect(function()
	frames += 1
	local now = os.clock()
	if now - windowStart >= 0.5 then
		clientFps = frames / (now - windowStart)
		frames, windowStart = 0, now
	end
end)

local lastState: any = nil
local function refresh()
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(stateValue.Value)
	end)
	if ok then
		lastState = decoded
		apply(decoded)
	end
end

stateValue.Changed:Connect(refresh)
refresh()

task.spawn(function()
	while gui.Parent do
		local state = lastState
		stats.Text = string.format(
			"FPS cliente %.0f · FPS servidor %.0f · fila do Scheduler %d",
			clientFps,
			if state then state.fps else 0,
			if state then state.queue else 0
		)
		task.wait(0.25)
	end
end)

gui.Parent = player:WaitForChild("PlayerGui")
