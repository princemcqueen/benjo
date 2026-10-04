"""Roblox GUI layout emulation: computes AbsolutePosition/AbsoluteSize for GuiObjects,
UIListLayout/UIGridLayout, UIPadding, UIScale, size/aspect constraints, ScrollingFrame canvas,
text measurement (TextBounds/TextFits/TextScaled)."""
import math
import re

from PIL import ImageFont

from luau_interp import LuaError
from rbx_types import Vector2, Vector3, UDim2, UDim, Font, EnumItem, E, font_from_enum

FONT_DIR_POP = "/usr/share/fonts/truetype/google-fonts/"
FONT_DIR_INTER = "/usr/share/fonts/opentype/inter/"

_font_cache = {}


def _font_file(font):
    """Map a Roblox Font to a local TTF with similar metrics."""
    fam = font.family.lower() if font is not None else "gothamssm"
    w = font.weight.value if font is not None else 400
    if "gotham" in fam or "montserrat" in fam or "builder" in fam:
        if w >= 800:
            return FONT_DIR_INTER + "Inter-Black.otf", 1.08
        if w >= 600:
            return FONT_DIR_POP + "Poppins-Bold.ttf", 1.0
        if w >= 500:
            return FONT_DIR_POP + "Poppins-Medium.ttf", 1.0
        return FONT_DIR_POP + "Poppins-Regular.ttf", 1.0
    if w >= 600:
        return FONT_DIR_POP + "Poppins-Bold.ttf", 1.0
    return FONT_DIR_POP + "Poppins-Regular.ttf", 1.0


def get_pil_font(font, size):
    path, wscale = _font_file(font)
    isz = max(1, int(round(size)))
    key = (path, isz)
    f = _font_cache.get(key)
    if f is None:
        f = ImageFont.truetype(path, isz)
        _font_cache[key] = f
    return f, wscale, isz


_TAG_RE = re.compile(r"<[^>]+>")


def strip_rich(text):
    t = _TAG_RE.sub("", text)
    return t.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&").replace("&quot;", '"').replace("&apos;", "'")


def to_unicode(s):
    try:
        return s.encode("latin-1").decode("utf-8")
    except (UnicodeDecodeError, UnicodeEncodeError):
        return s


def line_width(text, font, size):
    if not text:
        return 0.0
    f, wscale, isz = get_pil_font(font, size)
    return f.getlength(text) * wscale * (size / isz)


def wrap_lines(text, font, size, max_w):
    out = []
    for para in text.split("\n"):
        words = para.split(" ")
        cur = ""
        for w in words:
            cand = w if not cur else cur + " " + w
            if line_width(cand, font, size) <= max_w + 0.5 or not cur:
                cur = cand
                # very long single word: hard break
                while line_width(cur, font, size) > max_w + 0.5 and len(cur) > 1:
                    # split characters
                    lo = 1
                    for i in range(1, len(cur) + 1):
                        if line_width(cur[:i], font, size) > max_w:
                            break
                        lo = i
                    out.append(cur[:lo])
                    cur = cur[lo:]
            else:
                out.append(cur)
                cur = w
        out.append(cur)
    return out


def measure_text(text, size, font, max_w=1e9, wrapped=False, line_height=1.0):
    text = to_unicode(text)
    if font is None:
        font = font_from_enum(E("Font", "SourceSans"))
    if wrapped and max_w < 1e8:
        lines = wrap_lines(text, font, size, max_w)
    else:
        lines = text.split("\n")
    w = max((line_width(l, font, size) for l in lines), default=0.0)
    h = len(lines) * size * line_height
    return (w, h)


# =============================================================================== layout

def _gui_children(inst):
    return [c for c in inst.children if c.is_a("GuiObject")]


def _find_comp(inst, cname):
    for c in inst.children:
        if c.cls.name == cname:
            return c
    return None


def _udim_px(ud, ref, k):
    return ud.scale * ref + ud.offset * k


class Rectf:
    __slots__ = ("x", "y", "w", "h")

    def __init__(self, x, y, w, h):
        self.x, self.y, self.w, self.h = x, y, w, h


def _font_of(inst):
    ff = inst.props.get("FontFace")
    if ff is None:
        f = inst.props.get("Font")
        if f is not None:
            return font_from_enum(f)
        return font_from_enum(E("Font", "SourceSans"))
    return ff


def is_text(inst):
    return inst.cls.name in ("TextLabel", "TextButton", "TextBox")


def _padding(inst, w, h, k):
    p = _find_comp(inst, "UIPadding")
    if p is None:
        return (0.0, 0.0, 0.0, 0.0)
    g = p.get_prop
    return (_udim_px(g("PaddingLeft"), w, k), _udim_px(g("PaddingTop"), h, k),
            _udim_px(g("PaddingRight"), w, k), _udim_px(g("PaddingBottom"), h, k))


def text_effective(inst, w, h, k):
    """Returns (text_size_px, lines, bounds_w, bounds_h, fits)."""
    g = inst.get_prop
    text = g("Text")
    if inst.cls.name == "TextBox" and text == "":
        text = g("PlaceholderText")
    if g("RichText"):
        text = strip_rich(text)
    font = _font_of(inst)
    pl, pt, pr, pb = _padding(inst, w, h, k)
    aw = max(0.0, w - pl - pr)
    ah = max(0.0, h - pt - pb)
    lh = g("LineHeight")
    wrapped = bool(g("TextWrapped"))
    if g("TextScaled"):
        tsc = _find_comp(inst, "UITextSizeConstraint")
        mx = 100.0
        mn = 1.0
        if tsc is not None:
            mx = min(mx, tsc.get_prop("MaxTextSize") * k)
            mn = max(1.0, tsc.get_prop("MinTextSize") * k)
        best = mn
        lo, hi = 1, int(mx)
        while lo <= hi:
            mid = (lo + hi) // 2
            bw, bh = measure_text(text, mid, font, aw, wrapped, lh)
            if bw <= aw + 0.5 and bh <= ah + 0.5:
                best = mid
                lo = mid + 1
            else:
                hi = mid - 1
        size = max(mn, float(best))
    else:
        size = g("TextSize") * k
    bw, bh = measure_text(text, size, font, aw, wrapped, lh)
    fits = bw <= aw + 1.0 and bh <= ah + 1.0
    return size, bw, bh, fits, text


def layout_gui(sim, ctx):
    pg = ctx.player.find_child("PlayerGui") if ctx.player is not None else None
    if pg is None:
        return
    vw, vh = ctx.device.viewport
    inset = ctx.device.topbar[3]
    for sg in pg.children:
        if sg.cls.name != "ScreenGui":
            continue
        ignore = bool(sg.get_prop("IgnoreGuiInset"))
        si = sg.get_prop("ScreenInsets").name
        if ignore or si in ("None", "DeviceSafeInsets"):
            rect = Rectf(0.0, 0.0, float(vw), float(vh))
        else:
            rect = Rectf(0.0, float(inset), float(vw), float(vh - inset))
        sg.abs_pos = (rect.x, rect.y - inset)
        sg.abs_size = (rect.w, rect.h)
        sg.extra["screen_rect"] = (rect.x, rect.y, rect.w, rect.h)
        _layout_children(sim, sg, rect, 1.0, inset)


def _apply_constraints(inst, w, h, k):
    for c in inst.children:
        cn = c.cls.name
        if cn == "UISizeConstraint":
            mn = c.get_prop("MinSize")
            mx = c.get_prop("MaxSize")
            w = min(max(w, mn.x * k), mx.x * k if mx.x != math.inf else math.inf)
            h = min(max(h, mn.y * k), mx.y * k if mx.y != math.inf else math.inf)
    for c in inst.children:
        if c.cls.name == "UIAspectRatioConstraint":
            ar = c.get_prop("AspectRatio")
            if ar <= 0:
                continue
            at = c.get_prop("AspectType").name
            if at == "FitWithinMaxSize":
                if w / max(h, 1e-9) > ar:
                    w = h * ar
                else:
                    h = w / ar
            else:
                dom = c.get_prop("DominantAxis").name
                if dom == "Width":
                    h = w / ar
                else:
                    w = h * ar
    return w, h


def _own_scale(inst):
    s = _find_comp(inst, "UIScale")
    return s.get_prop("Scale") if s is not None else 1.0


def _content_extent(sim, inst, k):
    """Approximate content size for AutomaticSize."""
    w = h = 0.0
    lay = None
    for c in inst.children:
        if c.cls.name in ("UIListLayout", "UIGridLayout"):
            lay = c
    if lay is not None and lay.extra.get("content") is not None:
        cw, ch = lay.extra["content"]
        w, h = max(w, cw), max(h, ch)
    else:
        for c in _gui_children(inst):
            if not c.get_prop("Visible") or c.abs_size is None:
                continue
            rx = c.abs_pos[0] - (inst.abs_pos[0] if inst.abs_pos else 0) + c.abs_size[0]
            ry = c.abs_pos[1] - (inst.abs_pos[1] if inst.abs_pos else 0) + c.abs_size[1]
            w, h = max(w, rx), max(h, ry)
    return w, h


def _layout_one(sim, inst, parent_rect, k_parent, inset, list_pos=None, forced_size=None):
    """Compute abs size/pos for inst given parent content rect."""
    g = inst.get_prop
    W, H = parent_rect.w, parent_rect.h
    own = _own_scale(inst)
    k = k_parent * own
    if forced_size is not None:
        w, h = forced_size
        w *= own
        h *= own
    else:
        size = g("Size")
        sc = g("SizeConstraint").name
        refx = W if sc in ("RelativeXY", "RelativeXX") else H
        refy = H if sc in ("RelativeXY", "RelativeYY") else W
        w = size.xs * refx + size.xo * k_parent
        h = size.ys * refy + size.yo * k_parent
        w *= own
        h *= own
        w, h = _apply_constraints(inst, w, h, k)
    w = max(0.0, w)
    h = max(0.0, h)
    ap = g("AnchorPoint")
    if list_pos is not None:
        x, y = list_pos
    else:
        pos = g("Position")
        ax = parent_rect.x + pos.xs * W + pos.xo * k_parent
        ay = parent_rect.y + pos.ys * H + pos.yo * k_parent
        x = ax - ap.x * w
        y = ay - ap.y * h
    inst.extra["rect"] = (x, y, w, h)
    inst.extra["k"] = k
    inst.abs_size = (w, h)
    inst.abs_pos = (x, y - inset)
    rot = g("Rotation")
    inst.abs_rot = rot
    # text
    if is_text(inst):
        ts, bw, bh, fits, txt = text_effective(inst, w, h, k)
        inst.extra["text_size"] = ts
        inst.extra["text_bounds"] = (bw, bh)
        inst.extra["text_fits"] = fits
        inst.extra["text_draw"] = txt
    # automatic size
    auto = g("AutomaticSize").name
    pl, pt, pr, pb = _padding(inst, w, h, k)
    content = Rectf(x + pl, y + pt, max(0.0, w - pl - pr), max(0.0, h - pt - pb))
    if inst.cls.name == "ScrollingFrame":
        _layout_scrolling(sim, inst, content, k, inset)
    else:
        _layout_children(sim, inst, content, k, inset)
    if auto != "None" and forced_size is None:
        cw, ch = _content_extent(sim, inst, k)
        if is_text(inst):
            bw, bh = inst.extra["text_bounds"]
            cw, ch = max(cw, bw), max(ch, bh)
        nw = max(w, cw + pl + pr) if auto in ("X", "XY") else w
        nh = max(h, ch + pt + pb) if auto in ("Y", "XY") else h
        # Constraints still apply
        for c in inst.children:
            if c.cls.name == "UISizeConstraint":
                mx = c.get_prop("MaxSize")
                nw = min(nw, mx.x * k)
                nh = min(nh, mx.y * k)
        if nw != w or nh != h:
            if list_pos is None:
                x = x + ap.x * w - ap.x * nw
                y = y + ap.y * h - ap.y * nh
            w, h = nw, nh
            inst.extra["rect"] = (x, y, w, h)
            inst.abs_size = (w, h)
            inst.abs_pos = (x, y - inset)
            if is_text(inst):
                ts, bw, bh, fits, txt = text_effective(inst, w, h, k)
                inst.extra["text_size"] = ts
                inst.extra["text_bounds"] = (bw, bh)
                inst.extra["text_fits"] = fits
                inst.extra["text_draw"] = txt
            content = Rectf(x + pl, y + pt, max(0.0, w - pl - pr), max(0.0, h - pt - pb))
            if inst.cls.name == "ScrollingFrame":
                _layout_scrolling(sim, inst, content, k, inset)
            else:
                _layout_children(sim, inst, content, k, inset)
    return w, h


def _layout_scrolling(sim, sf, window, k, inset):
    g = sf.get_prop
    cs = g("CanvasSize")
    thick = g("ScrollBarThickness") * k
    vinset = g("VerticalScrollBarInset").name
    hinset = g("HorizontalScrollBarInset").name
    win_w, win_h = window.w, window.h
    canvas_w = cs.xs * win_w + cs.xo * k
    canvas_h = cs.ys * win_h + cs.yo * k
    auto = g("AutomaticCanvasSize").name
    for _ in range(2):
        eff_w = win_w - (thick if vinset == "Always" or (vinset == "ScrollBar" and canvas_h > win_h + 0.5) else 0)
        eff_h = win_h - (thick if hinset == "Always" or (hinset == "ScrollBar" and canvas_w > eff_w + 0.5) else 0)
        # Roblox: the canvas is never smaller than the visible window.
        cw = max(canvas_w, eff_w)
        ch = max(canvas_h, eff_h)
        cp = g("CanvasPosition")
        maxx = max(0.0, cw - eff_w)
        maxy = max(0.0, ch - eff_h)
        cpx = min(max(cp.x, 0.0), maxx)
        cpy = min(max(cp.y, 0.0), maxy)
        canvas_rect = Rectf(window.x - cpx, window.y - cpy, cw, ch)
        # children laid out against canvas width (scale relative to canvas)
        _layout_children(sim, sf, Rectf(canvas_rect.x, canvas_rect.y, max(canvas_rect.w, 0), max(canvas_rect.h, 0)), k, inset)
        if auto == "None":
            break
        # content extents relative to canvas origin
        ext_w = ext_h = 0.0
        lay = None
        for c in sf.children:
            if c.cls.name in ("UIListLayout", "UIGridLayout"):
                lay = c
        if lay is not None and lay.extra.get("content") is not None:
            ext_w, ext_h = lay.extra["content"]
            pl, pt, pr, pb = _padding(sf, cw, ch, k)
            ext_w += pl + pr
            ext_h += pt + pb
        else:
            for c in _gui_children(sf):
                if not c.get_prop("Visible") or "rect" not in c.extra:
                    continue
                rx, ry, rw, rh = c.extra["rect"]
                ext_w = max(ext_w, rx - canvas_rect.x + rw)
                ext_h = max(ext_h, ry - canvas_rect.y + rh)
        new_cw = max(canvas_w, ext_w) if auto in ("X", "XY") else canvas_w
        new_ch = max(canvas_h, ext_h) if auto in ("Y", "XY") else canvas_h
        if abs(new_cw - canvas_w) < 0.5 and abs(new_ch - canvas_h) < 0.5:
            break
        canvas_w, canvas_h = new_cw, new_ch
    sf.extra["canvas"] = (max(canvas_w, eff_w), max(canvas_h, eff_h))
    sf.extra["window"] = (eff_w, eff_h)
    sf.extra["canvas_pos"] = (cpx, cpy)
    sf.extra["clip"] = (window.x, window.y, eff_w, eff_h)


def _sorted_children(container, layout):
    kids = [c for c in _gui_children(container) if c.get_prop("Visible")]
    so = layout.get_prop("SortOrder").name
    if so == "Name":
        kids.sort(key=lambda c: c.Name)
    elif so == "LayoutOrder":
        kids = sorted(kids, key=lambda c: c.get_prop("LayoutOrder"))
    return kids


def _layout_children(sim, inst, content, k, inset):
    layout = None
    for c in inst.children:
        if c.cls.name in ("UIListLayout", "UIGridLayout", "UIPageLayout") and c not in ():
            layout = c
            break
    kids = _gui_children(inst)
    if layout is None:
        for c in kids:
            _layout_one(sim, c, content, k, inset)
        return
    # invisible children still get sizes
    for c in kids:
        if not c.get_prop("Visible"):
            _layout_one(sim, c, content, k, inset)
    if layout.cls.name == "UIListLayout":
        _list_layout(sim, inst, layout, content, k, inset)
    elif layout.cls.name == "UIGridLayout":
        _grid_layout(sim, inst, layout, content, k, inset)
    else:
        for c in kids:
            _layout_one(sim, c, content, k, inset)


def _translate(inst, dx, dy):
    if "rect" in inst.extra:
        x, y, w, h = inst.extra["rect"]
        inst.extra["rect"] = (x + dx, y + dy, w, h)
    if inst.abs_pos is not None:
        inst.abs_pos = (inst.abs_pos[0] + dx, inst.abs_pos[1] + dy)
    if "clip" in inst.extra:
        x, y, w, h = inst.extra["clip"]
        inst.extra["clip"] = (x + dx, y + dy, w, h)
    for c in inst.children:
        if c.is_a("GuiObject"):
            _translate(c, dx, dy)


def _list_layout(sim, inst, lay, content, k, inset):
    g = lay.get_prop
    vertical = g("FillDirection").name == "Vertical"
    pad = g("Padding")
    padpx = _udim_px(pad, content.h if vertical else content.w, k)
    kids = _sorted_children(inst, lay)
    sizes = []
    for c in kids:
        w, h = _layout_one(sim, c, content, k, inset, list_pos=(0.0, 0.0))
        sizes.append((w, h))
    if vertical:
        total = sum(s[1] for s in sizes) + padpx * max(0, len(kids) - 1)
        va = g("VerticalAlignment").name
        y = content.y + (0 if va == "Top" else (content.h - total) / 2 if va == "Center" else content.h - total)
        ha = g("HorizontalAlignment").name
        maxw = 0.0
        for c, (w, h) in zip(kids, sizes):
            x = content.x + (0 if ha == "Left" else (content.w - w) / 2 if ha == "Center" else content.w - w)
            _translate(c, x, y)
            y += h + padpx
            maxw = max(maxw, w)
        lay.extra["content"] = (maxw, total)
    else:
        total = sum(s[0] for s in sizes) + padpx * max(0, len(kids) - 1)
        ha = g("HorizontalAlignment").name
        x = content.x + (0 if ha == "Left" else (content.w - total) / 2 if ha == "Center" else content.w - total)
        va = g("VerticalAlignment").name
        maxh = 0.0
        for c, (w, h) in zip(kids, sizes):
            y = content.y + (0 if va == "Top" else (content.h - h) / 2 if va == "Center" else content.h - h)
            _translate(c, x, y)
            x += w + padpx
            maxh = max(maxh, h)
        lay.extra["content"] = (total, maxh)


def _grid_layout(sim, inst, lay, content, k, inset):
    g = lay.get_prop
    cs = g("CellSize")
    cp = g("CellPadding")
    cw = cs.xs * content.w + cs.xo * k
    ch = cs.ys * content.h + cs.yo * k
    arc = _find_comp(lay, "UIAspectRatioConstraint")
    if arc is not None:
        ar = arc.get_prop("AspectRatio")
        if cw / max(ch, 1e-9) > ar:
            cw = ch * ar
        else:
            ch = cw / ar
    px = cp.xs * content.w + cp.xo * k
    py = cp.ys * content.h + cp.yo * k
    kids = _sorted_children(inst, lay)
    horiz = g("FillDirection").name == "Horizontal"
    maxc = int(g("FillDirectionMaxCells"))
    if horiz:
        per = max(1, int(math.floor((content.w + px + 1e-6) / (cw + px)))) if cw + px > 0 else 1
    else:
        per = max(1, int(math.floor((content.h + py + 1e-6) / (ch + py)))) if ch + py > 0 else 1
    if maxc > 0:
        per = min(per, maxc)
    n = len(kids)
    if horiz:
        cols = min(per, max(1, n))
        rows = int(math.ceil(n / per)) if n else 0
    else:
        rows = min(per, max(1, n))
        cols = int(math.ceil(n / per)) if n else 0
    tw = cols * cw + max(0, cols - 1) * px
    th = rows * ch + max(0, rows - 1) * py
    ha = g("HorizontalAlignment").name
    va = g("VerticalAlignment").name
    ox = content.x + (0 if ha == "Left" else (content.w - tw) / 2 if ha == "Center" else content.w - tw)
    oy = content.y + (0 if va == "Top" else (content.h - th) / 2 if va == "Center" else content.h - th)
    for i, c in enumerate(kids):
        if horiz:
            r, col = divmod(i, per)
        else:
            col, r = divmod(i, per)
        x = ox + col * (cw + px)
        y = oy + r * (ch + py)
        _layout_one(sim, c, content, k, inset, list_pos=(x, y), forced_size=(cw / max(_own_scale(c), 1e-9) if False else cw, ch))
    lay.extra["content"] = (tw, th)
    lay.extra["cell"] = (cw, ch, cols, rows)


def ensure_layout(sim, ctx, fire_signals=False):
    if ctx.layout_dirty:
        ctx.layout_dirty = False
        layout_gui(sim, ctx)
    if fire_signals:
        notify_changes(sim, ctx)


def notify_changes(sim, ctx):
    pg = ctx.player.find_child("PlayerGui") if ctx.player is not None else None
    if pg is None:
        return
    for d in pg.descendants():
        if d.is_a("GuiBase2d"):
            snap = (d.abs_pos, d.abs_size, d.extra.get("window"), d.extra.get("canvas"))
            old = d.extra.get("notified")
            if old == snap:
                continue
            d.extra["notified"] = snap
            if old is None:
                old = (None, None, None, None)
            if old[0] != snap[0]:
                d.changed("AbsolutePosition")
            if old[1] != snap[1]:
                d.changed("AbsoluteSize")
            if d.cls.name == "ScrollingFrame":
                if old[2] != snap[2]:
                    d.changed("AbsoluteWindowSize")
                if old[3] != snap[3]:
                    d.changed("AbsoluteCanvasSize")
        elif d.cls.name in ("UIListLayout", "UIGridLayout"):
            snap = d.extra.get("content")
            if d.extra.get("notified") != snap:
                d.extra["notified"] = snap
                d.changed("AbsoluteContentSize")


def _ctx_for(sim, inst):
    p = inst
    while p is not None:
        if p.cls.name == "Player":
            return p.extra.get("ctx")
        p = p.parent
    return None


def install(sim, M, G, S):
    def lay(inst):
        ctx = _ctx_for(sim, inst)
        if ctx is not None and ctx.layout_dirty:
            ensure_layout(sim, ctx)

    @G("GuiBase2d", "AbsoluteSize")
    def g_abs_size(self):
        lay(self)
        s = self.abs_size or (0.0, 0.0)
        return Vector2(s[0], s[1])

    @G("GuiBase2d", "AbsolutePosition")
    def g_abs_pos(self):
        lay(self)
        p = self.abs_pos or (0.0, 0.0)
        return Vector2(p[0], p[1])

    @G("GuiBase2d", "AbsoluteRotation")
    def g_abs_rot(self):
        return float(self.get_prop("Rotation")) if self.is_a("GuiObject") else 0.0

    @G("TextLabel", "TextBounds")
    def g_tb(self):
        lay(self)
        b = self.extra.get("text_bounds", (0.0, 0.0))
        return Vector2(b[0], b[1])
    G("TextButton", "TextBounds")(g_tb)
    G("TextBox", "TextBounds")(g_tb)

    @G("TextLabel", "TextFits")
    def g_tf(self):
        lay(self)
        return bool(self.extra.get("text_fits", True))
    G("TextButton", "TextFits")(g_tf)
    G("TextBox", "TextFits")(g_tf)

    @G("TextLabel", "ContentText")
    def g_ct(self):
        t = self.get_prop("Text")
        return strip_rich(t) if self.get_prop("RichText") else t
    G("TextButton", "ContentText")(g_ct)
    G("TextBox", "ContentText")(g_ct)

    @G("ScrollingFrame", "AbsoluteCanvasSize")
    def g_acs(self):
        lay(self)
        c = self.extra.get("canvas", (0.0, 0.0))
        return Vector2(c[0], c[1])

    @G("ScrollingFrame", "AbsoluteWindowSize")
    def g_aws(self):
        lay(self)
        c = self.extra.get("window", (0.0, 0.0))
        return Vector2(c[0], c[1])

    @G("UIGridStyleLayout", "AbsoluteContentSize")
    def g_acs2(self):
        if self.parent is not None:
            lay(self.parent)
        c = self.extra.get("content", (0.0, 0.0))
        return Vector2(c[0], c[1])

    @G("UIGridLayout", "AbsoluteCellSize")
    def g_acell(self):
        if self.parent is not None:
            lay(self.parent)
        c = self.extra.get("cell", (0.0, 0.0, 0, 0))
        return Vector2(c[0], c[1])

    @G("UIGridLayout", "AbsoluteCellCount")
    def g_acellc(self):
        if self.parent is not None:
            lay(self.parent)
        c = self.extra.get("cell", (0.0, 0.0, 0, 0))
        return Vector2(c[2], c[3])

    @S("ScrollingFrame", "CanvasPosition")
    def s_canvaspos(self, v):
        old = self.props.get("CanvasPosition")
        self.props["CanvasPosition"] = v
        if old is None or not old.lua_eq(v):
            self.changed("CanvasPosition")
