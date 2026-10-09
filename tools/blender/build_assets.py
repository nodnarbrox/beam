"""Build all 10 Halloween-Blockbuster props -> assets/store3d/*.glb
Run: blender -b --factory-startup --python build_assets.py [-- name1 name2 ...]
Blender Z-up; asset FRONT modeled toward Blender -Y (== glTF +Z after export).
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib, common
importlib.reload(common)
from common import *
import numpy as np

PI = math.pi


# =================================================================== PUMPKINS
def warp_f(u, a):
    return u + a * np.sin(2 * PI * (u - 0.5)) / (2 * PI)


def warp_inv(ut, a):
    u = np.array(ut, float)
    for _ in range(12):
        u -= (warp_f(u, a) - ut) / (1 + a * np.cos(2 * PI * (u - 0.5)))
    return u


def pumpkin_geom(R, Rz, nu, nv, lobeA, dtop, dbot, warp_a):
    def zf(ph):
        s, c = math.sin(ph), math.cos(ph)
        z = Rz * c
        if c > 0:
            z -= dtop * math.exp(-(s / 0.35) ** 2)
        else:
            z += dbot * math.exp(-(s / 0.30) ** 2)
        return z
    rows = []
    for i in range(nv + 1):
        ph = PI * i / nv
        if i == 0 or i == nv:
            rows.append([(0, 0, zf(ph))]); continue
        ring = []
        for j in range(nu):
            th = PI / 2 + 2 * PI * j / nu
            lob = 1 - lobeA * (1 - abs(math.cos(4 * th)))
            s = math.sin(ph)
            ring.append((R * s * lob * math.cos(th), R * s * lob * math.sin(th), zf(ph)))
        rows.append(ring)
    p = ring_surface(rows, uvfn=lambda u, v: (float(warp_f(u, warp_a)), v))
    return p, zf(0.0)


def face_mask(X, Z):
    """Carved face design in front-view unit-sphere coords (X right, Z up)."""
    def tri(ax, az, bx, bz, cx, cz):
        e0 = (bx - ax) * (Z - az) - (bz - az) * (X - ax)
        e1 = (cx - bx) * (Z - bz) - (cz - bz) * (X - bx)
        e2 = (ax - cx) * (Z - cz) - (az - cz) * (X - cx)
        return ((e0 >= 0) & (e1 >= 0) & (e2 >= 0)) | ((e0 <= 0) & (e1 <= 0) & (e2 <= 0))
    m = np.zeros_like(X, bool)
    for s in (-1, 1):  # eyes: upward triangles, inner corner a bit higher (menacing)
        cx = 0.30 * s
        m |= tri(cx - 0.15, 0.13 + (0.03 if s < 0 else -0.0), cx + 0.15, 0.13 + (0.03 if s > 0 else 0.0), cx + 0.02 * s, 0.40)
    m |= tri(-0.085, -0.03, 0.085, -0.03, 0.0, 0.11)  # nose
    # grin: lens between two parabolas, jagged upper lip, pointed teeth
    zu = -0.20 + 0.35 * X ** 2 + 0.025 * np.abs(((X * 9) % 2) - 1)
    zl = -0.44 + 1.017 * X ** 2
    mouth = (Z < zu) & (Z > zl) & (np.abs(X) < 0.6)
    teeth = np.zeros_like(X, bool)
    for tx in (-0.27, 0.12):  # upper teeth hanging down
        h, w = 0.12, 0.13
        top = -0.20 + 0.35 * tx ** 2 + 0.02
        teeth |= (Z < top) & (Z > top - h) & (np.abs(X - tx) < (w / 2) * ((Z - (top - h)) / h))
    for tx in (-0.07, 0.30):  # lower teeth rising up
        h, w = 0.12, 0.13
        bot = -0.44 + 1.017 * tx ** 2 - 0.02
        teeth |= (Z > bot) & (Z < bot + h) & (np.abs(X - tx) < (w / 2) * (((bot + h) - Z) / h))
    m |= mouth & ~teeth
    return m


def pumpkin_textures(size, carved, warp_a, seed):
    H = W = size
    ss = 3 if carved else 1
    Hs, Ws = H * ss, W * ss
    ut = (np.arange(Ws) + 0.5) / Ws
    u = warp_inv(ut, warp_a)
    th = PI / 2 + 2 * PI * u
    ph = PI * (np.arange(Hs) + 0.5) / Hs
    TH, PH = np.meshgrid(th, ph)
    UU = np.broadcast_to(u, (Hs, Ws))
    # skin
    crease = np.exp(-(np.abs(np.cos(8 * PI * UU)) / 0.16) ** 2)
    streak = fbm(Hs, Ws, cells=3, octaves=4, seed=seed, aspect=(1, 8))
    blot = fbm(Hs, Ws, cells=4, octaves=5, seed=seed + 1)
    skin = np.array([0.95, 0.48, 0.07])
    dark = np.array([0.52, 0.20, 0.03])
    col = skin[None, None] * (0.86 + 0.22 * streak[..., None]) * (0.92 + 0.12 * blot[..., None])
    col = col * (1 - crease[..., None] * 0.55) + dark * crease[..., None] * 0.55
    top = np.exp(-(PH / 0.30) ** 2)[..., None]
    col = col * (1 - top * 0.75) + np.array([0.40, 0.33, 0.10]) * top * 0.75
    bot = np.exp(-((PI - PH) / 0.35) ** 2)[..., None]
    col = col * (1 - bot * 0.4) + np.array([0.55, 0.40, 0.15]) * bot * 0.4
    emis = np.zeros_like(col)
    if carved:
        X = np.sin(PH) * np.cos(TH)
        Y = np.sin(PH) * np.sin(TH)
        Z = np.cos(PH)
        m = face_mask(X, Z) & (Y < -0.3)
        mf = m.astype(float)
        rim = dilate(mf, 2 * ss) - mf  # cut flesh edge around holes
        glow = np.array([1.0, 0.78, 0.30])
        flesh = np.array([0.96, 0.80, 0.50])
        col = col * (1 - rim[..., None]) + flesh * rim[..., None]
        col = col * (1 - mf[..., None]) + glow * mf[..., None]
        emis = mf[..., None] * np.array([1.0, 0.62, 0.18])
    if ss > 1:
        col = col.reshape(H, ss, W, ss, 3).mean((1, 3))
        emis = emis.reshape(H, ss, W, ss, 3).mean((1, 3))
    return col, emis


def build_pumpkin(fname, width, height, carved, nu, nv, tex, warp_a, seed):
    reset()
    R = width / 2
    Rz = (height + 0.028 * height / 0.28 + 0.012 * height / 0.28) / 2
    dtop, dbot = 0.028 * height / 0.28, 0.012 * height / 0.28
    col, emis = pumpkin_textures(tex, carved, warp_a, seed)
    stem_name = 'stem' if carved else 'stem_small'
    bimg = np_to_image(fname.replace('.glb', '_base'), col)
    if carved:
        eimg = np_to_image(fname.replace('.glb', '_emis'), emis)
        skin = make_mat('pumpkin_carved', rough=0.55, base_img=bimg, emis_img=eimg)
    else:
        skin = make_mat('pumpkin_skin', rough=0.55, base_img=bimg)
    stem = make_mat(stem_name, color=(0.20, 0.17, 0.06), rough=0.85)
    mb = MB()
    body, ztop = pumpkin_geom(R, Rz, nu, nv, 0.085, dtop, dbot, warp_a)
    mb.add(body, skin)
    k = width / 0.34
    path = [(0, 0, ztop - 0.012 * k), (0.002 * k, 0.0, ztop + 0.018 * k), (0.010 * k, 0.004 * k, ztop + 0.040 * k),
            (0.024 * k, 0.010 * k, ztop + 0.054 * k), (0.036 * k, 0.014 * k, ztop + 0.058 * k)]
    mb.add(tube(path, [0.019 * k, 0.015 * k, 0.012 * k, 0.010 * k, 0.009 * k], sides=6), stem)
    ob = mb.build(fname[:-4], sharp_deg=60, origin='bottom')
    p = export_glb(ob, fname); report(ob, p)


# =================================================================== COBWEBS
WEB_RGB = np.array([0.88, 0.88, 0.85])


def web_image(alpha, name):
    img = np.zeros(alpha.shape + (4,))
    img[..., :3] = WEB_RGB  # RGB everywhere = thread colour (no dark fringes)
    img[..., 3] = alpha
    return np_to_image(name, img)


def corner_web_alpha(S=512, seed=3):
    rng = np.random.default_rng(seed)
    a = np.zeros((S, S))
    angs = np.radians(np.linspace(2, 88, 10) + rng.uniform(-3, 3, 10))
    angs[0], angs[-1] = np.radians(1.2), np.radians(88.8)
    rend = 470 + rng.uniform(-35, 25, len(angs))
    # radials (slight droop)
    rad_pts = []
    for ang, re in zip(angs, rend):
        pts = []
        for t in np.linspace(0, 1, 12):
            r = t * re
            pts.append((2 + r * math.cos(ang), 2 + r * math.sin(ang) + 6 * math.sin(PI * t)))
        rad_pts.append(np.array(pts))
        draw_polyline(a, pts, half_w=1.4)
    # frame thread linking radial ends
    ends = [rp[-1] for rp in rad_pts]
    for p, q in zip(ends[:-1], ends[1:]):
        mid = (p + q) / 2; ch = np.linalg.norm(q - p)
        inward = -norm(mid - 2)
        pts = [p + (q - p) * t + inward * ch * 0.10 * math.sin(PI * t) for t in np.linspace(0, 1, 8)]
        draw_polyline(a, pts, half_w=1.5)
    # capture spiral: sagging (catenary-ish) chords between neighbouring radials
    def on_radial(k, r):
        rp = rad_pts[k]; L = np.linalg.norm(rp[-1] - rp[0])
        t = min(r / L, 1.0) * (len(rp) - 1)
        i = min(int(t), len(rp) - 2); f = t - i
        return rp[i] * (1 - f) + rp[i + 1] * f
    r = 34.0
    while r < 450:
        for k in range(len(angs) - 1):
            if rng.random() < 0.10:
                continue  # broken strand
            jit = rng.uniform(-4, 4, 2)
            p = on_radial(k, r + jit[0]); q = on_radial(k + 1, r + jit[1])
            ch = np.linalg.norm(q - p)
            inward = -norm((p + q) / 2 - 2)
            pts = [p + (q - p) * t + inward * ch * 0.16 * math.sin(PI * t) for t in np.linspace(0, 1, 7)]
            draw_polyline(a, pts, half_w=1.15)
        r += 26 + r * 0.06
    # a couple of loose hanging strands
    for _ in range(4):
        k = rng.integers(1, len(angs) - 1); p = on_radial(k, rng.uniform(250, 420))
        L = rng.uniform(25, 60)
        draw_polyline(a, [p, p + (rng.uniform(-6, 6), L * 0.5), p + (rng.uniform(-8, 8), L)], half_w=1.1)
    return a


def sag_web_alpha(S=512, seed=7):
    rng = np.random.default_rng(seed)
    a = np.zeros((S, S))
    draw_polyline(a, [(0, 3), (S, 3)], half_w=1.8)  # top rope
    nstr = 10
    strands = [lambda x: 3.0 + 0 * x]
    for k in range(1, nstr + 1):
        y0 = k * (S - 40) / nstr + rng.uniform(-10, 10)
        sag = rng.uniform(10, 30)
        xs = np.linspace(0, S, 40)
        ys = y0 + sag * np.sin(PI * xs / S) + 4 * np.sin(xs / 37 + k)
        pts = np.stack([xs, ys], 1)
        strands.append(lambda x, y0=y0, sag=sag, k=k: y0 + sag * np.sin(PI * x / S) + 4 * np.sin(x / 37 + k))
        # tatter: drop runs of the strand, more toward the bottom
        keep = np.ones(len(pts) - 1, bool)
        p_gap = 0.012 + 0.010 * k
        i = 0
        while i < len(keep):
            if rng.random() < p_gap:
                n = rng.integers(1, 4); keep[i:i + n] = False
                if rng.random() < 0.6 and i < len(pts):  # broken end droops
                    e = pts[i]; L = rng.uniform(15, 45)
                    draw_polyline(a, [e, e + (rng.uniform(-5, 5), L * 0.6), e + (rng.uniform(-10, 10), L)], half_w=1.1)
                i += n
            i += 1
        seg = []
        for j, kp in enumerate(keep):
            if kp:
                seg.append(pts[j]) if not seg else None
                seg.append(pts[j + 1])
            elif seg:
                draw_polyline(a, seg, half_w=1.2); seg = []
        if seg:
            draw_polyline(a, seg, half_w=1.2)
    # zig-zag connectors between neighbouring strands (net look); texture is ~3:1
    # squashed vertically on the strip, so use long horizontal steps
    for k in range(len(strands) - 1):
        fa, fb = strands[k], strands[k + 1]
        x = rng.uniform(0, 30); up = True
        p_drop = 0.15 + 0.035 * k
        while x < S - 10:
            nx = min(S - 2, x + rng.uniform(22, 48))
            if rng.random() > p_drop:
                p = (x, float(fa(x)) if up else float(fb(x)))
                q = (nx, float(fb(nx)) if up else float(fa(nx)))
                mid = ((p[0] + q[0]) / 2, (p[1] + q[1]) / 2 + 3)
                draw_polyline(a, [p, mid, q], half_w=1.05)
            x = nx; up = not up
    # wisps off the bottom edge
    for _ in range(9):
        x = rng.uniform(40, S - 40); y = rng.uniform(S - 110, S - 60)
        draw_polyline(a, [(x, y), (x + rng.uniform(-8, 8), y + 30), (x + rng.uniform(-15, 15), min(S - 2, y + 70))], half_w=1.1)
    # tatter holes
    yy, xx = np.mgrid[0:S, 0:S]
    for _ in range(3):
        cx, cy, rr = rng.uniform(80, S - 80), rng.uniform(120, S - 60), rng.uniform(18, 32)
        a[(xx - cx) ** 2 + (yy - cy) ** 2 < rr * rr] = 0
    return a


def build_cobweb_corner():
    reset()
    img = web_image(corner_web_alpha(), 'cobweb_corner')
    mat = make_mat('cobweb_corner', rough=0.9, base_img=img, alpha_clip=0.3, double=True)
    s = 0.7
    V = [(0, 0, 0), (s, 0, 0), (s, 0, -s), (0, 0, -s)]
    F = [[0, 3, 2, 1]]  # normal -Y (Blender) == +Z glTF
    UV = [[(0, 1), (0, 0), (1, 0), (1, 1)]]
    mb = MB(); mb.add(Part(V, F, UV, closed=False), mat, orient=False)
    ob = mb.build('cobweb_corner', origin='none')
    p = export_glb(ob, 'cobweb_corner.glb'); report(ob, p)


def build_cobweb_sag():
    reset()
    img = web_image(sag_web_alpha(), 'cobweb_sag')
    mat = make_mat('cobweb_sag', rough=0.9, base_img=img, alpha_clip=0.3, double=True)
    # catenary a*cosh(x/a) with 0.25 sag over half-span 0.5
    lo, hi = 0.05, 10.0
    for _ in range(80):
        a = (lo + hi) / 2
        if a * (math.cosh(0.5 / a) - 1) > 0.25: lo = a
        else: hi = a
    nx, ny = 16, 4
    V, F, UV = [], [], []
    for m in range(ny + 1):
        for i in range(nx + 1):
            x = -0.5 + i / nx
            zt = a * math.cosh(x / a) - a * math.cosh(0.5 / a)
            h = 0.35 * max(0.0, 1 - (2 * x) ** 2) ** 0.6
            t = m / ny
            V.append((x, 0.05 * t * (1 - (2 * x) ** 2), zt - h * t))
    idx = lambda i, m: m * (nx + 1) + i
    for m in range(ny):
        for i in range(nx):
            F.append([idx(i, m), idx(i, m + 1), idx(i + 1, m + 1), idx(i + 1, m)])
            UV.append([(i / nx, 1 - m / ny), (i / nx, 1 - (m + 1) / ny), ((i + 1) / nx, 1 - (m + 1) / ny), ((i + 1) / nx, 1 - m / ny)])
    p = Part(V, F, UV, closed=False)
    # make sure the face normals point -Y (toward the viewer / glTF +Z)
    f = p.F[len(p.F) // 2]; A, B, C = p.V[f[0]], p.V[f[1]], p.V[f[2]]
    if np.cross(B - A, C - A)[1] > 0:
        p.flip()
    mb = MB(); mb.add(p, mat, orient=False)
    ob = mb.build('cobweb_sag', sharp_deg=80, origin='none')
    pth = export_glb(ob, 'cobweb_sag.glb'); report(ob, pth)


# =================================================================== TOMBSTONE
def stone_base(H, W, seed, moss_rows=None):
    n1 = fbm(H, W, cells=4, octaves=6, seed=seed)
    n2 = fbm(H, W, cells=16, octaves=3, seed=seed + 1)
    rng = np.random.default_rng(seed + 2)
    g = 0.46 + 0.20 * (n1 - 0.5) + 0.10 * (n2 - 0.5)
    col = np.stack([g * 0.98, g * 0.98, g * 1.02], -1)
    speck = rng.random((H, W))
    col[speck > 0.985] *= 0.55
    col[speck < 0.01] = col[speck < 0.01] * 0.6 + 0.35
    # lichen / moss near the bottom (row H-1 = bottom)
    heightf = np.linspace(1, 0, H)[:, None] if moss_rows is None else moss_rows
    mossn = fbm(H, W, cells=8, octaves=4, seed=seed + 3)
    mprob = np.clip((0.35 - heightf) / 0.35, 0, 1) ** 1.5
    moss = (mossn * mprob + rng.random((H, W)) * 0.25 * mprob) > 0.42
    mf = moss.astype(float)
    mf = np.maximum(mf, 0.6 * (dilate(mf, 1) - mf))
    mcol = np.array([0.30, 0.38, 0.14])
    col = col * (1 - mf[..., None] * 0.85) + mcol * mf[..., None] * 0.85
    lich = (fbm(H, W, cells=12, octaves=3, seed=seed + 4) > 0.68) & (rng.random((H, W)) > 0.4)
    col[lich] = col[lich] * 0.5 + np.array([0.62, 0.64, 0.50]) * 0.5
    return col


def build_tombstone():
    reset()
    import bmesh
    W, Hh, D = 0.55, 0.80, 0.14
    bw, bh, bd = 0.70, 0.08, 0.25
    rr = W / 2
    # ---- textures
    S = 512
    stone_tex = stone_base(S, S, 11)
    front = stone_base(S, S, 21)
    ext = (-W / 2, W / 2, 0.0, Hh)  # front face coords (x, z-from-headstone-bottom)
    cov = np.zeros((S, S))
    cov = np.maximum(cov, raster_text(S, S, ext, 'R.I.P.', (0, 0.535), 0.115, maxw=0.42, font=FONT_SERIF_BOLD))
    cov = np.maximum(cov, raster_text(S, S, ext, 'LATE FEES', (0, 0.385), 0.058, maxw=0.43, font=FONT_SERIF_BOLD))
    cov = np.maximum(cov, raster_text(S, S, ext, '1985 \u2013 2014', (0, 0.285), 0.040, maxw=0.34, font=FONT_SERIF_BOLD))
    # small carved cross above & rule line
    yy, xx = np.mgrid[0:S, 0:S]
    X = (xx + 0.5) / S * W - W / 2; Z = Hh - (yy + 0.5) / S * Hh
    cov = np.maximum(cov, ((np.abs(X) < 0.009) & (np.abs(Z - 0.70) < 0.045)).astype(float))
    cov = np.maximum(cov, ((np.abs(X) < 0.030) & (np.abs(Z - 0.715) < 0.008)).astype(float))
    cov = np.maximum(cov, ((np.abs(X) < 0.14) & (np.abs(Z - 0.335) < 0.0035)).astype(float))
    # engraving: dark recessed fill, shadowed upper inner edge, lit lower lip
    shadow = np.clip(cov - np.roll(cov, 3, 0), 0, 1)
    lip = np.clip(np.roll(cov, -2, 0) - cov, 0, 1)
    c = front * (1 - cov[..., None]) + (front * 0.30) * cov[..., None]
    c = c * (1 - 0.35 * shadow[..., None])
    c = c + 0.18 * lip[..., None]
    img_front = np_to_image('tombstone_front', c)
    img_stone = np_to_image('tombstone_stone', stone_tex)
    m_front = make_mat('stone_front', rough=0.85, base_img=img_front)
    m_stone = make_mat('stone', rough=0.9, base_img=img_stone)
    # ---- headstone: arched profile extruded along Y
    bm = bmesh.new()
    prof = [(-rr, 0.0), (rr, 0.0), (rr, Hh - rr)]
    narc = 16
    for k in range(1, narc):
        a = PI * k / narc
        prof.append((rr * math.cos(a), Hh - rr + rr * math.sin(a)))
    prof.append((-rr, Hh - rr))
    vf = [bm.verts.new((x, -D / 2, z + bh)) for x, z in prof]
    vb = [bm.verts.new((x, D / 2, z + bh)) for x, z in prof]
    bm.faces.new(vf); bm.faces.new(vb[::-1])
    n = len(prof)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new([vf[i], vb[i], vb[j], vf[j]])
    # base slab
    base_v = []
    for (x, y, z) in [(-bw/2, -bd/2, 0), (bw/2, -bd/2, 0), (bw/2, bd/2, 0), (-bw/2, bd/2, 0),
                      (-bw/2, -bd/2, bh), (bw/2, -bd/2, bh), (bw/2, bd/2, bh), (-bw/2, bd/2, bh)]:
        base_v.append(bm.verts.new((x, y, z)))
    for f in [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]:
        bm.faces.new([base_v[i] for i in f])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    sharp = [e for e in bm.edges if len(e.link_faces) == 2 and e.calc_face_angle(0) > math.radians(30)]
    bmesh.ops.bevel(bm, geom=sharp, offset=0.008, segments=2, affect='EDGES', profile=0.5, clamp_overlap=True)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()

    def face_fn(f):
        nrm = f.normal
        cz = f.calc_center_median().z
        if nrm.y < -0.7 and cz > bh + 0.005:  # headstone front
            return m_front, [((l.vert.co.x + W / 2) / W, (l.vert.co.z - bh) / Hh) for l in f.loops]
        ax = max(range(3), key=lambda i: abs(nrm[i]))
        uvs = []
        for l in f.loops:
            co = l.vert.co
            if ax == 0:   uvs.append((co.y / 0.9 + 0.5, co.z / 0.9))
            elif ax == 1: uvs.append((co.x / 0.9 + 0.5, co.z / 0.9))
            else:         uvs.append((co.x / 0.9 + 0.5, co.y / 0.9 + 0.5))
        return m_stone, uvs
    part = part_from_bmesh(bm, face_fn)
    bm.free()
    mb = MB(); mb.add(part, None, orient=False)
    ob = mb.build('tombstone', sharp_deg=35, origin='bottom')
    p = export_glb(ob, 'tombstone.glb'); report(ob, p)


# =================================================================== SKELETON
def build_skeleton():
    reset()
    bonem = make_mat('bone', color=(0.84, 0.80, 0.70), rough=0.75)
    dark = make_mat('socket_dark', color=(0.035, 0.028, 0.022), rough=0.9)
    mb = MB()
    pivot = (0, 0.03, 1.02)
    U = affine(rot_x(math.radians(14)), pivot=pivot)           # slouch upper body forward
    hp = (0, 0.005, 1.545)
    Hm = U @ affine(rot_x(math.radians(12)) @ rot_y(math.radians(-17)), pivot=hp)  # head tilt

    def addU(part, m=bonem):
        mb.add(part.xf(U), m)

    # ---- legs & feet
    for s in (1, -1):
        hip = (s * 0.095, 0.0, 0.93); knee = (s * 0.10, -0.025, 0.52); ank = (s * 0.095, 0.005, 0.085)
        mb.add(ellipsoid(hip, (0.026, 0.026, 0.026), 6, 4), bonem)
        mb.add(bone(hip, knee, 0.020, knob=1.55), bonem)
        mb.add(ellipsoid((s * 0.10, -0.052, 0.525), (0.022, 0.011, 0.025), 6, 4), bonem)
        mb.add(bone(knee, ank, 0.018, knob=1.55), bonem)
        mb.add(ellipsoid((s * 0.10, -0.055, 0.036), (0.043, 0.105, 0.030), 8, 5, R=rot_z(-s * 0.12)), bonem)
    # ---- pelvis
    path = []
    for k in range(11):
        a = math.radians(115 + k * 31)  # open at the back; sacrum covers the gap
        path.append((0.105 * math.cos(a), 0.0 + 0.075 * math.sin(a), 0.925 + 0.035 * math.sin(a)))
    mb.add(tube(path, 0.017, sides=5), bonem)
    for s in (1, -1):
        mb.add(ellipsoid((s * 0.100, 0.015, 1.005), (0.058, 0.022, 0.052), 8, 5,
                         R=rot_z(s * math.radians(-25)) @ rot_y(s * math.radians(20))), bonem)
    mb.add(ellipsoid((0, 0.055, 0.975), (0.040, 0.020, 0.058), 6, 4), bonem)
    # ---- spine (17 vertebrae), upright coords then slouched
    sp = []
    for k in range(18):
        t = k / 17
        z = 1.00 + t * 0.53
        y = 0.035 + 0.02 * math.sin(PI * min(t / 0.75, 1.0)) - (0.03 * (t - 0.75) / 0.25 if t > 0.75 else 0)
        sp.append(np.array([0, y, z]))
    for k in range(17):
        a, b = sp[k], sp[k + 1]
        c = (a + b) / 2; d = b - a
        r = 0.026 - 0.011 * (k / 16)
        addU(tube([c - d * 0.36, c + d * 0.36], r, sides=5))
    # ---- ribcage
    for k in range(6):
        zb = 1.405 - 0.043 * k
        rx = [0.085, 0.105, 0.120, 0.130, 0.134, 0.132][k]
        ry = [0.075, 0.085, 0.092, 0.095, 0.095, 0.090][k]
        cy = -0.030
        drop = 0.075 + 0.01 * k
        path = []
        for aa in np.linspace(-68, 248, 11):
            a = math.radians(aa)
            path.append((rx * math.cos(a), cy + ry * math.sin(a), zb - drop * (1 - math.sin(a)) / 2))
        addU(tube(path, 0.0075, sides=4))
    addU(bone((0, -0.118, 1.36), (0, -0.126, 1.19), 0.012, knob=1.25, sides=4))
    for s in (1, -1):
        addU(tube([(s * 0.02, -0.112, 1.405), (s * 0.10, -0.098, 1.425), (s * 0.175, -0.045, 1.42)], 0.0085, sides=4))
        addU(ellipsoid((s * 0.185, -0.02, 1.405), (0.026, 0.026, 0.026), 6, 4))  # shoulder heads
    # ---- arms: right (-X) waving high, left (+X) hanging with hand at hip level
    arms = {
        -1: dict(S=(-0.185, -0.02, 1.405), E=(-0.40, -0.05, 1.44), W=(-0.435, -0.10, 1.68),
                 d=(-0.08, -0.05, 1.0), n=(0.0, -1.0, 0.0), spread=11, curl=8),
        1: dict(S=(0.185, -0.02, 1.405), E=(0.235, 0.005, 1.13), W=(0.245, -0.055, 0.90),
                d=(0.02, -0.12, -1.0), n=(-1.0, 0.0, 0.0), spread=5, curl=30),
    }
    for s, A in arms.items():
        S_, E, Wr = map(np.array, (A['S'], A['E'], A['W']))
        addU(bone(S_, E, 0.017, knob=1.5))
        off = norm(np.cross(Wr - E, (0, 1, 0))) * 0.009
        addU(bone(E + off, Wr + off, 0.0095, knob=1.45, sides=5))
        addU(bone(E - off, Wr - off, 0.0085, knob=1.45, sides=5))
        # hand
        d = norm(A['d']); nrm = norm(np.asarray(A['n']) - np.dot(A['n'], d) * d); side = np.cross(d, nrm)
        addU(ellipsoid(Wr + d * 0.040, (0.034, 0.011, 0.040), 6, 4, R=np.stack([side, nrm, d], 1)))
        for i, (o, L) in enumerate(zip((-0.024, -0.008, 0.008, 0.024), (0.060, 0.070, 0.067, 0.054))):
            sp_a = math.radians(A['spread'] * (i - 1.5))
            dd = norm(d * math.cos(sp_a) + side * math.sin(sp_a))
            cu = math.radians(A['curl'])
            base = Wr + d * 0.074 + side * o
            mid = base + dd * L * 0.5
            tip = mid + norm(dd * math.cos(cu) - nrm * math.sin(cu)) * L * 0.5
            addU(tube([base, mid, tip], [0.0065, 0.0055, 0.0045], sides=4))
        tb = Wr + d * 0.02 + side * 0.028
        td = norm(d + side * 0.9 - nrm * 0.3)
        addU(tube([tb, tb + td * 0.03, tb + td * 0.055], [0.007, 0.006, 0.005], sides=4))
    # ---- skull (upright local, then head tilt + slouch)
    C = np.array([0, -0.02, 1.645])

    def addH(part, m=bonem):
        mb.add(part.xf(Hm), m)
    addH(ellipsoid(C, (0.074, 0.092, 0.088), 12, 8))
    addH(ellipsoid(C + (0, -0.045, -0.055), (0.052, 0.050, 0.045), 8, 5))
    for s in (1, -1):
        addH(ellipsoid(C + (s * 0.058, -0.035, -0.035), (0.018, 0.035, 0.014), 6, 3))  # cheekbones
    jaw = [C + p for p in [(0.052, 0.0, -0.05), (0.050, -0.022, -0.105), (0.030, -0.070, -0.122),
                           (0.0, -0.083, -0.126), (-0.030, -0.070, -0.122), (-0.050, -0.022, -0.105), (-0.052, 0.0, -0.05)]]
    addH(tube(jaw, 0.012, sides=4))
    addH(ellipsoid(C + (0, -0.080, -0.103), (0.036, 0.012, 0.009), 8, 3), bonem)  # teeth row
    for s in (1, -1):
        addH(ellipsoid(C + (s * 0.030, -0.080, -0.004), (0.023, 0.012, 0.020), 6, 4), dark)
    addH(ellipsoid(C + (0, -0.093, -0.045), (0.010, 0.008, 0.016), 6, 4), dark)
    addH(ellipsoid(C + (0, -0.088, -0.0955), (0.030, 0.006, 0.0035), 6, 3), dark)  # mouth gap
    ob = mb.build('skeleton', sharp_deg=75, origin='zfloor')
    p = export_glb(ob, 'skeleton.glb'); report(ob, p)


# =================================================================== BAT
def build_bat():
    reset()
    body = make_mat('bat_body', color=(0.05, 0.04, 0.05), rough=0.8)
    wing = make_mat('bat_wing', color=(0.05, 0.04, 0.05), rough=0.75, double=True)
    eye = make_mat('bat_eye', color=(0.30, 0.02, 0.02), rough=0.3)
    mb = MB()
    mb.add(ellipsoid((0, 0, 0), (0.022, 0.020, 0.038), 10, 6), body)
    mb.add(ellipsoid((0, -0.004, 0.047), (0.019, 0.018, 0.018), 8, 6), body)
    mb.add(ellipsoid((0, -0.020, 0.042), (0.008, 0.008, 0.007), 6, 4), body)
    for s in (1, -1):
        base = [(s * 0.005, -0.006, 0.058), (s * 0.018, -0.008, 0.054), (s * 0.012, 0.006, 0.056)]
        apex = (s * 0.021, -0.002, 0.092)
        mb.add(Part(base + [apex], [[0, 1, 2], [0, 3, 1], [1, 3, 2], [2, 3, 0]], [[(0, 0), (1, 0), (0.5, 1)]] * 4), body)
        mb.add(ellipsoid((s * 0.0085, -0.0205, 0.052), (0.0035, 0.0025, 0.0035), 6, 4), eye)
        # little feet
        mb.add(tube([(s * 0.008, 0.004, -0.030), (s * 0.010, 0.006, -0.048)], 0.003, sides=4), body)
    # wings
    N, M = 22, 3
    fing = [0.0, 0.32, 0.56, 0.79, 1.0]
    x0, x1 = 0.016, 0.18
    shear = math.tan(math.radians(16))
    for s in (1, -1):
        def top(t): return 0.022 + 0.05 * t + 0.032 * math.sin(PI * t) - 0.032 * t ** 3
        def bot(t):
            b = -0.028 + 0.066 * t ** 1.5
            for a, c in zip(fing[:-1], fing[1:]):
                if a <= t <= c:
                    b += 0.024 * (1 - 0.45 * t) * math.sin(PI * (t - a) / (c - a))
            return b
        def P(t, m):
            x = x0 + t * (x1 - x0)
            zb, zt = bot(t), top(t)
            z = zb + (zt - zb) * m + shear * (x - x0)
            y = 0.004 + 0.012 * math.sin(PI * m) * math.sin(PI * t) + 0.03 * t ** 2
            return (s * x, y, z)
        V, F, UV = [], [], []
        for m in range(M + 1):
            for i in range(N + 1):
                V.append(P(i / N, m / M))
        idx = lambda i, m: m * (N + 1) + i
        for m in range(M):
            for i in range(N):
                F.append([idx(i, m), idx(i + 1, m), idx(i + 1, m + 1), idx(i, m + 1)])
                UV.append([(i / N, m / M), ((i + 1) / N, m / M), ((i + 1) / N, (m + 1) / M), (i / N, (m + 1) / M)])
        mb.add(Part(V, F, UV, closed=False), wing, orient=False)
        # finger bones from the wrist to each scallop tip
        wrist = np.array(P(0.45, 1.0)) + (0, -0.002, 0)
        mb.add(tube([np.array(P(0.0, 1.0)) + (0, -0.002, 0), wrist], 0.0022, sides=3), body)
        for t in fing[1:]:
            tip = np.array(P(t, 0.0)) + (0, -0.002, 0)
            mb.add(tube([wrist + norm(tip - wrist) * 0.004, tip], 0.0014, sides=3), body)
    ob = mb.build('bat', sharp_deg=70, origin='none')
    p = export_glb(ob, 'bat.glb'); report(ob, p)


# =================================================================== VHS
def build_vhs():
    reset()
    import bmesh
    L, Dp, T = 0.187, 0.103, 0.025
    # top face texture (x across L, y across depth; row 0 = +Y back)
    Wt, Ht = 512, 256
    yy, xx = np.mgrid[0:Ht, 0:Wt]
    X = (xx + 0.5) / Wt * L - L / 2
    Y = Dp / 2 - (yy + 0.5) / Ht * Dp
    n = fbm(Ht, Wt, cells=8, octaves=3, seed=5)
    col = np.stack([0.07 + 0.02 * n] * 3, -1)
    wx0, wx1, wy0, wy1 = -0.070, 0.070, -0.024, 0.032
    rad = 0.006
    qx = np.clip(np.abs(X) - (wx1 - rad), 0, None); qy = np.clip(np.abs(Y - (wy0 + wy1) / 2) - ((wy1 - wy0) / 2 - rad), 0, None)
    win = np.hypot(qx, qy) < rad
    border = (np.hypot(np.clip(np.abs(X) - (wx1 - rad), 0, None), np.clip(np.abs(Y - (wy0 + wy1) / 2) - ((wy1 - wy0) / 2 - rad), 0, None)) < rad + 0.0022) & ~win
    inside = np.stack([np.full_like(X, 0.16)] * 3, -1)
    cyr = 0.004
    for cx, R in ((-0.0465, 0.041), (0.0465, 0.024)):
        d = np.hypot(X - cx, Y - cyr)
        tape = d < R
        ring = 0.85 + 0.15 * np.sin(d * 2400)
        tcol = np.stack([0.23 * ring, 0.14 * ring, 0.08 * ring], -1)
        inside = np.where(tape[..., None], tcol, inside)
        hub = d < 0.0125
        ang = np.arctan2(Y - cyr, X - cx)
        teeth = (d < 0.0145) & (np.cos(6 * ang) > 0.3)
        inside = np.where((hub | teeth)[..., None], np.array([0.90, 0.90, 0.88]), inside)
        inside = np.where((d < 0.005)[..., None], np.array([0.25, 0.25, 0.25]), inside)
    glare = np.exp(-(((X + Y * 1.4) - 0.01) / 0.006) ** 2) * 0.25
    inside = inside * 0.85 + 0.06 + glare[..., None]
    col = np.where(win[..., None], inside, col)
    col = np.where(border[..., None], np.array([0.13, 0.13, 0.13]), col)
    # molded grip ridges near the short ends
    ridges = (np.abs(X) > 0.076) & (np.abs(X) < 0.089) & (np.sin(Y * 1800) > 0.6)
    col[ridges] = 0.12
    img_top = np_to_image('vhs_top', col)
    # spine label texture (x across L, z across T; row 0 = top edge)
    Ws_, Hs_ = 512, 128
    ext = (-L / 2, L / 2, 0.0, T)
    yy, xx = np.mgrid[0:Hs_, 0:Ws_]
    X = (xx + 0.5) / Ws_ * L - L / 2
    Z = T - (yy + 0.5) / Hs_ * T
    lab = np.stack([np.full_like(X, 0.07)] * 3, -1)
    label = (np.abs(X) < 0.078) & (Z > 0.0035) & (Z < 0.0215)
    lab[label] = (0.95, 0.94, 0.90)
    stripe = label & (Z > 0.0185)
    lab[stripe] = (0.10, 0.20, 0.55)
    cov = raster_text(Hs_, Ws_, ext, 'BE KIND  REWIND', (0, 0.0105), 0.0070, maxw=0.135, font=FONT_SANS_BOLD)
    lab = lab * (1 - cov[..., None]) + np.array([0.08, 0.16, 0.50]) * cov[..., None]
    img_lab = np_to_image('vhs_label', lab)
    m_top = make_mat('vhs_top', rough=0.35, base_img=img_top)
    m_lab = make_mat('vhs_label', rough=0.6, base_img=img_lab)
    m_pl = make_mat('vhs_plastic', color=(0.018, 0.018, 0.02), rough=0.45)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= L; v.co.y *= Dp; v.co.z = (v.co.z + 0.5) * T
    bmesh.ops.bevel(bm, geom=bm.edges[:], offset=0.0012, segments=1, affect='EDGES', clamp_overlap=True)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])

    def face_fn(f):
        nrm = f.normal
        if nrm.z > 0.9:
            return m_top, [((l.vert.co.x + L / 2) / L, (l.vert.co.y + Dp / 2) / Dp) for l in f.loops]
        if nrm.y < -0.9:
            return m_lab, [((l.vert.co.x + L / 2) / L, l.vert.co.z / T) for l in f.loops]
        return m_pl, [((l.vert.co.x + L / 2) / L, (l.vert.co.y + l.vert.co.z) / Dp) for l in f.loops]
    part = part_from_bmesh(bm, face_fn); bm.free()
    mb = MB(); mb.add(part, None, orient=False)
    ob = mb.build('vhs_tape', sharp_deg=30, origin='bottom')
    p = export_glb(ob, 'vhs_tape.glb'); report(ob, p)


# =================================================================== CANDLES
def build_candles():
    reset()
    wax = make_mat('wax', color=(0.90, 0.86, 0.74), rough=0.55)
    wick = make_mat('wick', color=(0.02, 0.02, 0.02), rough=0.9)
    flame = make_mat('flame', color=(1.0, 0.7, 0.3), rough=0.5, emis_color=(1.0, 0.7, 0.3))
    rng = np.random.default_rng(4)
    mb = MB()
    specs = [((-0.029, 0.013), 0.030, 0.14), ((0.031, 0.019), 0.028, 0.10), ((0.002, -0.034), 0.025, 0.07)]
    n = 12
    for (cx, cy), r, h in specs:
        rimz = h - 0.003 * rng.random(n)
        rimz[rng.integers(n)] -= 0.006
        def ring(rad, z, jit=0.0):
            return [(cx + rad * (1 + jit * rng.uniform(-1, 1)) * math.cos(2 * PI * j / n),
                     cy + rad * (1 + jit * rng.uniform(-1, 1)) * math.sin(2 * PI * j / n),
                     z[j] if hasattr(z, '__len__') else z) for j in range(n)]
        rows = [[(cx, cy, h - 0.007)], ring(r * 0.72, h - 0.005), ring(r * 0.97, rimz),
                ring(r * 1.03, h - 0.012, 0.02), ring(r, h * 0.5, 0.01), ring(r * 1.01, 0.004), ring(r * 0.97, 0.0),
                [(cx, cy, 0.0)]]
        mb.add(ring_surface(rows), wax)
        for _ in range(4 if h > 0.09 else 3):  # wax drips
            a = rng.uniform(0, 2 * PI); Ld = rng.uniform(0.015, min(0.055, h * 0.6))
            dx, dy = math.cos(a), math.sin(a)
            rr = r * 1.02
            ts = (-0.12, 0.0, 0.35, 0.75, 0.97, 1.08)
            path = [(cx + dx * rr, cy + dy * rr, h - 0.004 - Ld * t) for t in ts]
            mb.add(tube(path, [0.0, 0.0034, 0.0036, 0.0032, 0.0042, 0.0], sides=6, caps=False), wax)
        wt = h - 0.007
        mb.add(tube([(cx, cy, wt - 0.002), (cx + 0.0008, cy, wt + 0.007), (cx + 0.0018, cy + 0.0006, wt + 0.013)],
                    0.0014, sides=4), wick)
        fb = wt + 0.008
        prof = [(0, 0.0), (0.0048, 0.004), (0.0064, 0.009), (0.0056, 0.015), (0.0036, 0.021), (0.0016, 0.026), (0, 0.031)]
        rows = []
        for rr_, z in prof:
            if rr_ == 0:
                rows.append([(cx + 0.0015, cy, fb + z)])
            else:
                rows.append([(cx + 0.0015 + rr_ * math.cos(2 * PI * j / 8), cy + rr_ * math.sin(2 * PI * j / 8), fb + z) for j in range(8)])
        mb.add(ring_surface(rows[::-1]), flame)
    ob = mb.build('candles', sharp_deg=50, origin='bottom')
    p = export_glb(ob, 'candles.glb'); report(ob, p)


# =================================================================== CART
def build_cart():
    reset()
    metal = make_mat('cart_metal', color=(0.62, 0.63, 0.65), rough=0.4, metal=0.6)
    red = make_mat('cart_handle_red', color=(0.70, 0.04, 0.03), rough=0.5)
    wheel = make_mat('cart_wheel', color=(0.06, 0.06, 0.06), rough=0.6)
    mb = MB()
    rw, rf, sides = 0.0038, 0.0065, 6

    def wire(a, b, r=rw):
        mb.add(tube([a, b], r, sides=sides, caps=False), metal)

    def lerp(a, b, t): return np.asarray(a, float) + (np.asarray(b, float) - np.asarray(a, float)) * t

    def grid(c00, c10, c01, c11, nu, nv, r=rw):
        for i in range(1, nu):
            t = i / nu; wire(lerp(c00, c10, t), lerp(c01, c11, t), r)
        for j in range(1, nv):
            t = j / nv; wire(lerp(c00, c01, t), lerp(c10, c11, t), r)
    # upright cart: handle end at +X
    zb, zt = 0.46, 0.84
    B = {  # basket corners: (x, half-width, z)
        'bf': (-0.30, 0.19), 'bb': (0.28, 0.23),     # bottom front/back
        'tf': (-0.42, 0.21), 'tb': (0.36, 0.26)}     # top front/back
    def P(key, s):
        x, hw = B[key]; z = zb if key[0] == 'b' else zt
        return np.array([x, s * hw, z])
    # sides
    for s in (1, -1):
        grid(P('bf', s), P('bb', s), P('tf', s), P('tb', s), 10, 5)
    grid(P('bf', -1), P('bb', -1), P('bf', 1), P('bb', 1), 8, 6)       # bottom
    grid(P('bf', -1), P('bf', 1), P('tf', -1), P('tf', 1), 6, 5)       # front
    grid(P('bb', -1), P('bb', 1), P('tb', -1), P('tb', 1), 6, 5)       # back gate
    # frame edges
    for a, b in [('bf', 'bb'), ('tf', 'tb'), ('bf', 'tf'), ('bb', 'tb')]:
        for s in (1, -1):
            wire(P(a, s), P(b, s), rf)
    for k in ('bf', 'bb', 'tf', 'tb'):
        wire(P(k, -1), P(k, 1), rf)
    # chassis
    zc = 0.11
    cf, cb = np.array([-0.36, 0.0, zc]), np.array([0.30, 0.0, zc])
    for s in (1, -1):
        wire(cf + (0, s * 0.17, 0), cb + (0, s * 0.22, 0), 0.009)
        wire(cb + (0, s * 0.22, 0), P('bb', s) + (0.0, 0, 0), 0.009)          # rear post
        wire(cf + (0.06, s * 0.16, 0), P('bf', s) + (0.02, 0, 0), 0.008)    # front post
        wire(P('tb', s), np.array([0.46, s * 0.25, 0.96]), 0.009)            # handle arms
    wire(cf + (0, -0.17, 0), cf + (0, 0.17, 0), 0.009)
    wire(cb + (0, -0.22, 0), cb + (0, 0.22, 0), 0.009)
    for t in (0.25, 0.5, 0.75):  # lower tray wires
        x = -0.30 + t * 0.55
        hw = 0.17 + t * 0.05
        wire(np.array([x, -hw, zc + 0.01]), np.array([x, hw, zc + 0.01]))
    mb.add(tube([(0.47, -0.265, 0.965), (0.47, 0.265, 0.965)], 0.016, sides=10), red)
    # wheels (casters)
    for (x, y) in [(-0.33, 0.16), (-0.33, -0.16), (0.27, 0.21), (0.27, -0.21)]:
        wire(np.array([x, y, zc]), np.array([x, y, 0.075]), 0.007)
        mb.add(tube([(x - 0.006, y - 0.012, 0.045), (x - 0.006, y + 0.012, 0.045)], 0.045, sides=10), wheel)
    # knock it over onto its side: rotate about the long (X) axis; open top -> Blender -Y (glTF +Z)
    M = affine(rot_x(math.radians(90)))
    for p, _ in mb.items:
        p.xf(M)
    ob = mb.build('shopping_cart', sharp_deg=70, origin='bottom')
    p = export_glb(ob, 'shopping_cart.glb'); report(ob, p)


# =================================================================== MAIN
BUILDERS = {
    'jack': lambda: build_pumpkin('jack_o_lantern.glb', 0.34, 0.28, True, 48, 20, 512, 0.55, 1),
    'cobweb_corner': build_cobweb_corner,
    'cobweb_sag': build_cobweb_sag,
    'tombstone': build_tombstone,
    'skeleton': build_skeleton,
    'bat': build_bat,
    'vhs': build_vhs,
    'candles': build_candles,
    'cart': build_cart,
    'pumpkin_small': lambda: build_pumpkin('pumpkin_small.glb', 0.22, 0.175, False, 32, 14, 256, 0.0, 9),
}

if __name__ == '__main__':
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    names = argv or list(BUILDERS)
    for nme in names:
        try:
            BUILDERS[nme]()
        except Exception:
            import traceback; traceback.print_exc()
            print('FAILED', nme)
