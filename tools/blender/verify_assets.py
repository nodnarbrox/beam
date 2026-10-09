"""Re-import every GLB in a fresh scene + parse the raw GLB JSON/BIN with plain Python.
Prints stats, material info, front-axis evidence and a ray-parity outward-normal check."""
import sys, os, json, struct, math
import bpy
import numpy as np
from mathutils.bvhtree import BVHTree
from mathutils import Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
OUT = os.path.join(ROOT, 'assets', 'store3d')
FILES = ['jack_o_lantern.glb', 'cobweb_corner.glb', 'cobweb_sag.glb', 'tombstone.glb', 'skeleton.glb',
         'bat.glb', 'vhs_tape.glb', 'candles.glb', 'shopping_cart.glb', 'pumpkin_small.glb']

CT = {5126: ('f', 4), 5123: ('H', 2), 5125: ('I', 4), 5121: ('B', 1)}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}


def read_glb(path):
    b = open(path, 'rb').read()
    magic, ver, total = struct.unpack_from('<III', b, 0)
    assert magic == 0x46546C67, 'not glb'
    off = 12; js = None; bin_ = None
    while off < len(b):
        ln, typ = struct.unpack_from('<II', b, off)
        chunk = b[off + 8: off + 8 + ln]
        if typ == 0x4E4F534A: js = json.loads(chunk.decode())
        elif typ == 0x004E4942: bin_ = chunk
        off += 8 + ln
    return js, bin_


def accessor(js, bin_, i):
    a = js['accessors'][i]; bv = js['bufferViews'][a['bufferView']]
    fmt, sz = CT[a['componentType']]; nc = NC[a['type']]
    start = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    stride = bv.get('byteStride', sz * nc)
    out = []
    for k in range(a['count']):
        out.append(struct.unpack_from('<' + fmt * nc, bin_, start + k * stride))
    return np.array(out, float)


def png_size(bin_, js, img):
    bv = js['bufferViews'][img['bufferView']]
    o = bv.get('byteOffset', 0)
    w, h = struct.unpack_from('>II', bin_, o + 16)
    return w, h, bv['byteLength']


def gltf_report(path):
    js, bin_ = read_glb(path)
    res = {'materials': [], 'images': [], 'prims': []}
    for m in js.get('materials', []):
        pbr = m.get('pbrMetallicRoughness', {})
        res['materials'].append(dict(
            name=m.get('name'), baseColorFactor=[round(x, 3) for x in pbr.get('baseColorFactor', [1, 1, 1, 1])],
            baseColorTex='baseColorTexture' in pbr, metallic=pbr.get('metallicFactor', 1.0),
            roughness=round(pbr.get('roughnessFactor', 1.0), 3),
            emissiveFactor=m.get('emissiveFactor'), emissiveTex='emissiveTexture' in m,
            alphaMode=m.get('alphaMode', 'OPAQUE'), alphaCutoff=m.get('alphaCutoff'),
            doubleSided=m.get('doubleSided', False), extensions=list(m.get('extensions', {}).keys())))
    for im in js.get('images', []):
        w, h, n = png_size(bin_, js, im)
        res['images'].append(f"{im.get('name')}:{im.get('mimeType')}:{w}x{h}:{n//1024}KB")
    res['extensionsUsed'] = js.get('extensionsUsed', [])
    res['nodes'] = len(js.get('nodes', [])); res['meshes'] = len(js.get('meshes', []))
    res['anims'] = len(js.get('animations', [])); res['cams'] = len(js.get('cameras', []))
    for mesh in js['meshes']:
        for pr in mesh['primitives']:
            mat = js['materials'][pr['material']]['name']
            P = accessor(js, bin_, pr['attributes']['POSITION'])
            N = accessor(js, bin_, pr['attributes']['NORMAL'])
            UV = accessor(js, bin_, pr['attributes']['TEXCOORD_0']) if 'TEXCOORD_0' in pr['attributes'] else None
            I = accessor(js, bin_, pr['indices']).astype(int).ravel()
            res['prims'].append(dict(mat=mat, P=P, N=N, UV=UV, ntri=len(I) // 3))
    return js, res


def front_evidence(fname, res):
    """Return a string proving where the asset's front points in glTF space."""
    allP = np.concatenate([p['P'] for p in res['prims']])
    ctr = (allP.min(0) + allP.max(0)) / 2
    by = {p['mat']: p for p in res['prims']}
    if fname == 'jack_o_lantern.glb':
        p = by['pumpkin_carved']; uv = p['UV']
        sel = (uv[:, 0] > 0.42) & (uv[:, 0] < 0.58) & (uv[:, 1] > 0.3) & (uv[:, 1] < 0.7)  # face region (u=0.5 centre)
        c = p['P'][sel].mean(0)
        return f'face-UV verts centroid={np.round(c,3).tolist()} -> front=+Z' if c[2] > 0.1 else f'FRONT WRONG {c}'
    if fname == 'tombstone.glb':
        n = by['stone_front']['N'].mean(0); return f'engraved-face mean normal={np.round(n,3).tolist()}'
    if fname == 'vhs_tape.glb':
        return (f"label mean normal={np.round(by['vhs_label']['N'].mean(0),3).tolist()}, "
                f"window/top mean normal={np.round(by['vhs_top']['N'].mean(0),3).tolist()}")
    if fname == 'skeleton.glb':
        c = by['socket_dark']['P'].mean(0); b = by['bone']['P']
        head = b[b[:, 1] > 1.5].mean(0)
        return f'eye/nose sockets z={c[2]:.3f} vs head centre z={head[2]:.3f} -> face toward +Z' if c[2] > head[2] else 'FRONT WRONG'
    if fname == 'bat.glb':
        c = by['bat_eye']['P'].mean(0); return f'eyes centroid={np.round(c,3).tolist()} (body at origin) -> +Z'
    if fname in ('cobweb_corner.glb', 'cobweb_sag.glb'):
        p = res['prims'][0]; return f'face normal mean={np.round(p["N"].mean(0),3).tolist()} (double-sided)'
    if fname == 'shopping_cart.glb':
        return 'open basket top faces +Z (tipped on its side, handle toward +X)'
    return 'n/a (rotationally symmetric)'


def probe_axis():
    """Prove Blender -Y -> glTF +Z with a marker cube."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(size=1)
    ob = bpy.context.active_object
    m1 = bpy.data.materials.new('FRONT_MINUS_Y'); m2 = bpy.data.materials.new('OTHER')
    ob.data.materials.append(m2); ob.data.materials.append(m1)
    for p in ob.data.polygons:
        p.material_index = 1 if p.normal.y < -0.9 else 0
    path = os.path.join(ROOT, 'tools', 'blender', 'tex', '_axis_probe.glb')
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', use_selection=True, export_yup=True)
    js, res = gltf_report(path)
    n = [p for p in res['prims'] if p['mat'] == 'FRONT_MINUS_Y'][0]['N'].mean(0)
    os.remove(path)
    return np.round(n, 3).tolist()


def ray_parity(ob, single_sided_mats):
    """Per connected shell (vertices welded by position): cast a ray along each face
    normal against ONLY its own shell; even hit count => face points outward."""
    me = ob.data
    mw = ob.matrix_world
    verts = [mw @ v.co for v in me.vertices]
    key = [tuple(round(c, 6) for c in v) for v in verts]
    parent = list(range(len(verts)))
    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]; i = parent[i]
        return i
    first = {}
    for i, k in enumerate(key):
        if k in first: parent[find(i)] = find(first[k])
        else: first[k] = i
    for p in me.polygons:
        vs = p.vertices
        for a in vs[1:]:
            ra, rb = find(a), find(vs[0])
            if ra != rb: parent[ra] = rb
    shells = {}
    for p in me.polygons:
        shells.setdefault(find(p.vertices[0]), []).append(p)
    ok = tot = 0
    for polys in shells.values():
        bvh = BVHTree.FromPolygons(verts, [p.vertices[:] for p in polys])
        for p in polys:
            if me.materials[p.material_index].name not in single_sided_mats:
                continue
            c = mw @ p.center; n = (mw.to_3x3() @ p.normal).normalized()
            o = c + n * 1e-5; hits = 0
            for _ in range(50):
                loc, nn, idx, d = bvh.ray_cast(o, n)
                if loc is None: break
                hits += 1; o = loc + n * 1e-5
            tot += 1; ok += (hits % 2 == 0)
    return ok, tot


def main():
    print('AXIS PROBE: Blender -Y face exported normal (glTF) =', probe_axis())
    summary = []
    for f in FILES:
        path = f'{OUT}/{f}'
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.gltf(filepath=path)
        obs = [o for o in bpy.context.scene.objects if o.type == 'MESH']
        tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in obs)
        import mathutils
        pts = [o.matrix_world @ mathutils.Vector(c) for o in obs for c in o.bound_box]
        mn = [min(p[i] for p in pts) for i in range(3)]; mx = [max(p[i] for p in pts) for i in range(3)]
        dims = [round(mx[i] - mn[i], 4) for i in range(3)]
        mats_bl = []
        for o in obs:
            for m in o.data.materials:
                b = m.node_tree.nodes.get('Principled BSDF')
                emis = b and (b.inputs['Emission Strength'].default_value > 0 and
                              (b.inputs['Emission Color'].is_linked or any(b.inputs['Emission Color'].default_value[:3])))
                alpha_linked = b and b.inputs['Alpha'].is_linked
                mats_bl.append(f"{m.name}(emis={'Y' if emis else 'N'},alphaLinked={'Y' if alpha_linked else 'N'},"
                               f"backfaceCull={m.use_backface_culling})")
        js, res = gltf_report(path)
        single = [m['name'] for m in res['materials'] if not m['doubleSided']]
        ok, tot = ray_parity(obs[0], single) if obs else (0, 0)
        print('=' * 100)
        print(f'{f}: size={os.path.getsize(path)//1024}KB objects={len(obs)} tris={tris} '
              f'bbox_blender_xyz={dims} min={[round(x,3) for x in mn]} max={[round(x,3) for x in mx]}')
        print('  blender mats:', mats_bl)
        print(f"  gltf nodes={res['nodes']} meshes={res['meshes']} anims={res['anims']} cams={res['cams']} "
              f"extUsed={res['extensionsUsed']} images={res['images']}")
        for m in res['materials']:
            print('  gltf mat:', json.dumps(m))
        gtri = sum(p['ntri'] for p in res['prims'])
        allP = np.concatenate([p['P'] for p in res['prims']])
        print(f'  gltf tris={gtri} gltf POSITION min={np.round(allP.min(0),3).tolist()} max={np.round(allP.max(0),3).tolist()}')
        print('  FRONT:', front_evidence(f, res))
        print(f'  outward-normal ray parity (single-sided tris): {ok}/{tot}')
        summary.append((f, os.path.getsize(path) // 1024, gtri, np.round(allP.max(0) - allP.min(0), 3).tolist()))
    print('SUMMARY (file, KB, tris, gltf bbox xyz):')
    for s in summary:
        print('  ', s)


main()
