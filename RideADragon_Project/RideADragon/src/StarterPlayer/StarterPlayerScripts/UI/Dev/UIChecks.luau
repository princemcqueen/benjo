--[[
	UIChecks
	Automated layout QA used by the Dev UI Lab (and the offline test runner).
	Detects: clipped text, off-screen elements, overlapping HUD/QA regions,
	microscopic text, too-small touch targets, oversized/undersized windows.
	All measurements are converted to the (virtual) screen's pixel space.
]]

local UIChecks = {}

local function isVisible(g: GuiObject): boolean
	local node: Instance? = g
	while node do
		if node:IsA("GuiObject") and not (node :: GuiObject).Visible then
			return false
		end
		if node:IsA("LayerCollector") then
			return (node :: LayerCollector).Enabled
		end
		node = node.Parent
	end
	return false
end

local function rectOf(g: GuiObject, origin: Vector2, k: number)
	local p = (g.AbsolutePosition - origin) / k
	local s = g.AbsoluteSize / k
	return p.X, p.Y, s.X, s.Y
end

-- Visible window of `g`: the intersection of EVERY clipping ancestor (nested scroll frames
-- clip each other). nil when nothing clips it; width/height <= 0 when nothing is visible.
local function clipRect(g: GuiObject, origin: Vector2, k: number): (number?, number?, number?, number?)
	local x0, y0, x1, y1 = -math.huge, -math.huge, math.huge, math.huge
	local found = false
	local node = g.Parent
	while node and node:IsA("GuiObject") do
		if node:IsA("ScrollingFrame") or (node :: GuiObject).ClipsDescendants then
			local cx, cy, cw, ch = rectOf(node :: GuiObject, origin, k)
			x0, y0 = math.max(x0, cx), math.max(y0, cy)
			x1, y1 = math.min(x1, cx + cw), math.min(y1, cy + ch)
			found = true
		end
		node = node.Parent
	end
	if not found then
		return nil
	end
	return x0, y0, x1 - x0, y1 - y0
end

local function overlap(a, b): number
	local x0 = math.max(a[1], b[1])
	local y0 = math.max(a[2], b[2])
	local x1 = math.min(a[1] + a[3], b[1] + b[3])
	local y1 = math.min(a[2] + a[4], b[2] + b[4])
	if x1 <= x0 or y1 <= y0 then
		return 0
	end
	return (x1 - x0) * (y1 - y0)
end

-- roots: list of layer Root frames (all share the same screen rect)
-- opts: { Device = "Desktop"|"Tablet"|"Phone", Window = GuiObject? }
function UIChecks.run(roots: { Frame }, opts: { [string]: any })
	local issues = {}
	local function add(kind: string, msg: string)
		table.insert(issues, { Kind = kind, Message = msg })
	end
	local main = roots[1]
	local scale = main:FindFirstChildOfClass("UIScale")
	local k = scale and scale.Scale or 1
	local origin = main.AbsolutePosition
	local W, H = main.AbsoluteSize.X / k, main.AbsoluteSize.Y / k
	local regions = {}

	for _, root in roots do
		for _, d in root:GetDescendants() do
			if not d:IsA("GuiObject") or not isVisible(d) then
				continue
			end
			local x, y, w, h = rectOf(d, origin, k)
			local name = d:GetFullName()
			local cx, cy, cw, ch = clipRect(d, origin, k)
			local clipped = false
			local vx, vy, vw, vh = x, y, w, h
			if cx then
				if cw < 1 or ch < 1 or x + w < cx - 1 or y + h < cy - 1 or x > cx + cw + 1 or y > cy + ch + 1 then
					clipped = true -- intentionally scrolled/clipped out of view
				else
					-- only the part inside the clipping ancestors is visible
					local x0, y0 = math.max(x, cx), math.max(y, cy)
					local x1, y1 = math.min(x + w, cx + cw), math.min(y + h, cy + ch)
					vx, vy, vw, vh = x0, y0, x1 - x0, y1 - y0
				end
			end
			if not clipped and vw > 1 and vh > 1 then
				if vx < -2 or vy < -2 or vx + vw > W + 2 or vy + vh > H + 2 then
					if not d:GetAttribute("QAAllowOffscreen") then
						add("Offscreen", string.format("%s at (%d,%d %dx%d) leaves the %dx%d screen", name, vx, vy, vw, vh, W, H))
					end
				end
			end
			if (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) and not clipped then
				local text = d.Text
				if text ~= "" and w > 0 then
					if not d.TextFits and d.TextTruncate == Enum.TextTruncate.None and not d.TextScaled then
						add("ClippedText", string.format("%s text '%s' does not fit (%dx%d)", name, string.sub(text, 1, 24), w, h))
					end
					local size = d.TextScaled and d.TextBounds.Y or d.TextSize
					if size > 0 and size < 9 then
						add("TinyText", string.format("%s text size %d px", name, size))
					end
				end
			end
			if opts.Device ~= "Desktop" and d:IsA("GuiButton") and not clipped and d.Active then
				if (w < 36 or h < 30) and not d:GetAttribute("QASmallOk") then
					add("TouchTarget", string.format("%s is %dx%d (too small to tap)", name, w, h))
				end
			end
			local region = d:GetAttribute("QARegion")
			if region then
				table.insert(regions, { x, y, w, h, region })
			end
		end
	end
	for i = 1, #regions do
		for j = i + 1, #regions do
			local a, b = regions[i], regions[j]
			local area = overlap(a, b)
			if area > 4 then
				add("Overlap", string.format("%s overlaps %s (%d px^2)", a[5], b[5], area))
			end
		end
	end
	if opts.Window then
		local _, _, w, h = rectOf(opts.Window, origin, k)
		local fw, fh = w / W, h / H
		if opts.Device == "Desktop" then
			if fw > 0.8 or fh > 0.9 then
				add("WindowSize", string.format("window covers %.0f%% x %.0f%% of the screen (too large)", fw * 100, fh * 100))
			elseif fw < 0.25 and fh < 0.3 then
				add("WindowSize", string.format("window covers only %.0f%% x %.0f%% (too small)", fw * 100, fh * 100))
			end
		end
	end
	return issues
end

function UIChecks.format(issues): string
	if #issues == 0 then
		return "PASS"
	end
	local lines = {}
	for _, i in issues do
		table.insert(lines, "[" .. i.Kind .. "] " .. i.Message)
	end
	return table.concat(lines, "\n")
end

return UIChecks
