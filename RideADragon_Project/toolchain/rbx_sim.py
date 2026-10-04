"""Roblox engine simulator: Instance tree, signals, task scheduler, services,
server/client contexts in one DataModel, remotes, DataStore mock."""
import heapq
import itertools
import json
import math
import os
import re
import sys
import time as _time
import uuid
import traceback
from collections import deque

import greenlet

import luau_interp as LI
from luau_interp import (UserData, LuaError, LuaTable, LuaFunction, BuiltinFunction, LuaThread,
                         tostring, lua_typeof, lua_type, call, truthy, eq, STATE, thread_resume,
                         thread_yield, create_globals, load, fmt_number)
from rbx_types import (Vector3, Vector2, CFrame, Color3, UDim, UDim2, Rect, NumberRange,
                       NumberSequence, ColorSequence, TweenInfo, Font, EnumItem, EnumType, ENUM, E,
                       RaycastParams, OverlapParams, RaycastResult, BrickColor, PhysicalProperties,
                       install_datatypes, ease, font_from_enum, _fn, IDENT)
from rbx_classes import CLASSES, is_a

DEG = math.pi / 180


class SimFatal(Exception):
    is_sim_fatal = True


# =============================================================================== contexts

class Device:
    def __init__(self, viewport=(1920, 1080), touch=False, keyboard=True, mouse=True, gamepad=False,
                 topbar=(0, 0, 320, 58), name="Desktop"):
        self.viewport = viewport
        self.touch = touch
        self.keyboard = keyboard
        self.mouse = mouse
        self.gamepad = gamepad
        self.topbar = topbar
        self.name = name


class Context:
    def __init__(self, sim, kind, player=None, device=None):
        self.sim = sim
        self.kind = kind  # "server" | "client"
        self.player = player
        self.device = device
        self.modules = {}
        self.globals = None
        self.shared = LuaTable()
        self.G = None
        self.render_binds = {}  # name -> (priority, fn)
        self.cas_binds = {}  # name -> dict
        self.keys_down = set()
        self.mouse_pos = Vector2(0, 0)
        self.mouse_delta = Vector2(0, 0)
        self.last_input = E("UserInputType", "MouseMovement")
        self.camera = None
        self.focused_textbox = None
        self.mouse_buttons = set()
        self.hovered = []
        self.layout_dirty = True
        self.name = "Server" if kind == "server" else f"Client({player.props.get('Name') if player else '?'})"

    def __repr__(self):
        return self.name


# =============================================================================== signals

class Connection(UserData):
    __slots__ = ("signal", "fn", "ctx", "connected", "once")

    def __init__(self, signal, fn, ctx, once=False):
        self.signal = signal
        self.fn = fn
        self.ctx = ctx
        self.connected = True
        self.once = once

    def lua_index(self, key):
        if key == "Connected":
            return self.connected
        if key == "Disconnect" or key == "disconnect":
            return _fn("Disconnect", lambda s: s.disconnect())
        raise LuaError(f"{key} is not a valid member of RBXScriptConnection")

    def disconnect(self):
        if self.connected:
            self.connected = False
            try:
                self.signal.conns.remove(self)
            except ValueError:
                pass
        return ()

    def lua_typeof(self):
        return "RBXScriptConnection"


class Signal(UserData):
    __slots__ = ("sim", "name", "conns", "waiting", "client_only", "server_only", "owner")

    def __init__(self, sim, name, owner=None, client_only=False, server_only=False):
        self.sim = sim
        self.name = name
        self.conns = []
        self.waiting = []
        self.client_only = client_only
        self.server_only = server_only
        self.owner = owner

    def lua_index(self, key):
        if key in ("Connect", "connect", "ConnectParallel"):
            return _fn("Connect", self._connect)
        if key == "Once":
            return _fn("Once", lambda s, fn: s._connect(s, fn, True))
        if key == "Wait" or key == "wait":
            return _fn("Wait", self._wait)
        raise LuaError(f"{key} is not a valid member of RBXScriptSignal")

    def _connect(self, s, fn, once=False):
        if fn is None or not (callable(fn)):
            raise LuaError("Attempt to connect failed: Passed value is not a function")
        ctx = self.sim.ctx()
        if self.client_only and ctx is not None and ctx.kind != "client":
            raise LuaError(f"{self.name} event can only be used from local scripts")
        c = Connection(self, fn, ctx, once)
        self.conns.append(c)
        return c

    def _wait(self, s):
        th = STATE.current_thread
        if th is None or th.is_main:
            raise LuaError("Wait called outside of a coroutine")
        self.waiting.append((th, self.sim.ctx()))
        r = thread_yield(())
        return r

    def fire(self, *args, ctx_filter=None):
        sim = self.sim
        for c in list(self.conns):
            if not c.connected:
                continue
            if ctx_filter is not None and not ctx_filter(c.ctx):
                continue
            if c.once:
                c.disconnect()
            sim.dispatch(c.fn, args, c.ctx)
        if self.waiting:
            ws = self.waiting
            self.waiting = []
            for th, ctx in ws:
                if ctx_filter is not None and not ctx_filter(ctx):
                    self.waiting.append((th, ctx))
                    continue
                sim.sched.resume_later(th, args)

    def disconnect_all(self):
        for c in list(self.conns):
            c.connected = False
        self.conns.clear()

    def lua_typeof(self):
        return "RBXScriptSignal"

    def lua_tostring(self):
        return "Signal " + self.name


# =============================================================================== Instance

_uid_counter = itertools.count(1)

GUI_LAYOUT_PROPS = {
    "Size", "Position", "AnchorPoint", "Visible", "Parent", "AutomaticSize", "SizeConstraint",
    "Text", "TextSize", "TextScaled", "TextWrapped", "Font", "FontFace", "RichText", "Rotation",
    "CanvasSize", "CanvasPosition", "AutomaticCanvasSize", "LayoutOrder", "Name", "Scale",
    "AspectRatio", "AspectType", "DominantAxis", "MinSize", "MaxSize", "MaxTextSize", "MinTextSize",
    "Padding", "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight", "FillDirection",
    "HorizontalAlignment", "VerticalAlignment", "SortOrder", "CellSize", "CellPadding",
    "FillDirectionMaxCells", "StartCorner", "Enabled", "IgnoreGuiInset", "ScreenInsets",
    "ScrollBarThickness", "VerticalScrollBarInset", "ScrollingDirection", "Thickness", "LineHeight",
    "Wraps", "DisplayOrder", "ClipsDescendants", "TextTruncate", "MaxVisibleGraphemes",
}


class Instance(UserData):
    __slots__ = ("cls", "props", "children", "parent", "attrs", "tags", "signals", "destroyed", "sim",
                 "uid", "abs_pos", "abs_size", "abs_rot", "extra", "parent_locked", "__weakref__")

    def __init__(self, sim, class_name):
        ci = CLASSES.get(class_name)
        if ci is None:
            raise LuaError(f"Unable to create an Instance of type \"{class_name}\"")
        self.cls = ci
        self.sim = sim
        self.props = {}
        self.children = []
        self.parent = None
        self.attrs = {}
        self.tags = []
        self.signals = {}
        self.destroyed = False
        self.parent_locked = False
        self.uid = next(_uid_counter)
        self.abs_pos = None
        self.abs_size = None
        self.abs_rot = 0.0
        self.extra = {}

    # ----------------------------------------------------------- basics
    @property
    def ClassName(self):
        return self.cls.name

    @property
    def Name(self):
        n = self.props.get("Name")
        return n if n is not None else self.cls.name

    def is_a(self, name):
        return name in self.cls.ancestors()

    def full_name(self):
        parts = []
        x = self
        while x is not None and x.cls.name != "DataModel":
            parts.append(x.Name)
            x = x.parent
        return ".".join(reversed(parts))

    def lua_typeof(self):
        return "Instance"

    def lua_tostring(self):
        return self.Name

    def __repr__(self):
        return f"<{self.cls.name} {self.full_name()}>"

    def descendants(self):
        out = []
        stack = list(reversed(self.children))
        while stack:
            c = stack.pop()
            out.append(c)
            stack.extend(reversed(c.children))
        return out

    def is_descendant_of(self, other):
        p = self.parent
        while p is not None:
            if p is other:
                return True
            p = p.parent
        return False

    def in_game(self):
        p = self
        while p is not None:
            if p.cls.name == "DataModel":
                return True
            p = p.parent
        return False

    def find_child(self, name):
        for c in self.children:
            if c.Name == name:
                return c
        return None

    # ----------------------------------------------------------- lua access
    def lua_index(self, key):
        if type(key) is not str:
            raise LuaError(f"invalid key type for Instance index ({lua_typeof(key)})")
        props = self.cls.all_props()
        if key in props:
            return self.get_prop(key)
        m = self.sim.find_method(self.cls, key)
        if m is not None:
            return m
        if key in self.cls.all_events():
            return self.get_signal(key)
        c = self.find_child(key)
        if c is not None:
            return c
        raise LuaError(f"{key} is not a valid member of {self.cls.name} \"{self.full_name()}\"")

    def lua_newindex(self, key, value):
        if type(key) is not str:
            raise LuaError("invalid key")
        props = self.cls.all_props()
        if key not in props:
            if key in self.cls.all_events() or self.sim.find_method(self.cls, key) is not None:
                raise LuaError(f"{key} cannot be assigned to")
            raise LuaError(f"{key} is not a valid member of {self.cls.name} \"{self.full_name()}\"")
        self.set_prop(key, value)

    def lua_eq(self, o):
        return self is o

    def get_signal(self, name):
        s = self.signals.get(name)
        if s is None:
            client_only = False
            s = Signal(self.sim, name, self, client_only=client_only)
            self.signals[name] = s
        return s

    # ----------------------------------------------------------- properties
    def get_prop(self, key):
        g = self.sim.special_get(self, key)
        if g is not NOTSET:
            return g
        if key in self.props:
            return self.props[key]
        t, d = self.cls.all_props()[key]
        if key == "Name":
            return self.cls.name
        if key == "ClassName":
            return self.cls.name
        if key == "Parent":
            return self.parent
        if key == "FontFace" and d is None:
            return font_from_enum(self.get_prop("Font"))
        return d

    def set_prop(self, key, value, internal=False):
        ci = self.cls
        if not internal and ci.is_ro(key):
            raise LuaError(f"Unable to assign property {key}. Property is read only")
        t, _ = ci.all_props()[key]
        value = coerce_prop(self, key, t, value)
        sp = self.sim.special_set(self, key, value)
        if sp is not NOTSET:
            return
        old = self.get_prop(key) if key in self.props or True else None
        self.props[key] = value
        if key == "Font":
            self.props["FontFace"] = font_from_enum(value)
        elif key == "FontFace":
            pass
        if not _same(old, value):
            self.changed(key)

    def changed(self, key):
        sim = self.sim
        if key in GUI_LAYOUT_PROPS and (self.is_a("GuiBase2d") or self.is_a("UIComponent")):
            sim.mark_layout_dirty(self)
        s = self.signals.get("Changed")
        if s is not None and s.conns:
            s.fire(key)
        s2 = self.signals.get("prop:" + key)
        if s2 is not None:
            s2.fire()
        sim.on_prop_changed(self, key)

    # ----------------------------------------------------------- hierarchy
    def set_parent(self, new_parent):
        if self.parent_locked:
            raise LuaError(f"The Parent property of {self.full_name()} is locked, current parent: NULL, new parent {new_parent.Name if new_parent else 'NULL'}")
        if new_parent is not None and not isinstance(new_parent, Instance):
            raise LuaError("Parent must be an Instance or nil")
        if new_parent is self:
            raise LuaError(f"Attempt to set {self.full_name()} as its own parent")
        if new_parent is not None and new_parent.is_descendant_of(self):
            raise LuaError(f"Attempt to set parent of {self.full_name()} to {new_parent.full_name()} would result in circular reference")
        old = self.parent
        if old is new_parent:
            return
        sim = self.sim
        was_in_game = self.in_game()
        if old is not None:
            # DescendantRemoving fires before removal
            desc = [self] + self.descendants()
            a = old
            while a is not None:
                s = a.signals.get("DescendantRemoving")
                if s is not None and s.conns:
                    for d in desc:
                        s.fire(d)
                a = a.parent
            old.children.remove(self)
            s = old.signals.get("ChildRemoved")
            if s is not None:
                s.fire(self)
        self.parent = new_parent
        if new_parent is not None:
            new_parent.children.append(self)
            s = new_parent.signals.get("ChildAdded")
            if s is not None:
                s.fire(self)
            desc = [self] + self.descendants()
            a = new_parent
            while a is not None:
                s = a.signals.get("DescendantAdded")
                if s is not None and s.conns:
                    for d in desc:
                        s.fire(d)
                a = a.parent
        for d in [self] + self.descendants():
            s = d.signals.get("AncestryChanged")
            if s is not None:
                s.fire(self, new_parent)
        s = self.signals.get("Changed")
        if s is not None:
            s.fire("Parent")
        s2 = self.signals.get("prop:Parent")
        if s2 is not None:
            s2.fire()
        now_in_game = self.in_game()
        sim.on_reparent(self, old, new_parent, was_in_game, now_in_game)

    def destroy(self):
        if self.destroyed:
            return
        s = self.signals.get("Destroying")
        if s is not None:
            s.fire()
        for c in list(self.children):
            c.destroy()
        if self.parent is not None:
            self.set_parent(None)
        self.destroyed = True
        self.parent_locked = True
        for sig in self.signals.values():
            sig.disconnect_all()
        self.sim.on_destroy(self)

    def clone(self, mapping=None, root=True):
        if not self.props.get("Archivable", True):
            return None
        if mapping is None:
            mapping = {}
        c = Instance(self.sim, self.cls.name)
        c.props = dict(self.props)
        c.props.pop("Parent", None)
        c.attrs = dict(self.attrs)
        c.tags = list(self.tags)
        c.extra = {k: v for k, v in self.extra.items() if k in ("weld_offset", "source_path")}
        mapping[self] = c
        for ch in self.children:
            cc = ch.clone(mapping, False)
            if cc is not None:
                cc.parent = c
                c.children.append(cc)
        if root:
            # remap references
            for orig, cl in mapping.items():
                for k, v in list(cl.props.items()):
                    if isinstance(v, Instance) and v in mapping:
                        cl.props[k] = mapping[v]
        return c


class _NotSet:
    pass


NOTSET = _NotSet()


def _same(a, b):
    if a is b:
        return True
    try:
        return eq(a, b)
    except Exception:
        return False


def coerce_prop(inst, key, t, value):
    opt = t.endswith("?")
    tt = t[:-1] if opt else t
    if value is None:
        if opt or tt in ("any", "Inst", "BrickColor", "Font"):
            if tt in ("BrickColor", "Font") and not opt:
                raise LuaError(f"Unable to assign property {key}. {tt} expected, got nil")
            return None
        raise LuaError(f"Unable to assign property {key}. {_tname(tt)} expected, got nil")
    tv = type(value)
    if tt == "bool":
        if tv is bool:
            return value
        raise LuaError(f"Unable to assign property {key}. bool expected, got {lua_typeof(value)}")
    if tt == "num" or tt == "int":
        if tv is float or tv is int:
            v = float(value)
            if tt == "int":
                if v != v or v in (math.inf, -math.inf):
                    return 0.0
                v = float(int(v))
            return v
        if tv is str:
            n = LI.tonumber(value)
            if n is not None:
                return float(n)
        raise LuaError(f"Unable to assign property {key}. number expected, got {lua_typeof(value)}")
    if tt == "str":
        if tv is str:
            return value
        if tv is float or tv is int:
            return fmt_number(value)
        raise LuaError(f"Unable to assign property {key}. string expected, got {lua_typeof(value)}")
    if tt.startswith("Enum:"):
        en = tt[5:]
        et = ENUM.types.get(en)
        if et is None:
            return value
        return et.coerce(value)
    checks = {"V3": Vector3, "V2": Vector2, "CF": CFrame, "C3": Color3, "UDim": UDim, "UDim2": UDim2,
              "Rect": Rect, "NR": NumberRange, "NS": NumberSequence, "CS": ColorSequence, "Font": Font,
              "BrickColor": BrickColor, "PhysProps": PhysicalProperties}
    if tt in checks:
        if isinstance(value, checks[tt]):
            return value
        if tt == "NS" and tv in (float, int):
            raise LuaError(f"Unable to assign property {key}. NumberSequence expected, got number")
        raise LuaError(f"Unable to assign property {key}. {_tname(tt)} expected, got {lua_typeof(value)}")
    if tt == "Inst":
        if isinstance(value, Instance):
            return value
        raise LuaError(f"Unable to assign property {key}. Object expected, got {lua_typeof(value)}")
    return value


def _tname(t):
    return {"V3": "Vector3", "V2": "Vector2", "CF": "CFrame", "C3": "Color3", "NR": "NumberRange",
            "NS": "NumberSequence", "CS": "ColorSequence", "Inst": "Object", "num": "number",
            "str": "string", "int": "int"}.get(t, t)


# =============================================================================== scheduler

class Scheduler:
    def __init__(self, sim):
        self.sim = sim
        self.clock = 0.0
        self.waiting = []  # heap (wake, seq, thread, args)
        self.deferred = deque()
        self.seq = itertools.count()
        self.main = LuaThread(None)
        self.main.is_main = True
        self.main.status = "running"
        STATE.current_thread = self.main
        STATE.main_thread = self.main

    def new_thread(self, fn, ctx):
        th = LuaThread(fn, context=ctx)
        return th

    def run(self, th, args):
        """Resume thread now; report errors."""
        if th.status != "suspended":
            return
        if th.cancelled:
            return
        r = thread_resume(th, args)
        if not r[0]:
            err = r[1][0] if r[1] else "error"
            self.sim.report_error(th, err, r[2] if len(r) > 2 else None)

    def spawn(self, fn, args, ctx):
        if type(fn) is LuaThread:
            th = fn
        else:
            th = self.new_thread(fn, ctx)
        self.run(th, tuple(args))
        return th

    def defer(self, fn, args, ctx):
        th = fn if type(fn) is LuaThread else self.new_thread(fn, ctx)
        self.deferred.append((th, tuple(args)))
        return th

    def delay(self, t, fn, args, ctx):
        th = fn if type(fn) is LuaThread else self.new_thread(fn, ctx)
        heapq.heappush(self.waiting, (self.clock + max(0.0, t), next(self.seq), th, ("__delay__", tuple(args))))
        th.wake = self.clock + t
        return th

    def wait(self, t):
        th = STATE.current_thread
        if th is None or th.is_main:
            raise LuaError("attempt to yield from outside a coroutine (task.wait)")
        start = self.clock
        t = max(t, 1 / 60) if t is not None else 1 / 60
        heapq.heappush(self.waiting, (self.clock + t, next(self.seq), th, ("__wait__", start)))
        th.wake = self.clock + t
        r = thread_yield(())
        return r

    def resume_later(self, th, args):
        self.deferred.append((th, tuple(args)))

    def run_deferred(self, limit=100000):
        n = 0
        while self.deferred and n < limit:
            th, args = self.deferred.popleft()
            n += 1
            if th.status == "suspended" and not th.cancelled:
                self.run(th, args)
        if n >= limit:
            raise SimFatal("deferred queue did not settle (infinite re-entry?)")

    def advance(self, new_clock):
        self.clock = new_clock
        while self.waiting and self.waiting[0][0] <= self.clock + 1e-9:
            wake, _, th, info = heapq.heappop(self.waiting)
            if th.cancelled or th.status != "suspended":
                continue
            if th.wake is not None and abs(th.wake - wake) > 1e-9:
                continue
            th.wake = None
            if info[0] == "__wait__":
                self.run(th, (self.clock - info[1],))
            else:
                self.run(th, info[1])
            self.run_deferred()


# =============================================================================== Sim

class Sim:
    def __init__(self, project_root=None, signal_behavior="Deferred", instant_tweens=False, verbose=True,
                 datastore=None):
        self.signal_behavior = signal_behavior
        self.instant_tweens = instant_tweens
        self.verbose = verbose
        self.output = []
        self.errors = []
        self.sched = Scheduler(self)
        self.methods = {}
        self.special_getters = {}
        self.special_setters = {}
        self.server_ctx = Context(self, "server")
        self.clients = []
        self.tag_signals = {}  # (tag, kind) -> Signal
        self.tweens = []
        self.collision_groups = {"Default": set()}
        self.noncollide = set()
        self.datastore_data = datastore if datastore is not None else {}
        self.datastore_fail = 0
        self.http_guid_seq = itertools.count(1)
        self.frame = 0
        self.wall_epoch = 1_790_000_000.0  # fixed unix epoch base for determinism
        self.render_hooks = []
        self.physics = None
        self.pending_network = []
        self.spatial_dirty = True
        self.weld_cache = None
        self.max_errors_print = 40
        import rbx_api
        rbx_api.install(self)
        self.game = Instance(self, "DataModel")
        self.game.props["Name"] = "Game"
        self.services = {}
        for sn in ("Workspace", "Players", "Lighting", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService",
                   "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "SoundService", "RunService",
                   "UserInputService", "ContextActionService", "TweenService", "HttpService", "DataStoreService",
                   "CollectionService", "PhysicsService", "ProximityPromptService", "GuiService", "TextService",
                   "ContentProvider", "Debris", "MarketplaceService", "TeleportService", "Teams", "Chat",
                   "LogService", "Stats", "MessagingService", "BadgeService", "TextChatService",
                   "AssetService", "MaterialService", "SocialService", "PolicyService", "LocalizationService",
                   "AnalyticsService", "MemoryStoreService", "HapticService", "VRService", "GamepadService",
                   "TestService"):
            self.get_service(sn)
        sp = self.services["StarterPlayer"]
        sps = Instance(self, "StarterPlayerScripts")
        sps.props["Name"] = "StarterPlayerScripts"
        sps.set_parent(sp)
        scs = Instance(self, "Folder")
        scs.props["Name"] = "StarterCharacterScripts"
        scs.set_parent(sp)
        ws = self.services["Workspace"]
        terrain = Instance(self, "Terrain")
        terrain.props["Name"] = "Terrain"
        terrain.props["Anchored"] = True
        terrain.set_parent(ws)
        ws.props["Terrain"] = terrain
        self.terrain = terrain
        cam = Instance(self, "Camera")
        cam.props["Name"] = "Camera"
        cam.set_parent(ws)
        self.server_ctx.camera = cam
        ws.props["CurrentCamera"] = cam
        self.server_ctx.globals = self.make_base_globals(self.server_ctx)

    # ----------------------------------------------------------- service/registry helpers
    def get_service(self, name):
        s = self.services.get(name)
        if s is None:
            if name not in CLASSES or not CLASSES[name].service:
                raise LuaError(f"'{name}' is not a valid Service name")
            s = Instance(self, name)
            s.props["Name"] = name
            self.services[name] = s
            if hasattr(self, "game"):
                s.parent = self.game
                self.game.children.append(s)
        return s

    def find_method(self, ci, key):
        for cn in ci.ancestors():
            m = self.methods.get(cn)
            if m is not None:
                f = m.get(key)
                if f is not None:
                    return f
        return None

    def method(self, class_name, name):
        def deco(fn):
            def wrapped(*args):
                if not args or not isinstance(args[0], Instance):
                    raise LuaError(f"Expected ':' not '.' calling member function {name}")
                return fn(*args)
            self.methods.setdefault(class_name, {})[name] = BuiltinFunction(wrapped, name)
            return fn
        return deco

    def getter(self, class_name, prop):
        def deco(fn):
            self.special_getters.setdefault(prop, []).append((class_name, fn))
            return fn
        return deco

    def setter(self, class_name, prop):
        def deco(fn):
            self.special_setters.setdefault(prop, []).append((class_name, fn))
            return fn
        return deco

    def special_get(self, inst, key):
        lst = self.special_getters.get(key)
        if lst:
            anc = inst.cls.ancestors()
            for cn, fn in lst:
                if cn in anc:
                    return fn(inst)
        return NOTSET

    def special_set(self, inst, key, value):
        lst = self.special_setters.get(key)
        if lst:
            anc = inst.cls.ancestors()
            for cn, fn in lst:
                if cn in anc:
                    r = fn(inst, value)
                    return NOTSET if r is NOTSET else True
        return NOTSET

    # ----------------------------------------------------------- contexts
    def ctx(self):
        th = STATE.current_thread
        c = getattr(th, "context", None) if th is not None else None
        return c if c is not None else self.server_ctx

    def is_client(self):
        return self.ctx().kind == "client"

    # ----------------------------------------------------------- output
    def log(self, level, msg, ctx=None):
        ctx = ctx or self.ctx()
        self.output.append((self.sched.clock, str(ctx), level, msg))
        if level == "error":
            self.errors.append((self.sched.clock, str(ctx), msg))
        if self.verbose or level == "error":
            if level != "error" or len(self.errors) <= self.max_errors_print:
                sys.stdout.write(f"[{self.sched.clock:8.3f}] [{ctx}] {level.upper()}: {msg}\n")

    def report_error(self, th, err, exc=None):
        msg = tostring(err) if not isinstance(err, str) else err
        self.log("error", msg, th.context)

    # ----------------------------------------------------------- dispatch
    def dispatch(self, fn, args, ctx):
        if self.signal_behavior == "Deferred":
            self.sched.defer(fn, args, ctx)
        else:
            self.sched.spawn(fn, args, ctx)

    # ----------------------------------------------------------- hooks
    def mark_layout_dirty(self, inst):
        for c in self.clients:
            c.layout_dirty = True

    def on_prop_changed(self, inst, key):
        pass

    def on_reparent(self, inst, old, new, was_in_game, now_in_game):
        if now_in_game and not was_in_game:
            for d in [inst] + inst.descendants():
                for tag in d.tags:
                    self.fire_tag(tag, "added", d)
            self.maybe_run_scripts(inst)
        elif was_in_game and not now_in_game:
            for d in [inst] + inst.descendants():
                for tag in d.tags:
                    self.fire_tag(tag, "removed", d)
        if inst.is_a("GuiBase2d") or (new is not None and new.is_a("GuiBase2d")) or (old is not None and old.is_a("GuiBase2d")):
            self.mark_layout_dirty(inst)
        elif (was_in_game or now_in_game) and (inst.is_a("JointInstance") or inst.cls.name == "WeldConstraint"
                                               or inst.is_a("PVInstance") or inst.cls.name == "Folder"):
            # joints entering/leaving the DataModel change which parts are driven
            self.weld_cache = None

    def on_destroy(self, inst):
        pass

    def fire_tag(self, tag, kind, inst):
        s = self.tag_signals.get((tag, kind))
        if s is not None:
            s.fire(inst)

    def tag_signal(self, tag, kind):
        s = self.tag_signals.get((tag, kind))
        if s is None:
            s = Signal(self, f"Tag{kind}:{tag}")
            self.tag_signals[(tag, kind)] = s
        return s

    def tagged(self, tag):
        return [d for d in self.game.descendants() if tag in d.tags]

    def maybe_run_scripts(self, inst):
        if not getattr(self, "started", False):
            return
        for d in [inst] + inst.descendants():
            if d.cls.name == "Script" and not d.props.get("Disabled") and d.props.get("Enabled", True):
                anc = d
                in_server_area = False
                while anc is not None:
                    if anc.cls.name in ("Workspace", "ServerScriptService"):
                        in_server_area = True
                        break
                    anc = anc.parent
                if in_server_area and not d.extra.get("ran"):
                    d.extra["ran"] = True
                    self.run_script(d, self.server_ctx)

    # ----------------------------------------------------------- globals / scripts
    def make_base_globals(self, ctx):
        G = create_globals(print_fn=lambda s: self.log("print", s), warn_fn=lambda s: self.log("warn", s))
        install_datatypes(G, lambda: self.wall_epoch + self.sched.clock)
        # os.time follows the same clock as workspace:GetServerTimeNow()
        import luau_interp as _LI
        import time as _time
        if True:
            sim_self = self

            class _Hooks:
                @staticmethod
                def os_time():
                    return sim_self.wall_epoch + sim_self.sched.clock

                @staticmethod
                def os_clock():
                    return _time.perf_counter()
            _LI.STATE.hooks = _Hooks()
        import rbx_api
        rbx_api.install_globals(self, G, ctx)
        G.set("shared", ctx.shared)
        return G

    def script_env(self, script, ctx):
        env = LuaTable()
        mt = LuaTable()
        mt.set("__index", ctx.globals)
        env.meta = mt
        env.set("script", script)
        return env

    def run_script(self, script, ctx):
        src = script.props.get("Source", "")
        chunk = script.extra.get("source_path") or script.full_name()
        env = self.script_env(script, ctx)
        try:
            fn = load(src, chunk, env)
        except Exception as e:
            self.log("error", f"{chunk}: {e}", ctx)
            return
        self.sched.spawn(fn, (), ctx)
        self.sched.run_deferred()

    def require(self, module):
        ctx = self.ctx()
        if not isinstance(module, Instance) or module.cls.name != "ModuleScript":
            raise LuaError("Attempted to call require with invalid argument(s).")
        cache = ctx.modules
        if module in cache:
            st, val = cache[module]
            if st == "loading":
                # wait until loaded (cyclic require would deadlock in Roblox)
                raise LuaError(f"Requested module was required recursively: {module.full_name()}")
            if st == "error":
                raise LuaError("Requested module experienced an error while loading")
            return val
        cache[module] = ("loading", None)
        src = module.props.get("Source", "")
        chunk = module.extra.get("source_path") or module.full_name()
        env = self.script_env(module, ctx)
        try:
            fn = load(src, chunk, env)
        except Exception as e:
            cache[module] = ("error", None)
            self.log("error", f"{chunk}: {e}", ctx)
            raise LuaError("Requested module experienced an error while loading")
        try:
            r = call(fn, ())
        except LuaError as e:
            cache[module] = ("error", None)
            self.log("error", f"{e.value}", ctx)
            raise LuaError("Requested module experienced an error while loading")
        if len(r) != 1:
            cache[module] = ("error", None)
            raise LuaError(f"Module code did not return exactly one value ({chunk})")
        cache[module] = ("ok", r[0])
        return r[0]

    # ----------------------------------------------------------- instances
    def new(self, class_name, parent=None, **props):
        inst = Instance(self, class_name)
        for k, v in props.items():
            inst.set_prop(k, v, internal=True)
        if parent is not None:
            inst.set_parent(parent)
        return inst

    # ----------------------------------------------------------- running
    def start(self):
        """Run server scripts (ServerScriptService, Workspace) and ReplicatedFirst later per client."""
        self.started = True
        ws = self.services["Workspace"]
        sss = self.services["ServerScriptService"]
        for root in (sss, ws):
            for d in root.descendants():
                if d.cls.name == "Script" and not d.props.get("Disabled") and not d.extra.get("ran"):
                    d.extra["ran"] = True
                    self.run_script(d, self.server_ctx)
        self.sched.run_deferred()

    def add_player(self, name="Player1", user_id=1001, device=None, spawn_character=True):
        import rbx_api
        return rbx_api.add_player(self, name, user_id, device or Device(), spawn_character)

    def remove_player(self, player):
        import rbx_api
        rbx_api.remove_player(self, player)

    def step(self, dt=1 / 60, n=1):
        import rbx_api
        for _ in range(n):
            rbx_api.step_frame(self, dt)

    def run_for(self, seconds, dt=1 / 60):
        steps = int(round(seconds / dt))
        self.step(dt, steps)

    def in_ctx(self, ctx, fn, *args):
        """Call a Lua function synchronously within a context (from Python)."""
        th = LuaThread(fn, context=ctx)
        r = thread_resume(th, args)
        self.sched.run_deferred()
        if not r[0]:
            raise LuaError(r[1][0] if r[1] else "error")
        return r[1]
