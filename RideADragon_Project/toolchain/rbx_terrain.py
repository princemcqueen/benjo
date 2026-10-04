"""Terrain simulation: records fill operations and voxel writes; supports
point queries, raycasts and surface sampling (for previews)."""
import math

import numpy as np

from luau_interp import LuaError, LuaTable
from rbx_types import Vector3, CFrame, Color3, EnumItem, ENUM, E

CELL = 64.0
MAT_NAMES = list(ENUM.types["Material"].items.keys())
MAT_INDEX = {n: i for i, n in enumerate(MAT_NAMES)}
AIR = MAT_INDEX["Air"]
WATER = MAT_INDEX["Water"]

DEFAULT_COLORS = {
    "Grass": (106, 127, 63), "LeafyGrass": (115, 132, 74), "Sand": (143, 126, 95), "Rock": (102, 108, 111),
    "Slate": (63, 127, 107), "Ground": (102, 92, 59), "Mud": (58, 46, 36), "Snow": (195, 199, 218),
    "Glacier": (101, 176, 234), "Ice": (129, 194, 224), "Basalt": (30, 30, 37), "CrackedLava": (232, 156, 74),
    "Limestone": (206, 173, 148), "Sandstone": (137, 90, 71), "Salt": (198, 189, 181), "Asphalt": (115, 123, 107),
    "Pavement": (148, 148, 140), "Concrete": (127, 102, 63), "Brick": (138, 86, 62), "Cobblestone": (132, 123, 90),
    "WoodPlanks": (139, 109, 79), "Water": (12, 84, 92),
}


class TerrainStore:
    def __init__(self):
        self.ops = []
        self.index = {}
        self.colors = {k: v for k, v in DEFAULT_COLORS.items()}

    def _add(self, op, aabb):
        idx = len(self.ops)
        self.ops.append(op)
        x0, y0, z0, x1, y1, z1 = aabb
        for x in range(int(math.floor(x0 / CELL)), int(math.floor(x1 / CELL)) + 1):
            for y in range(int(math.floor(y0 / CELL)), int(math.floor(y1 / CELL)) + 1):
                for z in range(int(math.floor(z0 / CELL)), int(math.floor(z1 / CELL)) + 1):
                    self.index.setdefault((x, y, z), []).append(idx)

    def clear(self):
        self.ops = []
        self.index = {}

    # ---------------------------------------------------------- ops
    def fill_block(self, cf, size, mat):
        inv = cf.inverse()
        hx, hy, hz = size.x / 2, size.y / 2, size.z / 2
        r = cf.r
        ex = abs(r[0]) * hx + abs(r[1]) * hy + abs(r[2]) * hz
        ey = abs(r[3]) * hx + abs(r[4]) * hy + abs(r[5]) * hz
        ez = abs(r[6]) * hx + abs(r[7]) * hy + abs(r[8]) * hz
        c = cf.p
        self._add(("block", inv, (hx, hy, hz), mat), (c[0] - ex, c[1] - ey, c[2] - ez, c[0] + ex, c[1] + ey, c[2] + ez))

    def fill_ball(self, center, radius, mat):
        self._add(("ball", center, radius, mat), (center.x - radius, center.y - radius, center.z - radius,
                                                   center.x + radius, center.y + radius, center.z + radius))

    def fill_cylinder(self, cf, height, radius, mat):
        inv = cf.inverse()
        e = max(height / 2, radius)
        c = cf.p
        self._add(("cyl", inv, (height / 2, radius), mat), (c[0] - e, c[1] - e, c[2] - e, c[0] + e, c[1] + e, c[2] + e))

    def fill_wedge(self, cf, size, mat):
        inv = cf.inverse()
        hx, hy, hz = size.x / 2, size.y / 2, size.z / 2
        e = math.sqrt(hx * hx + hy * hy + hz * hz)
        c = cf.p
        self._add(("wedge", inv, (hx, hy, hz), mat), (c[0] - e, c[1] - e, c[2] - e, c[0] + e, c[1] + e, c[2] + e))

    def add_heightfield(self, fn, x0, z0, x1, z1, ymin, ymax):
        """Analytic heightfield op: fn(x, z) -> (height, material name, water level)."""
        self._add(("hf", fn), (x0, ymin, z0, x1, ymax, z1))

    def write_voxels(self, mn, res, mats, occs):
        sx, sy, sz = mats.shape
        self._add(("vox", (mn.x, mn.y, mn.z), res, mats, occs),
                  (mn.x, mn.y, mn.z, mn.x + sx * res, mn.y + sy * res, mn.z + sz * res))

    # ---------------------------------------------------------- queries
    def material_at(self, x, y, z):
        lst = self.index.get((int(math.floor(x / CELL)), int(math.floor(y / CELL)), int(math.floor(z / CELL))))
        if not lst:
            return None
        for idx in reversed(lst):
            op = self.ops[idx]
            k = op[0]
            if k == "block":
                inv, (hx, hy, hz), mat = op[1], op[2], op[3]
                l = inv.point_to_world(Vector3(x, y, z))
                if abs(l.x) <= hx and abs(l.y) <= hy and abs(l.z) <= hz:
                    return mat
            elif k == "ball":
                c, r, mat = op[1], op[2], op[3]
                if (x - c.x) ** 2 + (y - c.y) ** 2 + (z - c.z) ** 2 <= r * r:
                    return mat
            elif k == "cyl":
                inv, (hh, r), mat = op[1], op[2], op[3]
                l = inv.point_to_world(Vector3(x, y, z))
                if abs(l.y) <= hh and l.x * l.x + l.z * l.z <= r * r:
                    return mat
            elif k == "wedge":
                inv, (hx, hy, hz), mat = op[1], op[2], op[3]
                l = inv.point_to_world(Vector3(x, y, z))
                if abs(l.x) <= hx and abs(l.y) <= hy and abs(l.z) <= hz:
                    # wedge: slope rising from front(-z) bottom to back(+z) top
                    if (l.y + hy) / (2 * hy) <= (l.z + hz) / (2 * hz) + 1e-9:
                        return mat
            elif k == "hf":
                h, mat, w = op[1](x, z)
                if y <= h:
                    return mat
                if w > 0 and y <= w:
                    return "Water"
                continue
            elif k == "vox":
                (ox, oy, oz), res, mats, occs = op[1], op[2], op[3], op[4]
                i = int((x - ox) // res)
                j = int((y - oy) // res)
                kk = int((z - oz) // res)
                if 0 <= i < mats.shape[0] and 0 <= j < mats.shape[1] and 0 <= kk < mats.shape[2]:
                    m = int(mats[i, j, kk])
                    o = float(occs[i, j, kk])
                    if m == AIR or o <= 0:
                        # an explicit air voxel overrides earlier ops only if fully written
                        return "Air"
                    # occupancy: solid only in lower part of voxel scaled by occ (approx)
                    fy = (y - oy) / res - j
                    if fy <= o + 1e-9 or o >= 0.999:
                        return MAT_NAMES[m]
                    return "Air"
        return None

    def solid(self, x, y, z, ignore_water):
        m = self.material_at(x, y, z)
        if m is None or m == "Air":
            return None
        if ignore_water and m == "Water":
            return None
        return m


def get_store(sim):
    st = getattr(sim, "terrain_store", None)
    if st is None:
        st = TerrainStore()
        sim.terrain_store = st
    return st


def raycast(sim, origin, d, maxlen, params, radius):
    st = getattr(sim, "terrain_store", None)
    if st is None or not st.ops:
        return None
    ignore_water = bool(params.IgnoreWater) if params is not None else False
    if params is not None:
        lst = params.FilterDescendantsInstances.arr
        terr = sim.terrain
        is_in = any(f is terr for f in lst)
        if params.FilterType.name in ("Exclude", "Blacklist") and is_in:
            return None
        if params.FilterType.name in ("Include", "Whitelist") and not is_in:
            return None
    step = 1.0
    t = 0.0
    prev = 0.0
    hitm = None
    while t <= maxlen + 1e-6:
        p = (origin.x + d.x * t, origin.y + d.y * t - radius, origin.z + d.z * t)
        m = st.solid(p[0], p[1], p[2], ignore_water)
        if m is not None:
            hitm = m
            break
        prev = t
        t += step
    if hitm is None:
        return None
    lo, hi = prev, t
    for _ in range(12):
        mid = (lo + hi) / 2
        p = (origin.x + d.x * mid, origin.y + d.y * mid - radius, origin.z + d.z * mid)
        if st.solid(p[0], p[1], p[2], ignore_water) is not None:
            hi = mid
        else:
            lo = mid
    t = hi
    hp = Vector3(origin.x + d.x * t, origin.y + d.y * t - radius, origin.z + d.z * t)
    e = 1.0
    gx = (1 if st.solid(hp.x - e, hp.y, hp.z, ignore_water) else 0) - (1 if st.solid(hp.x + e, hp.y, hp.z, ignore_water) else 0)
    gy = (1 if st.solid(hp.x, hp.y - e, hp.z, ignore_water) else 0) - (1 if st.solid(hp.x, hp.y + e, hp.z, ignore_water) else 0)
    gz = (1 if st.solid(hp.x, hp.y, hp.z - e, ignore_water) else 0) - (1 if st.solid(hp.x, hp.y, hp.z + e, ignore_water) else 0)
    n = Vector3(gx, gy, gz)
    n = n.unit() if n.mag() > 0 else Vector3(0, 1, 0)
    return (t, n, E("Material", hitm))


def _mat_name(m):
    if isinstance(m, EnumItem):
        if m.enum_name != "Material":
            raise LuaError("Material expected")
        return m.name
    return ENUM.types["Material"].coerce(m).name


def install(sim, M, G, S):
    @M("Terrain", "FillBlock")
    def fill_block(self, cf, size, mat):
        get_store(sim).fill_block(cf, size, _mat_name(mat))

    @M("Terrain", "FillBall")
    def fill_ball(self, center, radius, mat):
        get_store(sim).fill_ball(center, float(radius), _mat_name(mat))

    @M("Terrain", "FillCylinder")
    def fill_cylinder(self, cf, height, radius, mat):
        get_store(sim).fill_cylinder(cf, float(height), float(radius), _mat_name(mat))

    @M("Terrain", "FillWedge")
    def fill_wedge(self, cf, size, mat):
        get_store(sim).fill_wedge(cf, size, _mat_name(mat))

    @M("Terrain", "FillRegion")
    def fill_region(self, region, res, mat):
        c = (region.min + region.max).scale(0.5)
        get_store(sim).fill_block(CFrame(c.tup()), region.max - region.min, _mat_name(mat))

    @M("Terrain", "WriteVoxels")
    def write_voxels(self, region, res, mats, occs):
        res = float(res)
        if res != 4 and not getattr(sim, "allow_coarse_terrain", False):
            raise LuaError("WriteVoxels: resolution must be 4")
        size = region.max - region.min
        nx, ny, nz = int(round(size.x / res)), int(round(size.y / res)), int(round(size.z / res))
        ma = np.zeros((nx, ny, nz), dtype=np.int16)
        oa = np.zeros((nx, ny, nz), dtype=np.float32)
        if type(mats) is not LuaTable or len(mats.arr) != nx:
            raise LuaError(f"WriteVoxels: materials array size mismatch (expected {nx} in X)")
        for i in range(nx):
            mx = mats.arr[i]
            ox = occs.arr[i]
            if type(mx) is not LuaTable or len(mx.arr) != ny:
                raise LuaError("WriteVoxels: materials array size mismatch in Y")
            for j in range(ny):
                my = mx.arr[j]
                oy = ox.arr[j]
                if len(my.arr) != nz:
                    raise LuaError("WriteVoxels: materials array size mismatch in Z")
                for k in range(nz):
                    m = my.arr[k]
                    ma[i, j, k] = MAT_INDEX[m.name] if isinstance(m, EnumItem) else AIR
                    oa[i, j, k] = float(oy.arr[k])
        get_store(sim).write_voxels(region.min, res, ma, oa)

    @M("Terrain", "ReadVoxels")
    def read_voxels(self, region, res):
        res = float(res)
        size = region.max - region.min
        nx, ny, nz = int(round(size.x / res)), int(round(size.y / res)), int(round(size.z / res))
        st = get_store(sim)
        mats = LuaTable()
        occs = LuaTable()
        for i in range(nx):
            mx, ox = LuaTable(), LuaTable()
            for j in range(ny):
                my, oy = LuaTable(), LuaTable()
                for k in range(nz):
                    x = region.min.x + (i + 0.5) * res
                    y = region.min.y + (j + 0.5) * res
                    z = region.min.z + (k + 0.5) * res
                    m = st.material_at(x, y, z) or "Air"
                    my.arr.append(E("Material", m))
                    oy.arr.append(0.0 if m == "Air" else 1.0)
                mx.arr.append(my)
                ox.arr.append(oy)
            mats.arr.append(mx)
            occs.arr.append(ox)
        size_t = LuaTable()
        return (mats, occs)

    @M("Terrain", "Clear")
    def clear(self):
        get_store(sim).clear()

    @M("Terrain", "SetMaterialColor")
    def set_mat_color(self, mat, color):
        get_store(sim).colors[_mat_name(mat)] = color.rgb255()

    @M("Terrain", "GetMaterialColor")
    def get_mat_color(self, mat):
        c = get_store(sim).colors.get(_mat_name(mat), (128, 128, 128))
        return Color3(c[0] / 255, c[1] / 255, c[2] / 255)

    @M("Terrain", "ReplaceMaterial")
    def replace_mat(self, region, res, src, dst):
        pass

    @M("Terrain", "CellCenterToWorld")
    def cc2w(self, x, y, z):
        return Vector3(float(x) * 4 + 2, float(y) * 4 + 2, float(z) * 4 + 2)

    @M("Terrain", "WorldToCell")
    def w2c(self, v):
        return Vector3(math.floor(v.x / 4), math.floor(v.y / 4), math.floor(v.z / 4))
