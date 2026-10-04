"""A Luau interpreter written in Python (compile-to-closures).

Values:
  nil -> None, boolean -> bool, number -> float/int, string -> str (latin-1 bytes),
  table -> LuaTable, function -> LuaFunction / Python callable, thread -> LuaThread,
  userdata -> subclasses of UserData.
"""
import math
import sys
import time
import struct
import random as _random

import greenlet

from luau_parser import parse, ParseError
from luau_lexer import LexError
import lua_patterns

sys.setrecursionlimit(100000)

INF = float("inf")
NAN = float("nan")


class LuaError(Exception):
    def __init__(self, value, traceback=None):
        super().__init__(value)
        self.value = value
        self.lua_traceback = traceback

    def __str__(self):
        v = self.value
        if isinstance(v, str):
            return v
        return tostring(v)


class UserData:
    """Base for host objects. Subclasses implement lua_index / lua_newindex,
    lua_typeof, lua_tostring and optionally lua_arith(op, a, b), lua_eq, lua_lt, lua_le,
    lua_call, lua_len, lua_unm."""
    __slots__ = ()

    def lua_index(self, key):
        raise LuaError(f"attempt to index {self.lua_typeof()} with '{key}'")

    def lua_newindex(self, key, value):
        raise LuaError(f"attempt to index {self.lua_typeof()} with '{key}'")

    def lua_typeof(self):
        return "userdata"

    def lua_type(self):
        return "userdata"

    def lua_tostring(self):
        return self.lua_typeof()


class _BoolKey:
    __slots__ = ("v",)

    def __init__(self, v):
        self.v = v

    def __repr__(self):
        return "true" if self.v else "false"


TRUE_KEY = _BoolKey(True)
FALSE_KEY = _BoolKey(False)


def _norm_key(k):
    if k is True:
        return TRUE_KEY
    if k is False:
        return FALSE_KEY
    return k


def _denorm_key(k):
    if k is TRUE_KEY:
        return True
    if k is FALSE_KEY:
        return False
    return k


class LuaTable:
    __slots__ = ("hash", "arr", "meta", "frozen", "__weakref__")

    def __init__(self):
        self.hash = {}
        self.arr = []
        self.meta = None
        self.frozen = False

    def get(self, k):
        tk = type(k)
        if tk is float or tk is int:
            if tk is float and k.is_integer():
                i = int(k)
            else:
                i = k
            if tk is int or tk is float and k.is_integer():
                if 1 <= i <= len(self.arr):
                    return self.arr[i - 1]
            return self.hash.get(k)
        if tk is bool:
            return self.hash.get(TRUE_KEY if k else FALSE_KEY)
        return self.hash.get(k)

    def set(self, k, v):
        if self.frozen:
            raise LuaError("attempt to modify a readonly table")
        tk = type(k)
        if tk is float or tk is int:
            if tk is float:
                if k != k:
                    raise LuaError("table index is NaN")
                isint = k.is_integer()
                i = int(k) if isint else None
            else:
                isint = True
                i = k
            if isint:
                arr = self.arr
                n = len(arr)
                if 1 <= i <= n:
                    if v is None:
                        if i == n:
                            arr.pop()
                            while arr and arr[-1] is None:
                                arr.pop()
                        else:
                            arr[i - 1] = None
                    else:
                        arr[i - 1] = v
                    return
                if i == n + 1:
                    if v is None:
                        self.hash.pop(i, None)
                        return
                    arr.append(v)
                    self.hash.pop(i, None)
                    h = self.hash
                    if h:
                        j = i + 1
                        while j in h:
                            arr.append(h.pop(j))
                            j += 1
                    return
                k = i
            if v is None:
                self.hash.pop(k, None)
            else:
                self.hash[k] = v
            return
        if k is None:
            raise LuaError("table index is nil")
        if tk is bool:
            k = TRUE_KEY if k else FALSE_KEY
        if v is None:
            self.hash.pop(k, None)
        else:
            self.hash[k] = v

    def length(self):
        return len(self.arr)

    def next(self, k):
        arr = self.arr
        if k is None:
            i = 0
        else:
            tk = type(k)
            i = None
            if tk is float or tk is int:
                if (tk is int or k.is_integer()) and 1 <= k <= len(arr):
                    i = int(k)
            if i is None:
                # in hash part
                keys = list(self.hash.keys())
                nk = _norm_key(k)
                try:
                    idx = keys.index(nk)
                except ValueError:
                    raise LuaError("invalid key to 'next'")
                if idx + 1 < len(keys):
                    kk = keys[idx + 1]
                    return _denorm_key(kk), self.hash[kk]
                return None, None
        while i < len(arr):
            v = arr[i]
            if v is not None:
                return float(i + 1), v
            i += 1
        for kk, vv in self.hash.items():
            return _denorm_key(kk), vv
        return None, None

    def items(self):
        """Snapshot iteration (array part then hash part)."""
        res = []
        for i, v in enumerate(self.arr):
            if v is not None:
                res.append((float(i + 1), v))
        for k, v in list(self.hash.items()):
            res.append((_denorm_key(k), v))
        return res

    def __repr__(self):
        return f"<LuaTable {id(self):x}>"


class LuaThread:
    __slots__ = ("g", "fn", "status", "parent_thread", "context", "name", "wake", "cancelled",
                 "resume_values", "__weakref__", "is_main", "lua_stack", "last_error", "data")

    def __init__(self, fn, context=None):
        self.fn = fn
        self.g = None
        self.status = "suspended"
        self.context = context
        self.name = None
        self.wake = None
        self.cancelled = False
        self.is_main = False
        self.lua_stack = []
        self.last_error = None
        self.data = None


class Proto:
    __slots__ = ("name", "nparams", "vararg", "body", "nslots", "chunk", "line", "upval_desc")


class LuaFunction:
    __slots__ = ("proto", "upvals", "env", "__weakref__")

    def __init__(self, proto, upvals, env):
        self.proto = proto
        self.upvals = upvals
        self.env = env

    def __call__(self, *args):
        proto = self.proto
        frame = [None] * proto.nslots
        frame[0] = self.upvals
        np = proto.nparams
        na = len(args)
        for i in range(np):
            frame[2 + i] = [args[i] if i < na else None]
        if proto.vararg:
            frame[1] = args[np:] if na > np else ()
        st = STATE
        stack = st.stack
        stack.append(self)
        if len(stack) > 400:
            stack.pop()
            raise LuaError(f"{proto.chunk}:{proto.line}: stack overflow")
        try:
            r = proto.body(frame)
        finally:
            stack.pop()
        if r is None or r is BREAK or r is CONTINUE:
            return ()
        return r

    def __repr__(self):
        return f"<function {self.proto.name}>"


class BuiltinFunction:
    """Wrapper to name Python builtins (used for tostring)."""
    __slots__ = ("fn", "name", "__weakref__")

    def __init__(self, fn, name):
        self.fn = fn
        self.name = name

    def __call__(self, *args):
        return self.fn(*args)

    def __repr__(self):
        return f"<builtin {self.name}>"


class _State:
    def __init__(self):
        self.stack = []  # LuaFunction call stack (for depth)
        self.line = 0
        self.chunk = "?"
        self.string_meta = None
        self.string_lib = None
        self.current_thread = None
        self.main_thread = None
        self.hooks = None  # sim hooks


STATE = _State()

BREAK = object()
CONTINUE = object()


# ----------------------------------------------------------------------------- helpers

def lua_type(v):
    if v is None:
        return "nil"
    t = type(v)
    if t is bool:
        return "boolean"
    if t is float or t is int:
        return "number"
    if t is str:
        return "string"
    if t is LuaTable:
        return "table"
    if t is LuaFunction or t is BuiltinFunction:
        return "function"
    if t is LuaThread:
        return "thread"
    if isinstance(v, UserData):
        return v.lua_type()
    if callable(v):
        return "function"
    return "userdata"


def lua_typeof(v):
    if isinstance(v, UserData):
        return v.lua_typeof()
    return lua_type(v)


def fmt_number(x):
    if type(x) is int:
        return str(x)
    if x != x:
        return "nan"
    if x == INF:
        return "inf"
    if x == -INF:
        return "-inf"
    if x.is_integer() and abs(x) < 1e15:
        return str(int(x))
    r = repr(x)
    if "e" in r:
        mant, exp = r.split("e")
        if mant.endswith(".0"):
            mant = mant[:-2]
        sign = exp[0] if exp[0] in "+-" else "+"
        digits = exp.lstrip("+-")
        r = mant + "e" + sign + digits.rjust(2, "0")
    return r


def tostring(v):
    if v is None:
        return "nil"
    t = type(v)
    if t is str:
        return v
    if t is bool:
        return "true" if v else "false"
    if t is float or t is int:
        return fmt_number(v)
    if t is LuaTable:
        mt = v.meta
        if mt is not None:
            f = mt.get("__tostring")
            if f is not None:
                r = call(f, (v,))
                s = r[0] if r else None
                if type(s) is not str:
                    raise LuaError("'__tostring' must return a string")
                return s
            nm = mt.get("__name")
            if type(nm) is str:
                return f"{nm}: 0x{id(v) & 0xffffffff:08x}"
        return f"table: 0x{id(v) & 0xffffffffffff:012x}"
    if t is LuaFunction or t is BuiltinFunction or (callable(v) and not isinstance(v, UserData)):
        return f"function: 0x{id(v) & 0xffffffffffff:012x}"
    if t is LuaThread:
        return f"thread: 0x{id(v) & 0xffffffffffff:012x}"
    if isinstance(v, UserData):
        return v.lua_tostring()
    return str(v)


def tonumber(v, base=None):
    t = type(v)
    if base is None:
        if t is float or t is int:
            return v
        if t is str:
            s = v.strip(" \t\n\r\f\v")
            if not s:
                return None
            try:
                low = s.lower()
                neg = False
                body = low
                if body.startswith("-"):
                    neg = True
                    body = body[1:]
                elif body.startswith("+"):
                    body = body[1:]
                if body.startswith("0x"):
                    r = float(int(body[2:], 16))
                    return -r if neg else r
                if body.startswith("0b"):
                    r = float(int(body[2:], 2))
                    return -r if neg else r
                if "_" in s:
                    return None
                if body in ("inf", "infinity", "nan") or "n" in body and "e" not in body:
                    return None
                return float(s)
            except ValueError:
                return None
        return None
    b = int(base)
    if t is float or t is int:
        v = fmt_number(v)
    if type(v) is not str:
        return None
    s = v.strip().lower()
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    try:
        r = float(int(s, b))
    except ValueError:
        return None
    return -r if neg else r


def truthy(v):
    return v is not None and v is not False


def getmetafield(v, name):
    t = type(v)
    if t is LuaTable:
        mt = v.meta
        return mt.get(name) if mt is not None else None
    if t is str:
        return STATE.string_meta.get(name) if STATE.string_meta else None
    return None


def call(f, args):
    """Call any callable Lua value; returns tuple."""
    if type(f) is LuaFunction:
        return f(*args)
    if type(f) is LuaTable:
        mt = f.meta
        h = mt.get("__call") if mt is not None else None
        if h is None:
            raise LuaError(f"attempt to call a table value")
        return call(h, (f,) + tuple(args))
    if isinstance(f, UserData):
        lc = getattr(f, "lua_call", None)
        if lc is None:
            raise LuaError(f"attempt to call a {f.lua_typeof()} value")
        r = lc(*args)
    elif f is None:
        raise LuaError("attempt to call a nil value")
    elif callable(f) and type(f) not in (str, bool, float, int):
        r = f(*args)
    else:
        raise LuaError(f"attempt to call a {lua_type(f)} value")
    if type(r) is tuple:
        return r
    if r is None:
        return ()
    if type(r) is list:
        return tuple(r)
    return (r,)


def index(obj, key):
    t = type(obj)
    if t is LuaTable:
        v = obj.get(key)
        if v is not None:
            return v
        mt = obj.meta
        if mt is None:
            return None
        h = mt.get("__index")
        if h is None:
            return None
        if type(h) is LuaTable:
            return index(h, key)
        r = call(h, (obj, key))
        return r[0] if r else None
    if t is str:
        return STATE.string_lib.get(key) if type(key) is str else None
    if isinstance(obj, UserData):
        return obj.lua_index(key)
    if obj is None:
        raise LuaError(f"attempt to index nil with {_keydesc(key)}")
    raise LuaError(f"attempt to index {lua_type(obj)} with {_keydesc(key)}")


def _keydesc(key):
    if type(key) is str:
        return f"'{key}'"
    return lua_type(key)


def setindex(obj, key, val):
    t = type(obj)
    if t is LuaTable:
        mt = obj.meta
        if mt is None:
            obj.set(key, val)
            return
        if obj.get(key) is not None:
            obj.set(key, val)
            return
        h = mt.get("__newindex")
        if h is None:
            obj.set(key, val)
            return
        if type(h) is LuaTable:
            setindex(h, key, val)
            return
        call(h, (obj, key, val))
        return
    if isinstance(obj, UserData):
        obj.lua_newindex(key, val)
        return
    if obj is None:
        raise LuaError(f"attempt to index nil with {_keydesc(key)}")
    raise LuaError(f"attempt to index {lua_type(obj)} with {_keydesc(key)}")


_ARITH_EVENTS = {"+": "__add", "-": "__sub", "*": "__mul", "/": "__div", "//": "__idiv", "%": "__mod", "^": "__pow"}


def _num_coerce(v):
    t = type(v)
    if t is float or t is int:
        return v
    if t is str:
        return tonumber(v)
    return None


def _raw_arith(op, a, b):
    if op == "+":
        return a + b
    if op == "-":
        return a - b
    if op == "*":
        return a * b
    if op == "/":
        if b == 0:
            if a == 0 or a != a:
                return NAN
            return INF if (a > 0) == (math.copysign(1, b) > 0) else -INF
        return a / b
    if op == "//":
        if b == 0:
            if a == 0 or a != a:
                return NAN
            return INF if (a > 0) == (math.copysign(1, b) > 0) else -INF
        return float(math.floor(a / b))
    if op == "%":
        if b == 0:
            return NAN
        if a == INF or a == -INF:
            return NAN
        r = math.fmod(a, b)
        if r != 0 and (r < 0) != (b < 0):
            r += b
        return r
    if op == "^":
        try:
            return math.pow(a, b)
        except (ValueError, OverflowError):
            if a == 0 and b < 0:
                return INF
            try:
                return float(a) ** float(b) if not (a < 0 and not float(b).is_integer()) else NAN
            except OverflowError:
                return INF
    raise LuaError("bad arith op")


def arith(op, a, b):
    ta = type(a)
    tb = type(b)
    if (ta is float or ta is int) and (tb is float or tb is int):
        return _raw_arith(op, a, b)
    if isinstance(a, UserData) or isinstance(b, UserData):
        ud = a if isinstance(a, UserData) else b
        f = getattr(ud, "lua_arith", None)
        if f is not None:
            r = f(op, a, b)
            if r is not NotImplemented:
                return r
        ev = _ARITH_EVENTS[op]
        raise LuaError(f"attempt to perform arithmetic ({ev[2:]}) on {lua_typeof(a)} and {lua_typeof(b)}")
    na = _num_coerce(a) if ta is str else None
    nb = _num_coerce(b) if tb is str else None
    if ta is str and na is not None and (tb is float or tb is int or nb is not None):
        return _raw_arith(op, na, b if nb is None else nb)
    if tb is str and nb is not None and (ta is float or ta is int):
        return _raw_arith(op, a, nb)
    ev = _ARITH_EVENTS[op]
    h = getmetafield(a, ev)
    if h is None:
        h = getmetafield(b, ev)
    if h is not None:
        r = call(h, (a, b))
        return r[0] if r else None
    bad = b if (ta is float or ta is int or (ta is str and na is not None)) else a
    raise LuaError(f"attempt to perform arithmetic ({ev[2:]}) on {lua_typeof(bad)}" +
                   (f" and {lua_typeof(b)}" if bad is a and b is not a else ""))


def unm(a):
    t = type(a)
    if t is float or t is int:
        return -a
    if t is str:
        n = tonumber(a)
        if n is not None:
            return -n
    if isinstance(a, UserData):
        f = getattr(a, "lua_unm", None)
        if f is not None:
            return f()
    h = getmetafield(a, "__unm")
    if h is not None:
        r = call(h, (a, a))
        return r[0] if r else None
    raise LuaError(f"attempt to perform arithmetic (unm) on {lua_typeof(a)}")


def length(a):
    t = type(a)
    if t is str:
        return float(len(a))
    if t is LuaTable:
        mt = a.meta
        if mt is not None:
            h = mt.get("__len")
            if h is not None:
                r = call(h, (a,))
                return r[0] if r else None
        return float(len(a.arr))
    if isinstance(a, UserData):
        f = getattr(a, "lua_len", None)
        if f is not None:
            return f()
    raise LuaError(f"attempt to get length of a {lua_typeof(a)} value")


def concat(a, b):
    ta = type(a)
    tb = type(b)
    if (ta is str or ta is float or ta is int) and (tb is str or tb is float or tb is int):
        return (a if ta is str else fmt_number(a)) + (b if tb is str else fmt_number(b))
    h = getmetafield(a, "__concat")
    if h is None:
        h = getmetafield(b, "__concat")
    if h is not None:
        r = call(h, (a, b))
        return r[0] if r else None
    bad = a if not (ta is str or ta is float or ta is int) else b
    raise LuaError(f"attempt to concatenate {lua_typeof(bad)} with {lua_typeof(b if bad is a else a)}"
                   if False else f"attempt to concatenate {lua_typeof(a)} with {lua_typeof(b)}")


def eq(a, b):
    if a is b:
        return True
    ta = type(a)
    tb = type(b)
    if ta is bool or tb is bool:
        return False
    if (ta is float or ta is int) and (tb is float or tb is int):
        return a == b
    if ta is str and tb is str:
        return a == b
    if ta is LuaTable and tb is LuaTable:
        h = getmetafield(a, "__eq")
        if h is not None and h is getmetafield(b, "__eq") or (h is not None and getmetafield(b, "__eq") is not None):
            r = call(h, (a, b))
            return truthy(r[0] if r else None)
        return False
    if isinstance(a, UserData) and isinstance(b, UserData):
        f = getattr(a, "lua_eq", None)
        if f is not None:
            return f(b)
        return a is b
    return False


def lt(a, b):
    ta = type(a)
    tb = type(b)
    if (ta is float or ta is int) and (tb is float or tb is int):
        return a < b
    if ta is str and tb is str:
        return a < b
    if isinstance(a, UserData):
        f = getattr(a, "lua_lt", None)
        if f is not None:
            return f(b)
    h = getmetafield(a, "__lt")
    if h is None:
        h = getmetafield(b, "__lt")
    if h is not None:
        r = call(h, (a, b))
        return truthy(r[0] if r else None)
    raise LuaError(f"attempt to compare {lua_typeof(a)} < {lua_typeof(b)}")


def le(a, b):
    ta = type(a)
    tb = type(b)
    if (ta is float or ta is int) and (tb is float or tb is int):
        return a <= b
    if ta is str and tb is str:
        return a <= b
    h = getmetafield(a, "__le")
    if h is None:
        h = getmetafield(b, "__le")
    if h is not None:
        r = call(h, (a, b))
        return truthy(r[0] if r else None)
    h = getmetafield(a, "__lt")
    if h is None:
        h = getmetafield(b, "__lt")
    if h is not None:
        r = call(h, (b, a))
        return not truthy(r[0] if r else None)
    raise LuaError(f"attempt to compare {lua_typeof(a)} <= {lua_typeof(b)}")


def _add_pos(e, chunk, line):
    """Prefix error message with position if it is a plain string without position."""
    if isinstance(e.value, str) and not getattr(e, "positioned", False):
        e.value = f"{chunk}:{line}: {e.value}"
        e.args = (e.value,)
    e.positioned = True
    return e


# ----------------------------------------------------------------------------- compiler

class LocalVar:
    __slots__ = ("name", "slot", "line", "used")

    def __init__(self, name, slot, line):
        self.name = name
        self.slot = slot
        self.line = line
        self.used = False


class FuncState:
    def __init__(self, parent, name):
        self.parent = parent
        self.name = name
        self.scopes = [{}]
        self.nslots = 2
        self.upvals = []  # list of (name, is_parent_local, index)
        self.upval_index = {}
        self.vararg = False

    def declare(self, name, line):
        slot = self.nslots
        self.nslots += 1
        v = LocalVar(name, slot, line)
        self.scopes[-1][name] = v
        return v

    def find_local(self, name):
        for sc in reversed(self.scopes):
            v = sc.get(name)
            if v is not None:
                return v
        return None

    def resolve(self, name):
        v = self.find_local(name)
        if v is not None:
            return ("local", v.slot)
        idx = self.find_upval(name)
        if idx is not None:
            return ("upval", idx)
        return ("global", name)

    def find_upval(self, name):
        if name in self.upval_index:
            return self.upval_index[name]
        if self.parent is None:
            return None
        pv = self.parent.find_local(name)
        if pv is not None:
            idx = len(self.upvals)
            self.upvals.append((name, True, pv.slot))
            self.upval_index[name] = idx
            return idx
        pidx = self.parent.find_upval(name)
        if pidx is not None:
            idx = len(self.upvals)
            self.upvals.append((name, False, pidx))
            self.upval_index[name] = idx
            return idx
        return None


class Compiler:
    def __init__(self, chunkname, env):
        self.chunk = chunkname
        self.env = env
        self.fs = None

    # ------------------------------------------------------------ blocks
    def block(self, stats, new_scope=True):
        fs = self.fs
        if new_scope:
            fs.scopes.append({})
        code = [self.stat(s) for s in stats]
        code = [c for c in code if c is not None]
        if new_scope:
            fs.scopes.pop()
        n = len(code)
        if n == 0:
            return lambda frame: None
        if n == 1:
            return code[0]
        if n == 2:
            a, b = code

            def run2(frame):
                r = a(frame)
                if r is not None:
                    return r
                return b(frame)
            return run2
        code = tuple(code)

        def run(frame):
            for c in code:
                r = c(frame)
                if r is not None:
                    return r
            return None
        return run

    # ------------------------------------------------------------ statements
    def stat(self, s):
        k = s[0]
        m = getattr(self, "st_" + k)
        fn = m(s)
        if fn is None:
            return None
        line = s[1]
        chunk = self.chunk
        st = STATE

        def wrapped(frame):
            st.line = line
            try:
                return fn(frame)
            except LuaError as e:
                raise _add_pos(e, chunk, line)
        # Only wrap statement kinds that do work directly (not compound blocks)
        if k in ("If", "While", "Repeat", "NumFor", "GenFor", "Do", "Return", "Break", "Continue"):
            if k in ("Return",):
                return wrapped
            return fn
        return wrapped

    def st_Local(self, s):
        _, line, names, exprs = s
        fs = self.fs
        if len(names) == 1 and len(exprs) == 1:
            e = self.expr(exprs[0])
            v = fs.declare(names[0], line)
            slot = v.slot

            def local1(frame):
                frame[slot] = [e(frame)]
            return local1
        evm = self.exprlist(exprs)
        slots = [fs.declare(n, line).slot for n in names]
        nn = len(slots)

        def localn(frame):
            vals = evm(frame)
            nv = len(vals)
            for i in range(nn):
                frame[slots[i]] = [vals[i] if i < nv else None]
        return localn

    def st_LocalFunc(self, s):
        _, line, name, fb = s
        v = self.fs.declare(name, line)
        slot = v.slot
        mk = self.funcbody(fb)

        def localfunc(frame):
            cell = [None]
            frame[slot] = cell
            cell[0] = mk(frame)
        return localfunc

    def st_FuncStat(self, s):
        _, line, target, fb = s
        mk = self.funcbody(fb)
        assign = self.assigner(target)

        def funcstat(frame):
            assign(frame, mk(frame))
        return funcstat

    def assigner(self, target):
        k = target[0]
        if k == "Name":
            kind, ref = self.fs.resolve(target[2])
            if kind == "local":
                def set_local(frame, v):
                    frame[ref][0] = v
                return set_local
            if kind == "upval":
                def set_upval(frame, v):
                    frame[0][ref][0] = v
                return set_upval
            env = self.env
            name = ref

            def set_global(frame, v):
                setindex(env, name, v)
            return set_global
        if k == "Index":
            obj = self.expr(target[2])
            key = self.expr(target[3])

            def set_index(frame, v):
                setindex(obj(frame), key(frame), v)
            return set_index
        raise LuaError("cannot assign")

    def st_Assign(self, s):
        _, line, targets, exprs = s
        if len(targets) == 1 and len(exprs) == 1:
            tg = targets[0]
            e = self.expr(exprs[0])
            if tg[0] == "Name":
                a = self.assigner(tg)

                def assign1(frame):
                    a(frame, e(frame))
                return assign1
            obj = self.expr(tg[2])
            key = self.expr(tg[3])

            def assign_idx(frame):
                o = obj(frame)
                kk = key(frame)
                setindex(o, kk, e(frame))
            return assign_idx
        # general: evaluate target prefixes, then values, then assign
        prep = []
        for tg in targets:
            if tg[0] == "Name":
                a = self.assigner(tg)
                prep.append(("name", a, None))
            else:
                prep.append(("idx", self.expr(tg[2]), self.expr(tg[3])))
        evm = self.exprlist(exprs)
        nt = len(prep)

        def assignn(frame):
            refs = []
            for kind, a, b in prep:
                if kind == "name":
                    refs.append((a, None))
                else:
                    refs.append((a(frame), b(frame)))
            vals = evm(frame)
            nv = len(vals)
            for i in range(nt):
                v = vals[i] if i < nv else None
                r0, r1 = refs[i]
                if r1 is None and prep[i][0] == "name":
                    r0(frame, v)
                else:
                    setindex(r0, r1, v)
        return assignn

    def st_Compound(self, s):
        _, line, op, target, rhs = s
        r = self.expr(rhs)
        if target[0] == "Name":
            get = self.expr(target)
            a = self.assigner(target)
            if op == "..":
                def comp_name_cat(frame):
                    a(frame, concat(get(frame), r(frame)))
                return comp_name_cat

            def comp_name(frame):
                a(frame, arith(op, get(frame), r(frame)))
            return comp_name
        obj = self.expr(target[2])
        key = self.expr(target[3])

        def comp_idx(frame):
            o = obj(frame)
            kk = key(frame)
            cur = index(o, kk)
            rv = r(frame)
            setindex(o, kk, concat(cur, rv) if op == ".." else arith(op, cur, rv))
        return comp_idx

    def st_CallStat(self, s):
        e = self.expr_multi(s[2])

        def callstat(frame):
            e(frame)
        return callstat

    def st_Do(self, s):
        return self.block(s[2])

    def st_While(self, s):
        _, line, cond, body = s
        c = self.expr(cond)
        b = self.block(body)
        chunk = self.chunk
        st = STATE

        def while_(frame):
            while True:
                st.line = line
                try:
                    cv = c(frame)
                except LuaError as e:
                    raise _add_pos(e, chunk, line)
                if cv is None or cv is False:
                    break
                r = b(frame)
                if r is not None:
                    if r is BREAK:
                        break
                    if r is CONTINUE:
                        continue
                    return r
            return None
        return while_

    def st_Repeat(self, s):
        _, line, body, cond = s
        fs = self.fs
        fs.scopes.append({})
        stats = [self.stat(x) for x in body]
        stats = tuple(x for x in stats if x is not None)
        c = self.expr(cond)
        fs.scopes.pop()
        chunk = self.chunk

        def repeat_(frame):
            while True:
                brk = False
                for st in stats:
                    r = st(frame)
                    if r is not None:
                        if r is BREAK:
                            brk = True
                            break
                        if r is CONTINUE:
                            break
                        return r
                if brk:
                    break
                try:
                    cv = c(frame)
                except LuaError as e:
                    raise _add_pos(e, chunk, line)
                if cv is not None and cv is not False:
                    break
            return None
        return repeat_

    def st_If(self, s):
        _, line, clauses, else_body = s
        comp = []
        for cond, body in clauses:
            comp.append((self.expr(cond), self.block(body)))
        eb = self.block(else_body) if else_body is not None else None
        chunk = self.chunk
        st = STATE
        if len(comp) == 1:
            c, b = comp[0]

            def if1(frame):
                st.line = line
                try:
                    cv = c(frame)
                except LuaError as e:
                    raise _add_pos(e, chunk, line)
                if cv is not None and cv is not False:
                    return b(frame)
                if eb is not None:
                    return eb(frame)
                return None
            return if1
        comp = tuple(comp)

        def ifn(frame):
            for c, b in comp:
                try:
                    cv = c(frame)
                except LuaError as e:
                    raise _add_pos(e, chunk, line)
                if cv is not None and cv is not False:
                    return b(frame)
            if eb is not None:
                return eb(frame)
            return None
        return ifn

    def st_NumFor(self, s):
        _, line, var, start, stop, step, body = s
        e1 = self.expr(start)
        e2 = self.expr(stop)
        e3 = self.expr(step) if step is not None else None
        fs = self.fs
        fs.scopes.append({})
        slot = fs.declare(var, line).slot
        b = self.block(body)
        fs.scopes.pop()
        chunk = self.chunk

        def numfor(frame):
            try:
                a = e1(frame)
                z = e2(frame)
                st = e3(frame) if e3 is not None else 1
                a = tonumber(a) if type(a) is str else a
                z = tonumber(z) if type(z) is str else z
                st = tonumber(st) if type(st) is str else st
                if not isinstance(a, (int, float)) or isinstance(a, bool):
                    raise LuaError("invalid 'for' initial value (number expected, got %s)" % lua_typeof(a))
                if not isinstance(z, (int, float)) or isinstance(z, bool):
                    raise LuaError("invalid 'for' limit (number expected, got %s)" % lua_typeof(z))
                if not isinstance(st, (int, float)) or isinstance(st, bool):
                    raise LuaError("invalid 'for' step (number expected, got %s)" % lua_typeof(st))
                if st == 0:
                    raise LuaError("'for' step is zero")
            except LuaError as e:
                raise _add_pos(e, chunk, line)
            i = float(a)
            if st > 0:
                while i <= z:
                    frame[slot] = [i]
                    r = b(frame)
                    if r is not None:
                        if r is BREAK:
                            break
                        if r is not CONTINUE:
                            return r
                    i += st
            else:
                while i >= z:
                    frame[slot] = [i]
                    r = b(frame)
                    if r is not None:
                        if r is BREAK:
                            break
                        if r is not CONTINUE:
                            return r
                    i += st
            return None
        return numfor

    def st_GenFor(self, s):
        _, line, names, exprs, body = s
        evm = self.exprlist(exprs)
        fs = self.fs
        fs.scopes.append({})
        slots = [fs.declare(n, line).slot for n in names]
        b = self.block(body)
        fs.scopes.pop()
        nn = len(slots)
        chunk = self.chunk
        st_ = STATE

        def genfor(frame):
            try:
                vals = evm(frame)
            except LuaError as e:
                raise _add_pos(e, chunk, line)
            f = vals[0] if vals else None
            s_ = vals[1] if len(vals) > 1 else None
            ctl = vals[2] if len(vals) > 2 else None
            if type(f) is LuaTable and len(vals) == 1:
                mt = f.meta
                it = mt.get("__iter") if mt is not None else None
                if it is not None:
                    r = call(it, (f,))
                    f = r[0] if r else None
                    s_ = r[1] if len(r) > 1 else None
                    ctl = r[2] if len(r) > 2 else None
                elif mt is not None and mt.get("__call") is not None:
                    pass
                else:
                    # generalized iteration over table
                    for k, _v in f.items():
                        v = f.get(k)
                        if v is None:
                            continue
                        if nn >= 1:
                            frame[slots[0]] = [k]
                        if nn >= 2:
                            frame[slots[1]] = [v]
                        for j in range(2, nn):
                            frame[slots[j]] = [None]
                        r = b(frame)
                        if r is not None:
                            if r is BREAK:
                                break
                            if r is not CONTINUE:
                                return r
                    return None
            if f is None or (not callable(f) and type(f) is not LuaTable):
                raise _add_pos(LuaError(f"attempt to iterate over a {lua_typeof(f)} value"), chunk, line)
            # fast path for our pairs/ipairs iterators
            pyit = getattr(f, "_py_iter", None)
            if pyit is not None:
                for tup in pyit(s_, ctl):
                    for j in range(nn):
                        frame[slots[j]] = [tup[j] if j < len(tup) else None]
                    r = b(frame)
                    if r is not None:
                        if r is BREAK:
                            break
                        if r is not CONTINUE:
                            return r
                return None
            while True:
                try:
                    rs = call(f, (s_, ctl))
                except LuaError as e:
                    raise _add_pos(e, chunk, line)
                v0 = rs[0] if rs else None
                if v0 is None:
                    break
                ctl = v0
                nr = len(rs)
                for j in range(nn):
                    frame[slots[j]] = [rs[j] if j < nr else None]
                r = b(frame)
                if r is not None:
                    if r is BREAK:
                        break
                    if r is not CONTINUE:
                        return r
            return None
        return genfor

    def st_Return(self, s):
        _, line, exprs = s
        if len(exprs) == 1:
            e0 = exprs[0]
            if e0[0] in ("Call", "Method"):
                em = self.expr_multi(e0)

                def ret_call(frame):
                    return em(frame)
                return ret_call
            e = self.expr(e0)

            def ret1(frame):
                return (e(frame),)
            return ret1
        if not exprs:
            return lambda frame: ()
        evm = self.exprlist(exprs)

        def retn(frame):
            return tuple(evm(frame))
        return retn

    def st_Break(self, s):
        return lambda frame: BREAK

    def st_Continue(self, s):
        return lambda frame: CONTINUE

    # ------------------------------------------------------------ functions
    def funcbody(self, fb):
        _, line, params, vararg, body, name, end_line = fb
        parent = self.fs
        fs = FuncState(parent, name)
        fs.vararg = vararg
        self.fs = fs
        for p in params:
            fs.declare(p, line)
        code = self.block(body, new_scope=False)
        self.fs = parent
        proto = Proto()
        proto.name = name
        proto.nparams = len(params)
        proto.vararg = vararg
        proto.body = code
        proto.nslots = fs.nslots
        proto.chunk = self.chunk
        proto.line = line
        proto.upval_desc = tuple(fs.upvals)
        env = self.env
        desc = tuple((is_local, idx) for (_, is_local, idx) in fs.upvals)

        def make(frame):
            if desc:
                outer = frame[0]
                ups = [frame[idx] if is_local else outer[idx] for (is_local, idx) in desc]
            else:
                ups = None
            return LuaFunction(proto, ups, env)
        return make

    # ------------------------------------------------------------ expressions
    def exprlist(self, exprs):
        """Returns frame -> tuple of values (last expression expanded)."""
        if not exprs:
            return lambda frame: ()
        singles = [self.expr(e) for e in exprs[:-1]]
        last = exprs[-1]
        if last[0] in ("Call", "Method", "Vararg"):
            lm = self.expr_multi(last)
            if not singles:
                return lm
            singles = tuple(singles)

            def evm(frame):
                return tuple(s(frame) for s in singles) + tuple(lm(frame))
            return evm
        allx = tuple(singles + [self.expr(last)])
        if len(allx) == 1:
            a0 = allx[0]
            return lambda frame: (a0(frame),)
        if len(allx) == 2:
            a0, a1 = allx
            return lambda frame: (a0(frame), a1(frame))
        return lambda frame: tuple(x(frame) for x in allx)

    def expr_multi(self, e):
        k = e[0]
        if k == "Call":
            return self.call_expr(e)
        if k == "Method":
            return self.method_expr(e)
        if k == "Vararg":
            return lambda frame: frame[1]
        s = self.expr(e)
        return lambda frame: (s(frame),)

    def expr(self, e):
        k = e[0]
        return getattr(self, "ex_" + k)(e)

    def ex_Nil(self, e):
        return lambda frame: None

    def ex_True(self, e):
        return lambda frame: True

    def ex_False(self, e):
        return lambda frame: False

    def ex_Num(self, e):
        v = e[2]
        return lambda frame: v

    def ex_Str(self, e):
        v = e[2]
        return lambda frame: v

    def ex_Vararg(self, e):
        def vararg1(frame):
            va = frame[1]
            return va[0] if va else None
        return vararg1

    def ex_Function(self, e):
        return self.funcbody(e[2])

    def ex_Paren(self, e):
        return self.expr(e[2])

    def ex_Cast(self, e):
        return self.expr(e[2])

    def ex_Name(self, e):
        name = e[2]
        kind, ref = self.fs.resolve(name)
        if kind == "local":
            return lambda frame: frame[ref][0]
        if kind == "upval":
            return lambda frame: frame[0][ref][0]
        env = self.env

        def getglobal(frame):
            v = env.get(name)
            if v is None and env.meta is not None:
                return index(env, name)
            return v
        return getglobal

    def ex_Index(self, e):
        _, line, obj, key = e
        o = self.expr(obj)
        if key[0] == "Str":
            kv = key[2]

            def index_const(frame):
                ov = o(frame)
                if type(ov) is LuaTable:
                    v = ov.get(kv)
                    if v is not None or ov.meta is None:
                        return v
                return index(ov, kv)
            return index_const
        kf = self.expr(key)

        def index_dyn(frame):
            return index(o(frame), kf(frame))
        return index_dyn

    def call_expr(self, e):
        _, line, fn, args = e
        f = self.expr(fn)
        chunk = self.chunk
        st = STATE
        fdesc = self.describe(fn)
        nargs = len(args)
        if nargs == 0:
            def call0(frame):
                fv = f(frame)
                st.line = line
                st.chunk = chunk
                if type(fv) is LuaFunction:
                    return fv()
                try:
                    return call(fv, ())
                except LuaError as ex:
                    if fv is None or not callable(fv) and type(fv) is not LuaTable:
                        ex.value = f"attempt to call a {lua_typeof(fv)} value ({fdesc})"
                    raise _add_pos(ex, chunk, line)
            return call0
        argm = self.exprlist(args)

        def calln(frame):
            fv = f(frame)
            a = argm(frame)
            st.line = line
            st.chunk = chunk
            if type(fv) is LuaFunction:
                return fv(*a)
            try:
                return call(fv, a)
            except LuaError as ex:
                if fv is None or (not callable(fv) and type(fv) is not LuaTable and not isinstance(fv, UserData)):
                    ex.value = f"attempt to call a {lua_typeof(fv)} value ({fdesc})"
                    ex.positioned = False
                raise _add_pos(ex, chunk, line)
        return calln

    def describe(self, e):
        k = e[0]
        if k == "Name":
            return f"global '{e[2]}'" if self.fs.resolve(e[2])[0] == "global" else f"local '{e[2]}'"
        if k == "Index" and e[3][0] == "Str":
            return f"field '{e[3][2]}'"
        return "?"

    def method_expr(self, e):
        _, line, obj, name, args = e
        o = self.expr(obj)
        argm = self.exprlist(args)
        chunk = self.chunk
        st = STATE

        def method(frame):
            ov = o(frame)
            if type(ov) is LuaTable:
                fv = ov.get(name)
                if fv is None:
                    fv = index(ov, name)
            elif ov is None:
                raise _add_pos(LuaError(f"attempt to index nil with '{name}'"), chunk, line)
            else:
                try:
                    fv = index(ov, name)
                except LuaError as ex:
                    raise _add_pos(ex, chunk, line)
            a = argm(frame)
            st.line = line
            st.chunk = chunk
            if type(fv) is LuaFunction:
                return fv(ov, *a)
            if fv is None:
                raise _add_pos(LuaError(f"attempt to call a nil value (method '{name}')"), chunk, line)
            try:
                return call(fv, (ov,) + tuple(a))
            except LuaError as ex:
                raise _add_pos(ex, chunk, line)
        return method

    def ex_Call(self, e):
        m = self.call_expr(e)

        def call1(frame):
            r = m(frame)
            return r[0] if r else None
        return call1

    def ex_Method(self, e):
        m = self.method_expr(e)

        def meth1(frame):
            r = m(frame)
            return r[0] if r else None
        return meth1

    def ex_And(self, e):
        a = self.expr(e[2])
        b = self.expr(e[3])

        def and_(frame):
            v = a(frame)
            if v is None or v is False:
                return v
            return b(frame)
        return and_

    def ex_Or(self, e):
        a = self.expr(e[2])
        b = self.expr(e[3])

        def or_(frame):
            v = a(frame)
            if v is None or v is False:
                return b(frame)
            return v
        return or_

    def ex_Un(self, e):
        _, line, op, operand = e
        a = self.expr(operand)
        if op == "not":
            def not_(frame):
                v = a(frame)
                return v is None or v is False
            return not_
        if op == "-":
            def neg(frame):
                v = a(frame)
                if type(v) is float or type(v) is int:
                    return -v
                return unm(v)
            return neg
        if op == "#":
            def len_(frame):
                return length(a(frame))
            return len_
        raise LuaError("bad unop")

    def ex_Bin(self, e):
        _, line, op, l, r = e
        a = self.expr(l)
        b = self.expr(r)
        if op == "+":
            def add(frame):
                x = a(frame)
                y = b(frame)
                if type(x) is float and type(y) is float:
                    return x + y
                return arith("+", x, y)
            return add
        if op == "-":
            def sub(frame):
                x = a(frame)
                y = b(frame)
                if type(x) is float and type(y) is float:
                    return x - y
                return arith("-", x, y)
            return sub
        if op == "*":
            def mul(frame):
                x = a(frame)
                y = b(frame)
                if type(x) is float and type(y) is float:
                    return x * y
                return arith("*", x, y)
            return mul
        if op in ("/", "//", "%", "^"):
            def ar(frame):
                return arith(op, a(frame), b(frame))
            return ar
        if op == "..":
            def cat(frame):
                x = a(frame)
                y = b(frame)
                if type(x) is str and type(y) is str:
                    return x + y
                return concat(x, y)
            return cat
        if op == "==":
            return lambda frame: eq(a(frame), b(frame))
        if op == "~=":
            return lambda frame: not eq(a(frame), b(frame))
        if op == "<":
            def lt_(frame):
                x = a(frame)
                y = b(frame)
                if type(x) is float and type(y) is float:
                    return x < y
                return lt(x, y)
            return lt_
        if op == "<=":
            return lambda frame: le(a(frame), b(frame))
        if op == ">":
            def gt_(frame):
                x = a(frame)
                y = b(frame)
                if type(x) is float and type(y) is float:
                    return x > y
                return lt(y, x)
            return gt_
        if op == ">=":
            def ge_(frame):
                x = a(frame)
                y = b(frame)
                return le(y, x)
            return ge_
        raise LuaError("bad binop " + op)

    def ex_IfExpr(self, e):
        _, line, clauses, else_v = e
        comp = tuple((self.expr(c), self.expr(v)) for c, v in clauses)
        ev = self.expr(else_v)

        def ifexpr(frame):
            for c, v in comp:
                cv = c(frame)
                if cv is not None and cv is not False:
                    return v(frame)
            return ev(frame)
        return ifexpr

    def ex_Interp(self, e):
        _, line, parts, exprs = e
        ex = tuple(self.expr(x) for x in exprs)
        parts = tuple(parts)

        def interp(frame):
            out = [parts[0]]
            for i, x in enumerate(ex):
                out.append(tostring(x(frame)))
                out.append(parts[i + 1])
            return "".join(out)
        return interp

    def ex_Table(self, e):
        _, line, items = e
        if not items:
            return lambda frame: LuaTable()
        comp = []
        n = len(items)
        for i, it in enumerate(items):
            kind = it[0]
            if kind == "pos":
                val = it[1]
                if i == n - 1 and val[0] in ("Call", "Method", "Vararg"):
                    comp.append(("multi", self.expr_multi(val), None))
                else:
                    comp.append(("pos", self.expr(val), None))
            elif kind == "named":
                comp.append(("named", it[1], self.expr(it[2])))
            else:
                comp.append(("keyed", self.expr(it[1]), self.expr(it[2])))
        comp = tuple(comp)
        chunk = self.chunk

        def table(frame):
            t = LuaTable()
            arr = t.arr
            pos = 0
            for kind, a, b in comp:
                if kind == "pos":
                    pos += 1
                    v = a(frame)
                    if pos == len(arr) + 1 and v is not None:
                        arr.append(v)
                    else:
                        t.set(float(pos), v)
                elif kind == "named":
                    v = b(frame)
                    if v is not None:
                        t.hash[a] = v
                elif kind == "keyed":
                    kv = a(frame)
                    if kv is None:
                        raise _add_pos(LuaError("table index is nil"), chunk, line)
                    t.set(kv, b(frame))
                else:
                    for v in a(frame):
                        pos += 1
                        t.set(float(pos), v)
            # trailing nils in array
            while arr and arr[-1] is None:
                arr.pop()
            return t
        return table

    # ------------------------------------------------------------ entry
    def compile_chunk(self, ast):
        fs = FuncState(None, "main chunk")
        fs.vararg = True
        self.fs = fs
        code = self.block(ast[2], new_scope=False)
        proto = Proto()
        proto.name = "main chunk"
        proto.nparams = 0
        proto.vararg = True
        proto.body = code
        proto.nslots = fs.nslots
        proto.chunk = self.chunk
        proto.line = 1
        proto.upval_desc = ()
        return LuaFunction(proto, None, self.env)


_PARSE_CACHE = {}


def load(src, chunkname, env):
    key = (src, chunkname)
    ast = _PARSE_CACHE.get(key)
    if ast is None:
        ast = parse(src, chunkname)
        _PARSE_CACHE[key] = ast
    return Compiler(chunkname, env).compile_chunk(ast)


# ----------------------------------------------------------------------------- coroutines

class CoroutineDead(Exception):
    pass


def current_thread():
    return STATE.current_thread


def thread_resume(th, args):
    """Resume a LuaThread with args. Returns (ok, values_tuple)."""
    if th.status == "dead":
        return False, ("cannot resume dead coroutine",)
    if th.status == "running":
        return False, ("cannot resume non-suspended coroutine",)
    if th.status == "normal":
        return False, ("cannot resume non-suspended coroutine",)
    prev = STATE.current_thread
    if prev is not None:
        prev.status = "normal"
    th.status = "running"
    STATE.current_thread = th
    saved_stack = STATE.stack
    STATE.stack = th.lua_stack
    try:
        if th.g is None:
            fn = th.fn

            def runner(*a):
                try:
                    r = call(fn, a)
                    return ("__done__", True, r)
                except LuaError as e:
                    return ("__done__", False, (e.value,), e)
                except RecursionError:
                    return ("__done__", False, ("stack overflow",), None)
            th.g = greenlet.greenlet(runner)
            res = th.g.switch(*args)
        else:
            th.g.parent = greenlet.getcurrent()
            res = th.g.switch(args)
    finally:
        STATE.current_thread = prev
        STATE.stack = saved_stack
        if prev is not None:
            prev.status = "running"
    if isinstance(res, tuple) and len(res) >= 3 and res[0] == "__done__":
        th.status = "dead"
        if res[1]:
            return True, res[2]
        err = res[3] if len(res) > 3 else None
        th.last_error = err
        return False, res[2], err
    th.status = "suspended"
    return True, res


def thread_yield(values):
    th = STATE.current_thread
    if th is None or th.g is None or th.is_main:
        raise LuaError("attempt to yield from outside a coroutine")
    parent = th.g.parent
    res = parent.switch(tuple(values))
    return res


# ----------------------------------------------------------------------------- stdlib

def _check_num(v, i, fname):
    t = type(v)
    if t is float or t is int:
        return v
    if t is str:
        n = tonumber(v)
        if n is not None:
            return n
    raise LuaError(f"invalid argument #{i} to '{fname}' (number expected, got {lua_typeof(v) if v is not None else 'nil'})")


def _check_int(v, i, fname):
    n = _check_num(v, i, fname)
    if n != n or n in (INF, -INF):
        raise LuaError(f"invalid argument #{i} to '{fname}' (number has no integer representation)")
    return int(math.floor(n)) if n >= 0 else int(math.ceil(n)) if False else int(n)


def _check_str(v, i, fname):
    t = type(v)
    if t is str:
        return v
    if t is float or t is int:
        return fmt_number(v)
    raise LuaError(f"invalid argument #{i} to '{fname}' (string expected, got {lua_typeof(v) if v is not None else 'nil'})")


def _check_table(v, i, fname):
    if type(v) is not LuaTable:
        raise LuaError(f"invalid argument #{i} to '{fname}' (table expected, got {lua_typeof(v) if v is not None else 'nil'})")
    return v


def _arg(args, i):
    return args[i] if i < len(args) else None


def _report_host_error(e):
    import traceback
    sys.stderr.write("HOST ERROR inside pcall: " + "".join(traceback.format_exception(e))[-3000:] + "\n")


def make_table(d=None, arr=None):
    t = LuaTable()
    if arr:
        for v in arr:
            t.arr.append(v)
    if d:
        for k, v in d.items():
            t.set(k, v)
    return t


def builtin(name):
    def deco(fn):
        return BuiltinFunction(fn, name)
    return deco


def create_globals(print_fn=None, warn_fn=None):
    G = LuaTable()

    def lua_print(*args):
        s = "\t".join(tostring(a) for a in args)
        (print_fn or (lambda x: print(x)))(s)
        return ()

    def lua_warn(*args):
        s = "\t".join(tostring(a) for a in args)
        (warn_fn or (lambda x: print("WARN: " + x)))(s)
        return ()

    def lua_type_(*args):
        if not args:
            raise LuaError("missing argument #1 to 'type'")
        return lua_type(args[0])

    def lua_typeof_(*args):
        if not args:
            raise LuaError("missing argument #1 to 'typeof'")
        return lua_typeof(args[0])

    def lua_tostring(*args):
        if not args:
            raise LuaError("missing argument #1 to 'tostring'")
        return tostring(args[0])

    def lua_tonumber(*args):
        v = _arg(args, 0)
        b = _arg(args, 1)
        return tonumber(v, b)

    def lua_assert(*args):
        if not args:
            raise LuaError("missing argument #1 to 'assert'")
        if args[0] is None or args[0] is False:
            msg = args[1] if len(args) > 1 else "assertion failed!"
            e = LuaError(msg)
            if isinstance(msg, str):
                e.value = f"{STATE.chunk}:{STATE.line}: {msg}" if msg == "assertion failed!" else msg
                e.positioned = True
            raise e
        return tuple(args)

    def lua_error(*args):
        msg = _arg(args, 0)
        level = _arg(args, 1)
        if level is None:
            level = 1
        e = LuaError(msg)
        if isinstance(msg, str) and level and level > 0:
            e.value = f"{STATE.chunk}:{STATE.line}: {msg}"
        e.positioned = True
        e.args = (e.value,)
        raise e

    def lua_pcall(*args):
        if not args:
            raise LuaError("missing argument #1 to 'pcall'")
        f = args[0]
        depth = len(STATE.stack)
        try:
            r = call(f, args[1:])
            return (True,) + tuple(r)
        except LuaError as e:
            del STATE.stack[depth:]
            return (False, e.value)
        except RecursionError:
            del STATE.stack[depth:]
            return (False, "stack overflow")
        except greenlet.GreenletExit:
            raise
        except Exception as e:  # host errors become Lua errors
            del STATE.stack[depth:]
            if isinstance(e, (KeyboardInterrupt,)):
                raise
            if getattr(e, "is_sim_fatal", False):
                raise
            _report_host_error(e)
            return (False, f"{type(e).__name__}: {e}")

    def lua_xpcall(*args):
        f = _arg(args, 0)
        h = _arg(args, 1)
        depth = len(STATE.stack)
        try:
            r = call(f, args[2:])
            return (True,) + tuple(r)
        except LuaError as e:
            del STATE.stack[depth:]
            hr = call(h, (e.value,))
            return (False,) + tuple(hr)
        except greenlet.GreenletExit:
            raise
        except Exception as e:
            del STATE.stack[depth:]
            if getattr(e, "is_sim_fatal", False):
                raise
            _report_host_error(e)
            hr = call(h, (f"{type(e).__name__}: {e}",))
            return (False,) + tuple(hr)

    def lua_select(*args):
        n = _arg(args, 0)
        if n == "#":
            return float(len(args) - 1)
        n = _check_int(n, 1, "select")
        if n < 0:
            n = len(args) - 1 + n + 1
            if n < 1:
                raise LuaError("bad argument #1 to 'select' (index out of range)")
        elif n == 0:
            raise LuaError("bad argument #1 to 'select' (index out of range)")
        return tuple(args[n:])

    def lua_rawget(*args):
        t = _check_table(_arg(args, 0), 1, "rawget")
        return t.get(_arg(args, 1))

    def lua_rawset(*args):
        t = _check_table(_arg(args, 0), 1, "rawset")
        t.set(_arg(args, 1), _arg(args, 2))
        return t

    def lua_rawequal(*args):
        a, b = _arg(args, 0), _arg(args, 1)
        if a is b:
            return True
        if type(a) is bool or type(b) is bool:
            return False
        if isinstance(a, (int, float, str)) and isinstance(b, (int, float, str)) and type(a) is not bool:
            return a == b and (type(a) is str) == (type(b) is str)
        return False

    def lua_rawlen(*args):
        v = _arg(args, 0)
        if type(v) is LuaTable:
            return float(len(v.arr))
        if type(v) is str:
            return float(len(v))
        raise LuaError("table or string expected")

    def lua_setmetatable(*args):
        t = _arg(args, 0)
        mt = _arg(args, 1)
        if type(t) is not LuaTable:
            raise LuaError(f"invalid argument #1 to 'setmetatable' (table expected, got {lua_typeof(t)})")
        if mt is not None and type(mt) is not LuaTable:
            raise LuaError("invalid argument #2 to 'setmetatable' (nil or table expected)")
        if t.meta is not None and t.meta.get("__metatable") is not None:
            raise LuaError("cannot change a protected metatable")
        if t.frozen:
            raise LuaError("attempt to modify a readonly table")
        t.meta = mt
        return t

    def lua_getmetatable(*args):
        t = _arg(args, 0)
        if type(t) is LuaTable:
            mt = t.meta
            if mt is None:
                return None
            p = mt.get("__metatable")
            if p is not None:
                return p
            return mt
        if type(t) is str:
            return STATE.string_meta
        if isinstance(t, UserData):
            gm = getattr(t, "lua_getmetatable", None)
            if gm:
                return gm()
            return "The metatable is locked"
        return None

    def lua_next(*args):
        t = _check_table(_arg(args, 0), 1, "next")
        k, v = t.next(_arg(args, 1))
        if k is None:
            return None
        return (k, v)

    lua_next_b = BuiltinFunction(lua_next, "next")

    def _pairs_iter(t, ctl):
        for k, v in t.items():
            if t.get(k) is not None:
                yield (k, t.get(k))


    class PairsIter(BuiltinFunction):
        __slots__ = ("_py_iter",)

    pairs_it = PairsIter(lua_next, "next")
    pairs_it._py_iter = _pairs_iter

    def lua_pairs(*args):
        t = _arg(args, 0)
        if type(t) is LuaTable and t.meta is not None:
            h = t.meta.get("__pairs")
            if h is not None:
                return call(h, (t,))[:3]
        if type(t) is not LuaTable:
            raise LuaError(f"invalid argument #1 to 'pairs' (table expected, got {lua_typeof(t) if t is not None else 'nil'})")
        return (pairs_it, t, None)

    def _ipairs_next(*args):
        t = args[0]
        i = args[1] + 1
        v = index(t, float(i)) if type(t) is not LuaTable or t.meta else t.get(float(i))
        if v is None:
            return None
        return (float(i), v)

    def _ipairs_iter(t, ctl):
        i = 1
        while True:
            v = t.get(float(i)) if type(t) is LuaTable else index(t, float(i))
            if v is None:
                return
            yield (float(i), v)
            i += 1

    ipairs_it = PairsIter(_ipairs_next, "ipairs_iter")
    ipairs_it._py_iter = _ipairs_iter

    def lua_ipairs(*args):
        t = _arg(args, 0)
        if type(t) is not LuaTable and not isinstance(t, UserData):
            raise LuaError(f"invalid argument #1 to 'ipairs' (table expected, got {lua_typeof(t) if t is not None else 'nil'})")
        return (ipairs_it, t, 0.0)

    def lua_unpack(*args):
        t = _arg(args, 0)
        if type(t) is not LuaTable:
            raise LuaError("invalid argument #1 to 'unpack' (table expected)")
        i = _arg(args, 1)
        j = _arg(args, 2)
        i = 1 if i is None else int(i)
        j = len(t.arr) if j is None else int(j)
        if j - i >= 8000:
            raise LuaError("too many results to unpack")
        return tuple(t.get(float(k)) for k in range(i, j + 1))

    def lua_newproxy(*args):
        return LuaTable()

    G.set("print", BuiltinFunction(lua_print, "print"))
    G.set("warn", BuiltinFunction(lua_warn, "warn"))
    G.set("type", BuiltinFunction(lua_type_, "type"))
    G.set("typeof", BuiltinFunction(lua_typeof_, "typeof"))
    G.set("tostring", BuiltinFunction(lua_tostring, "tostring"))
    G.set("tonumber", BuiltinFunction(lua_tonumber, "tonumber"))
    G.set("assert", BuiltinFunction(lua_assert, "assert"))
    G.set("error", BuiltinFunction(lua_error, "error"))
    G.set("pcall", BuiltinFunction(lua_pcall, "pcall"))
    G.set("xpcall", BuiltinFunction(lua_xpcall, "xpcall"))
    G.set("select", BuiltinFunction(lua_select, "select"))
    G.set("rawget", BuiltinFunction(lua_rawget, "rawget"))
    G.set("rawset", BuiltinFunction(lua_rawset, "rawset"))
    G.set("rawequal", BuiltinFunction(lua_rawequal, "rawequal"))
    G.set("rawlen", BuiltinFunction(lua_rawlen, "rawlen"))
    G.set("setmetatable", BuiltinFunction(lua_setmetatable, "setmetatable"))
    G.set("getmetatable", BuiltinFunction(lua_getmetatable, "getmetatable"))
    G.set("next", lua_next_b)
    G.set("pairs", BuiltinFunction(lua_pairs, "pairs"))
    G.set("ipairs", BuiltinFunction(lua_ipairs, "ipairs"))
    G.set("unpack", BuiltinFunction(lua_unpack, "unpack"))
    G.set("newproxy", BuiltinFunction(lua_newproxy, "newproxy"))
    G.set("_G", G)
    G.set("_VERSION", "Luau")

    G.set("math", make_math())
    strlib = make_string()
    G.set("string", strlib)
    STATE.string_lib = strlib
    sm = LuaTable()
    sm.set("__index", strlib)
    STATE.string_meta = sm
    G.set("table", make_tablelib(lua_unpack))
    G.set("os", make_os())
    G.set("coroutine", make_coroutine())
    G.set("utf8", make_utf8())
    G.set("bit32", make_bit32())
    G.set("buffer", make_buffer())
    dbg = LuaTable()
    dbg.set("traceback", BuiltinFunction(lambda *a: (tostring(a[0]) if a and a[0] is not None else "") + "\nstack traceback: (sim)", "traceback"))
    dbg.set("info", BuiltinFunction(lambda *a: None, "info"))
    dbg.set("profilebegin", BuiltinFunction(lambda *a: None, "profilebegin"))
    dbg.set("profileend", BuiltinFunction(lambda *a: None, "profileend"))
    dbg.set("setmemorycategory", BuiltinFunction(lambda *a: None, "setmemorycategory"))
    dbg.set("resetmemorycategory", BuiltinFunction(lambda *a: None, "resetmemorycategory"))
    G.set("debug", dbg)
    return G


def make_math():
    M = LuaTable()
    rng = _random.Random(1234)

    def f1(name, fn):
        def w(*args):
            x = _check_num(_arg(args, 0), 1, "math." + name)
            try:
                return float(fn(x))
            except (ValueError, OverflowError):
                return NAN
        M.set(name, BuiltinFunction(w, "math." + name))

    f1("abs", abs)
    f1("ceil", math.ceil)
    f1("floor", math.floor)
    f1("sqrt", lambda x: math.sqrt(x) if x >= 0 else NAN)
    f1("sin", math.sin)
    f1("cos", math.cos)
    f1("tan", math.tan)
    f1("asin", lambda x: math.asin(x) if -1 <= x <= 1 else NAN)
    f1("acos", lambda x: math.acos(x) if -1 <= x <= 1 else NAN)
    f1("exp", lambda x: math.exp(x) if x < 709 else INF)
    f1("sinh", math.sinh)
    f1("cosh", math.cosh)
    f1("tanh", math.tanh)
    f1("rad", math.radians)
    f1("deg", math.degrees)
    f1("log10", lambda x: math.log10(x) if x > 0 else (-INF if x == 0 else NAN))

    def m_atan(*args):
        y = _check_num(_arg(args, 0), 1, "math.atan")
        x = _arg(args, 1)
        if x is None:
            return float(math.atan(y))
        return float(math.atan2(y, _check_num(x, 2, "math.atan")))
    M.set("atan", BuiltinFunction(m_atan, "math.atan"))

    def m_atan2(*args):
        return float(math.atan2(_check_num(_arg(args, 0), 1, "math.atan2"), _check_num(_arg(args, 1), 2, "math.atan2")))
    M.set("atan2", BuiltinFunction(m_atan2, "math.atan2"))

    def m_log(*args):
        x = _check_num(_arg(args, 0), 1, "math.log")
        b = _arg(args, 1)
        if x == 0:
            return -INF
        if x < 0:
            return NAN
        if b is None:
            return math.log(x)
        b = _check_num(b, 2, "math.log")
        if b == 2:
            return math.log2(x)
        if b == 10:
            return math.log10(x)
        return math.log(x) / math.log(b)
    M.set("log", BuiltinFunction(m_log, "math.log"))

    def m_pow(*args):
        return _raw_arith("^", _check_num(_arg(args, 0), 1, "math.pow"), _check_num(_arg(args, 1), 2, "math.pow"))
    M.set("pow", BuiltinFunction(m_pow, "math.pow"))

    def m_fmod(*args):
        a = _check_num(_arg(args, 0), 1, "math.fmod")
        b = _check_num(_arg(args, 1), 2, "math.fmod")
        if b == 0:
            return NAN
        return math.fmod(a, b)
    M.set("fmod", BuiltinFunction(m_fmod, "math.fmod"))

    def m_modf(*args):
        x = _check_num(_arg(args, 0), 1, "math.modf")
        f, i = math.modf(x)
        return (float(i), float(f))
    M.set("modf", BuiltinFunction(m_modf, "math.modf"))

    def m_frexp(*args):
        m, e = math.frexp(_check_num(_arg(args, 0), 1, "math.frexp"))
        return (m, float(e))
    M.set("frexp", BuiltinFunction(m_frexp, "math.frexp"))
    M.set("ldexp", BuiltinFunction(lambda *a: math.ldexp(_check_num(_arg(a, 0), 1, "ldexp"), int(_check_num(_arg(a, 1), 2, "ldexp"))), "math.ldexp"))

    def m_max(*args):
        if not args:
            raise LuaError("missing argument #1 to 'max' (number expected, got no value)")
        best = _check_num(args[0], 1, "math.max")
        for i, a in enumerate(args[1:]):
            v = _check_num(a, i + 2, "math.max")
            if v > best or best != best:
                best = v
        return best
    M.set("max", BuiltinFunction(m_max, "math.max"))

    def m_min(*args):
        if not args:
            raise LuaError("missing argument #1 to 'min' (number expected, got no value)")
        best = _check_num(args[0], 1, "math.min")
        for i, a in enumerate(args[1:]):
            v = _check_num(a, i + 2, "math.min")
            if v < best or best != best:
                best = v
        return best
    M.set("min", BuiltinFunction(m_min, "math.min"))

    def m_clamp(*args):
        x = _check_num(_arg(args, 0), 1, "math.clamp")
        lo = _check_num(_arg(args, 1), 2, "math.clamp")
        hi = _check_num(_arg(args, 2), 3, "math.clamp")
        if lo > hi:
            raise LuaError("invalid argument #3 to 'clamp' (max must be greater than or equal to min)")
        return min(max(x, lo), hi)
    M.set("clamp", BuiltinFunction(m_clamp, "math.clamp"))

    def m_sign(*args):
        x = _check_num(_arg(args, 0), 1, "math.sign")
        return 1.0 if x > 0 else (-1.0 if x < 0 else 0.0)
    M.set("sign", BuiltinFunction(m_sign, "math.sign"))

    def m_round(*args):
        x = _check_num(_arg(args, 0), 1, "math.round")
        if x != x or x in (INF, -INF):
            return x
        return float(math.floor(x + 0.5)) if x >= 0 else -float(math.floor(-x + 0.5))
    M.set("round", BuiltinFunction(m_round, "math.round"))

    def m_lerp(*args):
        a = _check_num(_arg(args, 0), 1, "math.lerp")
        b = _check_num(_arg(args, 1), 2, "math.lerp")
        t = _check_num(_arg(args, 2), 3, "math.lerp")
        return a + (b - a) * t if t != 1 else b
    M.set("lerp", BuiltinFunction(m_lerp, "math.lerp"))

    def m_map(*args):
        x, a, b, c, d = (_check_num(_arg(args, i), i + 1, "math.map") for i in range(5))
        return c + (x - a) * (d - c) / (b - a)
    M.set("map", BuiltinFunction(m_map, "math.map"))

    def m_random(*args):
        if not args:
            return rng.random()
        m = _check_int(args[0], 1, "math.random")
        if len(args) == 1:
            if m < 1:
                raise LuaError("invalid argument #1 to 'random' (interval is empty)")
            return float(rng.randint(1, m))
        n = _check_int(args[1], 2, "math.random")
        if m > n:
            raise LuaError("invalid argument #2 to 'random' (interval is empty)")
        return float(rng.randint(m, n))
    M.set("random", BuiltinFunction(m_random, "math.random"))
    M.set("randomseed", BuiltinFunction(lambda *a: (rng.seed(_arg(a, 0)), None)[1], "math.randomseed"))

    def m_noise(*args):
        x = _check_num(_arg(args, 0), 1, "math.noise")
        y = _arg(args, 1) or 0.0
        z = _arg(args, 2) or 0.0
        return perlin3(float(x), float(y), float(z))
    M.set("noise", BuiltinFunction(m_noise, "math.noise"))
    M.set("huge", INF)
    M.set("pi", math.pi)
    return M


# Improved Perlin noise (same algorithm family as Roblox's math.noise)
_PERM = [151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142,
         8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117,
         35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71,
         134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41,
         55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89,
         18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226,
         250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182,
         189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43,
         172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97,
         228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107,
         49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138,
         236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180]
_P = _PERM + _PERM


def _fade(t):
    return t * t * t * (t * (t * 6 - 15) + 10)


def _grad(h, x, y, z):
    h &= 15
    u = x if h < 8 else y
    v = y if h < 4 else (x if h in (12, 14) else z)
    return (u if (h & 1) == 0 else -u) + (v if (h & 2) == 0 else -v)


def perlin3(x, y, z):
    X = int(math.floor(x)) & 255
    Y = int(math.floor(y)) & 255
    Z = int(math.floor(z)) & 255
    x -= math.floor(x)
    y -= math.floor(y)
    z -= math.floor(z)
    u, v, w = _fade(x), _fade(y), _fade(z)
    A = _P[X] + Y
    AA = _P[A] + Z
    AB = _P[A + 1] + Z
    B = _P[X + 1] + Y
    BA = _P[B] + Z
    BB = _P[B + 1] + Z

    def lerp(t, a, b):
        return a + t * (b - a)
    r = lerp(w, lerp(v, lerp(u, _grad(_P[AA], x, y, z), _grad(_P[BA], x - 1, y, z)),
                     lerp(u, _grad(_P[AB], x, y - 1, z), _grad(_P[BB], x - 1, y - 1, z))),
             lerp(v, lerp(u, _grad(_P[AA + 1], x, y, z - 1), _grad(_P[BA + 1], x - 1, y, z - 1)),
                  lerp(u, _grad(_P[AB + 1], x, y - 1, z - 1), _grad(_P[BB + 1], x - 1, y - 1, z - 1))))
    return max(-1.0, min(1.0, r))


def _str_index(i, n):
    if i < 0:
        i = n + i + 1
        if i < 1:
            i = 1
    return i


def lua_format(fmt, args):
    out = []
    i = 0
    ai = 0
    n = len(fmt)
    while i < n:
        c = fmt[i]
        if c != "%":
            out.append(c)
            i += 1
            continue
        i += 1
        if i >= n:
            raise LuaError("invalid option '%' to 'format'")
        if fmt[i] == "%":
            out.append("%")
            i += 1
            continue
        j = i
        while j < n and fmt[j] in "-+ #0":
            j += 1
        while j < n and fmt[j].isdigit():
            j += 1
        if j < n and fmt[j] == ".":
            j += 1
            while j < n and fmt[j].isdigit():
                j += 1
        if j >= n:
            raise LuaError("invalid conversion to format")
        conv = fmt[j]
        spec = "%" + fmt[i:j]
        i = j + 1
        if ai >= len(args):
            raise LuaError(f"invalid argument #{ai + 2} to 'format' (no value)")
        a = args[ai]
        ai += 1
        if conv in "di":
            v = _check_num(a, ai + 1, "format")
            if v != v or v in (INF, -INF):
                raise LuaError("invalid argument to 'format' (number has no integer representation)")
            out.append((spec + "d") % int(v))
        elif conv in "xXo":
            v = _check_num(a, ai + 1, "format")
            out.append((spec + conv) % int(v))
        elif conv in "eEfFgG":
            v = _check_num(a, ai + 1, "format")
            out.append((spec + conv) % float(v))
        elif conv == "c":
            out.append(chr(int(_check_num(a, ai + 1, "format")) & 255))
        elif conv == "s":
            s = tostring(a)
            out.append((spec + "s") % s)
        elif conv == "q":
            s = _check_str(a, ai + 1, "format")
            r = ['"']
            for ch in s:
                if ch == '"':
                    r.append('\\"')
                elif ch == "\\":
                    r.append("\\\\")
                elif ch == "\n":
                    r.append("\\n")
                elif ch == "\r":
                    r.append("\\r")
                elif ch == "\0":
                    r.append("\\0")
                elif ord(ch) < 32 or ord(ch) == 127:
                    r.append("\\%d" % ord(ch))
                else:
                    r.append(ch)
            r.append('"')
            out.append("".join(r))
        elif conv == "*":
            out.append(tostring(a))
        else:
            raise LuaError(f"invalid option '%{conv}' to 'format'")
    return "".join(out)


def make_string():
    S = LuaTable()

    def reg(name, fn):
        S.set(name, BuiltinFunction(fn, "string." + name))

    def s_len(*a):
        return float(len(_check_str(_arg(a, 0), 1, "len")))
    reg("len", s_len)

    def s_sub(*a):
        s = _check_str(_arg(a, 0), 1, "sub")
        n = len(s)
        i = _arg(a, 1)
        j = _arg(a, 2)
        i = 1 if i is None else int(_check_num(i, 2, "sub"))
        j = -1 if j is None else int(_check_num(j, 3, "sub"))
        i = _str_index(i, n)
        if j < 0:
            j = n + j + 1
        if j > n:
            j = n
        if i > j:
            return ""
        return s[i - 1:j]
    reg("sub", s_sub)

    def s_upper(*a):
        s = _check_str(_arg(a, 0), 1, "upper")
        return "".join(ch.upper() if "a" <= ch <= "z" else ch for ch in s)
    reg("upper", s_upper)

    def s_lower(*a):
        s = _check_str(_arg(a, 0), 1, "lower")
        return "".join(ch.lower() if "A" <= ch <= "Z" else ch for ch in s)
    reg("lower", s_lower)

    def s_rep(*a):
        s = _check_str(_arg(a, 0), 1, "rep")
        n = int(_check_num(_arg(a, 1), 2, "rep"))
        sep = _arg(a, 2)
        if n <= 0:
            return ""
        if sep:
            return sep.join([s] * n)
        return s * n
    reg("rep", s_rep)

    def s_reverse(*a):
        return _check_str(_arg(a, 0), 1, "reverse")[::-1]
    reg("reverse", s_reverse)

    def s_byte(*a):
        s = _check_str(_arg(a, 0), 1, "byte")
        i = _arg(a, 1)
        i = 1 if i is None else int(i)
        j = _arg(a, 2)
        j = i if j is None else int(j)
        n = len(s)
        i = _str_index(i, n)
        if j < 0:
            j = n + j + 1
        if j > n:
            j = n
        return tuple(float(ord(ch)) for ch in s[i - 1:j])
    reg("byte", s_byte)

    def s_char(*a):
        return "".join(chr(int(_check_num(x, i + 1, "char"))) for i, x in enumerate(a))
    reg("char", s_char)

    def s_format(*a):
        fmt = _check_str(_arg(a, 0), 1, "format")
        return lua_format(fmt, a[1:])
    reg("format", s_format)

    def s_find(*a):
        s = _check_str(_arg(a, 0), 1, "find")
        p = _check_str(_arg(a, 1), 2, "find")
        init = _arg(a, 2)
        init = 1 if init is None else int(_check_num(init, 3, "find"))
        plain = truthy(_arg(a, 3))
        try:
            return lua_patterns.find_aux(s, p, init, plain, True)
        except lua_patterns.PatternError as e:
            raise LuaError(str(e))
    reg("find", s_find)

    def s_match(*a):
        s = _check_str(_arg(a, 0), 1, "match")
        p = _check_str(_arg(a, 1), 2, "match")
        init = _arg(a, 2)
        init = 1 if init is None else int(_check_num(init, 3, "match"))
        try:
            return lua_patterns.find_aux(s, p, init, False, False)
        except lua_patterns.PatternError as e:
            raise LuaError(str(e))
    reg("match", s_match)

    def s_gmatch(*a):
        s = _check_str(_arg(a, 0), 1, "gmatch")
        p = _check_str(_arg(a, 1), 2, "gmatch")
        it = lua_patterns.gmatch_iter(s, p)

        def w(*_):
            try:
                return it()
            except lua_patterns.PatternError as e:
                raise LuaError(str(e))
        return BuiltinFunction(w, "gmatch_iter")
    reg("gmatch", s_gmatch)

    def s_gsub(*a):
        s = _check_str(_arg(a, 0), 1, "gsub")
        p = _check_str(_arg(a, 1), 2, "gsub")
        r = _arg(a, 2)
        if type(r) in (float, int):
            r = fmt_number(r)
        n = _arg(a, 3)
        if n is not None:
            n = int(n)
        try:
            return lua_patterns.gsub(s, p, r, n, call, tostring, index)
        except lua_patterns.PatternError as e:
            raise LuaError(str(e))
    reg("gsub", s_gsub)

    def s_split(*a):
        s = _check_str(_arg(a, 0), 1, "split")
        sep = _arg(a, 1)
        if sep is None:
            sep = ","
        t = LuaTable()
        if sep == "":
            for ch in s:
                t.arr.append(ch)
            return t
        for part in s.split(sep):
            t.arr.append(part)
        return t
    reg("split", s_split)
    return S


def make_tablelib(unpack_fn):
    T = LuaTable()

    def reg(name, fn):
        T.set(name, BuiltinFunction(fn, "table." + name))

    def t_insert(*a):
        t = _check_table(_arg(a, 0), 1, "insert")
        if t.frozen:
            raise LuaError("attempt to modify a readonly table")
        if len(a) == 2:
            n = len(t.arr)
            t.set(float(n + 1), a[1])
            return ()
        if len(a) == 3:
            pos = int(_check_num(a[1], 2, "insert"))
            n = len(t.arr)
            if pos < 1 or pos > n + 1:
                raise LuaError("invalid argument #2 to 'insert' (position out of bounds)")
            if a[2] is None:
                return ()
            t.arr.insert(pos - 1, a[2])
            h = t.hash
            j = len(t.arr) + 1
            while j in h:
                t.arr.append(h.pop(j))
                j += 1
            return ()
        raise LuaError("wrong number of arguments to 'insert'")
    reg("insert", t_insert)

    def t_remove(*a):
        t = _check_table(_arg(a, 0), 1, "remove")
        if t.frozen:
            raise LuaError("attempt to modify a readonly table")
        n = len(t.arr)
        pos = _arg(a, 1)
        if pos is None:
            if n == 0:
                return None
            v = t.arr.pop()
            while t.arr and t.arr[-1] is None:
                t.arr.pop()
            return v
        pos = int(_check_num(pos, 2, "remove"))
        if n == 0 and pos in (0, n):
            return t.get(float(pos))
        if n + 1 == pos:
            v = t.get(float(pos))
            t.set(float(pos), None)
            return v
        if pos < 1 or pos > n + 1:
            raise LuaError("invalid argument #2 to 'remove' (position out of bounds)")
        v = t.arr.pop(pos - 1)
        while t.arr and t.arr[-1] is None:
            t.arr.pop()
        return v
    reg("remove", t_remove)

    def t_concat(*a):
        t = _check_table(_arg(a, 0), 1, "concat")
        sep = _arg(a, 1) or ""
        i = _arg(a, 2)
        j = _arg(a, 3)
        i = 1 if i is None else int(i)
        j = len(t.arr) if j is None else int(j)
        parts = []
        for k in range(i, j + 1):
            v = t.get(float(k))
            if type(v) is str:
                parts.append(v)
            elif type(v) in (float, int):
                parts.append(fmt_number(v))
            else:
                raise LuaError(f"invalid value (at index {k}) in table for 'concat'")
        return sep.join(parts)
    reg("concat", t_concat)

    def t_sort(*a):
        t = _check_table(_arg(a, 0), 1, "sort")
        cmp = _arg(a, 1)
        arr = t.arr
        if any(v is None for v in arr):
            raise LuaError("table.sort: array contains nil")
        import functools
        if cmp is None:
            def k(x, y):
                if lt(x, y):
                    return -1
                if lt(y, x):
                    return 1
                return 0
        else:
            def k(x, y):
                r = call(cmp, (x, y))
                if truthy(r[0] if r else None):
                    return -1
                r2 = call(cmp, (y, x))
                if truthy(r2[0] if r2 else None):
                    return 1
                return 0
        arr.sort(key=functools.cmp_to_key(k))
        return ()
    reg("sort", t_sort)
    reg("unpack", unpack_fn)

    def t_pack(*a):
        t = LuaTable()
        for i, v in enumerate(a):
            t.set(float(i + 1), v)
        t.set("n", float(len(a)))
        return t
    reg("pack", t_pack)

    def t_clear(*a):
        t = _check_table(_arg(a, 0), 1, "clear")
        if t.frozen:
            raise LuaError("attempt to modify a readonly table")
        t.arr.clear()
        t.hash.clear()
        return ()
    reg("clear", t_clear)

    def t_find(*a):
        t = _check_table(_arg(a, 0), 1, "find")
        needle = _arg(a, 1)
        init = _arg(a, 2)
        init = 1 if init is None else int(init)
        for i in range(init - 1, len(t.arr)):
            if eq(t.arr[i], needle):
                return float(i + 1)
        return None
    reg("find", t_find)

    def t_freeze(*a):
        t = _check_table(_arg(a, 0), 1, "freeze")
        t.frozen = True
        return t
    reg("freeze", t_freeze)
    reg("isfrozen", lambda *a: _check_table(_arg(a, 0), 1, "isfrozen").frozen)

    def t_clone(*a):
        t = _check_table(_arg(a, 0), 1, "clone")
        c = LuaTable()
        c.arr = list(t.arr)
        c.hash = dict(t.hash)
        c.meta = t.meta
        return c
    reg("clone", t_clone)

    def t_create(*a):
        n = int(_check_num(_arg(a, 0), 1, "create"))
        v = _arg(a, 1)
        t = LuaTable()
        if v is not None:
            t.arr = [v] * n
        return t
    reg("create", t_create)

    def t_move(*a):
        a1 = _check_table(_arg(a, 0), 1, "move")
        f = int(_arg(a, 1))
        e = int(_arg(a, 2))
        tpos = int(_arg(a, 3))
        a2 = _arg(a, 4) or a1
        if e >= f:
            if tpos > f or tpos > e or a1 is not a2:
                for i in range(0, e - f + 1):
                    a2.set(float(tpos + i), a1.get(float(f + i)))
            else:
                for i in range(e - f, -1, -1):
                    a2.set(float(tpos + i), a1.get(float(f + i)))
        return a2
    reg("move", t_move)
    reg("maxn", lambda *a: float(max([k for k in list(range(1, len(_check_table(_arg(a, 0), 1, 'maxn').arr) + 1))] + [k for k in a[0].hash if type(k) in (int, float)] + [0])))
    reg("getn", lambda *a: float(len(_check_table(_arg(a, 0), 1, "getn").arr)))
    return T


def make_os():
    O = LuaTable()
    O.set("time", BuiltinFunction(lambda *a: float(int(STATE.hooks.os_time() if STATE.hooks else time.time())), "os.time"))
    O.set("clock", BuiltinFunction(lambda *a: float(STATE.hooks.os_clock() if STATE.hooks else time.perf_counter()), "os.clock"))

    def os_date(*a):
        fmt = _arg(a, 0) or "%c"
        t = _arg(a, 1)
        tt = time.gmtime(t if t is not None else (STATE.hooks.os_time() if STATE.hooks else time.time())) if fmt.startswith("!") else time.localtime(t if t is not None else time.time())
        f = fmt.lstrip("!")
        if f.startswith("*t"):
            r = LuaTable()
            r.set("year", float(tt.tm_year))
            r.set("month", float(tt.tm_mon))
            r.set("day", float(tt.tm_mday))
            r.set("hour", float(tt.tm_hour))
            r.set("min", float(tt.tm_min))
            r.set("sec", float(tt.tm_sec))
            r.set("wday", float((tt.tm_wday + 1) % 7 + 1))
            r.set("yday", float(tt.tm_yday))
            r.set("isdst", False)
            return r
        return time.strftime(f, tt)
    O.set("date", BuiltinFunction(os_date, "os.date"))
    O.set("difftime", BuiltinFunction(lambda *a: float(a[0] - (a[1] if len(a) > 1 and a[1] is not None else 0)), "os.difftime"))
    return O


def make_coroutine():
    C = LuaTable()

    def co_create(*a):
        f = _arg(a, 0)
        if f is None or not (callable(f) or type(f) is LuaTable):
            raise LuaError("invalid argument #1 to 'create' (function expected)")
        th = LuaThread(f, context=getattr(STATE.current_thread, "context", None))
        return th
    C.set("create", BuiltinFunction(co_create, "coroutine.create"))

    def co_resume(*a):
        th = _arg(a, 0)
        if type(th) is not LuaThread:
            raise LuaError("invalid argument #1 to 'resume' (thread expected)")
        r = thread_resume(th, a[1:])
        ok = r[0]
        if ok:
            return (True,) + tuple(r[1])
        return (False,) + tuple(r[1])
    C.set("resume", BuiltinFunction(co_resume, "coroutine.resume"))

    def co_yield(*a):
        r = thread_yield(a)
        return r
    C.set("yield", BuiltinFunction(co_yield, "coroutine.yield"))

    def co_status(*a):
        th = _arg(a, 0)
        if type(th) is not LuaThread:
            raise LuaError("invalid argument #1 to 'status' (thread expected)")
        return th.status
    C.set("status", BuiltinFunction(co_status, "coroutine.status"))

    def co_running(*a):
        th = STATE.current_thread
        return th
    C.set("running", BuiltinFunction(co_running, "coroutine.running"))

    def co_isyieldable(*a):
        th = STATE.current_thread
        return th is not None and not th.is_main
    C.set("isyieldable", BuiltinFunction(co_isyieldable, "coroutine.isyieldable"))

    def co_wrap(*a):
        f = _arg(a, 0)
        th = LuaThread(f, context=getattr(STATE.current_thread, "context", None))

        def w(*args):
            r = thread_resume(th, args)
            if r[0]:
                return tuple(r[1])
            err = r[1][0] if r[1] else None
            raise LuaError(err)
        return BuiltinFunction(w, "wrapped")
    C.set("wrap", BuiltinFunction(co_wrap, "coroutine.wrap"))

    def co_close(*a):
        th = _arg(a, 0)
        if type(th) is not LuaThread:
            raise LuaError("invalid argument #1 to 'close' (thread expected)")
        if th.status in ("suspended", "dead"):
            th.status = "dead"
            th.cancelled = True
            if th.g is not None and not th.g.dead:
                try:
                    th.g.throw(greenlet.GreenletExit)
                except greenlet.GreenletExit:
                    pass
                except Exception:
                    pass
            return True
        raise LuaError("cannot close a running coroutine")
    C.set("close", BuiltinFunction(co_close, "coroutine.close"))
    return C


def make_utf8():
    U = LuaTable()

    def decode(s):
        return s.encode("latin-1").decode("utf-8", errors="replace")

    def u_char(*a):
        return "".join(chr(int(x)).encode("utf-8").decode("latin-1") for x in a)
    U.set("char", BuiltinFunction(u_char, "utf8.char"))

    def u_len(*a):
        s = _check_str(_arg(a, 0), 1, "utf8.len")
        try:
            return float(len(s.encode("latin-1").decode("utf-8")))
        except UnicodeDecodeError as e:
            return (None, float(e.start + 1))
    U.set("len", BuiltinFunction(u_len, "utf8.len"))

    def u_codepoint(*a):
        s = _check_str(_arg(a, 0), 1, "utf8.codepoint")
        i = int(_arg(a, 1) or 1)
        j = int(_arg(a, 2) or i)
        b = s.encode("latin-1")
        res = []
        pos = i - 1
        while pos < j:
            ch = b[pos:]
            for ln in (1, 2, 3, 4):
                try:
                    c = ch[:ln].decode("utf-8")
                    res.append(float(ord(c)))
                    pos += ln
                    break
                except UnicodeDecodeError:
                    continue
            else:
                raise LuaError("invalid UTF-8 code")
        return tuple(res)
    U.set("codepoint", BuiltinFunction(u_codepoint, "utf8.codepoint"))

    def u_codes(*a):
        s = _check_str(_arg(a, 0), 1, "utf8.codes")
        b = s.encode("latin-1")
        items = []
        pos = 0
        while pos < len(b):
            for ln in (1, 2, 3, 4):
                try:
                    c = b[pos:pos + ln].decode("utf-8")
                    items.append((float(pos + 1), float(ord(c))))
                    pos += ln
                    break
                except UnicodeDecodeError:
                    continue
            else:
                raise LuaError("invalid UTF-8 code")
        st = {"i": 0}

        def it(*_):
            if st["i"] >= len(items):
                return None
            r = items[st["i"]]
            st["i"] += 1
            return r
        return (BuiltinFunction(it, "codes_iter"), s, 0.0)
    U.set("codes", BuiltinFunction(u_codes, "utf8.codes"))

    def u_offset(*a):
        s = _check_str(_arg(a, 0), 1, "utf8.offset")
        n = int(_arg(a, 1))
        i = _arg(a, 2)
        b = s.encode("latin-1")
        starts = []
        pos = 0
        while pos < len(b):
            starts.append(pos + 1)
            c = b[pos]
            pos += 1 if c < 0x80 else 2 if c < 0xE0 else 3 if c < 0xF0 else 4
        starts.append(len(b) + 1)
        if i is None:
            i = 1 if n >= 0 else len(b) + 1
        i = int(i)
        if i not in starts:
            raise LuaError("initial position is a continuation byte")
        idx = starts.index(i)
        if n > 0:
            idx += n - 1
        elif n < 0:
            idx += n
        if 0 <= idx < len(starts):
            return float(starts[idx])
        return None
    U.set("offset", BuiltinFunction(u_offset, "utf8.offset"))
    U.set("charpattern", "[\x00-\x7F\xC2-\xF4][\x80-\xBF]*")

    def u_graphemes(*a):
        s = _check_str(_arg(a, 0), 1, "utf8.graphemes")
        b = s.encode("latin-1")
        items = []
        pos = 0
        while pos < len(b):
            c = b[pos]
            ln = 1 if c < 0x80 else 2 if c < 0xE0 else 3 if c < 0xF0 else 4
            items.append((float(pos + 1), float(pos + ln)))
            pos += ln
        st = {"i": 0}

        def it(*_):
            if st["i"] >= len(items):
                return None
            r = items[st["i"]]
            st["i"] += 1
            return r
        return BuiltinFunction(it, "graphemes_iter")
    U.set("graphemes", BuiltinFunction(u_graphemes, "utf8.graphemes"))
    return U


class LuaBuffer(UserData):
    """Luau buffer: fixed-size mutable byte array."""
    __slots__ = ("data",)

    def __init__(self, size):
        self.data = bytearray(size)

    def lua_typeof(self):
        return "buffer"

    def lua_type(self):
        return "buffer"

    def lua_tostring(self):
        return "buffer"


def make_buffer():
    B = LuaTable()

    def _buf(v):
        if not isinstance(v, LuaBuffer):
            raise LuaError("invalid argument #1 (buffer expected, got " + lua_typeof(v) + ")")
        return v

    def _chk(b, off, n):
        off = int(off)
        if off < 0 or off + n > len(b.data):
            raise LuaError("buffer access out of bounds")
        return off

    def create(*a):
        n = int(a[0])
        if n < 0:
            raise LuaError("invalid size")
        return LuaBuffer(n)

    def fromstring(*a):
        s = a[0]
        raw = s.encode("latin-1") if isinstance(s, str) else bytes(s)
        b = LuaBuffer(0)
        b.data = bytearray(raw)
        return b

    def tostring_(*a):
        return bytes(_buf(a[0]).data).decode("latin-1")

    def blen(*a):
        return float(len(_buf(a[0]).data))

    def reader(fmt, n, conv=float):
        def f(*a):
            b = _buf(a[0])
            off = _chk(b, a[1], n)
            return conv(struct.unpack_from(fmt, b.data, off)[0])
        return f

    def writer(fmt, n, isint=True, bits=8, signed=False):
        def f(*a):
            b = _buf(a[0])
            off = _chk(b, a[1], n)
            v = a[2]
            if isint:
                iv = int(v)  # truncation toward zero like Luau
                mod = 1 << bits
                iv %= mod
                if signed and iv >= mod // 2:
                    iv -= mod
                struct.pack_into(fmt, b.data, off, iv)
            else:
                struct.pack_into(fmt, b.data, off, float(v))
            return ()
        return f

    B.set("create", BuiltinFunction(create, "buffer.create"))
    B.set("fromstring", BuiltinFunction(fromstring, "buffer.fromstring"))
    B.set("tostring", BuiltinFunction(tostring_, "buffer.tostring"))
    B.set("len", BuiltinFunction(blen, "buffer.len"))
    for name, fmt, n, signed in (("i8", "<b", 1, True), ("u8", "<B", 1, False), ("i16", "<h", 2, True),
                                 ("u16", "<H", 2, False), ("i32", "<i", 4, True), ("u32", "<I", 4, False)):
        B.set("read" + name, BuiltinFunction(reader(fmt, n), "buffer.read" + name))
        B.set("write" + name, BuiltinFunction(writer(fmt, n, True, n * 8, signed), "buffer.write" + name))
    B.set("readf32", BuiltinFunction(reader("<f", 4), "buffer.readf32"))
    B.set("readf64", BuiltinFunction(reader("<d", 8), "buffer.readf64"))
    B.set("writef32", BuiltinFunction(writer("<f", 4, False), "buffer.writef32"))
    B.set("writef64", BuiltinFunction(writer("<d", 8, False), "buffer.writef64"))

    def readstring(*a):
        b = _buf(a[0])
        n = int(a[2])
        off = _chk(b, a[1], n)
        return bytes(b.data[off:off + n]).decode("latin-1")

    def writestring(*a):
        b = _buf(a[0])
        s = a[2]
        raw = s.encode("latin-1")
        n = int(a[3]) if len(a) > 3 and a[3] is not None else len(raw)
        off = _chk(b, a[1], n)
        b.data[off:off + n] = raw[:n]
        return ()

    def copy(*a):
        t = _buf(a[0])
        toff = int(a[1])
        src = _buf(a[2])
        soff = int(a[3]) if len(a) > 3 and a[3] is not None else 0
        n = int(a[4]) if len(a) > 4 and a[4] is not None else len(src.data) - soff
        _chk(src, soff, n)
        _chk(t, toff, n)
        t.data[toff:toff + n] = src.data[soff:soff + n]
        return ()

    def fill(*a):
        b = _buf(a[0])
        off = int(a[1])
        v = int(a[2]) & 255
        n = int(a[3]) if len(a) > 3 and a[3] is not None else len(b.data) - off
        _chk(b, off, n)
        b.data[off:off + n] = bytes([v]) * n
        return ()

    B.set("readstring", BuiltinFunction(readstring, "buffer.readstring"))
    B.set("writestring", BuiltinFunction(writestring, "buffer.writestring"))
    B.set("copy", BuiltinFunction(copy, "buffer.copy"))
    B.set("fill", BuiltinFunction(fill, "buffer.fill"))
    return B


def make_bit32():
    B = LuaTable()
    M = 0xFFFFFFFF

    def u(v):
        return int(v) & M

    B.set("band", BuiltinFunction(lambda *a: float(_band(a)), "bit32.band"))
    B.set("bor", BuiltinFunction(lambda *a: float(_bor(a)), "bit32.bor"))
    B.set("bxor", BuiltinFunction(lambda *a: float(_bxor(a)), "bit32.bxor"))
    B.set("bnot", BuiltinFunction(lambda *a: float((~u(a[0])) & M), "bit32.bnot"))
    B.set("lshift", BuiltinFunction(lambda *a: float((u(a[0]) << int(a[1])) & M) if a[1] < 32 else 0.0, "bit32.lshift"))
    B.set("rshift", BuiltinFunction(lambda *a: float(u(a[0]) >> int(a[1])) if a[1] < 32 else 0.0, "bit32.rshift"))
    B.set("arshift", BuiltinFunction(lambda *a: float((struct.unpack('i', struct.pack('I', u(a[0])))[0] >> int(a[1])) & M), "bit32.arshift"))
    B.set("btest", BuiltinFunction(lambda *a: _band(a) != 0, "bit32.btest"))
    B.set("extract", BuiltinFunction(lambda *a: float((u(a[0]) >> int(a[1])) & ((1 << int(a[2] if len(a) > 2 and a[2] is not None else 1)) - 1)), "bit32.extract"))

    def replace(*a):
        n, v, f = u(a[0]), u(a[1]), int(a[2])
        w = int(a[3]) if len(a) > 3 and a[3] is not None else 1
        mask = ((1 << w) - 1) << f
        return float((n & ~mask | ((v << f) & mask)) & M)
    B.set("replace", BuiltinFunction(replace, "bit32.replace"))
    B.set("lrotate", BuiltinFunction(lambda *a: float(((u(a[0]) << (int(a[1]) % 32)) | (u(a[0]) >> (32 - int(a[1]) % 32))) & M), "bit32.lrotate"))
    B.set("rrotate", BuiltinFunction(lambda *a: float(((u(a[0]) >> (int(a[1]) % 32)) | (u(a[0]) << (32 - int(a[1]) % 32))) & M), "bit32.rrotate"))
    return B


def _band(a):
    r = 0xFFFFFFFF
    for x in a:
        r &= int(x) & 0xFFFFFFFF
    return r


def _bor(a):
    r = 0
    for x in a:
        r |= int(x) & 0xFFFFFFFF
    return r


def _bxor(a):
    r = 0
    for x in a:
        r ^= int(x) & 0xFFFFFFFF
    return r


# ----------------------------------------------------------------------------- simple runner

def run_source(src, chunkname="main", env=None):
    if env is None:
        env = create_globals()
    fn = load(src, chunkname, env)
    th = LuaThread(fn)
    ok, *rest = thread_resume(th, ())
    if not ok:
        raise LuaError(rest[0][0] if rest and rest[0] else "error")
    return rest[0]


if __name__ == "__main__":
    import io
    path = sys.argv[1]
    with open(path, "rb") as f:
        src = f.read().decode("latin-1")
    try:
        run_source(src, path)
    except (LuaError, ParseError, LexError) as e:
        print("ERROR:", e)
        sys.exit(1)
