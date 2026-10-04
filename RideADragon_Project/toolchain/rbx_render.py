"""Render a client's PlayerGui to a PNG (PIL) for visual resolution QA."""
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

import rbx_layout
from rbx_layout import get_pil_font, to_unicode, wrap_lines, line_width, _font_of, _find_comp


def _c(c3, a=1.0):
    r, g, b = c3.rgb255()
    return (r, g, b, int(round(max(0, min(1, a)) * 255)))


def background(w, h, style="sky"):
    img = Image.new("RGBA", (w, h))
    arr = np.zeros((h, w, 4), dtype=np.uint8)
    yy = np.linspace(0, 1, h)[:, None]
    xx = np.linspace(0, 1, w)[None, :]
    # sky gradient + hills to mimic game scene
    sky_top = np.array([110, 160, 210])
    sky_bot = np.array([205, 220, 230])
    t = np.clip(yy / 0.62, 0, 1)
    col = sky_top * (1 - t)[..., None] + sky_bot * t[..., None]
    col = np.broadcast_to(col, (h, w, 3)).copy()
    hill = 0.58 + 0.05 * np.sin(xx * 9.0) + 0.03 * np.sin(xx * 23 + 1.3)
    ground = yy > hill
    g = np.array([88, 128, 70]) * (1 - 0.35 * (yy - 0.6))[..., None]
    g = np.broadcast_to(g, (h, w, 3))
    col = np.where(ground[..., None], g, col)
    mtn = (yy > 0.42 + 0.12 * np.abs(np.sin(xx * 5.0 + 0.4))) & ~ground
    col = np.where(mtn[..., None], np.array([120, 130, 150]), col)
    arr[..., :3] = col.astype(np.uint8)
    arr[..., 3] = 255
    return Image.fromarray(arr, "RGBA")


def _corner_radius(inst, w, h, k):
    c = _find_comp(inst, "UICorner")
    if c is None:
        return 0.0
    r = c.get_prop("CornerRadius")
    return min(r.scale * min(w, h) + r.offset * k, min(w, h) / 2)


def _gradient(inst):
    for c in inst.children:
        if c.cls.name == "UIGradient" and c.get_prop("Enabled"):
            return c
    return None


def _stroke(inst):
    for c in inst.children:
        if c.cls.name == "UIStroke" and c.get_prop("Enabled"):
            return c
    return None


def _draw_rounded(layer, rect, radius, fill=None, outline=None, width=1):
    x, y, w, h = rect
    if w <= 0 or h <= 0:
        return
    d = ImageDraw.Draw(layer)
    box = [x, y, x + max(w, 1.0) - 1, y + max(h, 1.0) - 1]
    radius = min(radius, max(0.0, min(w, h) / 2 - 0.01))
    if radius >= 1:
        d.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)
    else:
        d.rectangle(box, fill=fill, outline=outline, width=width)


def _gradient_fill(layer, rect, radius, base_color, base_alpha, grad):
    x, y, w, h = rect
    iw, ih = int(math.ceil(w)), int(math.ceil(h))
    if iw <= 0 or ih <= 0:
        return
    rot = math.radians(grad.get_prop("Rotation"))
    off = grad.get_prop("Offset")
    cs = grad.get_prop("Color")
    ns = grad.get_prop("Transparency")
    yy, xx = np.mgrid[0:ih, 0:iw]
    u = (xx + 0.5) / max(iw, 1) - 0.5 - off.x
    v = (yy + 0.5) / max(ih, 1) - 0.5 - off.y
    t = u * math.cos(rot) + v * math.sin(rot) + 0.5
    t = np.clip(t, 0, 1)
    # sample sequences
    kps_t = [k.time for k in cs.kps]
    rr = np.interp(t, kps_t, [k.value.r for k in cs.kps])
    gg = np.interp(t, kps_t, [k.value.g for k in cs.kps])
    bb = np.interp(t, kps_t, [k.value.b for k in cs.kps])
    tr = np.interp(t, [k.time for k in ns.kps], [k.value for k in ns.kps])
    br, bg, bbv = base_color.r, base_color.g, base_color.b
    arr = np.zeros((ih, iw, 4), dtype=np.uint8)
    arr[..., 0] = np.clip(rr * br * 255, 0, 255)
    arr[..., 1] = np.clip(gg * bg * 255, 0, 255)
    arr[..., 2] = np.clip(bb * bbv * 255, 0, 255)
    arr[..., 3] = np.clip(base_alpha * (1 - tr) * 255, 0, 255)
    img = Image.fromarray(arr, "RGBA")
    mask = Image.new("L", (iw, ih), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, iw - 1, ih - 1], radius=max(0, radius), fill=255)
    a = np.array(img.getchannel("A"), dtype=np.float32) * (np.array(mask, dtype=np.float32) / 255)
    img.putalpha(Image.fromarray(a.astype(np.uint8)))
    dx, dy = int(round(x)), int(round(y))
    W, H = layer.size
    # crop to layer bounds
    cx0, cy0 = max(0, -dx), max(0, -dy)
    cx1, cy1 = min(iw, W - dx), min(ih, H - dy)
    if cx1 > cx0 and cy1 > cy0:
        layer.alpha_composite(img.crop((cx0, cy0, cx1, cy1)), dest=(dx + cx0, dy + cy0))


def _draw_text(layer, inst, rect, k, stroke=None):
    g = inst.get_prop
    text = inst.extra.get("text_draw", g("Text"))
    if not text:
        return
    is_placeholder = inst.cls.name == "TextBox" and g("Text") == ""
    size = inst.extra.get("text_size", g("TextSize") * k)
    font = _font_of(inst)
    x, y, w, h = rect
    pl, pt, pr, pb = rbx_layout._padding(inst, w, h, k)
    ax, ay, aw, ah = x + pl, y + pt, w - pl - pr, h - pt - pb
    utext = to_unicode(text)
    if g("TextWrapped") or (g("TextScaled") and g("TextWrapped")):
        lines = wrap_lines(utext, font, size, aw)
    else:
        lines = utext.split("\n")
    trunc = g("TextTruncate").name
    if trunc == "AtEnd" and lines:
        lines2 = []
        for ln in lines:
            if line_width(ln, font, size) > aw + 0.5:
                while ln and line_width(ln + "…", font, size) > aw:
                    ln = ln[:-1]
                ln = ln + "…"
            lines2.append(ln)
        lines = lines2
    lh = size * g("LineHeight")
    total_h = lh * len(lines)
    xa = g("TextXAlignment").name
    ya = g("TextYAlignment").name
    if ya == "Top":
        ty = ay
    elif ya == "Bottom":
        ty = ay + ah - total_h
    else:
        ty = ay + (ah - total_h) / 2
    color = g("PlaceholderColor3") if is_placeholder else g("TextColor3")
    alpha = 1 - g("TextTransparency")
    pf, wscale, isz = get_pil_font(font, size)
    d = ImageDraw.Draw(layer)
    for i, ln in enumerate(lines):
        lw = line_width(ln, font, size)
        if xa == "Left":
            tx = ax
        elif xa == "Right":
            tx = ax + aw - lw
        else:
            tx = ax + (aw - lw) / 2
        yy = ty + i * lh
        # center glyphs vertically in line box (PIL draws from top incl. ascent)
        asc, desc = pf.getmetrics()
        oy = (lh - (asc + desc) * (size / isz)) / 2
        kw = {}
        if stroke is not None:
            kw = {"stroke_width": max(1, int(round(stroke.get_prop("Thickness") * k))),
                  "stroke_fill": _c(stroke.get_prop("Color"), alpha * (1 - stroke.get_prop("Transparency")))}
        elif g("TextStrokeTransparency") < 1:
            kw = {"stroke_width": max(1, int(round(1 * k))),
                  "stroke_fill": _c(g("TextStrokeColor3"), alpha * (1 - g("TextStrokeTransparency")))}
        d.text((tx, yy + oy), ln, font=pf, fill=_c(color, alpha), **kw)


def _subtree_layer(size):
    return Image.new("RGBA", size, (0, 0, 0, 0))


class _Crop:
    """Temporary image covering a screen region; draw with offset coords, then composite."""

    def __init__(self, layer, x, y, w, h, pad=4):
        W, H = layer.size
        self.x0 = max(0, int(math.floor(x - pad)))
        self.y0 = max(0, int(math.floor(y - pad)))
        x1 = min(W, int(math.ceil(x + w + pad)))
        y1 = min(H, int(math.ceil(y + h + pad)))
        self.ok = x1 > self.x0 and y1 > self.y0
        self.img = Image.new("RGBA", (max(1, x1 - self.x0), max(1, y1 - self.y0)), (0, 0, 0, 0)) if self.ok else None
        self.layer = layer

    def rect(self, r):
        return (r[0] - self.x0, r[1] - self.y0, r[2], r[3])

    def done(self):
        if self.ok:
            self.layer.alpha_composite(self.img, dest=(self.x0, self.y0))


def render_element(sim, inst, layer, clip, debug, issues):
    g = inst.get_prop
    if not g("Visible"):
        return
    rect = inst.extra.get("rect")
    if rect is None:
        return
    k = inst.extra.get("k", 1.0)
    x, y, w, h = rect
    rot = g("Rotation")
    target = layer
    if abs(rot) > 0.01:
        target = _subtree_layer(layer.size)
    cls = inst.cls.name
    radius = _corner_radius(inst, w, h, k)
    bt = g("BackgroundTransparency")
    if cls != "UIBase":
        if bt < 1:
            grad = _gradient(inst)
            base = g("BackgroundColor3")
            if grad is not None:
                _gradient_fill(target, rect, radius, base, 1 - bt, grad)
            else:
                cr = _Crop(target, x, y, w, h, 1)
                if cr.ok:
                    _draw_rounded(cr.img, cr.rect(rect), radius, fill=_c(base, 1 - bt))
                    cr.done()
        if cls == "ViewportFrame":
            cr = _Crop(target, x, y, w, h, 1)
            tmp = cr.img
            d = ImageDraw.Draw(tmp) if tmp is not None else None
            x, y = x - cr.x0, y - cr.y0
            cx, cy = x + w / 2, y + h * 0.55
            rx, ry = w * 0.32, h * 0.22
            if d is not None:
                d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=(30, 34, 40, 130))
                d.polygon([(cx - rx * 0.9, cy), (cx, cy - ry * 2.2), (cx + rx * 0.9, cy)], fill=(70, 120, 80, 180))
                cr.done()
            x, y = x + cr.x0, y + cr.y0
        if cls in ("ImageLabel", "ImageButton") and g("Image") and g("ImageTransparency") < 1:
            d = ImageDraw.Draw(target)
            d.rectangle([x, y, x + max(w, 1) - 1, y + max(h, 1) - 1], outline=_c(g("ImageColor3"), 0.6 * (1 - g("ImageTransparency"))), width=1)
        st = _stroke(inst)
        is_txt = rbx_layout.is_text(inst)
        if st is not None and not (is_txt and st.get_prop("ApplyStrokeMode").name == "Contextual"):
            th = st.get_prop("Thickness") * k
            if th > 0 and st.get_prop("Transparency") < 1:
                sw = max(1, int(round(th)))
                cr = _Crop(target, x - sw, y - sw, w + 2 * sw, h + 2 * sw, 2)
                if cr.ok:
                    _draw_rounded(cr.img, cr.rect((x - sw / 2, y - sw / 2, w + sw, h + sw)), radius + sw / 2 if radius > 0 else 0,
                                  outline=_c(st.get_prop("Color"), 1 - st.get_prop("Transparency")), width=sw)
                    cr.done()
        if is_txt:
            tst = st if (st is not None and st.get_prop("ApplyStrokeMode").name == "Contextual") else None
            bw, bh = inst.extra.get("text_bounds", (w, h))
            ex = max(0, bw - w) + 8
            ey = max(0, bh - h) + 8
            cr = _Crop(target, x - ex, y - ey, w + 2 * ex, h + 2 * ey, 4)
            if cr.ok:
                _draw_text(cr.img, inst, cr.rect(rect), k, tst)
                cr.done()
    # children
    child_clip = clip
    if cls == "ScrollingFrame":
        cl = inst.extra.get("clip", rect)
        child_clip = _intersect(clip, cl)
    elif g("ClipsDescendants"):
        child_clip = _intersect(clip, rect)
    kids = [c for c in inst.children if c.is_a("GuiObject")]
    kids = sorted(enumerate(kids), key=lambda t: (t[1].get_prop("ZIndex"), t[0]))
    if child_clip is not clip:
        sub = _subtree_layer(layer.size)
        for _, c in kids:
            render_element(sim, c, sub, child_clip, debug, issues)
        cx0, cy0, cw, ch = child_clip
        mask = Image.new("L", layer.size, 0)
        if cw > 0 and ch > 0:
            ImageDraw.Draw(mask).rectangle([cx0, cy0, cx0 + cw - 1, cy0 + ch - 1], fill=255)
        a = np.array(sub.getchannel("A"), dtype=np.float32) * (np.array(mask, dtype=np.float32) / 255)
        sub.putalpha(Image.fromarray(a.astype(np.uint8)))
        target.alpha_composite(sub)
        if cls == "ScrollingFrame":
            _draw_scrollbar(inst, target, k)
    else:
        for _, c in kids:
            render_element(sim, c, target, child_clip, debug, issues)
    if target is not layer:
        cx, cy = x + w / 2, y + h / 2
        rotated = target.rotate(-rot, resample=Image.BICUBIC, center=(cx, cy))
        layer.alpha_composite(rotated)
    if debug:
        if rbx_layout.is_text(inst) and not inst.extra.get("text_fits", True) and g("TextTruncate").name != "AtEnd":
            d = ImageDraw.Draw(layer)
            d.rectangle([x, y, x + w, y + h], outline=(255, 0, 60, 255), width=2)


def _draw_scrollbar(inst, layer, k):
    g = inst.get_prop
    canvas = inst.extra.get("canvas")
    window = inst.extra.get("window")
    clip = inst.extra.get("clip")
    if not canvas or not window or not clip:
        return
    if canvas[1] <= window[1] + 0.5:
        return
    th = g("ScrollBarThickness") * k
    if th <= 0 or g("ScrollBarImageTransparency") >= 1:
        return
    x, y, w, h = inst.extra["rect"]
    cpy = inst.extra.get("canvas_pos", (0, 0))[1]
    frac = window[1] / canvas[1]
    bh = max(8, h * frac)
    by = y + (h - bh) * (cpy / max(1, canvas[1] - window[1]))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle([x + w - th, by, x + w - 1, by + bh], radius=th / 2,
                        fill=_c(g("ScrollBarImageColor3"), 1 - g("ScrollBarImageTransparency")))


def _intersect(a, b):
    if a is None:
        return b
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    x0, y0 = max(ax, bx), max(ay, by)
    x1, y1 = min(ax + aw, bx + bw), min(ay + ah, by + bh)
    return (x0, y0, max(0, x1 - x0), max(0, y1 - y0))


def render_client(sim, ctx, path, debug=True, bg=None, scale=1.0):
    import rbx_layout as L
    L.ensure_layout(sim, ctx)
    vw, vh = ctx.device.viewport
    base = bg if bg is not None else background(vw, vh)
    layer = Image.new("RGBA", (vw, vh), (0, 0, 0, 0))
    pg = ctx.player.find_child("PlayerGui")
    issues = []
    guis = [s for s in pg.children if s.cls.name == "ScreenGui" and s.get_prop("Enabled")]
    guis = sorted(enumerate(guis), key=lambda t: (t[1].get_prop("DisplayOrder"), t[0]))
    for _, sg in guis:
        kids = [c for c in sg.children if c.is_a("GuiObject")]
        kids = sorted(enumerate(kids), key=lambda t: (t[1].get_prop("ZIndex"), t[0]))
        for _, c in kids:
            render_element(sim, c, layer, None, debug, issues)
    # topbar mock (Roblox core UI)
    tb = ctx.device.topbar
    d = ImageDraw.Draw(layer)
    if tb[2] > 0:
        r = 6
        d.rounded_rectangle([12, 10, 12 + 44, 10 + 44], radius=22, fill=(20, 20, 24, 140))
        d.rounded_rectangle([64, 10, min(tb[2], 300), 10 + 44], radius=22, fill=(20, 20, 24, 140))
    out = Image.alpha_composite(base, layer)
    if scale != 1.0:
        out = out.resize((int(vw * scale), int(vh * scale)), Image.LANCZOS)
    out.convert("RGB").save(path)
    return issues
