--[[
	Diagnostics
	Test-build helper: script errors show up ON SCREEN (Roblox Studio only) so a tester can
	take a screenshot instead of digging in the Output window. Nothing is drawn while there
	is no error, and nothing at all in a live game.

	  Diagnostics.report(stage, name, err)   a failed boot step (Main.client): listed + warn()
	  Diagnostics.start()                    also lists client runtime errors (ScriptContext.Error)
	                                         and the errors the server published
	                                         (ReplicatedStorage attributes ServerBootErrors /
	                                         ServerErrors, written by Main.server)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Diagnostics = {}

local MAX_ROWS = 7
local MAX_LENGTH = 230

local entries: { { Key: string, Text: string, Count: number, Source: string } } = {}
local byKey: { [string]: any } = {}
local gui: ScreenGui? = nil
local body: Frame? = nil
local header: TextLabel? = nil
local dirty = false
local started = false
local hidden = false

local function enabled(): boolean
	return RunService:IsStudio()
end

local function firstLine(text: string): string
	local line = string.match(text, "^[^\n]*") or text
	if #line > MAX_LENGTH then
		line = string.sub(line, 1, MAX_LENGTH) .. "..."
	end
	return line
end

local function add(source: string, text: string)
	local line = firstLine(text)
	local key = source .. "|" .. line
	local found = byKey[key]
	if found then
		found.Count += 1
	else
		found = { Key = key, Text = line, Count = 1, Source = source }
		byKey[key] = found
		table.insert(entries, found)
		if #entries > 40 then
			local old = table.remove(entries, 1)
			byKey[old.Key] = nil
		end
	end
	dirty = true
end

-- ============================================================== panel
local function build()
	if gui and gui.Parent then
		return
	end
	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "Diagnostics"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 1000
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = playerGui
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 8, 1, -8)
	panel.Size = UDim2.new(0.62, 0, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(40, 8, 12)
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Parent = screen
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 90, 90)
	stroke.Thickness = 2
	stroke.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 3)
	list.Parent = panel
	local head = Instance.new("TextButton")
	head.Name = "Header"
	head.LayoutOrder = 0
	head.BackgroundTransparency = 1
	head.AutoButtonColor = false
	head.Size = UDim2.new(1, 0, 0, 20)
	head.Font = Enum.Font.GothamBlack
	head.TextSize = 15
	head.TextColor3 = Color3.fromRGB(255, 140, 140)
	head.TextXAlignment = Enum.TextXAlignment.Left
	head.Text = ""
	head.Parent = panel
	head.Activated:Connect(function()
		-- tap the header: clear the list
		table.clear(entries)
		table.clear(byKey)
		dirty = true
	end)
	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.LayoutOrder = 1
	rows.BackgroundTransparency = 1
	rows.Size = UDim2.new(1, 0, 0, 0)
	rows.AutomaticSize = Enum.AutomaticSize.Y
	rows.Parent = panel
	local rowList = Instance.new("UIListLayout")
	rowList.SortOrder = Enum.SortOrder.LayoutOrder
	rowList.Padding = UDim.new(0, 2)
	rowList.Parent = rows
	gui, body, header = screen, rows, head
end

local function refresh()
	dirty = false
	if not enabled() then
		return
	end
	if #entries == 0 then
		if gui then
			gui.Enabled = false
		end
		return
	end
	build()
	if not gui or not body or not header then
		return
	end
	gui.Enabled = not hidden
	local total = 0
	for _, e in entries do
		total += e.Count
	end
	header.Text = string.format("SCRIPT ERRORS (%d) - take a screenshot and send it  |  tap here to clear", total)
	for _, child in body:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local first = math.max(1, #entries - MAX_ROWS + 1)
	for i = first, #entries do
		local e = entries[i]
		local row = Instance.new("TextLabel")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.Font = Enum.Font.Code
		row.TextSize = 13
		row.TextWrapped = true
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextYAlignment = Enum.TextYAlignment.Top
		row.TextColor3 = e.Source == "server" and Color3.fromRGB(255, 220, 140) or Color3.fromRGB(255, 255, 255)
		row.Text = string.format("[%s]%s %s", e.Source, e.Count > 1 and (" x" .. e.Count) or "", e.Text)
		row.Parent = body
	end
end

-- ============================================================== api
function Diagnostics.report(stage: string, name: string, err: any)
	add("client", string.format("%s %s: %s", stage, name, tostring(err)))
end

-- Errors collected so far (for tests / tools).
function Diagnostics.count(): number
	local n = 0
	for _, e in entries do
		n += e.Count
	end
	return n
end

function Diagnostics.entries()
	return entries
end

function Diagnostics.start()
	if started then
		return
	end
	started = true
	-- client runtime errors
	local ok, scriptContext = pcall(function()
		return game:GetService("ScriptContext")
	end)
	if ok and scriptContext then
		pcall(function()
			scriptContext.Error:Connect(function(message, _trace, source)
				add("client", (source and (source.Name .. ": ") or "") .. tostring(message))
			end)
		end)
	end
	-- what the server reports
	local function readServer()
		for _, attr in { "ServerBootErrors", "ServerErrors" } do
			local text = ReplicatedStorage:GetAttribute(attr)
			if type(text) == "string" and text ~= "" then
				for chunk in string.gmatch(text .. "\n---\n", "(.-)\n%-%-%-\n") do
					if chunk ~= "" then
						local key = "server|" .. firstLine(chunk)
						if not byKey[key] then
							add("server", chunk)
						end
					end
				end
			end
		end
	end
	readServer()
	for _, attr in { "ServerBootErrors", "ServerErrors" } do
		ReplicatedStorage:GetAttributeChangedSignal(attr):Connect(readServer)
	end
	task.spawn(function()
		while true do
			task.wait(0.5)
			if dirty then
				local fine, err = pcall(refresh)
				if not fine then
					warn("[Diagnostics] " .. tostring(err))
				end
			end
		end
	end)
	-- first paint (boot errors reported before start())
	pcall(refresh)
end

return Diagnostics
