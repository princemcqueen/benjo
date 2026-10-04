--[[
	Tooltip
	Small hover label next to an anchor element (desktop only).
]]

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)

local C = Theme.Colors

local Tooltip = {}
Tooltip.__index = Tooltip

function Tooltip.new(layerRoot: Frame)
	local self = setmetatable({}, Tooltip)
	self.Root = layerRoot
	local frame = Create("Frame", {
		Name = "Tooltip",
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.04,
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.X,
		Visible = false,
		Parent = layerRoot,
	})
	Responsive.bind(frame, "Size", function(R)
		return UDim2.fromOffset(0, R.px(30))
	end)
	Kit.corner(frame, "Small")
	Kit.stroke(frame, C.Gold, Theme.Stroke.Hairline, 0.4)
	Kit.padding(frame, 0, 12, 0, 12)
	self.Label = Kit.text({
		Text = "",
		Role = "Label",
		Font = Theme.Fonts.Label,
		Size = UDim2.fromScale(0, 1),
		AutoSize = Enum.AutomaticSize.X,
		Parent = frame,
	})
	self.Frame = frame
	return self
end

function Tooltip:Show(text: string, anchor: GuiObject)
	if Responsive.isMobile() then
		return
	end
	self.Label.Text = text
	local rootPos = self.Root.AbsolutePosition
	local rootSize = self.Root.AbsoluteSize
	local p = anchor.AbsolutePosition - rootPos
	local s = anchor.AbsoluteSize
	local gap = Responsive.px(10)
	local centerX = p.X + s.X / 2
	local f = self.Frame
	if centerX < rootSize.X * 0.33 then
		f.AnchorPoint = Vector2.new(0, 0.5)
		f.Position = UDim2.fromOffset(p.X + s.X + gap, p.Y + s.Y / 2)
	elseif centerX > rootSize.X * 0.67 then
		f.AnchorPoint = Vector2.new(1, 0.5)
		f.Position = UDim2.fromOffset(p.X - gap, p.Y + s.Y / 2)
	else
		f.AnchorPoint = Vector2.new(0.5, 1)
		f.Position = UDim2.fromOffset(centerX, p.Y - gap)
	end
	-- UIScale on the root (virtual preview) scales offsets; compensate.
	local scale = self.Root:FindFirstChildOfClass("UIScale")
	if scale and scale.Scale ~= 1 then
		local k = 1 / scale.Scale
		f.Position = UDim2.fromOffset(f.Position.X.Offset * k, f.Position.Y.Offset * k)
	end
	f.Visible = true
end

function Tooltip:Hide()
	self.Frame.Visible = false
end

return Tooltip
