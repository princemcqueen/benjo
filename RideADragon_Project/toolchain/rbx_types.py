"""Roblox datatypes implemented as interpreter UserData."""
import math
import random as _random
import time as _time

from luau_interp import (UserData, LuaError, LuaTable, BuiltinFunction, tostring, fmt_number,
                         lua_typeof, truthy, call)
from rbx_enums import ENUMS


def _num(v, what="number"):
    t = type(v)
    if t is float or t is int:
        return float(v)
    if v is None:
        return 0.0
    raise LuaError(f"invalid argument ({what} expected, got {lua_typeof(v)})")


def _opt_num(v, d=0.0):
    if v is None:
        return d
    return _num(v)


def _fn(name, f):
    return BuiltinFunction(f, name)


def fmt(x):
    return fmt_number(float(x))


def _ctor_table(name, funcs, consts=None):
    t = LuaTable()
    for k, v in funcs.items():
        t.set(k, _fn(f"{name}.{k}", v))
    if consts:
        for k, v in consts.items():
            t.set(k, v)
    t.frozen = True
    return t


# =============================================================================== Enums

class EnumItem(UserData):
    __slots__ = ("enum_name", "name", "value", "enum_type")

    def __init__(self, enum_type, name, value):
        self.enum_type = enum_type
        self.enum_name = enum_type.name
        self.name = name
        self.value = value

    def lua_index(self, key):
        if key == "Name":
            return self.name
        if key == "Value":
            return float(self.value)
        if key == "EnumType":
            return self.enum_type
        if key == "IsA":
            return _fn("IsA", lambda s, n: n == self.enum_name)
        raise LuaError(f"{key} is not a valid member of \"Enum.{self.enum_name}.{self.name}\"")

    def lua_typeof(self):
        return "EnumItem"

    def lua_tostring(self):
        return f"Enum.{self.enum_name}.{self.name}"

    def __repr__(self):
        return self.lua_tostring()


class EnumType(UserData):
    __slots__ = ("name", "items", "by_value")

    def __init__(self, name, items):
        self.name = name
        self.items = {}
        self.by_value = {}
        for n, v in items.items():
            it = EnumItem(self, n, v)
            self.items[n] = it
            self.by_value.setdefault(v, it)

    def lua_index(self, key):
        it = self.items.get(key)
        if it is not None:
            return it
        if key == "GetEnumItems":
            def gei(*a):
                t = LuaTable()
                for it in self.items.values():
                    t.arr.append(it)
                return t
            return _fn("GetEnumItems", gei)
        if key == "FromName":
            return _fn("FromName", lambda s, n: self.items.get(n))
        if key == "FromValue":
            return _fn("FromValue", lambda s, v: self.by_value.get(int(v)))
        raise LuaError(f"{key} is not a valid member of \"Enum.{self.name}\"")

    def lua_typeof(self):
        return "Enum"

    def lua_tostring(self):
        return self.name

    def coerce(self, v):
        """Accept EnumItem, name string, or numeric value."""
        if isinstance(v, EnumItem):
            if v.enum_type is self:
                return v
            raise LuaError(f"Invalid value for enum {self.name}")
        if type(v) is str:
            it = self.items.get(v)
            if it is None:
                raise LuaError(f"Invalid value \"{v}\" for enum {self.name}")
            return it
        if type(v) in (float, int) and not isinstance(v, bool):
            it = self.by_value.get(int(v))
            if it is None:
                raise LuaError(f"Invalid value {v} for enum {self.name}")
            return it
        raise LuaError(f"Invalid value for enum {self.name} (got {lua_typeof(v)})")


class EnumRoot(UserData):
    __slots__ = ("types",)

    def __init__(self):
        self.types = {n: EnumType(n, items) for n, items in ENUMS.items()}

    def lua_index(self, key):
        t = self.types.get(key)
        if t is not None:
            return t
        if key == "GetEnums":
            def ge(*a):
                r = LuaTable()
                for v in self.types.values():
                    r.arr.append(v)
                return r
            return _fn("GetEnums", ge)
        raise LuaError(f"{key} is not a valid member of \"Enum\"")

    def lua_typeof(self):
        return "Enums"

    def lua_tostring(self):
        return "Enum"


ENUM = EnumRoot()


def E(enum, item):
    return ENUM.types[enum].items[item]


# =============================================================================== Vector3

class Vector3(UserData):
    __slots__ = ("x", "y", "z")

    def __init__(self, x=0.0, y=0.0, z=0.0):
        self.x = float(x)
        self.y = float(y)
        self.z = float(z)

    def mag(self):
        return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)

    def unit(self):
        m = self.mag()
        if m == 0:
            return Vector3(math.nan, math.nan, math.nan)
        return Vector3(self.x / m, self.y / m, self.z / m)

    def dot(self, o):
        return self.x * o.x + self.y * o.y + self.z * o.z

    def cross(self, o):
        return Vector3(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x)

    def __add__(self, o):
        return Vector3(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o):
        return Vector3(self.x - o.x, self.y - o.y, self.z - o.z)

    def scale(self, k):
        return Vector3(self.x * k, self.y * k, self.z * k)

    def lerp(self, o, t):
        return Vector3(self.x + (o.x - self.x) * t, self.y + (o.y - self.y) * t, self.z + (o.z - self.z) * t)

    def tup(self):
        return (self.x, self.y, self.z)

    def lua_index(self, key):
        if key == "X" or key == "x":
            return self.x
        if key == "Y" or key == "y":
            return self.y
        if key == "Z" or key == "z":
            return self.z
        if key == "Magnitude" or key == "magnitude":
            return self.mag()
        if key == "Unit" or key == "unit":
            return self.unit()
        m = _V3_METHODS.get(key)
        if m is not None:
            return m
        raise LuaError(f"{key} is not a valid member of Vector3")

    def lua_newindex(self, key, value):
        raise LuaError(f"{key} cannot be assigned to")

    def lua_typeof(self):
        return "Vector3"

    def lua_type(self):
        return "vector"

    def lua_tostring(self):
        return f"{fmt(self.x)}, {fmt(self.y)}, {fmt(self.z)}"

    def lua_eq(self, o):
        return isinstance(o, Vector3) and self.x == o.x and self.y == o.y and self.z == o.z

    def lua_unm(self):
        return Vector3(-self.x, -self.y, -self.z)

    def lua_arith(self, op, a, b):
        if op == "+":
            if isinstance(a, Vector3) and isinstance(b, Vector3):
                return a + b
            raise LuaError(f"attempt to perform arithmetic (add) on {lua_typeof(a)} and {lua_typeof(b)}")
        if op == "-":
            if isinstance(a, Vector3) and isinstance(b, Vector3):
                return a - b
            raise LuaError(f"attempt to perform arithmetic (sub) on {lua_typeof(a)} and {lua_typeof(b)}")
        if op == "*":
            if isinstance(a, Vector3) and isinstance(b, Vector3):
                return Vector3(a.x * b.x, a.y * b.y, a.z * b.z)
            if isinstance(a, Vector3) and type(b) in (float, int):
                return a.scale(b)
            if isinstance(b, Vector3) and type(a) in (float, int):
                return b.scale(a)
        if op == "/":
            if isinstance(a, Vector3) and isinstance(b, Vector3):
                return Vector3(_div(a.x, b.x), _div(a.y, b.y), _div(a.z, b.z))
            if isinstance(a, Vector3) and type(b) in (float, int):
                return Vector3(_div(a.x, b), _div(a.y, b), _div(a.z, b))
            if isinstance(b, Vector3) and type(a) in (float, int):
                return Vector3(_div(a, b.x), _div(a, b.y), _div(a, b.z))
        if op == "//":
            if isinstance(a, Vector3) and type(b) in (float, int):
                return Vector3(math.floor(_div(a.x, b)), math.floor(_div(a.y, b)), math.floor(_div(a.z, b)))
        raise LuaError(f"attempt to perform arithmetic on {lua_typeof(a)} and {lua_typeof(b)}")

    def __repr__(self):
        return f"V3({self.x:.3f},{self.y:.3f},{self.z:.3f})"


def _div(a, b):
    if b == 0:
        if a == 0:
            return math.nan
        return math.inf if a > 0 else -math.inf
    return a / b


def _v3(v, what="Vector3"):
    if not isinstance(v, Vector3):
        raise LuaError(f"invalid argument ({what} expected, got {lua_typeof(v)})")
    return v


def _v3_angle(s, o, axis=None):
    a = s.unit()
    b = o.unit()
    d = max(-1.0, min(1.0, a.dot(b)))
    ang = math.acos(d)
    if axis is not None:
        c = a.cross(b)
        if c.dot(axis) < 0:
            ang = -ang
    return ang


_V3_METHODS = {
    "Dot": _fn("Dot", lambda s, o: _v3(s).dot(_v3(o))),
    "Cross": _fn("Cross", lambda s, o: _v3(s).cross(_v3(o))),
    "Lerp": _fn("Lerp", lambda s, o, t: _v3(s).lerp(_v3(o), _num(t))),
    "Abs": _fn("Abs", lambda s: Vector3(abs(s.x), abs(s.y), abs(s.z))),
    "Ceil": _fn("Ceil", lambda s: Vector3(math.ceil(s.x), math.ceil(s.y), math.ceil(s.z))),
    "Floor": _fn("Floor", lambda s: Vector3(math.floor(s.x), math.floor(s.y), math.floor(s.z))),
    "Sign": _fn("Sign", lambda s: Vector3(*(math.copysign(1, c) if c != 0 else 0 for c in (s.x, s.y, s.z)))),
    "Min": _fn("Min", lambda s, *o: Vector3(min([s.x] + [v.x for v in o]), min([s.y] + [v.y for v in o]), min([s.z] + [v.z for v in o]))),
    "Max": _fn("Max", lambda s, *o: Vector3(max([s.x] + [v.x for v in o]), max([s.y] + [v.y for v in o]), max([s.z] + [v.z for v in o]))),
    "FuzzyEq": _fn("FuzzyEq", lambda s, o, eps=1e-5: (s - o).mag() <= (eps if eps is not None else 1e-5)),
    "Angle": _fn("Angle", _v3_angle),
}


def _v3_new(*a):
    return Vector3(_opt_num(a[0] if len(a) > 0 else None), _opt_num(a[1] if len(a) > 1 else None),
                   _opt_num(a[2] if len(a) > 2 else None))


NORMAL_VECTORS = {
    "Right": Vector3(1, 0, 0), "Top": Vector3(0, 1, 0), "Back": Vector3(0, 0, 1),
    "Left": Vector3(-1, 0, 0), "Bottom": Vector3(0, -1, 0), "Front": Vector3(0, 0, -1),
}


def _v3_from_normal(n):
    if isinstance(n, EnumItem):
        return NORMAL_VECTORS[n.name]
    raise LuaError("FromNormalId expects NormalId")


VECTOR3_LIB = _ctor_table("Vector3", {
    "new": _v3_new,
    "FromNormalId": _v3_from_normal,
    "FromAxis": lambda n: {"X": Vector3(1, 0, 0), "Y": Vector3(0, 1, 0), "Z": Vector3(0, 0, 1)}[n.name],
}, {"zero": Vector3(0, 0, 0), "one": Vector3(1, 1, 1), "xAxis": Vector3(1, 0, 0),
    "yAxis": Vector3(0, 1, 0), "zAxis": Vector3(0, 0, 1)})


# =============================================================================== Vector2

class Vector2(UserData):
    __slots__ = ("x", "y")

    def __init__(self, x=0.0, y=0.0):
        self.x = float(x)
        self.y = float(y)

    def mag(self):
        return math.sqrt(self.x * self.x + self.y * self.y)

    def lua_index(self, key):
        if key == "X" or key == "x":
            return self.x
        if key == "Y" or key == "y":
            return self.y
        if key == "Magnitude" or key == "magnitude":
            return self.mag()
        if key == "Unit" or key == "unit":
            m = self.mag()
            return Vector2(self.x / m, self.y / m) if m else Vector2(math.nan, math.nan)
        m = _V2_METHODS.get(key)
        if m is not None:
            return m
        raise LuaError(f"{key} is not a valid member of Vector2")

    def lua_newindex(self, key, value):
        raise LuaError(f"{key} cannot be assigned to")

    def lua_typeof(self):
        return "Vector2"

    def lua_tostring(self):
        return f"{fmt(self.x)}, {fmt(self.y)}"

    def lua_eq(self, o):
        return isinstance(o, Vector2) and self.x == o.x and self.y == o.y

    def lua_unm(self):
        return Vector2(-self.x, -self.y)

    def lua_arith(self, op, a, b):
        A = isinstance(a, Vector2)
        B = isinstance(b, Vector2)
        if op == "+" and A and B:
            return Vector2(a.x + b.x, a.y + b.y)
        if op == "-" and A and B:
            return Vector2(a.x - b.x, a.y - b.y)
        if op == "*":
            if A and B:
                return Vector2(a.x * b.x, a.y * b.y)
            if A and type(b) in (float, int):
                return Vector2(a.x * b, a.y * b)
            if B and type(a) in (float, int):
                return Vector2(b.x * a, b.y * a)
        if op == "/":
            if A and B:
                return Vector2(_div(a.x, b.x), _div(a.y, b.y))
            if A and type(b) in (float, int):
                return Vector2(_div(a.x, b), _div(a.y, b))
        raise LuaError(f"attempt to perform arithmetic on {lua_typeof(a)} and {lua_typeof(b)}")

    def __repr__(self):
        return f"V2({self.x:.2f},{self.y:.2f})"


_V2_METHODS = {
    "Dot": _fn("Dot", lambda s, o: s.x * o.x + s.y * o.y),
    "Cross": _fn("Cross", lambda s, o: s.x * o.y - s.y * o.x),
    "Lerp": _fn("Lerp", lambda s, o, t: Vector2(s.x + (o.x - s.x) * t, s.y + (o.y - s.y) * t)),
    "Min": _fn("Min", lambda s, *o: Vector2(min([s.x] + [v.x for v in o]), min([s.y] + [v.y for v in o]))),
    "Max": _fn("Max", lambda s, *o: Vector2(max([s.x] + [v.x for v in o]), max([s.y] + [v.y for v in o]))),
    "Abs": _fn("Abs", lambda s: Vector2(abs(s.x), abs(s.y))),
    "Floor": _fn("Floor", lambda s: Vector2(math.floor(s.x), math.floor(s.y))),
    "Ceil": _fn("Ceil", lambda s: Vector2(math.ceil(s.x), math.ceil(s.y))),
    "FuzzyEq": _fn("FuzzyEq", lambda s, o, eps=1e-5: math.hypot(s.x - o.x, s.y - o.y) <= (eps or 1e-5)),
}

VECTOR2_LIB = _ctor_table("Vector2", {
    "new": lambda *a: Vector2(_opt_num(a[0] if a else None), _opt_num(a[1] if len(a) > 1 else None)),
}, {"zero": Vector2(0, 0), "one": Vector2(1, 1), "xAxis": Vector2(1, 0), "yAxis": Vector2(0, 1)})


# =============================================================================== CFrame

def _matmul(a, b):
    # 3x3 row-major tuples
    return (
        a[0] * b[0] + a[1] * b[3] + a[2] * b[6], a[0] * b[1] + a[1] * b[4] + a[2] * b[7], a[0] * b[2] + a[1] * b[5] + a[2] * b[8],
        a[3] * b[0] + a[4] * b[3] + a[5] * b[6], a[3] * b[1] + a[4] * b[4] + a[5] * b[7], a[3] * b[2] + a[4] * b[5] + a[5] * b[8],
        a[6] * b[0] + a[7] * b[3] + a[8] * b[6], a[6] * b[1] + a[7] * b[4] + a[8] * b[7], a[6] * b[2] + a[7] * b[5] + a[8] * b[8],
    )


def _rx(a):
    c, s = math.cos(a), math.sin(a)
    return (1, 0, 0, 0, c, -s, 0, s, c)


def _ry(a):
    c, s = math.cos(a), math.sin(a)
    return (c, 0, s, 0, 1, 0, -s, 0, c)


def _rz(a):
    c, s = math.cos(a), math.sin(a)
    return (c, -s, 0, s, c, 0, 0, 0, 1)


IDENT = (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)


def _transpose(r):
    return (r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8])


def _quat_from_mat(r):
    m00, m01, m02, m10, m11, m12, m20, m21, m22 = r
    tr = m00 + m11 + m22
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        w = 0.25 * s
        x = (m21 - m12) / s
        y = (m02 - m20) / s
        z = (m10 - m01) / s
    elif m00 > m11 and m00 > m22:
        s = math.sqrt(1.0 + m00 - m11 - m22) * 2
        w = (m21 - m12) / s
        x = 0.25 * s
        y = (m01 + m10) / s
        z = (m02 + m20) / s
    elif m11 > m22:
        s = math.sqrt(1.0 + m11 - m00 - m22) * 2
        w = (m02 - m20) / s
        x = (m01 + m10) / s
        y = 0.25 * s
        z = (m12 + m21) / s
    else:
        s = math.sqrt(1.0 + m22 - m00 - m11) * 2
        w = (m10 - m01) / s
        x = (m02 + m20) / s
        y = (m12 + m21) / s
        z = 0.25 * s
    return (x, y, z, w)


def _mat_from_quat(q):
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    return (
        1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
        2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
        2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
    )


def _slerp(q1, q2, t):
    dot = sum(a * b for a, b in zip(q1, q2))
    if dot < 0:
        q2 = tuple(-c for c in q2)
        dot = -dot
    if dot > 0.9995:
        r = tuple(a + (b - a) * t for a, b in zip(q1, q2))
        n = math.sqrt(sum(c * c for c in r))
        return tuple(c / n for c in r)
    th0 = math.acos(dot)
    th = th0 * t
    s0 = math.cos(th) - dot * math.sin(th) / math.sin(th0)
    s1 = math.sin(th) / math.sin(th0)
    return tuple(s0 * a + s1 * b for a, b in zip(q1, q2))


class CFrame(UserData):
    __slots__ = ("p", "r")

    def __init__(self, p=(0.0, 0.0, 0.0), r=IDENT):
        self.p = (float(p[0]), float(p[1]), float(p[2]))
        self.r = tuple(float(v) for v in r)

    # core math
    def mul(self, o):
        r = self.r
        op = o.p
        p = (r[0] * op[0] + r[1] * op[1] + r[2] * op[2] + self.p[0],
             r[3] * op[0] + r[4] * op[1] + r[5] * op[2] + self.p[1],
             r[6] * op[0] + r[7] * op[1] + r[8] * op[2] + self.p[2])
        return CFrame(p, _matmul(r, o.r))

    def point_to_world(self, v):
        r = self.r
        return Vector3(r[0] * v.x + r[1] * v.y + r[2] * v.z + self.p[0],
                       r[3] * v.x + r[4] * v.y + r[5] * v.z + self.p[1],
                       r[6] * v.x + r[7] * v.y + r[8] * v.z + self.p[2])

    def vector_to_world(self, v):
        r = self.r
        return Vector3(r[0] * v.x + r[1] * v.y + r[2] * v.z,
                       r[3] * v.x + r[4] * v.y + r[5] * v.z,
                       r[6] * v.x + r[7] * v.y + r[8] * v.z)

    def inverse(self):
        rt = _transpose(self.r)
        p = self.p
        np_ = (-(rt[0] * p[0] + rt[1] * p[1] + rt[2] * p[2]),
               -(rt[3] * p[0] + rt[4] * p[1] + rt[5] * p[2]),
               -(rt[6] * p[0] + rt[7] * p[1] + rt[8] * p[2]))
        return CFrame(np_, rt)

    def point_to_object(self, v):
        return self.inverse().point_to_world(v)

    def vector_to_object(self, v):
        rt = _transpose(self.r)
        return Vector3(rt[0] * v.x + rt[1] * v.y + rt[2] * v.z,
                       rt[3] * v.x + rt[4] * v.y + rt[5] * v.z,
                       rt[6] * v.x + rt[7] * v.y + rt[8] * v.z)

    def lerp(self, o, t):
        q = _slerp(_quat_from_mat(self.r), _quat_from_mat(o.r), t)
        p = tuple(a + (b - a) * t for a, b in zip(self.p, o.p))
        return CFrame(p, _mat_from_quat(q))

    def look(self):
        r = self.r
        return Vector3(-r[2], -r[5], -r[8])

    def right(self):
        r = self.r
        return Vector3(r[0], r[3], r[6])

    def up(self):
        r = self.r
        return Vector3(r[1], r[4], r[7])

    def zvec(self):
        r = self.r
        return Vector3(r[2], r[5], r[8])

    def pos(self):
        return Vector3(*self.p)

    def to_euler_xyz(self):
        m00, m01, m02, m10, m11, m12, m20, m21, m22 = self.r
        y = math.asin(max(-1.0, min(1.0, m02)))
        if abs(m02) < 0.9999999:
            x = math.atan2(-m12, m22)
            z = math.atan2(-m01, m00)
        else:
            x = math.atan2(m21, m11)
            z = 0.0
        return (x, y, z)

    def to_euler_yxz(self):
        m00, m01, m02, m10, m11, m12, m20, m21, m22 = self.r
        x = math.asin(max(-1.0, min(1.0, -m12)))
        if abs(m12) < 0.9999999:
            y = math.atan2(m02, m22)
            z = math.atan2(m10, m11)
        else:
            y = math.atan2(-m20, m00)
            z = 0.0
        return (x, y, z)

    def to_axis_angle(self):
        x, y, z, w = _quat_from_mat(self.r)
        w = max(-1.0, min(1.0, w))
        angle = 2 * math.acos(w)
        s = math.sqrt(max(0.0, 1 - w * w))
        if s < 1e-9:
            return Vector3(1, 0, 0), 0.0
        return Vector3(x / s, y / s, z / s), angle

    def lua_index(self, key):
        p = self.p
        r = self.r
        if key == "Position" or key == "p":
            return Vector3(*p)
        if key == "X" or key == "x":
            return p[0]
        if key == "Y" or key == "y":
            return p[1]
        if key == "Z" or key == "z":
            return p[2]
        if key == "LookVector" or key == "lookVector":
            return self.look()
        if key == "RightVector" or key == "rightVector" or key == "XVector":
            return self.right()
        if key == "UpVector" or key == "upVector" or key == "YVector":
            return self.up()
        if key == "ZVector":
            return self.zvec()
        if key == "Rotation":
            return CFrame((0, 0, 0), r)
        m = _CF_METHODS.get(key)
        if m is not None:
            return m
        raise LuaError(f"{key} is not a valid member of CFrame")

    def lua_newindex(self, key, value):
        raise LuaError(f"{key} cannot be assigned to")

    def lua_typeof(self):
        return "CFrame"

    def lua_tostring(self):
        return ", ".join(fmt(v) for v in self.p + self.r)

    def lua_eq(self, o):
        return isinstance(o, CFrame) and self.p == o.p and self.r == o.r

    def lua_arith(self, op, a, b):
        if op == "*":
            if isinstance(a, CFrame) and isinstance(b, CFrame):
                return a.mul(b)
            if isinstance(a, CFrame) and isinstance(b, Vector3):
                return a.point_to_world(b)
        if op == "+" and isinstance(a, CFrame) and isinstance(b, Vector3):
            return CFrame((a.p[0] + b.x, a.p[1] + b.y, a.p[2] + b.z), a.r)
        if op == "-" and isinstance(a, CFrame) and isinstance(b, Vector3):
            return CFrame((a.p[0] - b.x, a.p[1] - b.y, a.p[2] - b.z), a.r)
        raise LuaError(f"attempt to perform arithmetic on {lua_typeof(a)} and {lua_typeof(b)}")

    def __repr__(self):
        return f"CF(p={tuple(round(v, 3) for v in self.p)})"


def _cf(v):
    if not isinstance(v, CFrame):
        raise LuaError(f"invalid argument (CFrame expected, got {lua_typeof(v)})")
    return v


def _cf_to_world(s, *cfs):
    return tuple(s.mul(_cf(c)) for c in cfs) if len(cfs) != 1 else s.mul(_cf(cfs[0]))


def _cf_to_object(s, *cfs):
    inv = s.inverse()
    return tuple(inv.mul(_cf(c)) for c in cfs) if len(cfs) != 1 else inv.mul(_cf(cfs[0]))


def _cf_components(s):
    return tuple(s.p) + tuple(s.r)


def _cf_ortho(s):
    x = Vector3(s.r[0], s.r[3], s.r[6]).unit()
    y = Vector3(s.r[1], s.r[4], s.r[7])
    z = x.cross(y).unit()
    y = z.cross(x).unit()
    return CFrame(s.p, (x.x, y.x, z.x, x.y, y.y, z.y, x.z, y.z, z.z))


_CF_METHODS = {
    "Inverse": _fn("Inverse", lambda s: _cf(s).inverse()),
    "inverse": _fn("inverse", lambda s: _cf(s).inverse()),
    "Lerp": _fn("Lerp", lambda s, o, t: _cf(s).lerp(_cf(o), _num(t))),
    "lerp": _fn("lerp", lambda s, o, t: _cf(s).lerp(_cf(o), _num(t))),
    "ToWorldSpace": _fn("ToWorldSpace", _cf_to_world),
    "toWorldSpace": _fn("toWorldSpace", _cf_to_world),
    "ToObjectSpace": _fn("ToObjectSpace", _cf_to_object),
    "toObjectSpace": _fn("toObjectSpace", _cf_to_object),
    "PointToWorldSpace": _fn("PointToWorldSpace", lambda s, v: _cf(s).point_to_world(_v3(v))),
    "pointToWorldSpace": _fn("pointToWorldSpace", lambda s, v: _cf(s).point_to_world(_v3(v))),
    "PointToObjectSpace": _fn("PointToObjectSpace", lambda s, v: _cf(s).point_to_object(_v3(v))),
    "pointToObjectSpace": _fn("pointToObjectSpace", lambda s, v: _cf(s).point_to_object(_v3(v))),
    "VectorToWorldSpace": _fn("VectorToWorldSpace", lambda s, v: _cf(s).vector_to_world(_v3(v))),
    "vectorToWorldSpace": _fn("vectorToWorldSpace", lambda s, v: _cf(s).vector_to_world(_v3(v))),
    "VectorToObjectSpace": _fn("VectorToObjectSpace", lambda s, v: _cf(s).vector_to_object(_v3(v))),
    "vectorToObjectSpace": _fn("vectorToObjectSpace", lambda s, v: _cf(s).vector_to_object(_v3(v))),
    "GetComponents": _fn("GetComponents", _cf_components),
    "components": _fn("components", _cf_components),
    "ToEulerAnglesXYZ": _fn("ToEulerAnglesXYZ", lambda s: s.to_euler_xyz()),
    "toEulerAnglesXYZ": _fn("toEulerAnglesXYZ", lambda s: s.to_euler_xyz()),
    "ToEulerAnglesYXZ": _fn("ToEulerAnglesYXZ", lambda s: s.to_euler_yxz()),
    "toEulerAnglesYXZ": _fn("toEulerAnglesYXZ", lambda s: s.to_euler_yxz()),
    "ToOrientation": _fn("ToOrientation", lambda s: s.to_euler_yxz()),
    "ToAxisAngle": _fn("ToAxisAngle", lambda s: s.to_axis_angle()),
    "toAxisAngle": _fn("toAxisAngle", lambda s: s.to_axis_angle()),
    "Orthonormalize": _fn("Orthonormalize", _cf_ortho),
    "FuzzyEq": _fn("FuzzyEq", lambda s, o, eps=1e-5: all(abs(a - b) <= (eps or 1e-5) for a, b in zip(s.p + s.r, o.p + o.r))),
}


def _cf_new(*a):
    n = len(a)
    if n == 0:
        return CFrame()
    if n == 1:
        v = _v3(a[0])
        return CFrame(v.tup())
    if n == 2 and isinstance(a[0], Vector3) and isinstance(a[1], Vector3):
        return _cf_lookat(a[0], a[1])
    if n == 3:
        return CFrame((_num(a[0]), _num(a[1]), _num(a[2])))
    if n == 7:
        x, y, z, qx, qy, qz, qw = (_num(v) for v in a)
        return CFrame((x, y, z), _mat_from_quat((qx, qy, qz, qw)))
    if n == 12:
        vals = [_num(v) for v in a]
        return CFrame(vals[:3], vals[3:])
    raise LuaError("Invalid number of arguments to CFrame.new")


def _cf_lookat(pos, target, up=None):
    pos = _v3(pos)
    target = _v3(target)
    up = up if up is not None else Vector3(0, 1, 0)
    f = (target - pos)
    if f.mag() < 1e-9:
        return CFrame(pos.tup())
    f = f.unit()
    rgt = f.cross(up)
    if rgt.mag() < 1e-6:
        # looking straight up/down
        rgt = f.cross(Vector3(0, 0, 1) if abs(f.y) > 0.9 else Vector3(0, 1, 0))
    rgt = rgt.unit()
    u = rgt.cross(f).unit()
    z = f.scale(-1)
    return CFrame(pos.tup(), (rgt.x, u.x, z.x, rgt.y, u.y, z.y, rgt.z, u.z, z.z))


def _cf_angles(rx=0, ry=0, rz=0):
    return CFrame((0, 0, 0), _matmul(_matmul(_rx(_opt_num(rx)), _ry(_opt_num(ry))), _rz(_opt_num(rz))))


def _cf_yxz(rx=0, ry=0, rz=0):
    return CFrame((0, 0, 0), _matmul(_matmul(_ry(_opt_num(ry)), _rx(_opt_num(rx))), _rz(_opt_num(rz))))


def _cf_axis_angle(axis, angle):
    axis = _v3(axis).unit()
    angle = _num(angle)
    s = math.sin(angle / 2)
    return CFrame((0, 0, 0), _mat_from_quat((axis.x * s, axis.y * s, axis.z * s, math.cos(angle / 2))))


def _cf_from_matrix(pos, vx, vy, vz=None):
    if vz is None:
        vz = _v3(vx).cross(_v3(vy)).unit()
    return CFrame(_v3(pos).tup(), (vx.x, vy.x, vz.x, vx.y, vy.y, vz.y, vx.z, vy.z, vz.z))


CFRAME_LIB = _ctor_table("CFrame", {
    "new": _cf_new,
    "lookAt": _cf_lookat,
    "Angles": _cf_angles,
    "fromEulerAnglesXYZ": _cf_angles,
    "fromEulerAnglesYXZ": _cf_yxz,
    "fromOrientation": _cf_yxz,
    "fromAxisAngle": _cf_axis_angle,
    "fromMatrix": _cf_from_matrix,
    "lookAlong": lambda pos, d, up=None: _cf_lookat(pos, pos + d, up),
}, {"identity": CFrame()})


# =============================================================================== Color3

class Color3(UserData):
    __slots__ = ("r", "g", "b")

    def __init__(self, r=0.0, g=0.0, b=0.0):
        self.r = float(r)
        self.g = float(g)
        self.b = float(b)

    def lua_index(self, key):
        if key == "R" or key == "r":
            return self.r
        if key == "G" or key == "g":
            return self.g
        if key == "B" or key == "b":
            return self.b
        if key == "Lerp" or key == "lerp":
            return _fn("Lerp", lambda s, o, t: Color3(s.r + (o.r - s.r) * t, s.g + (o.g - s.g) * t, s.b + (o.b - s.b) * t))
        if key == "ToHSV":
            return _fn("ToHSV", lambda s: _to_hsv(s))
        if key == "ToHex":
            return _fn("ToHex", lambda s: "%02x%02x%02x" % tuple(int(round(max(0, min(1, c)) * 255)) for c in (s.r, s.g, s.b)))
        raise LuaError(f"{key} is not a valid member of Color3")

    def lua_newindex(self, key, value):
        raise LuaError(f"{key} cannot be assigned to")

    def lua_typeof(self):
        return "Color3"

    def lua_tostring(self):
        return f"{fmt(self.r)}, {fmt(self.g)}, {fmt(self.b)}"

    def lua_eq(self, o):
        return isinstance(o, Color3) and self.r == o.r and self.g == o.g and self.b == o.b

    def rgb255(self):
        return tuple(int(round(max(0.0, min(1.0, c)) * 255)) for c in (self.r, self.g, self.b))

    def __repr__(self):
        return f"C3{self.rgb255()}"


def _to_hsv(c):
    import colorsys
    h, s, v = colorsys.rgb_to_hsv(max(0, min(1, c.r)), max(0, min(1, c.g)), max(0, min(1, c.b)))
    return (h, s, v)


def _from_hsv(h, s, v):
    import colorsys
    r, g, b = colorsys.hsv_to_rgb(_num(h) % 1.0 if _num(h) != 1 else 1.0, _num(s), _num(v))
    return Color3(r, g, b)


def _from_hex(h):
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) != 6:
        raise LuaError("Unable to convert characters to hex value")
    return Color3(int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255)


COLOR3_LIB = _ctor_table("Color3", {
    "new": lambda *a: Color3(_opt_num(a[0] if a else None), _opt_num(a[1] if len(a) > 1 else None), _opt_num(a[2] if len(a) > 2 else None)),
    "fromRGB": lambda *a: Color3(_opt_num(a[0] if a else None) / 255, _opt_num(a[1] if len(a) > 1 else None) / 255, _opt_num(a[2] if len(a) > 2 else None) / 255),
    "fromHSV": _from_hsv,
    "fromHex": _from_hex,
    "toHSV": lambda c: _to_hsv(c),
})


# =============================================================================== UDim / UDim2

class UDim(UserData):
    __slots__ = ("scale", "offset")

    def __init__(self, scale=0.0, offset=0.0):
        self.scale = float(scale)
        self.offset = float(int(offset)) if offset == int(offset) else float(offset)

    def lua_index(self, key):
        if key == "Scale":
            return self.scale
        if key == "Offset":
            return float(self.offset)
        raise LuaError(f"{key} is not a valid member of UDim")

    def lua_newindex(self, key, value):
        raise LuaError(f"{key} cannot be assigned to")

    def lua_typeof(self):
        return "UDim"

    def lua_tostring(self):
        return f"{fmt(self.scale)}, {fmt(self.offset)}"

    def lua_eq(self, o):
        return isinstance(o, UDim) and self.scale == o.scale and self.offset == o.offset

    def lua_arith(self, op, a, b):
        if isinstance(a, UDim) and isinstance(b, UDim):
            if op == "+":
                return UDim(a.scale + b.scale, a.offset + b.offset)
            if op == "-":
                return UDim(a.scale - b.scale, a.offset - b.offset)
        raise LuaError("attempt to perform arithmetic on UDim")

    def lua_unm(self):
        return UDim(-self.scale, -self.offset)


def _int_offset(v):
    # Roblox stores UDim offsets as int32 (truncation)
    v = _opt_num(v)
    return float(int(v))


class UDim2(UserData):
    __slots__ = ("xs", "xo", "ys", "yo")

    def __init__(self, xs=0.0, xo=0.0, ys=0.0, yo=0.0):
        self.xs = float(xs)
        self.xo = float(int(xo))
        self.ys = float(ys)
        self.yo = float(int(yo))

    def lua_index(self, key):
        if key == "X" or key == "Width":
            return UDim(self.xs, self.xo)
        if key == "Y" or key == "Height":
            return UDim(self.ys, self.yo)
        if key == "Lerp":
            return _fn("Lerp", lambda s, o, t: UDim2(s.xs + (o.xs - s.xs) * t, s.xo + (o.xo - s.xo) * t,
                                                   s.ys + (o.ys - s.ys) * t, s.yo + (o.yo - s.yo) * t))
        raise LuaError(f"{key} is not a valid member of UDim2")

    def lua_newindex(self, key, value):
        raise LuaError(f"{key} cannot be assigned to")

    def lua_typeof(self):
        return "UDim2"

    def lua_tostring(self):
        return f"{{{fmt(self.xs)}, {fmt(self.xo)}}}, {{{fmt(self.ys)}, {fmt(self.yo)}}}"

    def lua_eq(self, o):
        return isinstance(o, UDim2) and (self.xs, self.xo, self.ys, self.yo) == (o.xs, o.xo, o.ys, o.yo)

    def lua_arith(self, op, a, b):
        if isinstance(a, UDim2) and isinstance(b, UDim2):
            if op == "+":
                return UDim2(a.xs + b.xs, a.xo + b.xo, a.ys + b.ys, a.yo + b.yo)
            if op == "-":
                return UDim2(a.xs - b.xs, a.xo - b.xo, a.ys - b.ys, a.yo - b.yo)
        raise LuaError("attempt to perform arithmetic on UDim2")

    def lua_unm(self):
        return UDim2(-self.xs, -self.xo, -self.ys, -self.yo)

    def __repr__(self):
        return f"UDim2({self.xs},{self.xo},{self.ys},{self.yo})"


def _udim2_new(*a):
    if len(a) == 2 and isinstance(a[0], UDim) and isinstance(a[1], UDim):
        return UDim2(a[0].scale, a[0].offset, a[1].scale, a[1].offset)
    vals = [_opt_num(a[i] if i < len(a) else None) for i in range(4)]
    return UDim2(vals[0], _int_offset(vals[1]), vals[2], _int_offset(vals[3]))


UDIM_LIB = _ctor_table("UDim", {"new": lambda *a: UDim(_opt_num(a[0] if a else None), _int_offset(a[1] if len(a) > 1 else None))})
UDIM2_LIB = _ctor_table("UDim2", {
    "new": _udim2_new,
    "fromScale": lambda *a: UDim2(_opt_num(a[0] if a else None), 0, _opt_num(a[1] if len(a) > 1 else None), 0),
    "fromOffset": lambda *a: UDim2(0, _int_offset(a[0] if a else None), 0, _int_offset(a[1] if len(a) > 1 else None)),
})


# =============================================================================== Rect

class Rect(UserData):
    __slots__ = ("min", "max")

    def __init__(self, x0=0.0, y0=0.0, x1=0.0, y1=0.0):
        self.min = Vector2(x0, y0)
        self.max = Vector2(x1, y1)

    def lua_index(self, key):
        if key == "Min":
            return self.min
        if key == "Max":
            return self.max
        if key == "Width":
            return self.max.x - self.min.x
        if key == "Height":
            return self.max.y - self.min.y
        raise LuaError(f"{key} is not a valid member of Rect")

    def lua_typeof(self):
        return "Rect"

    def lua_tostring(self):
        return f"{fmt(self.min.x)}, {fmt(self.min.y)}, {fmt(self.max.x)}, {fmt(self.max.y)}"

    def lua_eq(self, o):
        return isinstance(o, Rect) and self.min.lua_eq(o.min) and self.max.lua_eq(o.max)


def _rect_new(*a):
    if len(a) == 2 and isinstance(a[0], Vector2):
        return Rect(a[0].x, a[0].y, a[1].x, a[1].y)
    vals = [_opt_num(a[i] if i < len(a) else None) for i in range(4)]
    return Rect(*vals)


RECT_LIB = _ctor_table("Rect", {"new": _rect_new})


# =============================================================================== Number/Color sequences, ranges

class NumberRange(UserData):
    __slots__ = ("min", "max")

    def __init__(self, a, b=None):
        self.min = float(a)
        self.max = float(a if b is None else b)

    def lua_index(self, key):
        if key == "Min":
            return self.min
        if key == "Max":
            return self.max
        raise LuaError(f"{key} is not a valid member of NumberRange")

    def lua_typeof(self):
        return "NumberRange"

    def lua_tostring(self):
        return f"{fmt(self.min)} {fmt(self.max)} "

    def lua_eq(self, o):
        return isinstance(o, NumberRange) and self.min == o.min and self.max == o.max


def _nr_new(a, b=None):
    a = _num(a)
    b = a if b is None else _num(b)
    if b < a:
        raise LuaError("NumberRange: invalid range")
    return NumberRange(a, b)


NUMBERRANGE_LIB = _ctor_table("NumberRange", {"new": _nr_new})


class NumberSequenceKeypoint(UserData):
    __slots__ = ("time", "value", "envelope")

    def __init__(self, t, v, e=0.0):
        self.time = float(t)
        self.value = float(v)
        self.envelope = float(e or 0.0)

    def lua_index(self, key):
        if key == "Time":
            return self.time
        if key == "Value":
            return self.value
        if key == "Envelope":
            return self.envelope
        raise LuaError(f"{key} is not a valid member of NumberSequenceKeypoint")

    def lua_typeof(self):
        return "NumberSequenceKeypoint"


class NumberSequence(UserData):
    __slots__ = ("kps",)

    def __init__(self, kps):
        self.kps = kps

    def lua_index(self, key):
        if key == "Keypoints":
            t = LuaTable()
            for k in self.kps:
                t.arr.append(k)
            return t
        raise LuaError(f"{key} is not a valid member of NumberSequence")

    def lua_typeof(self):
        return "NumberSequence"

    def lua_tostring(self):
        return " ".join(f"{fmt(k.time)} {fmt(k.value)} {fmt(k.envelope)}" for k in self.kps) + " "

    def value_at(self, t):
        kps = self.kps
        if t <= kps[0].time:
            return kps[0].value
        for a, b in zip(kps, kps[1:]):
            if a.time <= t <= b.time:
                if b.time == a.time:
                    return b.value
                f = (t - a.time) / (b.time - a.time)
                return a.value + (b.value - a.value) * f
        return kps[-1].value


def _ns_new(*a):
    if len(a) == 1 and type(a[0]) in (float, int):
        return NumberSequence([NumberSequenceKeypoint(0, a[0]), NumberSequenceKeypoint(1, a[0])])
    if len(a) == 2 and type(a[0]) in (float, int):
        return NumberSequence([NumberSequenceKeypoint(0, a[0]), NumberSequenceKeypoint(1, a[1])])
    if len(a) == 1 and type(a[0]) is LuaTable:
        kps = list(a[0].arr)
        for k in kps:
            if not isinstance(k, NumberSequenceKeypoint):
                raise LuaError("NumberSequence.new: expected keypoints")
        if len(kps) < 2 or kps[0].time != 0 or kps[-1].time != 1:
            raise LuaError("NumberSequence: requires at least 2 keypoints, starting at 0 and ending at 1")
        for x, y in zip(kps, kps[1:]):
            if y.time < x.time:
                raise LuaError("NumberSequence: all keypoints must be ordered by time")
        return NumberSequence(kps)
    raise LuaError("NumberSequence.new: invalid arguments")


NUMBERSEQUENCE_LIB = _ctor_table("NumberSequence", {"new": _ns_new})
NUMBERSEQUENCEKEYPOINT_LIB = _ctor_table("NumberSequenceKeypoint", {
    "new": lambda t, v, e=None: NumberSequenceKeypoint(_num(t), _num(v), _opt_num(e))})


class ColorSequenceKeypoint(UserData):
    __slots__ = ("time", "value")

    def __init__(self, t, c):
        self.time = float(t)
        self.value = c

    def lua_index(self, key):
        if key == "Time":
            return self.time
        if key == "Value":
            return self.value
        raise LuaError(f"{key} is not a valid member of ColorSequenceKeypoint")

    def lua_typeof(self):
        return "ColorSequenceKeypoint"


class ColorSequence(UserData):
    __slots__ = ("kps",)

    def __init__(self, kps):
        self.kps = kps

    def lua_index(self, key):
        if key == "Keypoints":
            t = LuaTable()
            for k in self.kps:
                t.arr.append(k)
            return t
        raise LuaError(f"{key} is not a valid member of ColorSequence")

    def lua_typeof(self):
        return "ColorSequence"

    def color_at(self, t):
        kps = self.kps
        if t <= kps[0].time:
            return kps[0].value
        for a, b in zip(kps, kps[1:]):
            if a.time <= t <= b.time:
                f = 0 if b.time == a.time else (t - a.time) / (b.time - a.time)
                return Color3(a.value.r + (b.value.r - a.value.r) * f, a.value.g + (b.value.g - a.value.g) * f,
                              a.value.b + (b.value.b - a.value.b) * f)
        return kps[-1].value


def _cs_new(*a):
    if len(a) == 1 and isinstance(a[0], Color3):
        return ColorSequence([ColorSequenceKeypoint(0, a[0]), ColorSequenceKeypoint(1, a[0])])
    if len(a) == 2 and isinstance(a[0], Color3) and isinstance(a[1], Color3):
        return ColorSequence([ColorSequenceKeypoint(0, a[0]), ColorSequenceKeypoint(1, a[1])])
    if len(a) == 1 and type(a[0]) is LuaTable:
        kps = list(a[0].arr)
        for k in kps:
            if not isinstance(k, ColorSequenceKeypoint):
                raise LuaError("ColorSequence.new: expected keypoints")
        if len(kps) < 2 or kps[0].time != 0 or kps[-1].time != 1:
            raise LuaError("ColorSequence: requires at least 2 keypoints, starting at 0 and ending at 1")
        return ColorSequence(kps)
    raise LuaError("ColorSequence.new: invalid arguments")


def _csk_new(t, c):
    if not isinstance(c, Color3):
        raise LuaError("ColorSequenceKeypoint.new: Color3 expected")
    return ColorSequenceKeypoint(_num(t), c)


COLORSEQUENCE_LIB = _ctor_table("ColorSequence", {"new": _cs_new})
COLORSEQUENCEKEYPOINT_LIB = _ctor_table("ColorSequenceKeypoint", {"new": _csk_new})


# =============================================================================== TweenInfo

class TweenInfo(UserData):
    __slots__ = ("time", "style", "direction", "repeat", "reverses", "delay")

    def __init__(self, time=1.0, style=None, direction=None, repeat=0, reverses=False, delay=0.0):
        self.time = float(time)
        self.style = style or E("EasingStyle", "Quad")
        self.direction = direction or E("EasingDirection", "Out")
        self.repeat = int(repeat)
        self.reverses = bool(reverses)
        self.delay = float(delay)

    def lua_index(self, key):
        m = {"Time": self.time, "EasingStyle": self.style, "EasingDirection": self.direction,
             "RepeatCount": float(self.repeat), "Reverses": self.reverses, "DelayTime": self.delay}
        if key in m:
            return m[key]
        raise LuaError(f"{key} is not a valid member of TweenInfo")

    def lua_typeof(self):
        return "TweenInfo"


def _ti_new(*a):
    t = _opt_num(a[0] if a else None, 1.0)
    st = a[1] if len(a) > 1 and a[1] is not None else None
    if st is not None:
        st = ENUM.types["EasingStyle"].coerce(st)
    d = a[2] if len(a) > 2 and a[2] is not None else None
    if d is not None:
        d = ENUM.types["EasingDirection"].coerce(d)
    rep = _opt_num(a[3] if len(a) > 3 else None)
    rev = truthy(a[4] if len(a) > 4 else None)
    delay = _opt_num(a[5] if len(a) > 5 else None)
    return TweenInfo(t, st, d, rep, rev, delay)


TWEENINFO_LIB = _ctor_table("TweenInfo", {"new": _ti_new})


def ease(style, direction, t):
    """Roblox easing functions; t in [0,1]."""
    s = style.name
    d = direction.name

    def ein(x):
        if s == "Linear":
            return x
        if s == "Sine":
            return 1 - math.cos(x * math.pi / 2)
        if s == "Quad":
            return x * x
        if s == "Cubic":
            return x ** 3
        if s == "Quart":
            return x ** 4
        if s == "Quint":
            return x ** 5
        if s == "Exponential":
            return 0 if x == 0 else 2 ** (10 * x - 10)
        if s == "Circular":
            return 1 - math.sqrt(max(0, 1 - x * x))
        if s == "Back":
            c1 = 1.70158
            return (c1 + 1) * x ** 3 - c1 * x * x
        if s == "Elastic":
            if x in (0, 1):
                return x
            return -(2 ** (10 * x - 10)) * math.sin((x * 10 - 10.75) * (2 * math.pi) / 3)
        if s == "Bounce":
            return 1 - _bounce_out(1 - x)
        return x
    if d == "In":
        return ein(t)
    if d == "Out":
        return 1 - ein(1 - t)
    if t < 0.5:
        return ein(t * 2) / 2
    return 1 - ein((1 - t) * 2) / 2


def _bounce_out(x):
    n1, d1 = 7.5625, 2.75
    if x < 1 / d1:
        return n1 * x * x
    if x < 2 / d1:
        x -= 1.5 / d1
        return n1 * x * x + 0.75
    if x < 2.5 / d1:
        x -= 2.25 / d1
        return n1 * x * x + 0.9375
    x -= 2.625 / d1
    return n1 * x * x + 0.984375


# =============================================================================== Font

class Font(UserData):
    __slots__ = ("family", "weight", "style")

    def __init__(self, family, weight=None, style=None):
        self.family = family
        self.weight = weight or E("FontWeight", "Regular")
        self.style = style or E("FontStyle", "Normal")

    def lua_index(self, key):
        if key == "Family":
            return self.family
        if key == "Weight":
            return self.weight
        if key == "Style":
            return self.style
        if key == "Bold":
            return self.weight.value >= 600
        raise LuaError(f"{key} is not a valid member of Font")

    def lua_typeof(self):
        return "Font"

    def lua_eq(self, o):
        return isinstance(o, Font) and self.family == o.family and self.weight is o.weight and self.style is o.style


FONT_ENUM_FAMILY = {
    "Gotham": ("GothamSSm", "Regular"), "GothamMedium": ("GothamSSm", "Medium"),
    "GothamBold": ("GothamSSm", "Bold"), "GothamBlack": ("GothamSSm", "Heavy"),
    "SourceSans": ("SourceSansPro", "Regular"), "SourceSansBold": ("SourceSansPro", "Bold"),
    "SourceSansSemibold": ("SourceSansPro", "SemiBold"), "FredokaOne": ("FredokaOne", "Regular"),
    "LuckiestGuy": ("LuckiestGuy", "Regular"), "Merriweather": ("Merriweather", "Regular"),
    "Roboto": ("Roboto", "Regular"), "RobotoMono": ("RobotoMono", "Regular"),
}


def font_from_enum(item):
    fam, w = FONT_ENUM_FAMILY.get(item.name, (item.name, "Regular"))
    return Font(f"rbxasset://fonts/families/{fam}.json", E("FontWeight", w))


FONT_LIB = _ctor_table("Font", {
    "new": lambda fam, w=None, s=None: Font(fam, ENUM.types["FontWeight"].coerce(w) if w is not None else None,
                                            ENUM.types["FontStyle"].coerce(s) if s is not None else None),
    "fromEnum": lambda e: font_from_enum(ENUM.types["Font"].coerce(e)),
    "fromName": lambda n, w=None, s=None: Font(f"rbxasset://fonts/families/{n}.json",
                                                ENUM.types["FontWeight"].coerce(w) if w is not None else None,
                                                ENUM.types["FontStyle"].coerce(s) if s is not None else None),
    "fromId": lambda i, w=None, s=None: Font(f"rbxassetid://{int(i)}", w, s),
})


# =============================================================================== Random

class RandomObj(UserData):
    __slots__ = ("rng", "seed")

    def __init__(self, seed=None):
        self.seed = seed
        self.rng = _random.Random(seed)

    def lua_index(self, key):
        if key == "NextNumber":
            def nn(s, a=None, b=None):
                if a is None:
                    return s.rng.random()
                return float(a) + s.rng.random() * (float(b) - float(a))
            return _fn("NextNumber", nn)
        if key == "NextInteger":
            def ni(s, a, b):
                a = int(a)
                b = int(b)
                if b < a:
                    raise LuaError("invalid argument #2 to 'NextInteger' (interval is empty)")
                return float(s.rng.randint(a, b))
            return _fn("NextInteger", ni)
        if key == "NextUnitVector":
            def nu(s):
                while True:
                    v = Vector3(s.rng.uniform(-1, 1), s.rng.uniform(-1, 1), s.rng.uniform(-1, 1))
                    m = v.mag()
                    if 0.01 < m <= 1:
                        return v.scale(1 / m)
            return _fn("NextUnitVector", nu)
        if key == "Shuffle":
            def sh(s, t):
                s.rng.shuffle(t.arr)
            return _fn("Shuffle", sh)
        if key == "Clone":
            def cl(s):
                r = RandomObj()
                r.rng.setstate(s.rng.getstate())
                return r
            return _fn("Clone", cl)
        raise LuaError(f"{key} is not a valid member of Random")

    def lua_typeof(self):
        return "Random"


RANDOM_LIB = _ctor_table("Random", {"new": lambda seed=None: RandomObj(None if seed is None else int(seed))})


# =============================================================================== Raycast params / result

class RaycastParams(UserData):
    __slots__ = ("FilterType", "FilterDescendantsInstances", "IgnoreWater", "CollisionGroup",
                 "RespectCanCollide", "BruteForceAllSlow", "MaxParts")

    def __init__(self):
        self.FilterType = E("RaycastFilterType", "Exclude")
        self.FilterDescendantsInstances = LuaTable()
        self.IgnoreWater = False
        self.CollisionGroup = "Default"
        self.RespectCanCollide = False
        self.BruteForceAllSlow = False
        self.MaxParts = 0.0

    def lua_index(self, key):
        if key in ("FilterType", "FilterDescendantsInstances", "IgnoreWater", "CollisionGroup",
                   "RespectCanCollide", "BruteForceAllSlow", "MaxParts"):
            v = getattr(self, key)
            if key == "FilterDescendantsInstances":
                t = LuaTable()
                t.arr = list(v.arr)
                return t
            return v
        if key == "AddToFilter":
            def add(s, x):
                if type(x) is LuaTable:
                    s.FilterDescendantsInstances.arr.extend(x.arr)
                else:
                    s.FilterDescendantsInstances.arr.append(x)
            return _fn("AddToFilter", add)
        raise LuaError(f"{key} is not a valid member of RaycastParams")

    def lua_newindex(self, key, value):
        if key == "FilterType":
            self.FilterType = ENUM.types["RaycastFilterType"].coerce(value)
        elif key == "FilterDescendantsInstances":
            if type(value) is not LuaTable:
                raise LuaError("FilterDescendantsInstances must be a table of Instances")
            t = LuaTable()
            t.arr = list(value.arr)
            self.FilterDescendantsInstances = t
        elif key in ("IgnoreWater", "RespectCanCollide", "BruteForceAllSlow"):
            setattr(self, key, bool(value))
        elif key == "CollisionGroup":
            self.CollisionGroup = str(value)
        elif key == "MaxParts":
            self.MaxParts = float(value)
        else:
            raise LuaError(f"{key} is not a valid member of RaycastParams")

    def lua_typeof(self):
        return "RaycastParams"


class OverlapParams(RaycastParams):
    __slots__ = ()

    def lua_typeof(self):
        return "OverlapParams"


RAYCASTPARAMS_LIB = _ctor_table("RaycastParams", {"new": lambda *a: RaycastParams()})
OVERLAPPARAMS_LIB = _ctor_table("OverlapParams", {"new": lambda *a: OverlapParams()})


class RaycastResult(UserData):
    __slots__ = ("Instance", "Position", "Normal", "Material", "Distance")

    def __init__(self, inst, pos, normal, material, dist):
        self.Instance = inst
        self.Position = pos
        self.Normal = normal
        self.Material = material
        self.Distance = dist

    def lua_index(self, key):
        if key in ("Instance", "Position", "Normal", "Material", "Distance"):
            return getattr(self, key)
        raise LuaError(f"{key} is not a valid member of RaycastResult")

    def lua_typeof(self):
        return "RaycastResult"


# =============================================================================== PhysicalProperties, BrickColor, DateTime

class PhysicalProperties(UserData):
    __slots__ = ("d", "f", "e", "fw", "ew")

    def __init__(self, d=0.7, f=0.3, e=0.5, fw=1, ew=1):
        self.d, self.f, self.e, self.fw, self.ew = d, f, e, fw, ew

    def lua_index(self, key):
        m = {"Density": self.d, "Friction": self.f, "Elasticity": self.e, "FrictionWeight": self.fw,
             "ElasticityWeight": self.ew}
        if key in m:
            return float(m[key])
        raise LuaError(f"{key} is not a valid member of PhysicalProperties")

    def lua_typeof(self):
        return "PhysicalProperties"


PHYSICALPROPERTIES_LIB = _ctor_table("PhysicalProperties", {
    "new": lambda *a: PhysicalProperties(*(float(x) for x in a)) if a and type(a[0]) in (float, int) else PhysicalProperties()})


class BrickColor(UserData):
    __slots__ = ("name", "color")

    def __init__(self, name, color):
        self.name = name
        self.color = color

    def lua_index(self, key):
        if key == "Name":
            return self.name
        if key == "Color":
            return self.color
        if key == "Number":
            return 194.0
        raise LuaError(f"{key} is not a valid member of BrickColor")

    def lua_typeof(self):
        return "BrickColor"

    def lua_tostring(self):
        return self.name

    def lua_eq(self, o):
        return isinstance(o, BrickColor) and o.name == self.name


BRICK_COLORS = {
    "Medium stone grey": Color3(163 / 255, 162 / 255, 165 / 255), "White": Color3(242 / 255, 243 / 255, 243 / 255),
    "Black": Color3(27 / 255, 42 / 255, 53 / 255), "Bright red": Color3(196 / 255, 40 / 255, 28 / 255),
    "Bright green": Color3(75 / 255, 151 / 255, 75 / 255), "Bright blue": Color3(13 / 255, 105 / 255, 172 / 255),
    "Bright yellow": Color3(245 / 255, 205 / 255, 48 / 255), "Institutional white": Color3(248 / 255, 248 / 255, 248 / 255),
}


def _bc_new(v=None, *rest):
    if type(v) is str and v in BRICK_COLORS:
        return BrickColor(v, BRICK_COLORS[v])
    if isinstance(v, Color3):
        return BrickColor("Medium stone grey", v)
    return BrickColor("Medium stone grey", BRICK_COLORS["Medium stone grey"])


BRICKCOLOR_LIB = _ctor_table("BrickColor", {
    "new": _bc_new, "random": lambda: _bc_new(), "White": lambda: _bc_new("White"),
    "Black": lambda: _bc_new("Black"), "Red": lambda: _bc_new("Bright red"),
    "Green": lambda: _bc_new("Bright green"), "Blue": lambda: _bc_new("Bright blue"),
    "Yellow": lambda: _bc_new("Bright yellow"), "Gray": lambda: _bc_new(),
    "palette": lambda i: _bc_new(), "DarkGray": lambda: _bc_new(),
})


class DateTimeObj(UserData):
    __slots__ = ("ms",)

    def __init__(self, ms):
        self.ms = ms

    def lua_index(self, key):
        if key == "UnixTimestamp":
            return float(int(self.ms // 1000))
        if key == "UnixTimestampMillis":
            return float(int(self.ms))
        if key == "ToUniversalTime" or key == "ToLocalTime":
            def tu(s):
                tt = _time.gmtime(s.ms / 1000)
                t = LuaTable()
                for k, v in (("Year", tt.tm_year), ("Month", tt.tm_mon), ("Day", tt.tm_mday), ("Hour", tt.tm_hour),
                             ("Minute", tt.tm_min), ("Second", tt.tm_sec), ("Millisecond", int(s.ms % 1000))):
                    t.set(k, float(v))
                return t
            return _fn(key, tu)
        if key == "ToIsoDate":
            return _fn(key, lambda s: _time.strftime("%Y-%m-%dT%H:%M:%SZ", _time.gmtime(s.ms / 1000)))
        if key == "FormatUniversalTime" or key == "FormatLocalTime":
            return _fn(key, lambda s, f, loc=None: _time.strftime("%Y-%m-%d %H:%M", _time.gmtime(s.ms / 1000)))
        raise LuaError(f"{key} is not a valid member of DateTime")

    def lua_typeof(self):
        return "DateTime"


def make_datetime_lib(clock_fn):
    return _ctor_table("DateTime", {
        "now": lambda: DateTimeObj(clock_fn() * 1000),
        "fromUnixTimestamp": lambda t: DateTimeObj(float(t) * 1000),
        "fromUnixTimestampMillis": lambda t: DateTimeObj(float(t)),
    })


class Ray(UserData):
    __slots__ = ("origin", "direction")

    def __init__(self, o, d):
        self.origin = o
        self.direction = d

    def lua_index(self, key):
        if key == "Origin":
            return self.origin
        if key == "Direction":
            return self.direction
        if key == "Unit":
            return Ray(self.origin, self.direction.unit())
        raise LuaError(f"{key} is not a valid member of Ray")

    def lua_typeof(self):
        return "Ray"


RAY_LIB = _ctor_table("Ray", {"new": lambda o, d: Ray(_v3(o), _v3(d))})


def install_datatypes(G, clock_fn):
    G.set("Enum", ENUM)
    G.set("Vector3", VECTOR3_LIB)
    G.set("Vector2", VECTOR2_LIB)
    G.set("CFrame", CFRAME_LIB)
    G.set("Color3", COLOR3_LIB)
    G.set("UDim", UDIM_LIB)
    G.set("UDim2", UDIM2_LIB)
    G.set("Rect", RECT_LIB)
    G.set("NumberRange", NUMBERRANGE_LIB)
    G.set("NumberSequence", NUMBERSEQUENCE_LIB)
    G.set("NumberSequenceKeypoint", NUMBERSEQUENCEKEYPOINT_LIB)
    G.set("ColorSequence", COLORSEQUENCE_LIB)
    G.set("ColorSequenceKeypoint", COLORSEQUENCEKEYPOINT_LIB)
    G.set("TweenInfo", TWEENINFO_LIB)
    G.set("Font", FONT_LIB)
    G.set("Random", RANDOM_LIB)
    G.set("RaycastParams", RAYCASTPARAMS_LIB)
    G.set("OverlapParams", OVERLAPPARAMS_LIB)
    G.set("PhysicalProperties", PHYSICALPROPERTIES_LIB)
    G.set("BrickColor", BRICKCOLOR_LIB)
    G.set("DateTime", make_datetime_lib(clock_fn))
    G.set("Ray", RAY_LIB)
