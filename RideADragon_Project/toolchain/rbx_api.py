"""Roblox API implementations for the simulator."""
import heapq
import json
import math
import uuid

import luau_interp as LI
from luau_interp import (LuaError, LuaTable, LuaFunction, BuiltinFunction, LuaThread, tostring, lua_typeof,
                         call, truthy, STATE, thread_yield, fmt_number)
from rbx_types import (Vector3, Vector2, CFrame, Color3, UDim, UDim2, Rect, NumberRange, NumberSequence,
                       ColorSequence, TweenInfo, Font, EnumItem, ENUM, E, RaycastParams, OverlapParams,
                       RaycastResult, BrickColor, _fn, ease, IDENT, _matmul, _quat_from_mat, _mat_from_quat,
                       _slerp)
from rbx_classes import CLASSES
from rbx_sim import Instance, Signal, Context, Device, NOTSET, SimFatal

import luau_interp


def T(*items):
    t = LuaTable()
    for v in items:
        t.arr.append(v)
    return t


def D(d):
    t = LuaTable()
    for k, v in d.items():
        t.set(k, v)
    return t


def _str(v, what="string"):
    if type(v) is str:
        return v
    if type(v) in (float, int):
        return fmt_number(v)
    raise LuaError(f"{what} expected, got {lua_typeof(v)}")


# =============================================================================== globals

def install_globals(sim, G, ctx):
    G.set("game", sim.game)
    G.set("Game", sim.game)
    G.set("workspace", sim.services["Workspace"])
    G.set("Workspace", sim.services["Workspace"])

    def inst_new(class_name, parent=None):
        cn = _str(class_name)
        ci = CLASSES.get(cn)
        if ci is None or not ci.creatable:
            raise LuaError(f"Unable to create an Instance of type \"{cn}\"")
        inst = Instance(sim, cn)
        if parent is not None:
            inst.set_parent(parent)
        return inst

    def inst_fromexisting(i):
        return i.clone()

    it = LuaTable()
    it.set("new", BuiltinFunction(inst_new, "Instance.new"))
    it.set("fromExisting", BuiltinFunction(inst_fromexisting, "Instance.fromExisting"))
    G.set("Instance", it)

    task = LuaTable()

    def t_spawn(fn, *args):
        th = sim.sched.spawn(fn, args, sim.ctx())
        return th

    def t_defer(fn, *args):
        return sim.sched.defer(fn, args, sim.ctx())

    def t_delay(t, fn, *args):
        return sim.sched.delay(float(t or 0), fn, args, sim.ctx())

    def t_wait(t=None):
        return sim.sched.wait(float(t) if t is not None else None)

    def t_cancel(th):
        if type(th) is not LuaThread:
            raise LuaError("task.cancel expects a thread")
        th.cancelled = True
        if th.status == "suspended":
            th.status = "dead"
        return ()

    task.set("spawn", BuiltinFunction(t_spawn, "task.spawn"))
    task.set("defer", BuiltinFunction(t_defer, "task.defer"))
    task.set("delay", BuiltinFunction(t_delay, "task.delay"))
    task.set("wait", BuiltinFunction(t_wait, "task.wait"))
    task.set("cancel", BuiltinFunction(t_cancel, "task.cancel"))
    task.set("synchronize", BuiltinFunction(lambda *a: None, "task.synchronize"))
    task.set("desynchronize", BuiltinFunction(lambda *a: None, "task.desynchronize"))
    G.set("task", task)
    G.set("wait", BuiltinFunction(lambda t=None: (sim.sched.wait(float(t) if t else None)[0] if True else 0, sim.sched.clock), "wait"))
    G.set("spawn", BuiltinFunction(lambda fn: sim.sched.defer(fn, (), sim.ctx()) and None, "spawn"))
    G.set("delay", BuiltinFunction(lambda t, fn: sim.sched.delay(float(t), fn, (), sim.ctx()) and None, "delay"))
    G.set("tick", BuiltinFunction(lambda: sim.wall_epoch + sim.sched.clock, "tick"))
    G.set("time", BuiltinFunction(lambda: sim.sched.clock, "time"))
    G.set("elapsedTime", BuiltinFunction(lambda: sim.sched.clock, "elapsedTime"))
    G.set("require", BuiltinFunction(lambda m: sim.require(m), "require"))
    G.set("settings", BuiltinFunction(lambda: None, "settings"))

    us = LuaTable()
    G.set("UserSettings", BuiltinFunction(lambda: us, "UserSettings"))
    G.set("version", BuiltinFunction(lambda: "0.600.0.0", "version"))

    rg = LuaTable()

    def r3_new(a, b):
        return Region3(a, b)
    rg.set("new", BuiltinFunction(r3_new, "Region3.new"))
    G.set("Region3", rg)


class Region3(LI.UserData):
    __slots__ = ("min", "max")

    def __init__(self, a, b):
        self.min = a
        self.max = b

    def lua_index(self, key):
        if key == "CFrame":
            c = (self.min + self.max).scale(0.5)
            return CFrame(c.tup())
        if key == "Size":
            return self.max - self.min
        if key == "ExpandToGrid":
            def etg(s, res):
                r = float(res)
                mn = Vector3(math.floor(s.min.x / r) * r, math.floor(s.min.y / r) * r, math.floor(s.min.z / r) * r)
                mx = Vector3(math.ceil(s.max.x / r) * r, math.ceil(s.max.y / r) * r, math.ceil(s.max.z / r) * r)
                return Region3(mn, mx)
            return _fn("ExpandToGrid", etg)
        raise LuaError(f"{key} is not a valid member of Region3")

    def lua_typeof(self):
        return "Region3"


# =============================================================================== install methods

def install(sim):
    M = sim.method
    G = sim.getter
    S = sim.setter

    # ------------------------------------------------------------------ Instance
    @M("Instance", "FindFirstChild")
    def find_first_child(self, name, recursive=False):
        name = _str(name)
        if truthy(recursive):
            for d in self.descendants():
                if d.Name == name:
                    return d
            return None
        return self.find_child(name)

    @M("Instance", "FindFirstChildOfClass")
    def ffc_class(self, cn):
        for c in self.children:
            if c.cls.name == cn:
                return c
        return None

    @M("Instance", "FindFirstChildWhichIsA")
    def ffc_isa(self, cn, recursive=False):
        lst = self.descendants() if truthy(recursive) else self.children
        for c in lst:
            if c.is_a(cn):
                return c
        return None

    @M("Instance", "FindFirstDescendant")
    def ffd(self, name):
        for d in self.descendants():
            if d.Name == name:
                return d
        return None

    @M("Instance", "FindFirstAncestor")
    def ffa(self, name):
        p = self.parent
        while p is not None:
            if p.Name == name:
                return p
            p = p.parent
        return None

    @M("Instance", "FindFirstAncestorOfClass")
    def ffa_class(self, cn):
        p = self.parent
        while p is not None:
            if p.cls.name == cn:
                return p
            p = p.parent
        return None

    @M("Instance", "FindFirstAncestorWhichIsA")
    def ffa_isa(self, cn):
        p = self.parent
        while p is not None:
            if p.is_a(cn):
                return p
            p = p.parent
        return None

    @M("Instance", "WaitForChild")
    def wait_for_child(self, name, timeout=None):
        name = _str(name)
        c = self.find_child(name)
        if c is not None:
            return c
        th = STATE.current_thread
        if th is None or th.is_main:
            raise LuaError("WaitForChild called outside of a coroutine")
        deadline = None if timeout is None else sim.sched.clock + float(timeout)
        start = sim.sched.clock
        warned = False
        while True:
            sim.sched.wait(1 / 60)
            c = self.find_child(name)
            if c is not None:
                return c
            if deadline is not None and sim.sched.clock >= deadline:
                return None
            if not warned and timeout is None and sim.sched.clock - start > 5:
                warned = True
                sim.log("warn", f"Infinite yield possible on '{self.full_name()}:WaitForChild(\"{name}\")'", th.context)

    @M("Instance", "GetChildren")
    def get_children(self):
        return T(*self.children)

    @M("Instance", "GetDescendants")
    def get_descendants(self):
        return T(*self.descendants())

    @M("Instance", "IsA")
    def isa(self, cn):
        return self.is_a(_str(cn))

    @M("Instance", "IsDescendantOf")
    def isdesc(self, other):
        return self.is_descendant_of(other) if other is not None else False

    @M("Instance", "IsAncestorOf")
    def isanc(self, other):
        return other.is_descendant_of(self) if other is not None else False

    @M("Instance", "Destroy")
    def destroy(self):
        self.destroy()

    @M("Instance", "Remove")
    def remove(self):
        self.set_parent(None)

    @M("Instance", "Clone")
    def clone(self):
        return self.clone()

    @M("Instance", "ClearAllChildren")
    def clear_all(self):
        for c in list(self.children):
            c.destroy()

    @M("Instance", "GetFullName")
    def gfn(self):
        return self.full_name()

    ATTR_TYPES = (bool, float, int, str, UDim, UDim2, BrickColor, Color3, Vector2, Vector3, CFrame,
                  NumberSequence, ColorSequence, NumberRange, Rect, Font, EnumItem)

    @M("Instance", "SetAttribute")
    def set_attr(self, name, value=None):
        name = _str(name)
        if len(name) > 100 or not all(ch.isalnum() or ch == "_" for ch in name) or name.startswith("RBX"):
            raise LuaError(f"Attribute name '{name}' is invalid")
        if value is not None and not isinstance(value, ATTR_TYPES):
            raise LuaError(f"{lua_typeof(value)} is not a supported attribute type")
        old = self.attrs.get(name)
        if value is None:
            self.attrs.pop(name, None)
        else:
            self.attrs[name] = float(value) if type(value) is int else value
        if not LI.eq(old, value) or (old is None) != (value is None):
            s = self.signals.get("AttributeChanged")
            if s is not None:
                s.fire(name)
            s2 = self.signals.get("attr:" + name)
            if s2 is not None:
                s2.fire()
            sim.on_prop_changed(self, "@" + name)

    @M("Instance", "GetAttribute")
    def get_attr(self, name):
        return self.attrs.get(_str(name))

    @M("Instance", "GetAttributes")
    def get_attrs(self):
        return D(dict(self.attrs))

    @M("Instance", "GetAttributeChangedSignal")
    def gacs(self, name):
        name = _str(name)
        s = self.signals.get("attr:" + name)
        if s is None:
            s = Signal(sim, "attr:" + name, self)
            self.signals["attr:" + name] = s
        return s

    @M("Instance", "GetPropertyChangedSignal")
    def gpcs(self, prop):
        prop = _str(prop)
        if prop not in self.cls.all_props():
            raise LuaError(f"{prop} is not a valid property name.")
        s = self.signals.get("prop:" + prop)
        if s is None:
            s = Signal(sim, "prop:" + prop, self)
            self.signals["prop:" + prop] = s
        return s

    @M("Instance", "AddTag")
    def add_tag(self, tag):
        _cs_add(sim, self, _str(tag))

    @M("Instance", "RemoveTag")
    def remove_tag(self, tag):
        _cs_remove(sim, self, _str(tag))

    @M("Instance", "HasTag")
    def has_tag(self, tag):
        return _str(tag) in self.tags

    @M("Instance", "GetTags")
    def get_tags(self):
        return T(*self.tags)

    @M("Instance", "GetActor")
    def get_actor(self):
        return None

    @G("Instance", "Parent")
    def g_parent(self):
        return self.parent

    @S("Instance", "Parent")
    def s_parent(self, v):
        self.set_parent(v)

    @G("Instance", "ClassName")
    def g_classname(self):
        return self.cls.name

    # ------------------------------------------------------------------ CollectionService
    @M("CollectionService", "AddTag")
    def cs_add(self, inst, tag):
        _cs_add(sim, inst, _str(tag))

    @M("CollectionService", "RemoveTag")
    def cs_remove(self, inst, tag):
        _cs_remove(sim, inst, _str(tag))

    @M("CollectionService", "HasTag")
    def cs_has(self, inst, tag):
        return _str(tag) in inst.tags

    @M("CollectionService", "GetTagged")
    def cs_tagged(self, tag):
        return T(*sim.tagged(_str(tag)))

    @M("CollectionService", "GetTags")
    def cs_tags(self, inst):
        return T(*inst.tags)

    @M("CollectionService", "GetInstanceAddedSignal")
    def cs_added(self, tag):
        return sim.tag_signal(_str(tag), "added")

    @M("CollectionService", "GetInstanceRemovedSignal")
    def cs_removed(self, tag):
        return sim.tag_signal(_str(tag), "removed")

    @M("CollectionService", "GetAllTags")
    def cs_all(self):
        s = set()
        for d in sim.game.descendants():
            s.update(d.tags)
        return T(*sorted(s))

    # ------------------------------------------------------------------ DataModel
    @M("DataModel", "GetService")
    def get_service(self, name):
        return sim.get_service(_str(name))

    @M("DataModel", "FindService")
    def find_service(self, name):
        return sim.services.get(_str(name))

    @M("DataModel", "IsLoaded")
    def is_loaded(self):
        return True

    @M("DataModel", "BindToClose")
    def bind_to_close(self, fn):
        sim.close_callbacks = getattr(sim, "close_callbacks", [])
        sim.close_callbacks.append((fn, sim.ctx()))

    @G("DataModel", "Loaded")
    def g_loaded(self):
        return self.get_signal("Loaded")

    @G("DataModel", "JobId")
    def g_jobid(self):
        return getattr(sim, "job_id", "sim-job-1")

    # ------------------------------------------------------------------ RunService
    @M("RunService", "IsServer")
    def rs_is_server(self):
        return sim.ctx().kind == "server"

    @M("RunService", "IsClient")
    def rs_is_client(self):
        return sim.ctx().kind == "client"

    @M("RunService", "IsStudio")
    def rs_is_studio(self):
        return getattr(sim, "is_studio", True)

    @M("RunService", "IsRunning")
    def rs_is_running(self):
        return True

    @M("RunService", "IsRunMode")
    def rs_is_runmode(self):
        return False

    @M("RunService", "BindToRenderStep")
    def rs_bind(self, name, priority, fn):
        ctx = sim.ctx()
        if ctx.kind != "client":
            raise LuaError("BindToRenderStep can only be called from local scripts")
        ctx.render_binds[_str(name)] = (float(priority), fn, next(_bind_seq))

    @M("RunService", "UnbindFromRenderStep")
    def rs_unbind(self, name):
        ctx = sim.ctx()
        ctx.render_binds.pop(_str(name), None)

    # ------------------------------------------------------------------ Players
    @G("Players", "LocalPlayer")
    def g_localplayer(self):
        ctx = sim.ctx()
        return ctx.player if ctx.kind == "client" else None

    @M("Players", "GetPlayers")
    def get_players(self):
        return T(*[c for c in self.children if c.cls.name == "Player"])

    @M("Players", "GetPlayerFromCharacter")
    def gpfc(self, char):
        for p in self.children:
            if p.cls.name == "Player" and p.props.get("Character") is char and char is not None:
                return p
        return None

    @M("Players", "GetPlayerByUserId")
    def gpbu(self, uid):
        for p in self.children:
            if p.cls.name == "Player" and p.props.get("UserId") == float(uid):
                return p
        return None

    @M("Players", "GetUserThumbnailAsync")
    def guta(self, uid, ttype=None, size=None):
        return (f"rbxthumb://type=AvatarHeadShot&id={int(uid)}&w=150&h=150", True)

    @M("Players", "GetNameFromUserIdAsync")
    def gnfu(self, uid):
        return f"User{int(uid)}"

    @M("Player", "Kick")
    def kick(self, msg=None):
        sim.log("warn", f"Player {self.Name} kicked: {msg}")
        self.extra["kicked"] = msg or ""
        remove_player(sim, self)

    @M("Player", "GetMouse")
    def get_mouse(self):
        return sim.new("Folder", Name="Mouse")

    @M("Player", "RequestStreamAroundAsync")
    def rsa(self, pos, timeout=None):
        sim.stream_requests = getattr(sim, "stream_requests", 0) + 1
        return ()

    @M("Player", "GetNetworkPing")
    def ping(self):
        return 0.05

    @M("Player", "IsInGroup")
    def in_group(self, gid):
        return False

    @M("Player", "GetRankInGroup")
    def rank(self, gid):
        return 0.0

    @M("Player", "LoadCharacter")
    def load_char(self):
        spawn_character(sim, self)

    @M("Player", "HasAppearanceLoaded")
    def hal(self):
        return True

    @M("Player", "DistanceFromCharacter")
    def dfc(self, pos):
        ch = self.props.get("Character")
        if ch is None:
            return 0.0
        hrp = ch.find_child("HumanoidRootPart")
        if hrp is None:
            return 0.0
        return (part_cframe(sim, hrp).pos() - pos).mag()

    @G("Player", "UserId")
    def g_userid(self):
        return self.props.get("UserId", 0.0)

    # ------------------------------------------------------------------ Workspace
    @G("Workspace", "CurrentCamera")
    def g_curcam(self):
        ctx = sim.ctx()
        return ctx.camera if ctx.camera is not None else sim.server_ctx.camera

    @S("Workspace", "CurrentCamera")
    def s_curcam(self, v):
        sim.ctx().camera = v

    @M("Workspace", "GetServerTimeNow")
    def gstn(self):
        return sim.wall_epoch + sim.sched.clock

    @M("Workspace", "GetRealPhysicsFPS")
    def grpf(self):
        return 60.0

    @M("Workspace", "Raycast")
    def ws_raycast(self, origin, direction, params=None):
        return raycast(sim, origin, direction, params, 0.0)

    @M("Workspace", "Spherecast")
    def ws_spherecast(self, origin, radius, direction, params=None):
        return raycast(sim, origin, direction, params, float(radius))

    @M("Workspace", "Blockcast")
    def ws_blockcast(self, cf, size, direction, params=None):
        r = min(size.x, size.y, size.z) / 2
        return raycast(sim, cf.pos(), direction, params, r)

    @M("Workspace", "GetPartBoundsInRadius")
    def gpbir(self, pos, radius, params=None):
        out = []
        for p in all_parts(sim):
            cf = part_cframe(sim, p)
            sz = p.get_prop("Size")
            rr = 0.5 * math.sqrt(sz.x ** 2 + sz.y ** 2 + sz.z ** 2)
            if (cf.pos() - pos).mag() > radius + rr or not _passes_filter(sim, p, params):
                continue  # cheap bounding-sphere reject first
            # exact test: distance from the point to the oriented box (shapes count as boxes)
            rel = cf.point_to_object(pos)
            dx = max(abs(rel.x) - sz.x / 2, 0.0)
            dy = max(abs(rel.y) - sz.y / 2, 0.0)
            dz = max(abs(rel.z) - sz.z / 2, 0.0)
            if (dx * dx + dy * dy + dz * dz) ** 0.5 <= radius:
                out.append(p)
        return T(*out)

    @M("Workspace", "GetPartBoundsInBox")
    def gpbib(self, cf, size, params=None):
        out = []
        c = cf.pos()
        for p in all_parts(sim):
            pc = part_cframe(sim, p).pos()
            if abs(pc.x - c.x) <= size.x / 2 and abs(pc.y - c.y) <= size.y / 2 and abs(pc.z - c.z) <= size.z / 2:
                if _passes_filter(sim, p, params):
                    out.append(p)
        return T(*out)

    @M("Workspace", "GetPartsInPart")
    def gpip(self, part, params=None):
        return T()

    # ------------------------------------------------------------------ PVInstance / Model / BasePart
    @M("PVInstance", "GetPivot")
    def m_get_pivot(self):
        return _get_pivot_impl(sim, self)

    @M("PVInstance", "PivotTo")
    def m_pivot_to(self, cf):
        _pivot_to_impl(sim, self, cf)

    @M("Model", "SetPrimaryPartCFrame")
    def sppc(self, cf):
        pp = self.props.get("PrimaryPart")
        if pp is None:
            raise LuaError("Model:SetPrimaryPartCFrame() failed because no PrimaryPart has been set")
        pivot_to(sim, self, cf * pp.get_prop("PivotOffset"))

    @M("Model", "GetPrimaryPartCFrame")
    def gppc(self):
        pp = self.props.get("PrimaryPart")
        return part_cframe(sim, pp) if pp is not None else None

    @M("Model", "GetBoundingBox")
    def gbb(self):
        return bounding_box(sim, self)

    @M("Model", "GetExtentsSize")
    def ges(self):
        return bounding_box(sim, self)[1]

    @M("Model", "MoveTo")
    def moveto(self, pos):
        cf = get_pivot(sim, self)
        pivot_to(sim, self, CFrame(pos.tup(), cf.r))

    @M("Model", "GetScale")
    def get_scale(self):
        return self.extra.get("scale", 1.0)

    @M("Model", "ScaleTo")
    def scale_to(self, s):
        s = float(s)
        if s <= 0:
            raise LuaError("Model:ScaleTo scale must be positive")
        cur = self.extra.get("scale", 1.0)
        k = s / cur
        piv = get_pivot(sim, self)
        for d in self.descendants():
            if d.is_a("BasePart"):
                cf = part_cframe(sim, d)
                rel = piv.inverse().mul(cf)
                rel = CFrame((rel.p[0] * k, rel.p[1] * k, rel.p[2] * k), rel.r)
                d.props["Size"] = d.get_prop("Size").scale(k)
                d.props["CFrame"] = piv.mul(rel)
            elif d.is_a("JointInstance"):
                for key in ("C0", "C1"):
                    c = d.get_prop(key)
                    d.props[key] = CFrame((c.p[0] * k, c.p[1] * k, c.p[2] * k), c.r)
            elif d.cls.name in ("Attachment", "Bone"):
                c = d.get_prop("CFrame")
                d.props["CFrame"] = CFrame((c.p[0] * k, c.p[1] * k, c.p[2] * k), c.r)
            elif d.cls.name == "SpecialMesh":
                pass
        self.extra["scale"] = s
        invalidate_weld_cache(sim)

    @G("BasePart", "CFrame")
    def g_cframe(self):
        return part_cframe(sim, self)

    @S("BasePart", "CFrame")
    def s_cframe(self, cf):
        set_part_cframe(sim, self, cf)

    @G("BasePart", "Position")
    def g_position(self):
        return part_cframe(sim, self).pos()

    @S("BasePart", "Position")
    def s_position(self, v):
        cf = part_cframe(sim, self)
        set_part_cframe(sim, self, CFrame(v.tup(), cf.r))

    @G("BasePart", "Orientation")
    def g_orient(self):
        x, y, z = part_cframe(sim, self).to_euler_yxz()
        return Vector3(math.degrees(x), math.degrees(y), math.degrees(z))

    @S("BasePart", "Orientation")
    def s_orient(self, v):
        from rbx_types import _cf_yxz
        cf = part_cframe(sim, self)
        r = _cf_yxz(math.radians(v.x), math.radians(v.y), math.radians(v.z))
        set_part_cframe(sim, self, CFrame(cf.p, r.r))

    @G("BasePart", "Rotation")
    def g_rotation(self):
        x, y, z = part_cframe(sim, self).to_euler_xyz()
        return Vector3(math.degrees(x), math.degrees(y), math.degrees(z))

    @S("BasePart", "Size")
    def s_size(self, v):
        if self.cls.name == "Part" and self.get_prop("Shape").name == "Ball":
            m = min(v.x, v.y, v.z)
            v = Vector3(m, m, m)
        v = Vector3(max(0.001, v.x), max(0.001, v.y), max(0.001, v.z))
        old = self.props.get("Size")
        self.props["Size"] = v
        if old is None or not old.lua_eq(v):
            self.changed("Size")
        sim.spatial_dirty = True

    @G("BasePart", "BrickColor")
    def g_brickcolor(self):
        return BrickColor("Medium stone grey", self.get_prop("Color"))

    @S("BasePart", "BrickColor")
    def s_brickcolor(self, v):
        self.set_prop("Color", v.color)

    @G("BasePart", "AssemblyRootPart")
    def g_arp(self):
        return assembly_root(sim, self)

    @M("BasePart", "GetMass")
    def get_mass(self):
        s = self.get_prop("Size")
        return s.x * s.y * s.z * 0.7

    @M("BasePart", "SetNetworkOwner")
    def set_owner(self, player=None):
        if sim.ctx().kind != "server":
            raise LuaError("Network Ownership API can only be called from the server")
        if self.get_prop("Anchored"):
            raise LuaError("Network Ownership API cannot be called on Anchored parts or parts welded to Anchored parts.")
        assembly_root(sim, self).extra["net_owner"] = player
        assembly_root(sim, self).extra["net_auto"] = False

    @M("BasePart", "GetNetworkOwner")
    def get_owner(self):
        if sim.ctx().kind != "server":
            raise LuaError("Network Ownership API can only be called from the server")
        return assembly_root(sim, self).extra.get("net_owner")

    @M("BasePart", "SetNetworkOwnershipAuto")
    def set_owner_auto(self):
        assembly_root(sim, self).extra["net_owner"] = None
        assembly_root(sim, self).extra["net_auto"] = True

    @M("BasePart", "CanSetNetworkOwnership")
    def can_set_owner(self):
        return (not self.get_prop("Anchored"), None)

    @M("BasePart", "ApplyImpulse")
    def apply_impulse(self, v):
        r = assembly_root(sim, self)
        m = max(1.0, r.get_prop("Size").x * r.get_prop("Size").y * r.get_prop("Size").z * 0.7)
        r.props["AssemblyLinearVelocity"] = r.get_prop("AssemblyLinearVelocity") + v.scale(1 / m)

    @M("BasePart", "ApplyAngularImpulse")
    def apply_ang_impulse(self, v):
        pass

    @M("BasePart", "GetRootPart")
    def get_root_part(self):
        return assembly_root(sim, self)

    @M("BasePart", "GetJoints")
    def get_joints(self):
        return T(*[j for j in all_joints(sim) if j.props.get("Part0") is self or j.props.get("Part1") is self])

    @M("BasePart", "GetConnectedParts")
    def get_connected(self, recursive=False):
        return T(self)

    @M("BasePart", "GetTouchingParts")
    def get_touching(self):
        return T()

    @M("BasePart", "IsGrounded")
    def is_grounded(self):
        return self.get_prop("Anchored")

    @M("BasePart", "GetVelocityAtPosition")
    def gvap(self, pos):
        return assembly_root(sim, self).get_prop("AssemblyLinearVelocity")

    @G("BasePart", "AssemblyLinearVelocity")
    def g_alv(self):
        r = assembly_root(sim, self)
        return r.props.get("AssemblyLinearVelocity", Vector3())

    @S("BasePart", "AssemblyLinearVelocity")
    def s_alv(self, v):
        assembly_root(sim, self).props["AssemblyLinearVelocity"] = v

    @G("BasePart", "ReceiveAge")
    def g_receive_age(self):
        ctx = sim.ctx()
        owner = assembly_root(sim, self).extra.get("net_owner")
        if ctx.kind == "client" and owner is ctx.player:
            return 0.0
        return 0.05

    # attachments
    @G("Attachment", "WorldCFrame")
    def g_att_wcf(self):
        return attachment_world_cf(sim, self)

    @S("Attachment", "WorldCFrame")
    def s_att_wcf(self, cf):
        p = self.parent
        if p is not None and p.is_a("BasePart"):
            self.set_prop("CFrame", part_cframe(sim, p).inverse().mul(cf))
        else:
            self.set_prop("CFrame", cf)

    @G("Attachment", "WorldPosition")
    def g_att_wpos(self):
        return attachment_world_cf(sim, self).pos()

    @S("Attachment", "WorldPosition")
    def s_att_wpos(self, v):
        cf = attachment_world_cf(sim, self)
        s_att_wcf(self, CFrame(v.tup(), cf.r))

    @G("Attachment", "Position")
    def g_att_pos(self):
        return self.get_prop_raw_cf().pos() if False else _att_cf(self).pos()

    @S("Attachment", "Position")
    def s_att_pos(self, v):
        cf = _att_cf(self)
        self.set_prop("CFrame", CFrame(v.tup(), cf.r))

    @G("Attachment", "Orientation")
    def g_att_orient(self):
        x, y, z = _att_cf(self).to_euler_yxz()
        return Vector3(math.degrees(x), math.degrees(y), math.degrees(z))

    @S("Attachment", "Orientation")
    def s_att_orient(self, v):
        from rbx_types import _cf_yxz
        cf = _att_cf(self)
        r = _cf_yxz(math.radians(v.x), math.radians(v.y), math.radians(v.z))
        self.set_prop("CFrame", CFrame(cf.p, r.r))

    @G("Attachment", "WorldOrientation")
    def g_att_worient(self):
        x, y, z = attachment_world_cf(sim, self).to_euler_yxz()
        return Vector3(math.degrees(x), math.degrees(y), math.degrees(z))

    @G("Attachment", "Axis")
    def g_att_axis(self):
        return _att_cf(self).right()

    @G("Attachment", "SecondaryAxis")
    def g_att_saxis(self):
        return _att_cf(self).up()

    @G("Attachment", "WorldAxis")
    def g_att_waxis(self):
        return attachment_world_cf(sim, self).right()

    # joints invalidate cache
    for jprop in ("Part0", "Part1", "C0", "C1", "Enabled"):
        def mk(jp):
            def setter(self, v):
                old = self.props.get(jp)
                self.props[jp] = v
                if jp in ("Part0", "Part1", "Enabled") and self.cls.name == "WeldConstraint":
                    _capture_weld_offset(sim, self)
                if self.in_game():
                    invalidate_weld_cache(sim)
                if not LI.eq(old, v) if not isinstance(v, Instance) else old is not v:
                    self.changed(jp)
            return setter
        S("JointInstance", jprop)(mk(jprop))
        if jprop in ("Part0", "Part1", "Enabled"):
            S("WeldConstraint", jprop)(mk(jprop))

    @S("Motor6D", "Transform")
    def s_transform(self, v):
        self.props["Transform"] = v

    # ------------------------------------------------------------------ Humanoid / Seat
    @M("Humanoid", "ChangeState")
    def h_change_state(self, st):
        st = ENUM.types["HumanoidStateType"].coerce(st)
        disabled = self.extra.setdefault("disabled_states", set())
        if st.name in disabled:
            return
        old = self.extra.get("state", E("HumanoidStateType", "Running"))
        if st.name == "Jumping" and self.props.get("SeatPart") is not None:
            unseat(sim, self)
        self.extra["state"] = st
        self.get_signal("StateChanged").fire(old, st)

    @M("Humanoid", "GetState")
    def h_get_state(self):
        return self.extra.get("state", E("HumanoidStateType", "Running"))

    @M("Humanoid", "SetStateEnabled")
    def h_set_state_enabled(self, st, enabled):
        st = ENUM.types["HumanoidStateType"].coerce(st)
        disabled = self.extra.setdefault("disabled_states", set())
        if truthy(enabled):
            disabled.discard(st.name)
        else:
            disabled.add(st.name)

    @M("Humanoid", "GetStateEnabled")
    def h_get_state_enabled(self, st):
        st = ENUM.types["HumanoidStateType"].coerce(st)
        return st.name not in self.extra.get("disabled_states", set())

    @M("Humanoid", "Move")
    def h_move(self, v, rel=False):
        self.props["MoveDirection"] = v

    @M("Humanoid", "MoveTo")
    def h_move_to(self, pos, part=None):
        self.props["WalkToPoint"] = pos

    @M("Humanoid", "TakeDamage")
    def h_take_damage(self, amt):
        self.set_prop("Health", max(0.0, self.get_prop("Health") - float(amt)))

    @M("Humanoid", "UnequipTools")
    def h_unequip(self):
        pass

    @M("Humanoid", "GetAppliedDescription")
    def h_gad(self):
        return sim.new("Folder")

    @S("Humanoid", "Sit")
    def s_sit(self, v):
        if not truthy(v) and self.props.get("SeatPart") is not None:
            unseat(sim, self)
        self.props["Sit"] = bool(v)

    @S("Humanoid", "Jump")
    def s_jump(self, v):
        if truthy(v) and self.props.get("SeatPart") is not None:
            if "Jumping" not in self.extra.get("disabled_states", set()):
                unseat(sim, self)
        self.props["Jump"] = False

    @G("Humanoid", "RootPart")
    def g_rootpart(self):
        ch = self.parent
        return ch.find_child("HumanoidRootPart") if ch is not None else None

    @M("Seat", "Sit")
    def seat_sit(self, humanoid):
        seat_humanoid(sim, self, humanoid)

    @M("VehicleSeat", "Sit")
    def vseat_sit(self, humanoid):
        seat_humanoid(sim, self, humanoid)

    # ------------------------------------------------------------------ ProximityPrompt
    @M("ProximityPrompt", "InputHoldBegin")
    def pp_hold_begin(self):
        import rbx_prompts
        rbx_prompts.prompt_hold_begin(sim, self, sim.ctx())

    @M("ProximityPrompt", "InputHoldEnd")
    def pp_hold_end(self):
        import rbx_prompts
        rbx_prompts.prompt_hold_end(sim, self, sim.ctx())

    # ------------------------------------------------------------------ Sound / particles
    @M("Sound", "Play")
    def snd_play(self):
        self.props["Playing"] = True
        self.extra["played_at"] = sim.sched.clock
        sim.sounds_played = getattr(sim, "sounds_played", [])
        sim.sounds_played.append((sim.sched.clock, self.Name, self.props.get("SoundId", "")))
        self.get_signal("Played").fire(self.props.get("SoundId", ""))

    @M("Sound", "Stop")
    def snd_stop(self):
        self.props["Playing"] = False

    @M("Sound", "Pause")
    def snd_pause(self):
        self.props["Playing"] = False

    @M("Sound", "Resume")
    def snd_resume(self):
        self.props["Playing"] = True

    @G("Sound", "IsPlaying")
    def g_snd_isplaying(self):
        return bool(self.props.get("Playing"))

    @M("ParticleEmitter", "Emit")
    def pe_emit(self, n=16):
        self.extra["emitted"] = self.extra.get("emitted", 0) + int(n or 16)

    @M("ParticleEmitter", "Clear")
    def pe_clear(self):
        pass

    @M("SoundService", "PlayLocalSound")
    def ss_play_local(self, snd):
        snd_play(snd)

    # ------------------------------------------------------------------ Camera
    @G("Camera", "ViewportSize")
    def g_viewport(self):
        for c in sim.clients:
            if c.camera is self:
                return Vector2(*c.device.viewport)
        return Vector2(1920, 1080)

    @M("Camera", "WorldToViewportPoint")
    def w2vp(self, pos):
        return world_to_viewport(sim, self, pos)

    @M("Camera", "WorldToScreenPoint")
    def w2sp(self, pos):
        v, on = world_to_viewport(sim, self, pos)
        return (Vector3(v.x, v.y - 0, v.z), on)

    @M("Camera", "ViewportPointToRay")
    def vp2ray(self, x, y, depth=0):
        return viewport_ray(sim, self, float(x), float(y))

    @M("Camera", "ScreenPointToRay")
    def sp2ray(self, x, y, depth=0):
        return viewport_ray(sim, self, float(x), float(y))

    @M("Camera", "GetPartsObscuringTarget")
    def gpot(self, targets, ignore):
        return T()

    # ------------------------------------------------------------------ Lighting
    @M("Lighting", "GetSunDirection")
    def sun_dir(self):
        t = self.get_prop("ClockTime")
        a = (t - 6) / 12 * math.pi
        return Vector3(math.cos(a) * 0.5, math.sin(a), 0.6).unit()

    @M("Lighting", "GetMinutesAfterMidnight")
    def gmam(self):
        return self.get_prop("ClockTime") * 60

    @M("Lighting", "SetMinutesAfterMidnight")
    def smam(self, m):
        self.set_prop("ClockTime", (float(m) / 60) % 24)

    # ------------------------------------------------------------------ StarterGui
    @M("StarterGui", "SetCoreGuiEnabled")
    def sg_scge(self, t, enabled):
        sim.coregui = getattr(sim, "coregui", {})
        sim.coregui[(str(sim.ctx()), t.name if isinstance(t, EnumItem) else str(t))] = truthy(enabled)

    @M("StarterGui", "GetCoreGuiEnabled")
    def sg_gcge(self, t):
        return getattr(sim, "coregui", {}).get((str(sim.ctx()), t.name), True)

    @M("StarterGui", "SetCore")
    def sg_setcore(self, name, value=None):
        pass

    @M("StarterGui", "GetCore")
    def sg_getcore(self, name):
        return None

    # ------------------------------------------------------------------ ReplicatedFirst
    @M("ReplicatedFirst", "RemoveDefaultLoadingScreen")
    def rf_rdls(self):
        pass

    @M("ReplicatedFirst", "IsFinishedReplicating")
    def rf_ifr(self):
        return True

    # ------------------------------------------------------------------ ContentProvider / Debris
    @M("ContentProvider", "PreloadAsync")
    def cp_preload(self, items, cb=None):
        if cb is not None and type(items) is LuaTable:
            for it in items.arr:
                call(cb, ("rbxassetid://0", E("AssetFetchStatus", "Success") if "AssetFetchStatus" in ENUM.types else None))
        return ()

    @G("ContentProvider", "RequestQueueSize")
    def cp_rqs(self):
        return 0.0

    @M("Debris", "AddItem")
    def debris_add(self, item, life=10):
        def kill(*a):
            if not item.destroyed:
                item.destroy()
        sim.sched.delay(float(life), BuiltinFunction(kill, "debris"), (), sim.ctx())

    # ------------------------------------------------------------------ GuiService
    @G("GuiService", "TopbarInset")
    def g_topbar(self):
        ctx = sim.ctx()
        if ctx.kind == "client":
            t = ctx.device.topbar
            return Rect(*t)
        return Rect(0, 0, 0, 0)

    @M("GuiService", "GetGuiInset")
    def gs_inset(self):
        ctx = sim.ctx()
        h = ctx.device.topbar[3] if ctx.kind == "client" else 58
        return (Vector2(0, h), Vector2(0, 0))

    @M("GuiService", "IsTenFootInterface")
    def gs_tenfoot(self):
        return False

    @G("GuiService", "SelectedObject")
    def g_selobj(self):
        return sim.ctx().__dict__.get("selected_object")

    @S("GuiService", "SelectedObject")
    def s_selobj(self, v):
        sim.ctx().__dict__["selected_object"] = v

    @M("GuiService", "Select")
    def gs_select(self, inst):
        pass

    # ------------------------------------------------------------------ UserInputService
    for prop, attr in (("TouchEnabled", "touch"), ("KeyboardEnabled", "keyboard"), ("MouseEnabled", "mouse"),
                       ("GamepadEnabled", "gamepad")):
        def mkg(a):
            def g(self):
                ctx = sim.ctx()
                if ctx.kind != "client":
                    return False
                return bool(getattr(ctx.device, a))
            return g
        G("UserInputService", prop)(mkg(attr))

    @G("UserInputService", "MouseBehavior")
    def g_mb(self):
        return sim.ctx().__dict__.get("mouse_behavior", E("MouseBehavior", "Default"))

    @S("UserInputService", "MouseBehavior")
    def s_mb(self, v):
        sim.ctx().__dict__["mouse_behavior"] = v

    @G("UserInputService", "MouseIconEnabled")
    def g_mie(self):
        return sim.ctx().__dict__.get("mouse_icon", True)

    @S("UserInputService", "MouseIconEnabled")
    def s_mie(self, v):
        sim.ctx().__dict__["mouse_icon"] = bool(v)

    @M("UserInputService", "IsKeyDown")
    def uis_iskeydown(self, kc):
        kc = ENUM.types["KeyCode"].coerce(kc)
        return kc.name in sim.ctx().keys_down

    @M("UserInputService", "IsMouseButtonPressed")
    def uis_ismbp(self, b):
        b = ENUM.types["UserInputType"].coerce(b)
        return b.name in sim.ctx().mouse_buttons

    @M("UserInputService", "GetMouseDelta")
    def uis_gmd(self):
        return sim.ctx().mouse_delta

    @M("UserInputService", "GetMouseLocation")
    def uis_gml(self):
        return sim.ctx().mouse_pos

    @M("UserInputService", "GetLastInputType")
    def uis_glit(self):
        return sim.ctx().last_input

    @M("UserInputService", "GetKeysPressed")
    def uis_gkp(self):
        return T()

    @M("UserInputService", "GetConnectedGamepads")
    def uis_gcg(self):
        return T()

    @M("UserInputService", "GetGamepadConnected")
    def uis_ggc(self, gp):
        return False

    @M("UserInputService", "GetGamepadState")
    def uis_ggs(self, gp):
        return T()

    @M("UserInputService", "GetFocusedTextBox")
    def uis_gftb(self):
        return sim.ctx().focused_textbox

    @M("UserInputService", "GetStringForKeyCode")
    def uis_gsfkc(self, kc):
        return kc.name

    # ------------------------------------------------------------------ ContextActionService
    @M("ContextActionService", "BindAction")
    def cas_bind(self, name, fn, touch_button, *inputs):
        _cas_bind(sim, _str(name), fn, inputs, 1000 + next(_bind_seq) * 0.001)

    @M("ContextActionService", "BindActionAtPriority")
    def cas_bind_pri(self, name, fn, touch_button, priority, *inputs):
        _cas_bind(sim, _str(name), fn, inputs, float(priority) + next(_bind_seq) * 1e-6)

    @M("ContextActionService", "UnbindAction")
    def cas_unbind(self, name):
        sim.ctx().cas_binds.pop(_str(name), None)

    @M("ContextActionService", "UnbindAllActions")
    def cas_unbind_all(self):
        sim.ctx().cas_binds.clear()

    @M("ContextActionService", "GetButton")
    def cas_getbutton(self, name):
        return None

    @M("ContextActionService", "SetTitle")
    def cas_settitle(self, name, title):
        pass

    @M("ContextActionService", "SetImage")
    def cas_setimage(self, name, img):
        pass

    @M("ContextActionService", "SetPosition")
    def cas_setpos(self, name, pos):
        pass

    # ------------------------------------------------------------------ TweenService
    @M("TweenService", "Create")
    def ts_create(self, inst, info, props):
        if not isinstance(inst, Instance):
            raise LuaError("TweenService:Create - Instance expected")
        if not isinstance(info, TweenInfo):
            raise LuaError("TweenService:Create - TweenInfo expected")
        if type(props) is not LuaTable:
            raise LuaError("TweenService:Create - property table expected")
        goals = {}
        for k, v in props.items():
            if k not in inst.cls.all_props():
                raise LuaError(f"TweenService:Create property named '{k}' cannot be tweened due to type mismatch (property is a 'nil', but given type is '{lua_typeof(v)}')")
            t = inst.cls.all_props()[k][0]
            goals[k] = v
        tw = Instance(sim, "Tween")
        tw.extra["target"] = inst
        tw.extra["info"] = info
        tw.extra["goals"] = goals
        tw.extra["state"] = E("PlaybackState", "Begin")
        return tw

    @M("TweenService", "GetValue")
    def ts_getvalue(self, alpha, style, direction):
        return ease(ENUM.types["EasingStyle"].coerce(style), ENUM.types["EasingDirection"].coerce(direction),
                    float(alpha))

    @M("Tween", "Play")
    def tween_play_m(self):
        tween_play(sim, self)

    @M("Tween", "Cancel")
    def tween_cancel(self):
        if self in sim.tweens:
            sim.tweens.remove(self)
        self.extra["state"] = E("PlaybackState", "Cancelled")
        self.get_signal("Completed").fire(E("PlaybackState", "Cancelled"))

    @M("Tween", "Pause")
    def tween_pause(self):
        if self in sim.tweens:
            sim.tweens.remove(self)
        self.extra["state"] = E("PlaybackState", "Paused")

    @G("Tween", "PlaybackState")
    def g_tween_state(self):
        return self.extra.get("state")

    # ------------------------------------------------------------------ HttpService
    @M("HttpService", "GenerateGUID")
    def http_guid(self, wrap=True):
        n = next(sim.http_guid_seq)
        g = str(uuid.UUID(int=(0x5EED << 100) + n * 7919)).upper()
        return "{" + g + "}" if (wrap is None or truthy(wrap)) else g

    @M("HttpService", "JSONEncode")
    def http_json_encode(self, v):
        return json.dumps(to_json(v), separators=(",", ":"))

    @M("HttpService", "JSONDecode")
    def http_json_decode(self, s):
        try:
            return from_json(json.loads(_str(s)))
        except json.JSONDecodeError as e:
            raise LuaError(f"Can't parse JSON: {e}")

    @M("HttpService", "UrlEncode")
    def http_urlenc(self, s):
        import urllib.parse
        return urllib.parse.quote(s)

    @M("HttpService", "GetAsync")
    def http_get(self, url, *a):
        raise LuaError("Http requests are not enabled. Enable via game settings")

    # ------------------------------------------------------------------ DataStoreService
    @M("DataStoreService", "GetDataStore")
    def dss_get(self, name, scope=None, options=None):
        if sim.ctx().kind != "server":
            raise LuaError("DataStore can't be accessed from client")
        ds = Instance(sim, "DataStore")
        ds.extra["name"] = f"{_str(name)}/{scope or 'global'}"
        return ds

    @M("DataStoreService", "GetRequestBudgetForRequestType")
    def dss_budget(self, rt):
        return 60.0

    @M("DataStore", "GetAsync")
    def ds_get(self, key, options=None):
        _ds_maybe_fail(sim)
        sim.sched.wait(0.05)
        raw = sim.datastore_data.get((self.extra["name"], _str(key)))
        return from_json(json.loads(raw)) if raw is not None else None

    @M("DataStore", "SetAsync")
    def ds_set(self, key, value, uids=None, options=None):
        _ds_maybe_fail(sim)
        sim.sched.wait(0.05)
        raw = json.dumps(to_json(value, strict=True))
        if len(raw) > 4_000_000:
            raise LuaError("105: Serialized value exceeds 4MB limit.")
        sim.datastore_data[(self.extra["name"], _str(key))] = raw
        sim.datastore_writes = getattr(sim, "datastore_writes", 0) + 1
        return "v1"

    @M("DataStore", "UpdateAsync")
    def ds_update(self, key, fn):
        _ds_maybe_fail(sim)
        sim.sched.wait(0.05)
        k = (self.extra["name"], _str(key))
        raw = sim.datastore_data.get(k)
        cur = from_json(json.loads(raw)) if raw is not None else None
        r = call(fn, (cur, None))
        nv = r[0] if r else None
        if nv is None:
            return cur
        raw2 = json.dumps(to_json(nv, strict=True))
        if len(raw2) > 4_000_000:
            raise LuaError("105: Serialized value exceeds 4MB limit.")
        sim.datastore_data[k] = raw2
        sim.datastore_writes = getattr(sim, "datastore_writes", 0) + 1
        return (from_json(json.loads(raw2)), None)

    @M("DataStore", "RemoveAsync")
    def ds_remove(self, key):
        _ds_maybe_fail(sim)
        return from_json(json.loads(sim.datastore_data.pop((self.extra["name"], _str(key)), "null")))

    @M("DataStore", "IncrementAsync")
    def ds_inc(self, key, delta=1):
        k = (self.extra["name"], _str(key))
        cur = json.loads(sim.datastore_data.get(k, "0"))
        cur = (cur or 0) + float(delta)
        sim.datastore_data[k] = json.dumps(cur)
        return cur

    # ------------------------------------------------------------------ PhysicsService
    @M("PhysicsService", "RegisterCollisionGroup")
    def ps_register(self, name):
        sim.collision_groups.setdefault(_str(name), set())

    @M("PhysicsService", "CreateCollisionGroup")
    def ps_create(self, name):
        sim.collision_groups.setdefault(_str(name), set())

    @M("PhysicsService", "IsCollisionGroupRegistered")
    def ps_isreg(self, name):
        return _str(name) in sim.collision_groups

    @M("PhysicsService", "CollisionGroupSetCollidable")
    def ps_setcoll(self, a, b, coll):
        a, b = _str(a), _str(b)
        for g in (a, b):
            if g not in sim.collision_groups:
                raise LuaError(f"Collision group '{g}' does not exist")
        key = frozenset((a, b))
        if truthy(coll):
            sim.noncollide.discard(key)
        else:
            sim.noncollide.add(key)

    @M("PhysicsService", "CollisionGroupsAreCollidable")
    def ps_arecoll(self, a, b):
        return frozenset((_str(a), _str(b))) not in sim.noncollide

    @M("PhysicsService", "GetRegisteredCollisionGroups")
    def ps_getreg(self):
        return T(*[D({"name": n}) for n in sim.collision_groups])

    # ------------------------------------------------------------------ TextService
    @M("TextService", "GetTextSize")
    def text_size(self, text, size, font, frame):
        import rbx_layout
        w, h = rbx_layout.measure_text(_str(text), float(size), font_from_any(font),
                                       frame.x if frame else 1e9, wrapped=frame is not None and frame.x < 1e8)
        return Vector2(w, h)

    @M("TextService", "GetTextBoundsAsync")
    def text_bounds(self, params):
        import rbx_layout
        text = params.extra.get("Text", "")
        size = params.extra.get("Size", 14.0)
        font = params.extra.get("Font")
        width = params.extra.get("Width", 1e9)
        w, h = rbx_layout.measure_text(text, size, font, width, wrapped=width < 1e8)
        return Vector2(w, h)

    # ------------------------------------------------------------------ MarketplaceService
    @M("MarketplaceService", "PromptProductPurchase")
    def mps_ppp(self, player, pid, *a):
        pass

    @M("MarketplaceService", "PromptGamePassPurchase")
    def mps_pgpp(self, player, pid):
        pass

    @M("MarketplaceService", "UserOwnsGamePassAsync")
    def mps_uogp(self, uid, pid):
        return False

    @M("MarketplaceService", "GetProductInfo")
    def mps_gpi(self, aid, info=None):
        return D({"Name": "Product", "PriceInRobux": 0})

    # ------------------------------------------------------------------ MessagingService / TeleportService
    @M("MessagingService", "PublishAsync")
    def ms_pub(self, topic, msg):
        pass

    @M("MessagingService", "SubscribeAsync")
    def ms_sub(self, topic, fn):
        return Instance(sim, "Folder")

    # ------------------------------------------------------------------ Remotes
    @M("RemoteEvent", "FireServer")
    def re_fire_server(self, *args):
        ctx = sim.ctx()
        if ctx.kind != "client":
            raise LuaError("FireServer can only be called from the client")
        _remote_deliver(sim, self, "OnServerEvent", (ctx.player,) + _marshal_args(sim, args, "client"), None)

    @M("RemoteEvent", "FireClient")
    def re_fire_client(self, player, *args):
        ctx = sim.ctx()
        if ctx.kind != "server":
            raise LuaError("FireClient can only be called from the server")
        if player is None or not isinstance(player, Instance) or player.cls.name != "Player":
            raise LuaError("FireClient: player argument must be a Player object")
        _remote_deliver(sim, self, "OnClientEvent", _marshal_args(sim, args, "server"), player)

    @M("RemoteEvent", "FireAllClients")
    def re_fire_all(self, *args):
        ctx = sim.ctx()
        if ctx.kind != "server":
            raise LuaError("FireAllClients can only be called from the server")
        margs = _marshal_args(sim, args, "server")
        for c in sim.clients:
            _remote_deliver(sim, self, "OnClientEvent", margs, c.player)

    for cn in ("UnreliableRemoteEvent",):
        sim.methods.setdefault(cn, {}).update({
            "FireServer": sim.methods["RemoteEvent"]["FireServer"],
            "FireClient": sim.methods["RemoteEvent"]["FireClient"],
            "FireAllClients": sim.methods["RemoteEvent"]["FireAllClients"],
        })

    @M("RemoteFunction", "InvokeServer")
    def rf_invoke_server(self, *args):
        ctx = sim.ctx()
        if ctx.kind != "client":
            raise LuaError("InvokeServer can only be called from the client")
        cb = self.extra.get("OnServerInvoke")
        th = STATE.current_thread
        margs = (ctx.player,) + _marshal_args(sim, args, "client")
        if cb is None:
            # Roblox queues until callback assigned; sim: wait a bit
            for _ in range(600):
                sim.sched.wait(1 / 60)
                cb = self.extra.get("OnServerInvoke")
                if cb is not None:
                    break
            if cb is None:
                raise LuaError("RemoteFunction has no OnServerInvoke callback (timed out in sim)")
        result = {}

        def server_side(*_):
            try:
                r = call(cb, margs)
                result["ok"] = True
                result["vals"] = _marshal_args(sim, r, "server")
            except LuaError as e:
                result["ok"] = False
                result["err"] = e.value
                sim.log("error", f"OnServerInvoke error: {e.value}", sim.server_ctx)
            sim.sched.resume_later(th, ())
        # deliver on next frame
        sim.pending_network.append((BuiltinFunction(server_side, "server_invoke"), (), sim.server_ctx))
        thread_yield(())
        while "ok" not in result:
            thread_yield(())
        if not result["ok"]:
            raise LuaError(tostring(result["err"]))
        return tuple(result["vals"])

    @G("RemoteFunction", "OnServerInvoke")
    def g_osi(self):
        raise LuaError("OnServerInvoke is a callback member of RemoteFunction; you can only set the callback value, get is not available")

    @S("RemoteFunction", "OnServerInvoke")
    def s_osi(self, v):
        self.extra["OnServerInvoke"] = v

    @M("BindableEvent", "Fire")
    def be_fire(self, *args):
        self.get_signal("Event").fire(*_marshal_args(sim, args, None, bindable=True))

    @M("BindableFunction", "Invoke")
    def bf_invoke(self, *args):
        cb = self.extra.get("OnInvoke")
        if cb is None:
            raise LuaError("BindableFunction has no OnInvoke callback")
        return call(cb, args)

    @S("BindableFunction", "OnInvoke")
    def s_oninvoke(self, v):
        self.extra["OnInvoke"] = v

    # ------------------------------------------------------------------ Terrain
    import rbx_terrain
    rbx_terrain.install(sim, M, G, S)

    # ------------------------------------------------------------------ GUI absolute props
    import rbx_layout
    rbx_layout.install(sim, M, G, S)


# make Tween / DataStore classes known
from rbx_classes import cls as _cls
_cls("Tween", "Instance", {"PlaybackState": ("ro:Enum:PlaybackState", None)}, "Completed", creatable=False)
_cls("DataStore", "Instance", {}, "", creatable=False)
_cls("TextBoundsParams", "Instance", {}, "", creatable=False)
CLASSES["RemoteFunction"].props["OnServerInvoke"] = ("any", None)
CLASSES["BindableFunction"].props["OnInvoke"] = ("any", None)
CLASSES["RemoteFunction"].props["OnClientInvoke"] = ("any", None)

import itertools
_bind_seq = itertools.count()


def font_from_any(f):
    from rbx_types import font_from_enum
    if isinstance(f, EnumItem):
        return font_from_enum(f)
    return f


def _ds_maybe_fail(sim):
    if sim.datastore_fail > 0:
        sim.datastore_fail -= 1
        raise LuaError("502: API Services rejected request (simulated failure)")
    if getattr(sim, "datastore_disabled", False):
        raise LuaError("Studio access to APIs is not allowed.")


def _cs_add(sim, inst, tag):
    if tag in inst.tags:
        return
    inst.tags.append(tag)
    if inst.in_game():
        sim.fire_tag(tag, "added", inst)


def _cs_remove(sim, inst, tag):
    if tag not in inst.tags:
        return
    inst.tags.remove(tag)
    if inst.in_game():
        sim.fire_tag(tag, "removed", inst)


# =============================================================================== JSON (Roblox semantics)

def to_json(v, strict=False, depth=0):
    if depth > 100:
        raise LuaError("Cannot serialize: nesting too deep")
    if v is None:
        return None
    t = type(v)
    if t is bool or t is str:
        return v
    if t is float or t is int:
        if v != v or v in (math.inf, -math.inf):
            if strict:
                raise LuaError("Cannot store NaN/inf in DataStore")
            return None
        return int(v) if float(v).is_integer() and abs(v) < 2 ** 53 else v
    if t is LuaTable:
        n = len(v.arr)
        has_hash = bool(v.hash)
        if n > 0 and not has_hash:
            return [to_json(x, strict, depth + 1) for x in v.arr]
        if n > 0 and has_hash:
            raise LuaError("Cannot convert mixed or non-array tables: keys must be strings")
        out = {}
        for k, x in v.hash.items():
            if type(k) is not str:
                raise LuaError(f"Cannot convert table with non-string key ({lua_typeof(k)}) to JSON")
            out[k] = to_json(x, strict, depth + 1)
        return out
    raise LuaError(f"Cannot serialize value of type {lua_typeof(v)} to JSON")


def from_json(v):
    if v is None or isinstance(v, (bool, str)):
        return v
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, list):
        t = LuaTable()
        for x in v:
            t.arr.append(from_json(x))
        while t.arr and t.arr[-1] is None:
            t.arr.pop()
        return t
    if isinstance(v, dict):
        t = LuaTable()
        for k, x in v.items():
            if x is not None:
                t.set(k, from_json(x))
        return t
    raise LuaError("bad json")


# =============================================================================== remotes marshalling

def _marshal_args(sim, args, sender, bindable=False):
    return tuple(_marshal(sim, a, 0, bindable) for a in args)


def _marshal(sim, v, depth, bindable=False):
    if depth > 60:
        raise LuaError("Remote argument nesting too deep")
    t = type(v)
    if v is None or t in (bool, float, int, str):
        return v
    if t is LuaTable:
        n = len(v.arr)
        out = LuaTable()
        if n and v.hash:
            # Roblox: mixed tables lose data. Flag loudly.
            sim.log("warn", "Remote/Bindable sent a MIXED table (array + dictionary keys): dictionary keys would be lost in Roblox")
            for x in v.arr:
                out.arr.append(_marshal(sim, x, depth + 1, bindable))
            return out
        for x in v.arr:
            out.arr.append(_marshal(sim, x, depth + 1, bindable))
        for k, x in v.hash.items():
            if type(k) is not str:
                if isinstance(k, (int, float)) and not isinstance(k, bool):
                    sim.log("warn", f"Remote sent a table with sparse/non-sequential numeric key {k}: Roblox converts/drops these")
                    kk = k
                else:
                    kk = tostring(LI._denorm_key(k))
            else:
                kk = k
            out.set(kk, _marshal(sim, x, depth + 1, bindable))
        return out
    if isinstance(v, Instance):
        return v
    if callable(v) and not isinstance(v, LI.UserData):
        if bindable:
            return v
        sim.log("warn", "Remote sent a function value: functions cannot be sent over remotes (arrives as nil)")
        return None
    return v  # datatypes are immutable


def _remote_deliver(sim, remote, event, args, player):
    sig = remote.get_signal(event)

    def deliver(*_):
        if player is None:
            sig.fire(*args, ctx_filter=lambda c: c is not None and c.kind == "server")
        else:
            sig.fire(*args, ctx_filter=lambda c: c is not None and c.kind == "client" and c.player is player)
    sim.pending_network.append((BuiltinFunction(deliver, "deliver"), (), sim.server_ctx))


# =============================================================================== tweens

def tween_play(sim, tw):
    inst = tw.extra["target"]
    info = tw.extra["info"]
    tw.extra["start"] = {k: inst.get_prop(k) for k in tw.extra["goals"]}
    tw.extra["t0"] = sim.sched.clock + info.delay
    tw.extra["state"] = E("PlaybackState", "Playing")
    if tw in sim.tweens:
        sim.tweens.remove(tw)
    if sim.instant_tweens or info.time <= 0:
        for k, v in tw.extra["goals"].items():
            if not inst.destroyed:
                inst.set_prop(k, v, internal=True)
        tw.extra["state"] = E("PlaybackState", "Completed")
        tw.get_signal("Completed").fire(E("PlaybackState", "Completed"))
        return
    sim.tweens.append(tw)


def lerp_value(a, b, t):
    if isinstance(a, (float, int)) and isinstance(b, (float, int)) and not isinstance(a, bool):
        return a + (b - a) * t
    if isinstance(a, Vector3):
        return a.lerp(b, t)
    if isinstance(a, Vector2):
        return Vector2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    if isinstance(a, Color3):
        return Color3(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    if isinstance(a, UDim2):
        return UDim2(a.xs + (b.xs - a.xs) * t, a.xo + (b.xo - a.xo) * t, a.ys + (b.ys - a.ys) * t, a.yo + (b.yo - a.yo) * t)
    if isinstance(a, UDim):
        return UDim(a.scale + (b.scale - a.scale) * t, a.offset + (b.offset - a.offset) * t)
    if isinstance(a, CFrame):
        return a.lerp(b, t)
    if isinstance(a, bool):
        return b if t >= 1 else a
    return b if t >= 1 else a


def update_tweens(sim):
    for tw in list(sim.tweens):
        inst = tw.extra["target"]
        info = tw.extra["info"]
        if inst.destroyed:
            sim.tweens.remove(tw)
            continue
        el = sim.sched.clock - tw.extra["t0"]
        if el < 0:
            continue
        a = min(1.0, el / info.time) if info.time > 0 else 1.0
        k = ease(info.style, info.direction, a)
        for p, goal in tw.extra["goals"].items():
            st = tw.extra["start"][p]
            try:
                inst.set_prop(p, lerp_value(st, goal, k) if a < 1 else goal, internal=True)
            except LuaError:
                pass
        if a >= 1:
            if info.repeat != 0 or info.reverses:
                if info.reverses and not tw.extra.get("reversing"):
                    tw.extra["reversing"] = True
                    tw.extra["start"], tw.extra["goals"] = dict(tw.extra["goals"]), dict(tw.extra["start"])
                    tw.extra["t0"] = sim.sched.clock
                    continue
                if info.repeat != 0:
                    if info.repeat > 0:
                        info_rep = tw.extra.get("reps", 0) + 1
                        tw.extra["reps"] = info_rep
                        if info_rep > info.repeat:
                            sim.tweens.remove(tw)
                            tw.extra["state"] = E("PlaybackState", "Completed")
                            tw.get_signal("Completed").fire(E("PlaybackState", "Completed"))
                            continue
                    if tw.extra.get("reversing"):
                        tw.extra["reversing"] = False
                        tw.extra["start"], tw.extra["goals"] = dict(tw.extra["goals"]), dict(tw.extra["start"])
                    tw.extra["t0"] = sim.sched.clock
                    continue
            sim.tweens.remove(tw)
            tw.extra["state"] = E("PlaybackState", "Completed")
            tw.get_signal("Completed").fire(E("PlaybackState", "Completed"))


# =============================================================================== parts / joints / pivots

def all_parts(sim):
    ws = sim.services["Workspace"]
    return [d for d in ws.descendants() if d.is_a("BasePart") and d.cls.name != "Terrain"]


def all_joints(sim):
    ws = sim.services["Workspace"]
    return [d for d in ws.descendants() if d.is_a("JointInstance") or d.cls.name == "WeldConstraint"]


def invalidate_weld_cache(sim):
    sim.weld_cache = None
    sim.spatial_dirty = True


def _build_weld_cache(sim):
    drive = {}
    for d in sim.game.descendants():
        if d.is_a("JointInstance") or d.cls.name == "WeldConstraint":
            if not d.props.get("Enabled", True):
                continue
            p0 = d.props.get("Part0")
            p1 = d.props.get("Part1")
            if p0 is None or p1 is None or p0 is p1:
                continue
            if d.parent is None:
                continue
            if p1 not in drive:
                drive[p1] = d
    sim.weld_cache = drive
    return drive


def driving_joint(sim, part):
    wc = getattr(sim, "weld_cache", None)
    if wc is None:
        wc = _build_weld_cache(sim)
    return wc.get(part)


def _capture_weld_offset(sim, wc):
    p0 = wc.props.get("Part0")
    p1 = wc.props.get("Part1")
    if p0 is not None and p1 is not None:
        wc.extra["weld_offset"] = part_cframe(sim, p0).inverse().mul(part_cframe(sim, p1))


def part_cframe(sim, part, depth=0):
    own = part.props.get("CFrame") or CFrame()
    if depth > 64 or part.props.get("Anchored"):
        return own
    j = driving_joint(sim, part)
    if j is None:
        return own
    p0 = j.props.get("Part0")
    cf0 = part_cframe(sim, p0, depth + 1)
    if j.cls.name == "WeldConstraint":
        off = j.extra.get("weld_offset")
        if off is None:
            return own
        return cf0.mul(off)
    c0 = j.props.get("C0") or CFrame()
    c1 = j.props.get("C1") or CFrame()
    if j.cls.name == "Motor6D":
        tr = j.props.get("Transform") or CFrame()
        return cf0.mul(c0).mul(tr).mul(c1.inverse())
    return cf0.mul(c0).mul(c1.inverse())


def assembly_root(sim, part, depth=0):
    if part.props.get("Anchored") or depth > 64:
        return part
    j = driving_joint(sim, part)
    if j is None:
        return part
    return assembly_root(sim, j.props.get("Part0"), depth + 1)


def set_part_cframe(sim, part, cf):
    root = assembly_root(sim, part)
    if root is part:
        old = part.props.get("CFrame")
        part.props["CFrame"] = cf
        if part.props.get("Anchored"):
            sim.spatial_dirty = True
        if old is None or not old.lua_eq(cf):
            part.changed("CFrame")
        return
    cur = part_cframe(sim, part)
    rcf = part_cframe(sim, root)
    rel = rcf.inverse().mul(cur)
    root.props["CFrame"] = cf.mul(rel.inverse())
    if root.props.get("Anchored"):
        sim.spatial_dirty = True
    root.changed("CFrame")


def get_pivot(sim, inst):
    if inst.is_a("BasePart"):
        return part_cframe(sim, inst).mul(inst.get_prop("PivotOffset"))
    if inst.is_a("Model"):
        pp = inst.props.get("PrimaryPart")
        if pp is not None:
            return part_cframe(sim, pp).mul(pp.get_prop("PivotOffset"))
        return inst.props.get("WorldPivot") or bounding_box(sim, inst)[0]
    raise LuaError("GetPivot on non-PVInstance")


def pivot_to(sim, inst, cf):
    if inst.is_a("BasePart"):
        set_part_cframe(sim, inst, cf.mul(inst.get_prop("PivotOffset").inverse()))
        return
    cur = get_pivot(sim, inst)
    delta = cf.mul(cur.inverse())
    parts = [d for d in inst.descendants() if d.is_a("BasePart")]
    roots = []
    for p in parts:
        r = assembly_root(sim, p)
        if r is p:
            roots.append(p)
    from rbx_types import _cf_ortho
    for p in roots:
        # Roblox keeps part CFrames orthonormal; without this, repeated
        # PivotTo calls accumulate drift until the rotation degenerates
        p.props["CFrame"] = _cf_ortho(delta.mul(part_cframe(sim, p)))
        p.changed("CFrame")
    if inst.props.get("PrimaryPart") is None:
        inst.props["WorldPivot"] = cf
    sim.spatial_dirty = True


def bounding_box(sim, model):
    parts = [d for d in model.descendants() if d.is_a("BasePart")]
    if not parts:
        return (CFrame(), Vector3())
    pp = model.props.get("PrimaryPart")
    ori = part_cframe(sim, pp) if pp is not None else CFrame()
    ori = CFrame((0, 0, 0), ori.r)
    inv = ori.inverse()
    mn = [math.inf] * 3
    mx = [-math.inf] * 3
    for p in parts:
        cf = part_cframe(sim, p)
        s = p.get_prop("Size")
        for sx in (-0.5, 0.5):
            for sy in (-0.5, 0.5):
                for sz in (-0.5, 0.5):
                    w = cf.point_to_world(Vector3(s.x * sx, s.y * sy, s.z * sz))
                    l = inv.point_to_world(w)
                    for i, c in enumerate((l.x, l.y, l.z)):
                        mn[i] = min(mn[i], c)
                        mx[i] = max(mx[i], c)
    center = ori.point_to_world(Vector3((mn[0] + mx[0]) / 2, (mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2))
    return (CFrame(center.tup(), ori.r), Vector3(mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]))


def _att_cf(att):
    return att.props.get("CFrame") or CFrame()


def attachment_world_cf(sim, att):
    p = att.parent
    cf = _att_cf(att)
    if att.cls.name == "Bone":
        cf = cf.mul(att.props.get("Transform") or CFrame())
    if p is not None and p.is_a("BasePart"):
        return part_cframe(sim, p).mul(cf)
    if p is not None and p.cls.name in ("Attachment", "Bone"):
        return attachment_world_cf(sim, p).mul(cf)
    return cf


# =============================================================================== seats

def seat_humanoid(sim, seat, humanoid):
    if humanoid is None or humanoid.cls.name != "Humanoid":
        raise LuaError("Seat:Sit expects a Humanoid")
    if seat.props.get("Disabled"):
        return
    if seat.props.get("Occupant") is not None:
        return
    if humanoid.props.get("SeatPart") is not None:
        unseat(sim, humanoid)
    ch = humanoid.parent
    hrp = ch.find_child("HumanoidRootPart") if ch is not None else None
    if hrp is None:
        return
    w = Instance(sim, "Weld")
    w.props["Name"] = "SeatWeld"
    w.props["Part0"] = seat
    w.props["Part1"] = hrp
    w.props["C0"] = CFrame((0, seat.get_prop("Size").y / 2, 0))
    w.props["C1"] = CFrame((0, -1.5, 0))
    w.set_parent(seat)
    invalidate_weld_cache(sim)
    seat.props["Occupant"] = humanoid
    humanoid.props["SeatPart"] = seat
    humanoid.props["Sit"] = True
    humanoid.extra["state"] = E("HumanoidStateType", "Seated")
    seat.changed("Occupant")
    humanoid.changed("SeatPart")
    humanoid.changed("Sit")
    humanoid.get_signal("Seated").fire(True, seat)


def unseat(sim, humanoid):
    seat = humanoid.props.get("SeatPart")
    if seat is None:
        return
    for c in list(seat.children):
        if c.Name == "SeatWeld":
            c.destroy()
    invalidate_weld_cache(sim)
    seat.props["Occupant"] = None
    humanoid.props["SeatPart"] = None
    humanoid.props["Sit"] = False
    humanoid.extra["state"] = E("HumanoidStateType", "Running")
    seat.changed("Occupant")
    humanoid.changed("SeatPart")
    humanoid.changed("Sit")
    humanoid.get_signal("Seated").fire(False, None)


# =============================================================================== raycast

def _passes_filter(sim, part, params):
    if params is None:
        return True
    lst = params.FilterDescendantsInstances.arr
    inside = False
    for f in lst:
        if f is part or (isinstance(f, Instance) and part.is_descendant_of(f)):
            inside = True
            break
    if params.FilterType.name in ("Exclude", "Blacklist"):
        if inside:
            return False
    else:
        if not inside:
            return False
    g = part.props.get("CollisionGroup", "Default")
    if params.CollisionGroup and frozenset((g, params.CollisionGroup)) in sim.noncollide:
        return False
    if getattr(params, "RespectCanCollide", False) and not part.props.get("CanCollide", True):
        return False
    return True


def _ray_obb(origin, d, cf, size, radius):
    inv = cf.inverse()
    o = inv.point_to_world(origin)
    dd = inv.vector_to_world(d)
    tmin, tmax = -math.inf, math.inf
    half = (size.x / 2 + radius, size.y / 2 + radius, size.z / 2 + radius)
    oc = (o.x, o.y, o.z)
    dc = (dd.x, dd.y, dd.z)
    nidx = -1
    nsign = 0
    for i in range(3):
        if abs(dc[i]) < 1e-12:
            if oc[i] < -half[i] or oc[i] > half[i]:
                return None
            continue
        t1 = (-half[i] - oc[i]) / dc[i]
        t2 = (half[i] - oc[i]) / dc[i]
        s = -1
        if t1 > t2:
            t1, t2 = t2, t1
            s = 1
        if t1 > tmin:
            tmin = t1
            nidx = i
            nsign = s
        tmax = min(tmax, t2)
        if tmin > tmax:
            return None
    if tmax < 0:
        return None
    t = tmin if tmin >= 0 else 0.0
    if nidx < 0:
        return (t, Vector3(0, 1, 0))
    nl = [0.0, 0.0, 0.0]
    nl[nidx] = float(nsign)
    n = cf.vector_to_world(Vector3(*nl))
    return (t, n)


def _ray_sphere(origin, d, center, r):
    oc = origin - center
    b = oc.dot(d)
    c = oc.dot(oc) - r * r
    disc = b * b - c
    if disc < 0:
        return None
    t = -b - math.sqrt(disc)
    if t < 0:
        t = -b + math.sqrt(disc)
        if t < 0:
            return None
    hit = origin + d.scale(t)
    return (t, (hit - center).unit())


def raycast(sim, origin, direction, params, radius):
    if not isinstance(origin, Vector3) or not isinstance(direction, Vector3):
        raise LuaError("Raycast expects Vector3 origin and direction")
    length = direction.mag()
    if length == 0:
        return None
    d = direction.scale(1 / length)
    best = None
    import rbx_spatial
    for p in rbx_spatial.candidates(sim, origin, d, length, radius):
        if not p.props.get("CanQuery", True):
            continue
        if not _passes_filter(sim, p, params):
            continue
        cf = part_cframe(sim, p)
        size = p.get_prop("Size")
        shape = p.props.get("Shape")
        if p.cls.name == "Part" and shape is not None and shape.name == "Ball":
            r = _ray_sphere(origin, d, cf.pos(), size.x / 2 + radius)
        else:
            r = _ray_obb(origin, d, cf, size, radius)
        if r is None:
            continue
        t, n = r
        if t <= length and (best is None or t < best[0]):
            best = (t, n, p)
    # terrain
    import rbx_terrain
    tr = rbx_terrain.raycast(sim, origin, d, length if best is None else best[0], params, radius)
    if tr is not None:
        t, n, mat = tr
        if best is None or t < best[0]:
            # shape casts report the contact point on the surface (center - n*r)
            return RaycastResult(sim.terrain, origin + d.scale(t) - n.scale(radius), n, mat, t)
    if best is None:
        return None
    t, n, p = best
    return RaycastResult(p, origin + d.scale(t) - n.scale(radius), n, p.get_prop("Material"), t)


# =============================================================================== camera projection

def world_to_viewport(sim, cam, pos):
    cf = cam.get_prop("CFrame")
    vp = g_viewport_for(sim, cam)
    fov = math.radians(cam.get_prop("FieldOfView"))
    loc = cf.point_to_object(pos)
    if loc.z >= 0:
        on = False
    else:
        on = True
    z = -loc.z
    if abs(z) < 1e-6:
        z = 1e-6
    f = (vp[1] / 2) / math.tan(fov / 2)
    x = vp[0] / 2 + loc.x / z * f
    y = vp[1] / 2 - loc.y / z * f
    on = on and 0 <= x <= vp[0] and 0 <= y <= vp[1]
    return (Vector3(x, y, z), on)


def g_viewport_for(sim, cam):
    for c in sim.clients:
        if c.camera is cam:
            return c.device.viewport
    return (1920, 1080)


def viewport_ray(sim, cam, x, y):
    from rbx_types import Ray
    cf = cam.get_prop("CFrame")
    vp = g_viewport_for(sim, cam)
    fov = math.radians(cam.get_prop("FieldOfView"))
    f = (vp[1] / 2) / math.tan(fov / 2)
    dx = (x - vp[0] / 2) / f
    dy = -(y - vp[1] / 2) / f
    d = cf.vector_to_world(Vector3(dx, dy, -1)).unit()
    return Ray(cf.pos(), d)


# =============================================================================== CAS / input

def _cas_bind(sim, name, fn, inputs, priority):
    ctx = sim.ctx()
    ctx.cas_binds[name] = {"fn": fn, "inputs": [i for i in inputs if i is not None], "priority": priority,
                           "ctx": ctx}


def input_object(sim, kind, keycode=None, state="Begin", pos=None, delta=None):
    io = Instance(sim, "InputObject")
    io.props["UserInputType"] = E("UserInputType", kind)
    io.props["KeyCode"] = E("KeyCode", keycode or "Unknown")
    io.props["UserInputState"] = E("UserInputState", state)
    io.props["Position"] = pos or Vector3()
    io.props["Delta"] = delta or Vector3()
    return io


_cls("InputObject", "Instance", {"UserInputType": ("Enum:UserInputType", None), "KeyCode": ("Enum:KeyCode", None),
                                 "UserInputState": ("Enum:UserInputState", None), "Position": ("V3", None),
                                 "Delta": ("V3", None)}, "", creatable=False)


def dispatch_input(sim, client, io, began=True, game_processed=False):
    """CAS first (by priority), then UIS events."""
    kc = io.props["KeyCode"]
    uit = io.props["UserInputType"]
    state = io.props["UserInputState"]
    binds = sorted(client.cas_binds.items(), key=lambda kv: -kv[1]["priority"])
    sunk = False
    for name, b in binds:
        matched = any((isinstance(i, EnumItem) and (i is kc or i is uit)) for i in b["inputs"])
        if not matched:
            continue
        th = LuaThread(b["fn"], context=client)
        r = LI.thread_resume(th, (name, state, io))
        if not r[0]:
            sim.report_error(th, r[1][0] if r[1] else "error")
            continue
        res = r[1][0] if r[1] else None
        if res is None or (isinstance(res, EnumItem) and res.name == "Sink"):
            sunk = True
            break
    uis = sim.services["UserInputService"]
    ev = {"Begin": "InputBegan", "End": "InputEnded", "Change": "InputChanged"}.get(state.name, "InputChanged")
    uis.get_signal(ev).fire(io, game_processed, ctx_filter=lambda c: c is client)
    sim.sched.run_deferred()
    return sunk


# =============================================================================== players

def build_character(sim, player):
    ch = Instance(sim, "Model")
    ch.props["Name"] = player.Name
    hrp = Instance(sim, "Part")
    hrp.props.update(Name="HumanoidRootPart", Size=Vector3(2, 2, 1), Transparency=1.0, CanCollide=False)
    spawn = None
    for d in sim.services["Workspace"].descendants():
        if d.cls.name == "SpawnLocation":
            spawn = d
            break
    pos = part_cframe(sim, spawn).pos() + Vector3(0, 4, 0) if spawn is not None else Vector3(0, 10, 0)
    hrp.props["CFrame"] = CFrame(pos.tup())
    hrp.set_parent(ch)
    head = Instance(sim, "Part")
    head.props.update(Name="Head", Size=Vector3(2, 1, 1))
    head.props["CFrame"] = CFrame((pos.x, pos.y + 1.5, pos.z))
    head.set_parent(ch)
    torso = Instance(sim, "Part")
    torso.props.update(Name="UpperTorso", Size=Vector3(2, 2, 1))
    torso.props["CFrame"] = CFrame(pos.tup())
    torso.set_parent(ch)
    for p, c0 in ((head, CFrame((0, 1.5, 0))), (torso, CFrame())):
        m = Instance(sim, "Motor6D")
        m.props.update(Name="Joint_" + p.Name, Part0=hrp, Part1=p, C0=c0)
        m.set_parent(hrp)
    hum = Instance(sim, "Humanoid")
    hum.props["Name"] = "Humanoid"
    hum.set_parent(ch)
    an = Instance(sim, "Animator")
    an.set_parent(hum)
    ch.props["PrimaryPart"] = hrp
    return ch


def spawn_character(sim, player):
    old = player.props.get("Character")
    if old is not None:
        player.get_signal("CharacterRemoving").fire(old)
        old.destroy()
    ch = build_character(sim, player)
    ch.set_parent(sim.services["Workspace"])
    player.set_prop("Character", ch)
    invalidate_weld_cache(sim)
    player.get_signal("CharacterAdded").fire(ch)
    sim.sched.run_deferred()
    # StarterCharacterScripts
    scs = sim.services["StarterPlayer"].find_child("StarterCharacterScripts")
    client = player.extra.get("ctx")
    if scs is not None and client is not None:
        for s in scs.children:
            c = s.clone()
            if c is not None:
                c.set_parent(ch)
                if c.cls.name == "LocalScript":
                    sim.run_script(c, client)
    return ch


def add_player(sim, name, user_id, device, spawn_char):
    players = sim.services["Players"]
    p = Instance(sim, "Player")
    p.props["Name"] = name
    p.props["UserId"] = float(user_id)
    p.props["DisplayName"] = name
    client = Context(sim, "client", p, device)
    client.name = f"Client({name})"
    p.extra["ctx"] = client
    cam = Instance(sim, "Camera")
    cam.props["Name"] = "Camera"
    client.camera = cam
    sim.clients.append(client)
    client.globals = sim.make_base_globals(client)
    pg = Instance(sim, "PlayerGui")
    pg.props["Name"] = "PlayerGui"
    pg.set_parent(p)
    ps = Instance(sim, "PlayerScripts")
    ps.props["Name"] = "PlayerScripts"
    ps.set_parent(p)
    bp = Instance(sim, "Backpack")
    bp.props["Name"] = "Backpack"
    bp.set_parent(p)
    p.set_parent(players)
    players.get_signal("PlayerAdded").fire(p)
    sim.sched.run_deferred()
    # ReplicatedFirst local scripts
    for d in sim.services["ReplicatedFirst"].descendants():
        if d.cls.name == "LocalScript" and not d.props.get("Disabled"):
            sim.run_script(d, client)
    # StarterGui -> PlayerGui
    for g in sim.services["StarterGui"].children:
        c = g.clone()
        if c is not None:
            c.set_parent(pg)
    for d in pg.descendants():
        if d.cls.name == "LocalScript" and not d.props.get("Disabled"):
            sim.run_script(d, client)
    # StarterPlayerScripts
    sps = sim.services["StarterPlayer"].find_child("StarterPlayerScripts")
    if sps is not None:
        for s in sps.children:
            c = s.clone()
            if c is not None:
                c.set_parent(ps)
        for d in ps.descendants():
            if d.cls.name == "LocalScript" and not d.props.get("Disabled"):
                sim.run_script(d, client)
    if spawn_char and sim.services["Players"].get_prop("CharacterAutoLoads"):
        spawn_character(sim, p)
    sim.sched.run_deferred()
    return p


def remove_player(sim, player):
    players = sim.services["Players"]
    if player.parent is not players:
        return
    players.get_signal("PlayerRemoving").fire(player)
    sim.sched.run_deferred()
    ch = player.props.get("Character")
    if ch is not None:
        ch.destroy()
    client = player.extra.get("ctx")
    if client in sim.clients:
        sim.clients.remove(client)
    # kill client threads
    player.set_parent(None)
    sim.sched.run_deferred()


def shutdown(sim):
    """Simulate server shutdown: BindToClose callbacks."""
    for fn, ctx in getattr(sim, "close_callbacks", []):
        th = sim.sched.spawn(fn, (), ctx)
    for _ in range(60 * 30):
        if not any(th for th in [] if True):
            pass
        step_frame(sim, 1 / 60)


# =============================================================================== frame step

def step_frame(sim, dt):
    sched = sim.sched
    sim.frame += 1
    rs = sim.services["RunService"]
    sched.run_deferred()
    # network delivery (queued last frame)
    pend = sim.pending_network
    sim.pending_network = []
    for fn, args, ctx in pend:
        sched.spawn(fn, args, ctx)
        sched.run_deferred()
    # clients: render step
    for c in list(sim.clients):
        binds = sorted(c.render_binds.values(), key=lambda b: (b[0], b[2]))
        for pri, fn, _ in binds:
            th = LuaThread(fn, context=c)
            r = LI.thread_resume(th, (dt,))
            if not r[0]:
                sim.report_error(th, r[1][0] if r[1] else "error")
        rs.get_signal("RenderStepped").fire(dt, ctx_filter=lambda x, c=c: x is c)
        rs.get_signal("PreRender").fire(dt, ctx_filter=lambda x, c=c: x is c)
        sched.run_deferred()
    for c in [sim.server_ctx] + list(sim.clients):
        rs.get_signal("PreAnimation").fire(dt, ctx_filter=lambda x, c=c: x is c)
    sched.run_deferred()
    for c in [sim.server_ctx] + list(sim.clients):
        rs.get_signal("Stepped").fire(sched.clock, dt, ctx_filter=lambda x, c=c: x is c)
        rs.get_signal("PreSimulation").fire(dt, ctx_filter=lambda x, c=c: x is c)
    sched.run_deferred()
    # physics
    if sim.physics is not None:
        sim.physics(sim, dt)
    sched.advance(sched.clock + dt)
    for c in [sim.server_ctx] + list(sim.clients):
        rs.get_signal("PostSimulation").fire(dt, ctx_filter=lambda x, c=c: x is c)
        rs.get_signal("Heartbeat").fire(dt, ctx_filter=lambda x, c=c: x is c)
    sched.run_deferred()
    update_tweens(sim)
    sched.run_deferred()
    # prompts + layout
    import rbx_prompts
    rbx_prompts.update(sim, dt)
    import rbx_layout
    for c in list(sim.clients):
        rbx_layout.ensure_layout(sim, c, fire_signals=True)
    sched.run_deferred()


_get_pivot_impl = get_pivot
_pivot_to_impl = pivot_to
