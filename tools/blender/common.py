"""Shared helpers for the Blockbuster-Halloween prop builders (Blender 4.5, headless).

Geometry is accumulated as numpy "Parts" (verts, faces, per-face-corner UVs) and
joined into ONE mesh object per asset. Closed parts are auto-oriented outward
via signed volume, so no inside-out normals.
"""
import bpy, bmesh, math, os
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
OUT = ROOT + '/assets/store3d'
TOOLS = ROOT + '/tools/blender'
TEX = TOOLS + '/tex'
PREV = TOOLS + '/previews'
for _d in (OUT, TEX, PREV):
    os.makedirs(_d, exist_ok=True)

FONT_SERIF_BOLD = 'C:/Windows/Fonts/georgiab.ttf'
FONT_SANS_BOLD = 'C:/Windows/Fonts/arialbd.ttf'


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


# ----------------------------------------------------------------- math utils
def norm(v):
    v = np.asarray(v, float)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]], float)


def rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]], float)


def rot_z(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], float)


def affine(R=None, t=(0, 0, 0), pivot=None):
    """4x4: rotate R about pivot, then translate t."""
    M = np.eye(4)
    R = np.eye(3) if R is None else np.asarray(R, float)
    M[:3, :3] = R
    if pivot is not None:
        p = np.asarray(pivot, float)
        M[:3, 3] = p - R @ p
    M[:3, 3] += np.asarray(t, float)
    return M


def xpt(M, p):
    return (M[:3, :3] @ np.asarray(p, float)) + M[:3, 3]


def frame_from(d, up_hint=(0, 0, 1)):
    """Rotation matrix whose columns are (a, b, d): local Z = d."""
    d = norm(d)
    u = np.asarray(up_hint, float)
    if abs(np.dot(u, d)) > 0.95:
        u = np.array([1.0, 0, 0]) if abs(d[0]) < 0.9 else np.array([0, 1.0, 0])
    a = norm(np.cross(u, d))
    b = np.cross(d, a)
    return np.stack([a, b, d], 1)


# ----------------------------------------------------------------- parts
class Part:
    def __init__(self, V, F, UV, closed=True, FM=None):
        self.V = np.asarray(V, float).reshape(-1, 3)
        self.F = [list(f) for f in F]
        self.UV = [[tuple(x) for x in u] for u in UV]
        self.closed = closed
        self.FM = FM  # optional per-face material list

    def xf(self, M):
        M = np.asarray(M, float)
        R = M[:3, :3]
        t = M[:3, 3] if M.shape == (4, 4) else np.zeros(3)
        self.V = self.V @ R.T + t
        if np.linalg.det(R) < 0:
            self.flip()
        return self

    def move(self, t):
        self.V = self.V + np.asarray(t, float)
        return self

    def flip(self):
        self.F = [f[::-1] for f in self.F]
        self.UV = [u[::-1] for u in self.UV]
        return self

    def signed_volume(self):
        c = self.V.mean(0)
        vol = 0.0
        for f in self.F:
            a = self.V[f[0]] - c
            for k in range(1, len(f) - 1):
                vol += np.dot(a, np.cross(self.V[f[k]] - c, self.V[f[k + 1]] - c))
        return vol / 6.0

    def orient_outward(self):
        if self.signed_volume() < 0:
            self.flip()
        return self


def ring_surface(rows, uvfn=None, closed=True):
    """rows: list of point arrays; a row of length 1 is a pole. Closed in u."""
    rows = [np.asarray(r, float).reshape(-1, 3) for r in rows]
    n = max(len(r) for r in rows)
    V, starts = [], []
    for r in rows:
        starts.append(len(V))
        V.extend(r.tolist())
    L = len(rows)

    def uv(i, j):
        u, v = j / n, 1.0 - i / (L - 1)
        return uvfn(u, v) if uvfn else (u, v)

    F, UV = [], []
    for i in range(L - 1):
        p0, p1 = len(rows[i]) == 1, len(rows[i + 1]) == 1
        for j in range(n):
            j1 = (j + 1) % n
            if p0 and p1:
                continue
            if p0:
                F.append([starts[i], starts[i + 1] + j, starts[i + 1] + j1])
                UV.append([uv(i, j + 0.5), uv(i + 1, j), uv(i + 1, j + 1)])
            elif p1:
                F.append([starts[i] + j, starts[i + 1], starts[i] + j1])
                UV.append([uv(i, j), uv(i + 1, j + 0.5), uv(i, j + 1)])
            else:
                F.append([starts[i] + j, starts[i + 1] + j, starts[i + 1] + j1, starts[i] + j1])
                UV.append([uv(i, j), uv(i + 1, j), uv(i + 1, j + 1), uv(i, j + 1)])
    return Part(V, F, UV, closed=closed)


def ellipsoid(c, radii, nu=8, nv=6, R=None):
    rows = []
    for i in range(nv + 1):
        ph = math.pi * i / nv
        if i == 0 or i == nv:
            rows.append([(0, 0, radii[2] * math.cos(ph))])
            continue
        rows.append([(radii[0] * math.sin(ph) * math.cos(2 * math.pi * j / nu),
                      radii[1] * math.sin(ph) * math.sin(2 * math.pi * j / nu),
                      radii[2] * math.cos(ph)) for j in range(nu)])
    p = ring_surface(rows)
    if R is not None:
        p.xf(affine(R))
    return p.move(c)


def tube(path, radii, sides=6, caps=True, up_hint=(0, 0, 1), phase=0.0):
    """Tube along a polyline, parallel-transport frames. radius 0 => pole."""
    P = np.asarray(path, float)
    n = len(P)
    radii = np.broadcast_to(np.asarray(radii, float), (n,))
    T = np.zeros_like(P)
    for i in range(n):
        a, b = P[max(i - 1, 0)], P[min(i + 1, n - 1)]
        T[i] = norm(b - a)
    fr = frame_from(T[0], up_hint)
    N = fr[:, 0]
    rows = []
    if caps and radii[0] > 0:
        rows.append([P[0]])
    for i in range(n):
        if i > 0:
            N = norm(N - np.dot(N, T[i]) * T[i])
        B = np.cross(T[i], N)
        if radii[i] <= 0:
            rows.append([P[i]])
            continue
        ring = []
        for j in range(sides):
            a = 2 * math.pi * j / sides + phase
            ring.append(P[i] + radii[i] * (math.cos(a) * N + math.sin(a) * B))
        rows.append(ring)
    if caps and radii[-1] > 0:
        rows.append([P[-1]])
    return ring_surface(rows)


def bone(p0, p1, r, knob=1.5, sides=6):
    """Long bone: shaft with knobby epiphyses, rounded ends."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    ts = [0.0, 0.05, 0.16, 0.5, 0.84, 0.95, 1.0]
    rs = [0.0, r * knob, r * 1.05, r * 0.9, r * 1.05, r * knob, 0.0]
    path = [p0 + (p1 - p0) * t for t in ts]
    return tube(path, rs, sides=sides, caps=False)


def box(c, size, R=None):
    sx, sy, sz = [s / 2 for s in size]
    V = [(-sx, -sy, -sz), (sx, -sy, -sz), (sx, sy, -sz), (-sx, sy, -sz),
         (-sx, -sy, sz), (sx, -sy, sz), (sx, sy, sz), (-sx, sy, sz)]
    F = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
    UV = [[(0, 0), (1, 0), (1, 1), (0, 1)]] * 6
    p = Part(V, F, UV)
    if R is not None:
        p.xf(affine(R))
    return p.move(c)


def part_from_bmesh(bm, face_fn):
    """face_fn(face) -> (material_name, [uv per loop])"""
    bm.verts.ensure_lookup_table()
    V = [tuple(v.co) for v in bm.verts]
    F, UV, FM = [], [], []
    for f in bm.faces:
        m, uvs = face_fn(f)
        F.append([v.index for v in f.verts])
        UV.append(uvs)
        FM.append(m)
    return Part(V, F, UV, closed=False, FM=FM)


# ----------------------------------------------------------------- builder
class MB:
    def __init__(self):
        self.items = []  # (part, material)

    def add(self, part, mat, orient=True):
        if orient and part.closed:
            part.orient_outward()
        self.items.append((part, mat))
        return part

    def tris(self):
        return sum(len(f) - 2 for p, _ in self.items for f in p.F)

    def build(self, name, sharp_deg=45.0, origin='bottom'):
        mats, V, F, UV, MI = [], [], [], [], []
        for p, m in self.items:
            base = len(V)
            V.extend(p.V.tolist())
            for k, f in enumerate(p.F):
                mm = p.FM[k] if p.FM is not None else m
                if mm not in mats:
                    mats.append(mm)
                F.append([base + i for i in f])
                UV.append(p.UV[k])
                MI.append(mats.index(mm))
        V = np.asarray(V)
        if origin == 'bottom':
            mn, mx = V.min(0), V.max(0)
            V = V - np.array([(mn[0] + mx[0]) / 2, (mn[1] + mx[1]) / 2, mn[2]])
        elif origin == 'zfloor':
            V = V - np.array([0, 0, V[:, 2].min()])
        me = bpy.data.meshes.new(name)
        me.from_pydata(V.tolist(), [], F)
        uvl = me.uv_layers.new(name='UVMap')
        flat = [c for u in UV for c in u]
        uvl.data.foreach_set('uv', np.asarray(flat, float).ravel())
        for m in mats:
            me.materials.append(m)
        me.polygons.foreach_set('material_index', MI)
        me.validate(clean_customdata=False)
        me.shade_smooth()
        bm = bmesh.new()
        bm.from_mesh(me)
        thr = math.radians(sharp_deg)
        for e in bm.edges:
            if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > thr:
                e.smooth = False
        bm.to_mesh(me)
        bm.free()
        me.update()
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        return ob


# ----------------------------------------------------------------- materials
def make_mat(name, color=(0.8, 0.8, 0.8), rough=0.5, metal=0.0, base_img=None,
             emis_img=None, emis_color=None, alpha_clip=None, double=False):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*color, 1.0)
    b.inputs['Roughness'].default_value = rough
    b.inputs['Metallic'].default_value = metal
    if base_img is not None:
        t = nt.nodes.new('ShaderNodeTexImage')
        t.image = base_img
        t.location = (-600, 200)
        nt.links.new(t.outputs['Color'], b.inputs['Base Color'])
        if alpha_clip is not None:
            lt = nt.nodes.new('ShaderNodeMath'); lt.operation = 'LESS_THAN'
            lt.inputs[1].default_value = alpha_clip
            sub = nt.nodes.new('ShaderNodeMath'); sub.operation = 'SUBTRACT'
            sub.inputs[0].default_value = 1.0
            nt.links.new(t.outputs['Alpha'], lt.inputs[0])
            nt.links.new(lt.outputs[0], sub.inputs[1])
            nt.links.new(sub.outputs[0], b.inputs['Alpha'])
            try:
                m.surface_render_method = 'DITHERED'
            except Exception:
                m.blend_method = 'CLIP'
    if emis_img is not None:
        t2 = nt.nodes.new('ShaderNodeTexImage')
        t2.image = emis_img
        t2.location = (-600, -200)
        nt.links.new(t2.outputs['Color'], b.inputs['Emission Color'])
        b.inputs['Emission Strength'].default_value = 1.0
    elif emis_color is not None:
        b.inputs['Emission Color'].default_value = (*emis_color, 1.0)
        b.inputs['Emission Strength'].default_value = 1.0
    else:
        b.inputs['Emission Strength'].default_value = 0.0
    m.use_backface_culling = not double
    return m


def np_to_image(name, arr):
    """arr: (H,W,3|4) float 0..1, row 0 = TOP of image. Saved as PNG + packed."""
    arr = np.clip(np.asarray(arr, float), 0, 1)
    H, W = arr.shape[:2]
    px = np.ones((H, W, 4), np.float32)
    px[..., :arr.shape[2]] = arr
    img = bpy.data.images.new(name, W, H, alpha=True)
    img.pixels.foreach_set(px[::-1].ravel())
    path = f'{TEX}/{name}.png'
    img.filepath_raw = path
    img.file_format = 'PNG'
    img.save()
    img.pack()
    return img


def export_glb(ob, fname):
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    path = f'{OUT}/{fname}'
    bpy.ops.export_scene.gltf(
        filepath=path, export_format='GLB', use_selection=True, export_apply=True,
        export_yup=True, export_animations=False, export_cameras=False, export_lights=False,
        export_texcoords=True, export_normals=True, export_materials='EXPORT',
        export_image_format='AUTO', export_tangents=False, export_skins=False,
        export_morph=False, export_extras=False, export_attributes=False)
    return path


# ----------------------------------------------------------------- textures
def value_noise(H, W, cy, cx, rng):
    g = rng.random((cy + 1, cx + 1))
    g[:, -1] = g[:, 0]
    g[-1, :] = g[0, :]
    y = np.linspace(0, cy, H, endpoint=False)
    x = np.linspace(0, cx, W, endpoint=False)
    y0 = np.floor(y).astype(int); x0 = np.floor(x).astype(int)
    fy = y - y0; fx = x - x0
    fy = fy * fy * (3 - 2 * fy); fx = fx * fx * (3 - 2 * fx)
    a = g[y0][:, x0]; b = g[y0][:, x0 + 1]; c = g[y0 + 1][:, x0]; d = g[y0 + 1][:, x0 + 1]
    fx = fx[None, :]; fy = fy[:, None]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(H, W, cells=4, octaves=5, seed=0, pers=0.5, aspect=(1, 1)):
    rng = np.random.default_rng(seed)
    out = np.zeros((H, W)); amp = 1.0; tot = 0.0; c = cells
    for _ in range(octaves):
        out += amp * value_noise(H, W, max(1, int(c * aspect[0])), max(1, int(c * aspect[1])), rng)
        tot += amp; amp *= pers; c *= 2
    return out / tot


def dilate(mask, r):
    out = mask.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy <= r * r:
                out = np.maximum(out, np.roll(np.roll(mask, dy, 0), dx, 1))
    return out


def draw_polyline(alpha, pts, half_w=1.3, soft=0.9, val=1.0):
    """Anti-aliased thick polyline into alpha (H,W). pts in pixel coords (x,y)."""
    H, W = alpha.shape
    pts = np.asarray(pts, float)
    pad = half_w + soft + 1
    for a, b in zip(pts[:-1], pts[1:]):
        x0 = int(max(0, math.floor(min(a[0], b[0]) - pad))); x1 = int(min(W - 1, math.ceil(max(a[0], b[0]) + pad)))
        y0 = int(max(0, math.floor(min(a[1], b[1]) - pad))); y1 = int(min(H - 1, math.ceil(max(a[1], b[1]) + pad)))
        if x1 < x0 or y1 < y0:
            continue
        yy, xx = np.mgrid[y0:y1 + 1, x0:x1 + 1]
        px = xx + 0.5 - a[0]; py = yy + 0.5 - a[1]
        d = b - a; L2 = max(float(d @ d), 1e-9)
        t = np.clip((px * d[0] + py * d[1]) / L2, 0, 1)
        dist = np.hypot(px - t * d[0], py - t * d[1])
        v = np.clip((half_w + soft - dist) / soft, 0, 1) * val
        alpha[y0:y1 + 1, x0:x1 + 1] = np.maximum(alpha[y0:y1 + 1, x0:x1 + 1], v)


# ----------------------------------------------------------------- text raster
def text_mesh2d(text, font_path=None):
    cu = bpy.data.curves.new('txt', 'FONT')
    cu.body = text
    cu.align_x = 'CENTER'
    if font_path and os.path.exists(font_path):
        cu.font = bpy.data.fonts.load(font_path, check_existing=True)
    ob = bpy.data.objects.new('txt', cu)
    bpy.context.scene.collection.objects.link(ob)
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    co = np.array([v.co[:2] for v in me.vertices], float)
    tri = np.array([t.vertices[:] for t in me.loop_triangles], int)
    ev.to_mesh_clear()
    bpy.data.objects.remove(ob)
    bpy.data.curves.remove(cu)
    return co, tri


def raster_text(H, W, extent, text, center, height, maxw=None, font=None, ss=4):
    """Coverage (H,W) of `text` placed in a canvas spanning extent=(x0,x1,y0,y1)
    (y up; row 0 = y1). `height` = glyph bbox height in canvas units."""
    x0, x1, y0, y1 = extent
    co, tri = text_mesh2d(text, font)
    mn, mx = co.min(0), co.max(0)
    s = height / (mx[1] - mn[1])
    if maxw and (mx[0] - mn[0]) * s > maxw:
        s = maxw / (mx[0] - mn[0])
    co = (co - (mn + mx) / 2) * s + np.asarray(center, float)
    Hs, Ws = H * ss, W * ss
    P = np.stack([(co[:, 0] - x0) / (x1 - x0) * Ws - 0.5, (y1 - co[:, 1]) / (y1 - y0) * Hs - 0.5], 1)
    mask = np.zeros((Hs, Ws), bool)
    for t in tri:
        a, b, c = P[t]
        c0 = max(0, int(math.floor(min(a[0], b[0], c[0])))); c1 = min(Ws - 1, int(math.ceil(max(a[0], b[0], c[0]))))
        r0 = max(0, int(math.floor(min(a[1], b[1], c[1])))); r1 = min(Hs - 1, int(math.ceil(max(a[1], b[1], c[1]))))
        if c1 < c0 or r1 < r0:
            continue
        yy, xx = np.mgrid[r0:r1 + 1, c0:c1 + 1].astype(float)
        e0 = (b[0] - a[0]) * (yy - a[1]) - (b[1] - a[1]) * (xx - a[0])
        e1 = (c[0] - b[0]) * (yy - b[1]) - (c[1] - b[1]) * (xx - b[0])
        e2 = (a[0] - c[0]) * (yy - c[1]) - (a[1] - c[1]) * (xx - c[0])
        ins = ((e0 >= 0) & (e1 >= 0) & (e2 >= 0)) | ((e0 <= 0) & (e1 <= 0) & (e2 <= 0))
        mask[r0:r1 + 1, c0:c1 + 1] |= ins
    return mask.reshape(H, ss, W, ss).mean((1, 3))


def report(ob, path):
    me = ob.data
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    dims = tuple(round(d, 4) for d in ob.dimensions)
    print(f'BUILT {os.path.basename(path)} tris={tris} dims(blender xyz)={dims} '
          f'mats={[m.name for m in me.materials]} size={os.path.getsize(path)//1024}KB')
