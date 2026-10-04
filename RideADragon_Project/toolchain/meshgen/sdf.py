"""Signed distance primitives + smooth blending, evaluated on regular grids
with per-primitive bounding boxes (fast for hundreds of primitives)."""
import numpy as np


def smin(a, b, k):
    """Polynomial smooth minimum (blend radius k)."""
    if k <= 0:
        return np.minimum(a, b)
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b * (1 - h) + a * h - k * h * (1 - h)


def smax(a, b, k):
    return -smin(-a, -b, k)


class Prim:
    """Base primitive: subclasses implement eval(P[..., 3]) and bounds()."""
    k = 0.4  # blend radius used when this primitive is merged
    tag = None  # bone / region tag for weights and colors
    color = None
    op = "union"  # union | subtract

    def bounds(self):
        raise NotImplementedError

    def eval(self, P):
        raise NotImplementedError


class Ellipsoid(Prim):
    def __init__(self, center, axes, radii, k=0.4, tag=None, color=None, op="union"):
        self.c = np.asarray(center, float)
        self.R = np.asarray(axes, float)  # 3x3, columns = local axes in world
        self.r = np.maximum(np.asarray(radii, float), 1e-3)
        self.k, self.tag, self.color, self.op = k, tag, color, op

    def bounds(self):
        ext = np.abs(self.R) @ self.r
        return self.c - ext, self.c + ext

    def eval(self, P):
        q = (P - self.c) @ self.R
        k0 = np.linalg.norm(q / self.r, axis=-1)
        k1 = np.linalg.norm(q / (self.r * self.r), axis=-1)
        k1 = np.maximum(k1, 1e-9)
        return k0 * (k0 - 1.0) / k1


class RoundCone(Prim):
    """Capsule with different radii at both ends (iq's round cone)."""
    def __init__(self, a, b, ra, rb, k=0.4, tag=None, color=None, op="union"):
        self.a = np.asarray(a, float)
        self.b = np.asarray(b, float)
        self.ra, self.rb = float(ra), float(rb)
        self.k, self.tag, self.color, self.op = k, tag, color, op

    def bounds(self):
        r = max(self.ra, self.rb)
        return np.minimum(self.a, self.b) - r, np.maximum(self.a, self.b) + r

    def eval(self, P):
        a, b, r1, r2 = self.a, self.b, self.ra, self.rb
        ba = b - a
        l2 = float(ba @ ba)
        rr = r1 - r2
        a2 = l2 - rr * rr
        il2 = 1.0 / max(l2, 1e-9)
        pa = P - a
        y = pa @ ba
        z = y - l2
        xv = pa * l2 - y[..., None] * ba
        x2 = np.sum(xv * xv, axis=-1)
        y2 = y * y * l2
        z2 = z * z * l2
        k = np.sign(rr) * rr * rr * x2
        out = np.empty(P.shape[:-1])
        m1 = np.sign(z) * a2 * z2 > k
        m2 = (~m1) & (np.sign(y) * a2 * y2 < k)
        m3 = ~(m1 | m2)
        out[m1] = np.sqrt(x2[m1] + z2[m1]) * il2 - r2
        out[m2] = np.sqrt(x2[m2] + y2[m2]) * il2 - r1
        out[m3] = (np.sqrt(x2[m3] * a2 * il2) + y[m3] * rr) * il2 - r1
        return out


class Box(Prim):
    def __init__(self, center, axes, half, rounding=0.1, k=0.2, tag=None, color=None, op="union"):
        self.c = np.asarray(center, float)
        self.R = np.asarray(axes, float)
        self.h = np.asarray(half, float)
        self.rd = rounding
        self.k, self.tag, self.color, self.op = k, tag, color, op

    def bounds(self):
        ext = np.abs(self.R) @ (self.h + self.rd)
        return self.c - ext, self.c + ext

    def eval(self, P):
        q = np.abs((P - self.c) @ self.R) - (self.h - self.rd)
        outside = np.linalg.norm(np.maximum(q, 0), axis=-1)
        inside = np.minimum(np.max(q, axis=-1), 0)
        return outside + inside - self.rd


class Grid:
    def __init__(self, lo, hi, h):
        self.h = float(h)
        self.lo = np.asarray(lo, float)
        self.n = np.maximum(np.ceil((np.asarray(hi, float) - self.lo) / self.h).astype(int) + 1, 2)
        self.D = np.full(tuple(self.n), 1e3, dtype=np.float32)

    def sub(self, lo, hi, pad):
        i0 = np.clip(np.floor((lo - pad - self.lo) / self.h).astype(int), 0, self.n - 1)
        i1 = np.clip(np.ceil((hi + pad - self.lo) / self.h).astype(int) + 1, 0, self.n)
        return i0, i1

    def points(self, i0, i1):
        ax = [self.lo[d] + self.h * np.arange(i0[d], i1[d]) for d in range(3)]
        X, Y, Z = np.meshgrid(*ax, indexing="ij")
        return np.stack([X, Y, Z], axis=-1)

    def add(self, prim):
        lo, hi = prim.bounds()
        i0, i1 = self.sub(lo, hi, prim.k + 2 * self.h)
        if np.any(i1 <= i0):
            return
        P = self.points(i0, i1)
        d = prim.eval(P).astype(np.float32)
        sl = tuple(slice(i0[k], i1[k]) for k in range(3))
        if prim.op == "subtract":
            self.D[sl] = smax(self.D[sl], -d, prim.k)
        else:
            self.D[sl] = smin(self.D[sl], d, prim.k)


def frame_from_cf(cf):
    """cf = [x,y,z, r00..r22] (Roblox row-major rotation) -> (center, axes cols)."""
    c = np.array(cf[:3], float)
    R = np.array(cf[3:12], float).reshape(3, 3)
    return c, R
