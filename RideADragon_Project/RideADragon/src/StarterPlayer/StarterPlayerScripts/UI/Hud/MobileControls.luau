--[[
	MobileControls
	Touch riding controls (phones and tablets), shown only while mounted:

	  JUMP / FLY / UP   big thumb button (hold: climb while flying)
	  DOWN              descend / land
	  BOOST             sprint on ground, boost in flight; its fill shows
	                    the boost meter (blue, orange while boosting)
	  ROAR              roar
	  DASH / FIRE / DANCE  Dragon Bond abilities (shown once the bond level unlocks
	                    them; the fill shows the cooldown)
	  DISMOUNT          leave the saddle
	  speed readout     km/h above the cluster

	The cluster sits bottom-right, mirroring the thumbstick, sized from the
	short side of the screen so it keeps the same physical size everywhere.
	Buttons drive InputController virtual actions (press = down, release =
	up), so mobile uses exactly the same riding code as keyboard/gamepad.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local Format = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Format"))

local C = Theme.Colors
local H = Theme.Hud

local MobileControls = {}
MobileControls.__index = MobileControls

local BUTTONS = {
	{ Id = "Jump", Action = "Jump", Icon = "Wing", Text = "JUMP", Big = true },
	{ Id = "Boost", Action = "Sprint", Icon = "Wind", Text = "BOOST" },
	{ Id = "Descend", Action = "Descend", Icon = "Descend", Text = "DOWN" },
	{ Id = "Roar", Action = "Roar", Icon = "Roar", Text = "ROAR" },
	{ Id = "Dash", Action = "Dash", Icon = "Wind", Text = "DASH", Perk = "Dash" },
	{ Id = "Fire", Action = "Fire", Icon = "Flame", Text = "FIRE", Perk = "Fire" },
	{ Id = "Dance", Action = "Flourish", Icon = "Star", Text = "DANCE", Perk = "Flourish" },
	{ Id = "Dismount", Action = nil, Icon = "Dismount", Text = "LEAVE" },
}

local function roundButton(def, parent: Instance)
	local root = Create("TextButton", {
		Name = def.Id,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 1),
		Selectable = false,
		Parent = parent,
	})
	root:SetAttribute("QARegion", "Mobile" .. def.Id)
	Kit.corner(root, "pill")
	local stroke = Kit.stroke(root, def.Big and C.Accent or H.Stroke, Theme.Stroke.Bold, def.Big and 0.15 or 0.45)
	local scale = Create("UIScale", { Parent = root })
	-- fill (boost meter); clipped to the circle by a rounded holder
	local fillHolder = Create("Frame", {
		Name = "FillHolder",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		Visible = def.Id == "Boost" or def.Perk ~= nil,
		Parent = root,
	})
	Kit.corner(fillHolder, "pill")
	local fill = Create("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.BlueDeep,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Parent = fillHolder,
	})
	local iconHolder = Kit.frame({
		Name = "IconHolder",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromScale(0.46, 0.46),
		ZIndex = 2,
		Parent = root,
	})
	Kit.aspect(iconHolder, 1)
	local icon = Icons.make(def.Icon, { Color = H.Icon, Accent = def.Big and C.Accent or C.BlueDeep, Ink = H.Panel })
	icon.Parent = iconHolder
	local caption = Kit.text({
		Name = "Caption",
		Text = def.Text,
		Role = "Micro",
		Color = H.TextMuted,
		XAlign = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.68),
		Size = UDim2.fromScale(0.9, 0.2),
		Scaled = true,
		ZIndex = 2,
		Parent = root,
	})
	return { Instance = root, Stroke = stroke, Scale = scale, Fill = fill, Caption = caption, Def = def }
end

function MobileControls.new(parent: Instance, registry)
	local self = setmetatable({}, MobileControls)
	self.Registry = registry
	self.Visible = false
	self.Mode = "Ground"
	local root = Create("Frame", {
		Name = "MobileControls",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 5,
		Parent = parent,
	})
	self.Root = root
	self.Buttons = {}
	for _, def in BUTTONS do
		local b = roundButton(def, root)
		self.Buttons[def.Id] = b
		self:_wire(b)
		if def.Perk then
			b.Instance.Visible = false -- until the dragon's bond unlocks it (SetPerks)
			b.Fill.Size = UDim2.fromScale(1, 0)
			b.Fill.BackgroundColor3 = C.Disabled
		end
	end
	-- speed readout: big number with the unit underneath
	local speedBox = Kit.frame({ Name = "SpeedBox", AnchorPoint = Vector2.new(1, 1), Parent = root })
	speedBox:SetAttribute("QARegion", "MobileSpeed")
	self.SpeedBox = speedBox
	self.SpeedText = Kit.text({
		Name = "Speed",
		Text = "0",
		Role = "Title",
		Font = Theme.Fonts.Number,
		Color = H.Text,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 0.66),
		Scaled = true,
		MaxRole = "Title",
		Parent = speedBox,
	})
	Kit.text({
		Name = "Unit",
		Text = "KM/H",
		Role = "Micro",
		Color = H.TextMuted,
		XAlign = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.34),
		Scaled = true,
		Parent = speedBox,
	})
	self:Layout()
	return self
end

function MobileControls:_wire(b)
	local def = b.Def
	local input = self.Registry.InputController
	local active: InputObject? = nil
	local function release()
		if active then
			active = nil
			if def.Action and input then
				input.setVirtual(def.Action, false)
			end
			Kit.tween(b.Scale, 0.1, { Scale = 1 }, Enum.EasingStyle.Back)
			b.Stroke.Transparency = def.Big and 0.15 or 0.45
		end
	end
	b.Instance.InputBegan:Connect(function(io)
		if io.UserInputType ~= Enum.UserInputType.Touch and io.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if active then
			return
		end
		active = io
		Kit.tween(b.Scale, Theme.Motion.Press, { Scale = 0.9 })
		b.Stroke.Transparency = 0
		if def.Action and input then
			input.setVirtual(def.Action, true)
		elseif def.Id == "Dismount" then
			local dc = self.Registry.DragonController
			if dc then
				dc.toggleRide()
			end
		end
	end)
	b.Instance.InputEnded:Connect(function(io)
		if io == active then
			release()
		end
	end)
	UserInputService.TouchEnded:Connect(function(io)
		if io == active then
			release()
		end
	end)
	self.Buttons[def.Id].Release = release
end

-- Pure Scale layout: every size/offset is a fraction of the screen's short
-- side (SizeConstraint keeps buttons round), converted to per-axis scale.
--   landscape            portrait
--   [LEAVE]      [DOWN]          [LEAVE]
--   [ROAR][BOOST][ UP ]   [ROAR] [DOWN]
--                         [BOOST][ UP ]
function MobileControls:Layout()
	local R = Responsive
	local W, H = R.Width, R.Height
	local S = math.min(W, H)
	local phone = R.Device == "Phone"
	local big = phone and 0.25 or 0.15
	local small = phone and 0.165 or 0.1
	local gap = phone and 0.025 or 0.016
	local margin = phone and 0.045 or 0.03
	local bottom = margin + (R.Portrait and 0.05 or 0)
	local constraint = R.Portrait and Enum.SizeConstraint.RelativeXX or Enum.SizeConstraint.RelativeYY
	local function place(inst: GuiObject, w: number, h: number, right: number, up: number)
		inst.SizeConstraint = constraint
		inst.Size = UDim2.fromScale(w, h)
		inst.Position = UDim2.fromScale(1 - right * S / W, 1 - up * S / H)
	end
	local B = self.Buttons
	local centerUp = margin + (big - small) * 0.5 -- small button centered on UP's column
	local midRow = bottom + (big - small) * 0.5 -- small button centered on UP's row
	place(B.Jump.Instance, big, big, margin, bottom)
	-- Dragon Bond abilities: one more column to the left
	local perkRight = R.Portrait and (margin + big + small + gap * 2) or (margin + big + small * 2 + gap * 3)
	place(B.Dash.Instance, small, small, perkRight, midRow)
	place(B.Fire.Instance, small, small, perkRight, midRow + small + gap)
	place(B.Dance.Instance, small, small, perkRight, midRow + (small + gap) * 2)
	if R.Portrait then
		place(B.Boost.Instance, small, small, margin + big + gap, midRow)
		place(B.Descend.Instance, small, small, centerUp, bottom + big + gap)
		place(B.Roar.Instance, small, small, margin + big + gap, bottom + big + gap)
		place(B.Dismount.Instance, small, small, centerUp, bottom + big + small + gap * 2)
		place(self.SpeedBox, small, small * 0.62, margin + big + gap, bottom + big + small + gap * 2)
	else
		place(B.Boost.Instance, small, small, margin + big + gap, midRow)
		place(B.Roar.Instance, small, small, margin + big + small + gap * 2, midRow)
		place(B.Descend.Instance, small, small, centerUp, bottom + big + gap)
		place(B.Dismount.Instance, small, small, margin + big + small + gap * 2, midRow + small + gap)
		place(self.SpeedBox, small + gap, small * 0.62, margin + big + gap * 0.5, midRow + small + gap)
	end
end

function MobileControls:SetVisible(on: boolean)
	on = on and Responsive.isMobile()
	if self.Visible == on then
		return
	end
	self.Visible = on
	self.Root.Visible = on
	if not on then
		for _, b in self.Buttons do
			if b.Release then
				b.Release()
			end
		end
	end
	-- hide the default jump button while riding (ours replaces it)
	pcall(function()
		local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local touch = gui and gui:FindFirstChild("TouchGui")
		local frame = touch and touch:FindFirstChild("TouchControlFrame")
		local jump = frame and frame:FindFirstChild("JumpButton")
		if jump then
			jump.Visible = not on
		end
	end)
end

-- mode: Ground | Air | Takeoff | Fly | Landing
function MobileControls:SetMode(mode: string)
	if mode == self.Mode then
		return
	end
	self.Mode = mode
	local flying = mode == "Fly" or mode == "Takeoff" or mode == "Landing"
	local jump = self.Buttons.Jump
	if flying then
		jump.Caption.Text = "UP"
	elseif mode == "Air" then
		jump.Caption.Text = "FLY"
	else
		jump.Caption.Text = "JUMP"
	end
	self.Buttons.Descend.Instance.Visible = flying
	self.Buttons.Boost.Caption.Text = flying and "BOOST" or "SPRINT"
end

-- Dragon Bond: show the ability buttons the bond level has unlocked, with their cooldown.
-- info = BondController.info()
function MobileControls:SetPerks(info)
	for _, def in BUTTONS do
		if def.Perk then
			local b = self.Buttons[def.Id]
			local unlocked = info and info.Unlocked and info.Unlocked[def.Perk] == true
			b.Instance.Visible = unlocked
			if unlocked then
				b.Fill.Size = UDim2.fromScale(1, math.clamp((info.Cooldown and info.Cooldown[def.Perk]) or 0, 0, 1))
			end
		end
	end
end

function MobileControls:SetStats(speed: number, boost01: number, boosting: boolean)
	if not self.Visible then
		return
	end
	self.SpeedText.Text = tostring(Format.kmh(speed))
	local b = self.Buttons.Boost
	b.Fill.Size = UDim2.fromScale(1, math.clamp(boost01, 0, 1))
	b.Fill.BackgroundColor3 = boosting and C.Accent or C.BlueDeep
end

return MobileControls
