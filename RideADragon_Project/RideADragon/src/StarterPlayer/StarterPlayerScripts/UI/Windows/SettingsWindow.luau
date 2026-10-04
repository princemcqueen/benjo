--[[
	SettingsWindow
	Graphics preset, audio volumes, camera options, UI size, controls help.
	Changes apply instantly on the client and are saved on the server
	(validated + rate-limited) via Settings.Set.
]]

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Kit = require(UI.Kit)
local WindowBase = require(UI.WindowBase)

local C = Theme.Colors

local SettingsWindow = {}
SettingsWindow.__index = SettingsWindow
setmetatable(SettingsWindow, { __index = WindowBase })

local CONTROLS = {
	{ "Move", "W A S D" },
	{ "Jump / Take off / Fly up", "SPACE (hold to take off)" },
	{ "Fly down / Land", "CTRL or C" },
	{ "Sprint / Boost", "SHIFT" },
	{ "Ride / Dismount", "R" },
	{ "Roar", "F" },
	{ "Interact", "E (hold)" },
	{ "Rotate camera", "Right mouse / V to lock" },
	{ "Dragons / Index / Quests", "G / X / Q" },
	{ "Shop / Daily / Settings", "B / J / P" },
}

function SettingsWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Settings",
		Title = "Settings",
		Icon = "Gear",
		Spec = {
			Desktop = { Width = 0.42, Height = 0.74, Aspect = 1.08 },
			Tablet = { Width = 0.7, Height = 0.84, Aspect = 1.1 },
			Phone = { Width = 0.8, Height = 1 },
			PhonePortrait = { Width = 0.96, Height = 1 },
		},
	})
	setmetatable(self, SettingsWindow)
	self.UIC = ui
	self.Registry = registry
	self.Controls = {}
	self:Build()
	return self
end

function SettingsWindow:Row(parent: Instance, order: number, label: string, sub: string?)
	local row = Kit.frame({ Name = "Row_" .. label, LayoutOrder = order, Parent = parent })
	Responsive.bind(row, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(R.Device == "Phone" and 64 or 54))
	end)
	Kit.text({
		Name = "Label",
		Text = label,
		Role = "Body",
		Font = Theme.Fonts.Label,
		Position = UDim2.fromScale(0, sub and 0.08 or 0),
		Size = UDim2.fromScale(0.5, sub and 0.5 or 1),
		Parent = row,
	})
	if sub then
		Kit.text({
			Name = "Sub",
			Text = sub,
			Role = "Caption",
			Color = C.TextDim,
			Position = UDim2.fromScale(0, 0.55),
			Size = UDim2.fromScale(0.5, 0.38),
			Truncate = true,
			Parent = row,
		})
	end
	local slot = Kit.frame({ Name = "Control", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromScale(0.46, 0.62), Parent = row })
	Kit.divider(row, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Transparency = 0.82 })
	return slot
end

function SettingsWindow:Section(parent: Instance, order: number, title: string)
	local f = Kit.frame({ Name = "Section_" .. title, LayoutOrder = order, Parent = parent })
	Responsive.bind(f, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(40))
	end)
	Kit.text({
		Text = title,
		Role = "Label",
		Font = Theme.Fonts.Title,
		Color = C.Gold,
		YAlign = Enum.TextYAlignment.Bottom,
		Size = UDim2.fromScale(1, 0.8),
		Parent = f,
	})
end

function SettingsWindow:Build()
	local scroll = Kit.scroll({ Name = "List", Parent = self.Content })
	Kit.padding(scroll, 0, 14, 10, 2)
	Kit.list(scroll, "V", 2)
	self.List = scroll
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	self:Section(scroll, nextOrder(), "GRAPHICS")
	local quality = Kit.segmented({ Options = { "Max", "High", "Medium" }, Value = "Max", Parent = self:Row(scroll, nextOrder(), "Quality", "MAX looks best on gaming PCs") })
	quality.Changed:Connect(function(v)
		self:Set("Graphics", v)
	end)
	self.Controls.Graphics = quality

	self:Section(scroll, nextOrder(), "AUDIO")
	local music = Kit.slider({ Value = 0.6, Min = 0, Max = 1, Step = 0.05, Parent = self:Row(scroll, nextOrder(), "Music") })
	music.Changed:Connect(function(v)
		self:Set("Music", v)
	end)
	self.Controls.Music = music
	local sfx = Kit.slider({ Value = 0.8, Min = 0, Max = 1, Step = 0.05, Parent = self:Row(scroll, nextOrder(), "Effects") })
	sfx.Changed:Connect(function(v)
		self:Set("SFX", v)
	end)
	self.Controls.SFX = sfx

	self:Section(scroll, nextOrder(), "CAMERA")
	local sens = Kit.slider({ Value = 1, Min = 0.4, Max = 2, Step = 0.05, Parent = self:Row(scroll, nextOrder(), "Sensitivity") })
	sens.Changed:Connect(function(v)
		self:Set("Sensitivity", v)
	end)
	self.Controls.Sensitivity = sens
	local function toggleRow(key: string, label: string, sub: string?)
		local slot = self:Row(scroll, nextOrder(), label, sub)
		local t = Kit.toggle({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromScale(1, 0.9), Parent = slot })
		t.Changed:Connect(function(v)
			self:Set(key, v)
		end)
		self.Controls[key] = t
	end
	toggleRow("CameraShake", "Camera shake", "Landings and boosts")
	toggleRow("SpeedFOV", "Speed effects", "Field of view widens when boosting")
	toggleRow("MouseLock", "Mouse steering", "Lock the cursor while riding (V)")
	toggleRow("InvertY", "Invert camera Y")

	self:Section(scroll, nextOrder(), "INTERFACE")
	local uiSize = Kit.segmented({ Options = { "0.9", "1", "1.1" }, Labels = { "SMALL", "NORMAL", "LARGE" }, Value = "1", Parent = self:Row(scroll, nextOrder(), "Interface size") })
	uiSize.Changed:Connect(function(v)
		self:Set("UIScale", tonumber(v))
	end)
	self.Controls.UIScale = uiSize

	self:Section(scroll, nextOrder(), "CONTROLS")
	for _, pair in CONTROLS do
		local row = Kit.frame({ Name = "Key_" .. pair[1], LayoutOrder = nextOrder(), Parent = scroll })
		Responsive.bind(row, "Size", function(R)
			return UDim2.new(1, 0, 0, R.px(34))
		end)
		Kit.text({ Text = pair[1], Role = "Label", Color = C.TextMuted, Size = UDim2.fromScale(0.55, 1), Parent = row })
		Kit.text({ Text = pair[2], Role = "Label", Font = Theme.Fonts.Label, XAlign = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(0.45, 1), Parent = row })
	end

	self.SaveNote = Kit.text({
		Name = "SaveNote",
		Text = "",
		Role = "Caption",
		Color = C.Warning,
		Wrapped = true,
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, 0, 0, 0),
		AutoSize = Enum.AutomaticSize.Y,
		Parent = scroll,
	})
end

function SettingsWindow:Set(key: string, value: any)
	local settings = self.Registry.SettingsController
	if settings then
		settings.set(key, value)
	end
end

function SettingsWindow:OnOpen()
	local data = self.Registry.DataController.all()
	if not data then
		return
	end
	local s = data.Settings
	self.Controls.Graphics:Set(s.Graphics)
	self.Controls.Music:Set(s.Music)
	self.Controls.SFX:Set(s.SFX)
	self.Controls.Sensitivity:Set(s.Sensitivity)
	self.Controls.CameraShake:Set(s.CameraShake)
	self.Controls.SpeedFOV:Set(s.SpeedFOV)
	self.Controls.MouseLock:Set(s.MouseLock)
	self.Controls.InvertY:Set(s.InvertY)
	local uiValue = s.UIScale >= 1.05 and "1.1" or (s.UIScale <= 0.95 and "0.9" or "1")
	self.Controls.UIScale:Set(uiValue)
	self.SaveNote.Text = self.Registry.DataController.Temporary
		and "Studio: DataStore access is off, so changes will not be saved. Enable 'Studio Access to API Services' to test saving."
		or ""
end

return SettingsWindow
