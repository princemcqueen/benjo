--[[
	Modal
	Reusable confirmation dialog on the highest interactive layer.
	Modal:Confirm({ Title, Body, ConfirmText, CancelText, Danger }) -> boolean
	(yields until the player answers; Esc / B / clicking outside = cancel)
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local Fade = require(UI.Fade)

local C = Theme.Colors

local Modal = {}
Modal.__index = Modal

function Modal.new(layerRoot: Frame)
	local self = setmetatable({}, Modal)
	self.Root = layerRoot
	self.Open = false
	self._resolve = nil

	local dim = Create("TextButton", {
		Name = "Dim",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = layerRoot,
	})
	self.Dim = dim
	dim.Activated:Connect(function()
		self:_answer(false)
	end)

	local win = Kit.window({ Name = "ConfirmDialog", Parent = dim })
	self.Window = win
	local body = win.Body
	Kit.padding(body, 26, 30, 24, 30)

	self.IconBg = Create("Frame", {
		Name = "IconBg",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0.2, 0.2),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundColor3 = C.Danger,
		BorderSizePixel = 0,
		Parent = body,
	})
	Kit.corner(self.IconBg, "pill")
	local iconBox = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.56, 0.56), Parent = self.IconBg })
	self.Icon = Icons.make("Warning", { Color = C.Text, Ink = C.Danger })
	self.Icon.Parent = iconBox

	self.Title = Kit.text({
		Name = "Title",
		Text = "",
		Role = "Title",
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0, 0.25),
		Size = UDim2.fromScale(1, 0.18),
		Scaled = true,
		MaxRole = "Title",
		Parent = body,
	})
	self.Body = Kit.text({
		Name = "Message",
		Text = "",
		Role = "Body",
		Color = C.TextMuted,
		XAlign = Enum.TextXAlignment.Center,
		YAlign = Enum.TextYAlignment.Top,
		Wrapped = true,
		Position = UDim2.fromScale(0, 0.45),
		Size = UDim2.fromScale(1, 0.24),
		Parent = body,
	})
	local row = Kit.frame({ Name = "Buttons", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0.22), Parent = body })
	self.Cancel = Kit.button({ Name = "Cancel", Text = "CANCEL", Style = "Secondary", Size = UDim2.fromScale(0.48, 1), Parent = row })
	self.ConfirmButton = Kit.button({ Name = "Confirm", Text = "CONFIRM", Style = "Danger", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(0.48, 1), Parent = row })
	self.Cancel.Activated:Connect(function()
		self:_answer(false)
	end)
	self.ConfirmButton.Activated:Connect(function()
		self:_answer(true)
	end)

	-- block clicks on the panel from reaching the dim button
	Create("TextButton", {
		Name = "Blocker",
		AutoButtonColor = false,
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 0,
		Parent = body,
	})

	self.Scale = Create("UIScale", { Parent = win.Root })
	self:Layout()
	Responsive.Changed:Connect(function()
		self:Layout()
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if not self.Open then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			self:_answer(false)
		elseif not processed and (input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.ButtonA) then
			self:_answer(true)
		end
	end)
	return self
end

function Modal:Layout()
	local R = Responsive
	local root = self.Window.Root
	local ar = root:FindFirstChildOfClass("UIAspectRatioConstraint") or Create("UIAspectRatioConstraint", { Parent = root })
	if R.Device == "Phone" then
		root.Size = UDim2.fromScale(R.Portrait and 0.9 or 0.56, R.Portrait and 0.4 or 0.74)
		ar.AspectRatio = 1.7
	else
		root.Size = UDim2.fromScale(0.34, 0.36)
		ar.AspectRatio = 1.75
	end
end

function Modal:_answer(value: boolean)
	if not self.Open then
		return
	end
	self.Open = false
	local resolve = self._resolve
	self._resolve = nil
	local state = Fade.capture(self.Dim)
	local start = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local a = math.clamp((os.clock() - start) / Theme.Motion.Close, 0, 1)
		Fade.apply(state, 1 - a)
		self.Scale.Scale = 1 - 0.04 * a
		if a >= 1 then
			conn:Disconnect()
			self.Dim.Visible = false
			Fade.restore(state)
		end
	end)
	if resolve then
		resolve(value)
	end
end

function Modal:Confirm(opts: { [string]: any }): boolean
	if self.Open then
		self:_answer(false)
	end
	local danger = opts.Danger ~= false
	self.Title.Text = string.upper(opts.Title or "ARE YOU SURE?")
	self.Body.Text = opts.Body or ""
	self.ConfirmButton:SetText(string.upper(opts.ConfirmText or "CONFIRM"))
	self.ConfirmButton:SetStyle(danger and "Danger" or "Primary")
	self.Cancel:SetText(string.upper(opts.CancelText or "CANCEL"))
	self.IconBg.BackgroundColor3 = danger and C.Danger or C.Accent
	Icons.recolor(self.Icon, danger and C.Accent or C.Danger, danger and C.Danger or C.Accent)
	self.Open = true
	self.Dim.Visible = true
	local state = Fade.capture(self.Dim)
	Fade.apply(state, 0)
	self.Scale.Scale = Theme.Motion.StartScale
	local start = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local a = math.clamp((os.clock() - start) / Theme.Motion.Open, 0, 1)
		local e = 1 - (1 - a) ^ 4
		Fade.apply(state, e)
		self.Scale.Scale = Theme.Motion.StartScale + (1 - Theme.Motion.StartScale) * e
		if a >= 1 then
			conn:Disconnect()
		end
	end)
	local thread = coroutine.running()
	local answered = false
	self._resolve = function(v)
		if answered then
			return
		end
		answered = true
		task.spawn(thread, v)
	end
	return coroutine.yield()
end

function Modal:IsOpen(): boolean
	return self.Open
end

return Modal
