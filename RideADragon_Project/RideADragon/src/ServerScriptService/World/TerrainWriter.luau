--[[
	TerrainWriter
	Writes Roblox smooth terrain from compact generated map data
	(HavenTerrainData: 8-stud uint16 heightmap, material indices, RLE water
	levels, cave carve capsules).

	Column function (identical to toolchain/worldgen/terrain_data.py):
	  height   = bilinear(heightmap) + hash detail (+-0.6 studs)
	  material = one of the 4 surrounding map materials, chosen with
	             probability equal to its bilinear weight (dithered borders)
	  water    = bilinear water level where all 4 samples are wet, else max
	Each column is filled from just below its lowest neighbour (closes cliff
	faces) up to its surface; deeper only where caves are carved.

	Uses WriteVoxelChannels (solid + liquid in one voxel = clean shorelines)
	when available, otherwise WriteVoxels.
]]

local TerrainWriter = {}

local M32 = 4294967296
local bxor, rshift, band, lshift, bor = bit32.bxor, bit32.rshift, bit32.band, bit32.lshift, bit32.bor
local floor, ceil, min, max, clamp, sqrt = math.floor, math.ceil, math.min, math.max, math.clamp, math.sqrt

-- ============================================================== decoding
local B64 = {}
do
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do
		B64[string.byte(alphabet, i)] = i - 1
	end
end

local function decode(chunks: { string }): buffer
	local s = table.concat(chunks)
	local n = #s
	local pad = 0
	if string.sub(s, -1) == "=" then
		pad += 1
	end
	if string.sub(s, -2, -2) == "=" then
		pad += 1
	end
	local outLen = (n // 4) * 3 - pad
	local out = buffer.create(outLen)
	local o = 0
	for i = 1, n, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local v = bor(lshift(B64[a] or 0, 18), lshift(B64[b] or 0, 12), lshift(B64[c] or 0, 6), B64[d] or 0)
		if o < outLen then
			buffer.writeu8(out, o, rshift(v, 16))
		end
		if o + 1 < outLen then
			buffer.writeu8(out, o + 1, band(rshift(v, 8), 255))
		end
		if o + 2 < outLen then
			buffer.writeu8(out, o + 2, band(v, 255))
		end
		o += 3
	end
	return out
end
TerrainWriter.decode = decode

local function hash01(ix: number, iy: number, seed: number): number
	local h = (ix * 73856093) % M32
	h = bxor(h, (iy * 19349663) % M32)
	h = bxor(h, seed % M32)
	h = (h * 69069 + 1013904223) % M32
	h = bxor(h, rshift(h, 15))
	h = (h * 40503 + 12345) % M32
	h = bxor(h, rshift(h, 13))
	return (h % 16777216) / 16777216
end
TerrainWriter.hash01 = hash01

-- ============================================================== map
export type Map = {
	N: number,
	Grid: number,
	Extent: number,
	H: buffer,
	M: buffer,
	W: buffer,
	Materials: { Enum.Material },
	Sub: { Enum.Material },
	Carves: { { number } },
}

function TerrainWriter.load(data): Map
	local N = data.N
	local H = decode(data.Heights)
	local M = decode(data.Mats)
	-- water: RLE (count, value) uint16 pairs -> full uint16 grid
	local rle = decode(data.Water)
	local W = buffer.create(N * N * 2)
	local o = 0
	for i = 0, buffer.len(rle) - 4, 4 do
		local count = buffer.readu16(rle, i)
		local value = buffer.readu16(rle, i + 2)
		if value ~= 0 then
			for k = o, o + count - 1 do
				buffer.writeu16(W, k * 2, value)
			end
		end
		o += count
	end
	local mats, subs = {}, {}
	for i, name in data.Materials do
		mats[i] = (Enum.Material :: any)[name]
	end
	for i, name in data.SubMaterials do
		subs[i] = (Enum.Material :: any)[name]
	end
	return {
		N = N,
		Grid = data.Grid,
		Extent = data.Extent,
		H = H,
		M = M,
		W = W,
		Materials = mats,
		Sub = subs,
		Carves = data.Carves or {},
	}
end

-- Column sample at world (x, z): height, material index (1-based), water level (0 = dry).
function TerrainWriter.sample(map: Map, x: number, z: number): (number, number, number)
	local N, G, E = map.N, map.Grid, map.Extent
	local fx = clamp((x + E) / G, 0, N - 1.000001)
	local fz = clamp((z + E) / G, 0, N - 1.000001)
	local ix, iz = floor(fx), floor(fz)
	local tx, tz = fx - ix, fz - iz
	local H, M, W = map.H, map.M, map.W
	local i00 = iz * N + ix
	local i10 = i00 + 1
	local i01 = i00 + N
	local i11 = i01 + 1
	local h00, h10 = buffer.readu16(H, i00 * 2) / 64, buffer.readu16(H, i10 * 2) / 64
	local h01, h11 = buffer.readu16(H, i01 * 2) / 64, buffer.readu16(H, i11 * 2) / 64
	local h = (h00 * (1 - tx) + h10 * tx) * (1 - tz) + (h01 * (1 - tx) + h11 * tx) * tz
	local cx, cz = floor(x / 4), floor(z / 4)
	h += (hash01(cx, cz, 977) - 0.5) * 1.2
	local rnd = hash01(cx, cz, 433)
	local w00 = (1 - tx) * (1 - tz)
	local w10 = tx * (1 - tz)
	local w01 = (1 - tx) * tz
	local mi
	if rnd < w00 then
		mi = buffer.readu8(M, i00)
	elseif rnd < w00 + w10 then
		mi = buffer.readu8(M, i10)
	elseif rnd < w00 + w10 + w01 then
		mi = buffer.readu8(M, i01)
	else
		mi = buffer.readu8(M, i11)
	end
	local a, b = buffer.readu16(W, i00 * 2) / 64, buffer.readu16(W, i10 * 2) / 64
	local c, d = buffer.readu16(W, i01 * 2) / 64, buffer.readu16(W, i11 * 2) / 64
	local water = 0
	if a > 0 and b > 0 and c > 0 and d > 0 then
		water = (a * (1 - tx) + b * tx) * (1 - tz) + (c * (1 - tx) + d * tx) * tz
	else
		water = max(a, b, c, d)
	end
	return h, mi + 1, water
end

function TerrainWriter.heightAt(map: Map, x: number, z: number): number
	local h = TerrainWriter.sample(map, x, z)
	return h
end

-- ============================================================== caves
local function segDist(px, py, pz, c): (number, number)
	local ax, ay, az, bx, by, bz, r0, r1 = c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local l2 = dx * dx + dy * dy + dz * dz
	local t = l2 > 1e-9 and clamp(((px - ax) * dx + (py - ay) * dy + (pz - az) * dz) / l2, 0, 1) or 0
	local qx, qy, qz = ax + dx * t - px, ay + dy * t - py, az + dz * t - pz
	return sqrt(qx * qx + qy * qy + qz * qz), r0 + (r1 - r0) * t
end

-- horizontal distance from (px, pz) to a carve segment and its radius there
local function segDist2D(px, pz, c): (number, number)
	local ax, az, bx, bz, r0, r1 = c[1], c[3], c[4], c[6], c[7], c[8]
	local dx, dz = bx - ax, bz - az
	local l2 = dx * dx + dz * dz
	local t = l2 > 1e-9 and clamp(((px - ax) * dx + (pz - az) * dz) / l2, 0, 1) or 0
	local qx, qz = ax + dx * t - px, az + dz * t - pz
	return sqrt(qx * qx + qz * qz), r0 + (r1 - r0) * t
end

local function carvesNear(map: Map, x0: number, z0: number, x1: number, z1: number)
	local out = {}
	for _, c in map.Carves do
		local r = max(c[7], c[8]) + 12
		local cx0, cx1 = min(c[1], c[4]) - r, max(c[1], c[4]) + r
		local cz0, cz1 = min(c[3], c[6]) - r, max(c[3], c[6]) + r
		if cx1 >= x0 and cx0 <= x1 and cz1 >= z0 and cz0 <= z1 then
			table.insert(out, c)
		end
	end
	return out
end

-- ============================================================== writing
local AIR = Enum.Material.Air
local WATER = Enum.Material.Water

-- Builds voxel arrays for one chunk (CHUNK x CHUNK studs at x0, z0).
local function buildChunk(map: Map, x0: number, z0: number, size: number)
	local n = size // 4
	-- column samples incl. a 1-column border for neighbour minima
	local hs, ms, ws = {}, {}, {}
	for i = 0, n + 1 do
		local hrow, mrow, wrow = {}, {}, {}
		for k = 0, n + 1 do
			local x = x0 + (i - 0.5) * 4
			local z = z0 + (k - 0.5) * 4
			local h, mi, w = TerrainWriter.sample(map, x, z)
			hrow[k] = h
			mrow[k] = mi
			wrow[k] = w
		end
		hs[i], ms[i], ws[i] = hrow, mrow, wrow
	end
	local carves = carvesNear(map, x0, z0, x0 + size, z0 + size)
	local bottoms = {}
	local yLo, yHi = math.huge, -math.huge
	for i = 1, n do
		local brow = {}
		for k = 1, n do
			local h = hs[i][k]
			local lo = min(h, hs[i - 1][k], hs[i + 1][k], hs[i][k - 1], hs[i][k + 1]) - 8
			if #carves > 0 then
				local x = x0 + (i - 0.5) * 4
				local z = z0 + (k - 0.5) * 4
				for _, c in carves do
					-- columns over a tunnel stay solid down below its floor
					local d, r = segDist2D(x, z, c)
					if d < r + 12 then
						lo = min(lo, min(c[2], c[5]) - r - 10)
					end
				end
			end
			brow[k] = lo
			yLo = min(yLo, lo)
			yHi = max(yHi, h + 4, ws[i][k] + 4)
		end
		bottoms[i] = brow
	end
	yLo = floor(yLo / 4) * 4
	yHi = ceil(yHi / 4) * 4
	local ny = (yHi - yLo) // 4
	local mats = table.create(n)
	local occ = table.create(n)
	local liq = table.create(n)
	local hasLiquid = false
	for i = 1, n do
		local mi_, oi, li = table.create(ny), table.create(ny), table.create(ny)
		for j = 1, ny do
			mi_[j] = table.create(n, AIR)
			oi[j] = table.create(n, 0)
			li[j] = table.create(n, 0)
		end
		for k = 1, n do
			local h = hs[i][k]
			local w = ws[i][k]
			local idx = ms[i][k]
			local surf = map.Materials[idx] or Enum.Material.Grass
			local sub = map.Sub[idx] or Enum.Material.Rock
			local bottom = bottoms[i][k]
			local x = x0 + (i - 0.5) * 4
			local z = z0 + (k - 0.5) * 4
			for j = 1, ny do
				local y0 = yLo + (j - 1) * 4
				local y1 = y0 + 4
				if y1 > bottom then
					local o = clamp((h - y0) / 4, 0, 1)
					if o > 0 then
						mi_[j][k] = (h - y1 < 5) and surf or sub
						oi[j][k] = o
					end
					if w > 0 and w > y0 and o < 1 then
						local lo = clamp((w - y0) / 4, 0, 1)
						li[j][k] = lo
						hasLiquid = true
					end
				end
				if #carves > 0 and oi[j][k] > 0 then
					local yc = y0 + 2
					for _, c in carves do
						local d, r = segDist(x, yc, z, c)
						if d < r + 4 then
							local keep = clamp((d - r) / 4 + 0.5, 0, 1)
							if keep < oi[j][k] then
								oi[j][k] = keep
								if keep <= 0 then
									mi_[j][k] = AIR
								else
									mi_[j][k] = Enum.Material.Rock
								end
							end
						end
					end
				end
			end
		end
		mats[i], occ[i], liq[i] = mi_, oi, li
	end
	return Region3.new(Vector3.new(x0, yLo, z0), Vector3.new(x0 + size, yHi, z0 + size)), mats, occ, liq, hasLiquid
end
TerrainWriter.buildChunk = buildChunk

local channelsSupported: boolean? = nil

local function writeChunk(terrain: Terrain, region: Region3, mats, occ, liq, hasLiquid: boolean)
	if channelsSupported ~= false then
		local ok = pcall(function()
			(terrain :: any):WriteVoxelChannels(region, 4, {
				SolidMaterial = mats,
				SolidOccupancy = occ,
				LiquidOccupancy = liq,
			})
		end)
		if ok then
			channelsSupported = true
			return
		end
		channelsSupported = false
	end
	-- fallback: one material per voxel; liquid wins over air and partial solids
	if hasLiquid then
		for i, plane in mats do
			for j, row in plane do
				local orow, lrow = occ[i][j], liq[i][j]
				for k = 1, #row do
					local l = lrow[k]
					if l > 0 and orow[k] < 0.5 then
						row[k] = WATER
						orow[k] = l
					end
				end
			end
		end
	end
	terrain:WriteVoxels(region, 4, mats, occ)
end

-- Writes the whole map (yields between chunks). progress(fraction) optional.
function TerrainWriter.write(terrain: Terrain, map: Map, opts: { [string]: any }?)
	local o = opts or {}
	local size = o.ChunkSize or 128
	local E = map.Extent
	local lo = -E
	local hi = E
	local x0s = {}
	local x = lo
	while x < hi do
		table.insert(x0s, x)
		x += size
	end
	local total = #x0s * #x0s
	local done = 0
	local budget = o.FrameBudget or 0.012
	local t0 = os.clock()
	for _, cx in x0s do
		for _, cz in x0s do
			local region, mats, occ, liq, hasLiquid = buildChunk(map, cx, cz, size)
			writeChunk(terrain, region, mats, occ, liq, hasLiquid)
			done += 1
			if o.Progress then
				o.Progress(done / total)
			end
			if os.clock() - t0 > budget then
				task.wait()
				t0 = os.clock()
			end
		end
	end
	return done
end

function TerrainWriter.applyLook(terrain: Terrain, data)
	for name, rgb in data.Colors or {} do
		local mat = (Enum.Material :: any)[name]
		if mat and name ~= "Water" then
			pcall(function()
				terrain:SetMaterialColor(mat, Color3.fromRGB(rgb[1], rgb[2], rgb[3]))
			end)
		end
	end
	local w = data.Colors and data.Colors.Water
	if w then
		terrain.WaterColor = Color3.fromRGB(w[1], w[2], w[3])
	end
	terrain.WaterReflectance = 0.6
	terrain.WaterTransparency = 0.72
	terrain.WaterWaveSize = 0.12
	terrain.WaterWaveSpeed = 9
	pcall(function()
		(terrain :: any).Decoration = true
	end)
end

return TerrainWriter
