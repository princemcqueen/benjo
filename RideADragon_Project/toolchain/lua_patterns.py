"""Port of Lua 5.1 string pattern matching (lstrlib.c) to Python.
Strings are Python str where each character is one byte (latin-1)."""

L_ESC = "%"
SPECIALS = "^$*+?.([%-"
MAXCCALLS = 200


class PatternError(Exception):
    pass


class MatchState:
    __slots__ = ("src", "pat", "level", "capture", "depth")

    def __init__(self, src, pat):
        self.src = src
        self.pat = pat
        self.level = 0
        self.capture = []  # list of [start, len]  len: -1 = position capture, -2 = unfinished
        self.depth = 0


CAP_UNFINISHED = -1
CAP_POSITION = -2


def _class_end(ms, p):
    pat = ms.pat
    if p >= len(pat):
        raise PatternError("malformed pattern (ends with '%')")
    c = pat[p]
    p += 1
    if c == L_ESC:
        if p >= len(pat):
            raise PatternError("malformed pattern (ends with '%')")
        return p + 1
    if c == "[":
        if p < len(pat) and pat[p] == "^":
            p += 1
        while True:  # look for a ']'
            if p >= len(pat):
                raise PatternError("malformed pattern (missing ']')")
            cc = pat[p]
            p += 1
            if cc == L_ESC:
                if p >= len(pat):
                    raise PatternError("malformed pattern")
                p += 1
            if p < len(pat) and pat[p] == "]":
                return p + 1
            if p >= len(pat):
                raise PatternError("malformed pattern (missing ']')")
    return p


def _single_class(c, cl):
    o = ord(c)
    lower = cl.lower()
    if lower == "a":
        res = c.isalpha() and o < 128
    elif lower == "c":
        res = o < 32 or o == 127
    elif lower == "d":
        res = "0" <= c <= "9"
    elif lower == "l":
        res = "a" <= c <= "z"
    elif lower == "p":
        res = (33 <= o <= 47) or (58 <= o <= 64) or (91 <= o <= 96) or (123 <= o <= 126)
    elif lower == "s":
        res = c in " \t\n\r\f\v"
    elif lower == "u":
        res = "A" <= c <= "Z"
    elif lower == "w":
        res = (c.isalnum() and o < 128)
    elif lower == "x":
        res = c in "0123456789abcdefABCDEF"
    elif lower == "z":
        res = o == 0
    else:
        return cl == c
    if cl.isupper():
        return not res
    return res


def _match_bracket_class(ms, c, p, ec):
    # p points at '[' ; ec points at ']'
    pat = ms.pat
    sig = True
    p += 1
    if pat[p] == "^":
        sig = False
        p += 1
    while p < ec:
        if pat[p] == L_ESC:
            p += 1
            if _single_class(c, pat[p]):
                return sig
            p += 1
        elif p + 2 < ec and pat[p + 1] == "-":
            if pat[p] <= c <= pat[p + 2]:
                return sig
            p += 3
        else:
            if pat[p] == c:
                return sig
            p += 1
    return not sig


def _single_match(ms, s, p, ep):
    if s >= len(ms.src):
        return False
    c = ms.src[s]
    pc = ms.pat[p]
    if pc == ".":
        return True
    if pc == L_ESC:
        return _single_class(c, ms.pat[p + 1])
    if pc == "[":
        return _match_bracket_class(ms, c, p, ep - 1)
    return pc == c


def _match_balance(ms, s, p):
    pat = ms.pat
    if p + 1 >= len(pat):
        raise PatternError("missing arguments to '%b'")
    src = ms.src
    if s >= len(src) or src[s] != pat[p]:
        return -1
    b, e = pat[p], pat[p + 1]
    cont = 1
    s += 1
    while s < len(src):
        ch = src[s]
        if ch == e:
            cont -= 1
            if cont == 0:
                return s + 1
        elif ch == b:
            cont += 1
        s += 1
    return -1


def _max_expand(ms, s, p, ep):
    i = 0
    while _single_match(ms, s + i, p, ep):
        i += 1
    while i >= 0:
        res = _do_match(ms, s + i, ep + 1)
        if res != -1:
            return res
        i -= 1
    return -1


def _min_expand(ms, s, p, ep):
    while True:
        res = _do_match(ms, s, ep + 1)
        if res != -1:
            return res
        if _single_match(ms, s, p, ep):
            s += 1
        else:
            return -1


def _start_capture(ms, s, p, what):
    ms.capture.append([s, what])
    ms.level += 1
    res = _do_match(ms, s, p)
    if res == -1:
        ms.level -= 1
        ms.capture.pop()
    return res


def _capture_to_close(ms):
    level = ms.level - 1
    while level >= 0:
        if ms.capture[level][1] == CAP_UNFINISHED:
            return level
        level -= 1
    raise PatternError("invalid pattern capture")


def _end_capture(ms, s, p):
    l = _capture_to_close(ms)
    ms.capture[l][1] = s - ms.capture[l][0]
    res = _do_match(ms, s, p)
    if res == -1:
        ms.capture[l][1] = CAP_UNFINISHED
    return res


def _check_capture(ms, l):
    idx = ord(l) - ord("1")
    if idx < 0 or idx >= ms.level or ms.capture[idx][1] == CAP_UNFINISHED:
        raise PatternError("invalid capture index")
    return idx


def _match_capture(ms, s, l):
    idx = _check_capture(ms, l)
    st, ln = ms.capture[idx]
    cap = ms.src[st:st + ln]
    if ms.src[s:s + ln] == cap and len(ms.src) - s >= ln:
        return s + ln
    return -1


def _do_match(ms, s, p):
    ms.depth += 1
    if ms.depth > MAXCCALLS * 50:
        raise PatternError("pattern too complex")
    try:
        pat = ms.pat
        while True:
            if p >= len(pat):
                return s
            pc = pat[p]
            if pc == "(":
                if p + 1 < len(pat) and pat[p + 1] == ")":
                    return _start_capture(ms, s, p + 2, CAP_POSITION)
                return _start_capture(ms, s, p + 1, CAP_UNFINISHED)
            if pc == ")":
                return _end_capture(ms, s, p + 1)
            if pc == "$" and p + 1 == len(pat):
                return s if s == len(ms.src) else -1
            if pc == L_ESC and p + 1 < len(pat):
                nc = pat[p + 1]
                if nc == "b":
                    s = _match_balance(ms, s, p + 2)
                    if s != -1:
                        p += 4
                        continue
                    return -1
                if nc == "f":
                    p += 2
                    if p >= len(pat) or pat[p] != "[":
                        raise PatternError("missing '[' after '%f' in pattern")
                    ep = _class_end(ms, p)
                    prev = ms.src[s - 1] if s > 0 else "\0"
                    cur = ms.src[s] if s < len(ms.src) else "\0"
                    if (not _match_bracket_class(ms, prev, p, ep - 1)) and _match_bracket_class(ms, cur, p, ep - 1):
                        p = ep
                        continue
                    return -1
                if nc.isdigit():
                    s = _match_capture(ms, s, nc)
                    if s != -1:
                        p += 2
                        continue
                    return -1
            # default
            ep = _class_end(ms, p)
            m = s < len(ms.src) and _single_match(ms, s, p, ep)
            epc = pat[ep] if ep < len(pat) else ""
            if epc == "?":
                if m:
                    res = _do_match(ms, s + 1, ep + 1)
                    if res != -1:
                        return res
                p = ep + 1
                continue
            if epc == "*":
                return _max_expand(ms, s, p, ep)
            if epc == "+":
                return _max_expand(ms, s + 1, p, ep) if m else -1
            if epc == "-":
                return _min_expand(ms, s, p, ep)
            if not m:
                return -1
            s += 1
            p = ep
    finally:
        ms.depth -= 1


def _get_capture(ms, i, s, e):
    if i >= ms.level:
        if i == 0:
            return ms.src[s:e]
        raise PatternError("invalid capture index")
    st, ln = ms.capture[i]
    if ln == CAP_UNFINISHED:
        raise PatternError("unfinished capture")
    if ln == CAP_POSITION:
        return float(st + 1)
    return ms.src[st:st + ln]


def get_captures(ms, s, e, whole_if_none=True):
    n = ms.level if (ms.level or not whole_if_none) else 1
    return [_get_capture(ms, i, s, e) for i in range(n)]


def find_aux(src, pat, init, plain, find):
    """Returns tuple of results (Lua semantics) for string.find / string.match."""
    ls = len(src)
    if init < 0:
        init = ls + init + 1
        if init < 1:
            init = 1
    elif init == 0:
        init = 1
    if init > ls + 1:
        return (None,)
    if find and (plain or not any(c in SPECIALS for c in pat)):
        idx = src.find(pat, init - 1)
        if idx < 0:
            return (None,)
        return (float(idx + 1), float(idx + len(pat)))
    anchor = pat.startswith("^")
    p0 = 1 if anchor else 0
    s1 = init - 1
    while True:
        ms = MatchState(src, pat)
        e = _do_match(ms, s1, p0)
        if e != -1:
            if find:
                caps = get_captures(ms, s1, e, whole_if_none=False) if ms.level else []
                return (float(s1 + 1), float(e)) + tuple(caps)
            return tuple(get_captures(ms, s1, e))
        s1 += 1
        if anchor or s1 > ls:
            return (None,)


def gmatch_iter(src, pat):
    pos = [0]

    def it(*_):
        s = pos[0]
        while s <= len(src):
            ms = MatchState(src, pat)
            e = _do_match(ms, s, 0)
            if e != -1:
                newstart = e
                if e == s:
                    newstart += 1
                pos[0] = newstart
                return tuple(get_captures(ms, s, e))
            s += 1
        pos[0] = len(src) + 1
        return (None,)
    return it


def gsub(src, pat, repl, max_n, call_fn, tostr, index_fn):
    """repl: str | LuaTable | callable. call_fn(fn, args) -> tuple; index_fn(t, k)."""
    anchor = pat.startswith("^")
    p0 = 1 if anchor else 0
    s = 0
    n = 0
    out = []
    ls = len(src)
    while max_n is None or n < max_n:
        ms = MatchState(src, pat)
        e = _do_match(ms, s, p0)
        if e != -1:
            n += 1
            whole = src[s:e]
            if isinstance(repl, str):
                i = 0
                while i < len(repl):
                    c = repl[i]
                    if c == "%":
                        i += 1
                        if i >= len(repl):
                            raise PatternError("invalid use of '%' in replacement string")
                        d = repl[i]
                        if d == "%":
                            out.append("%")
                        elif d.isdigit():
                            if d == "0":
                                out.append(whole)
                            else:
                                cap = _get_capture(ms, ord(d) - ord("1"), s, e)
                                out.append(tostr(cap) if not isinstance(cap, str) else cap)
                        else:
                            raise PatternError("invalid use of '%' in replacement string")
                    else:
                        out.append(c)
                    i += 1
            else:
                caps = get_captures(ms, s, e)
                if callable(repl) and not hasattr(repl, "hash"):
                    r = call_fn(repl, caps)
                    v = r[0] if r else None
                else:
                    v = index_fn(repl, caps[0])
                if v is None or v is False:
                    out.append(whole)
                elif isinstance(v, str):
                    out.append(v)
                elif isinstance(v, (int, float)) and not isinstance(v, bool):
                    out.append(tostr(v))
                else:
                    raise PatternError("invalid replacement value (a %s)" % type(v).__name__)
        if e != -1 and e > s:
            s = e
        elif s < ls:
            out.append(src[s])
            s += 1
        else:
            break
        if anchor:
            break
    out.append(src[s:])
    return "".join(out), float(n)
