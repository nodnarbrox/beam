"""Render a 3/4-front preview of every GLB (imported back from disk) + contact sheet.
Cycles CPU, 32 samples, 512x512, grey bg, sun + fill. Front = glTF +Z = Blender -Y after import."""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import numpy as np
from mathutils import Vector
import common

OUT, PREV = common.OUT, common.PREV
FILES = ['jack_o_lantern', 'cobweb_corner', 'cobweb_sag', 'tombstone', 'skeleton',
         'bat', 'vhs_tape', 'candles', 'shopping_cart', 'pumpkin_small']


def look_at(cam, target):
    d = Vector(target) - cam.location
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()


def render(name, az=35.0, el=18.0, dark=False, suffix='', zoom=1.0):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=f'{OUT}/{name}.glb')
    obs = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    pts = [o.matrix_world @ Vector(c) for o in obs for c in o.bound_box]
    mn = Vector([min(p[i] for p in pts) for i in range(3)]); mx = Vector([max(p[i] for p in pts) for i in range(3)])
    ctr = (mn + mx) / 2; rad = (mx - mn).length / 2
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 32
    sc.cycles.use_denoising = True
    sc.render.resolution_x = sc.render.resolution_y = 512
    sc.view_settings.view_transform = 'Standard'
    w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
    bg = w.node_tree.nodes['Background']
    bg.inputs['Color'].default_value = (0.02, 0.02, 0.025, 1) if dark else (0.18, 0.18, 0.18, 1)
    bg.inputs['Strength'].default_value = 1.0
    cam_d = bpy.data.cameras.new('c'); cam_d.lens = 50
    cam = bpy.data.objects.new('c', cam_d); sc.collection.objects.link(cam); sc.camera = cam
    dist = rad / math.sin(math.radians(19.8)) * 1.08 / zoom
    a, e = math.radians(az), math.radians(el)
    cam.location = ctr + Vector((math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e))) * dist
    look_at(cam, ctr)
    if not dark:
        for nm, en, rot in (('sun', 3.0, (math.radians(50), 0, math.radians(-30))),
                            ('fill', 1.0, (math.radians(60), 0, math.radians(120)))):
            ld = bpy.data.lights.new(nm, 'SUN'); ld.energy = en
            lo = bpy.data.objects.new(nm, ld); lo.rotation_euler = rot; sc.collection.objects.link(lo)
    else:
        ld = bpy.data.lights.new('moon', 'SUN'); ld.energy = 0.15
        lo = bpy.data.objects.new('moon', ld); lo.rotation_euler = (math.radians(50), 0, math.radians(-30)); sc.collection.objects.link(lo)
    sc.render.filepath = f'{PREV}/{name}{suffix}.png'
    bpy.ops.render.render(write_still=True)
    print('RENDERED', sc.render.filepath)


def contact_sheet():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    tiles = []
    for n in FILES:
        im = bpy.data.images.load(f'{PREV}/{n}.png')
        a = np.array(im.pixels[:], np.float32).reshape(im.size[1], im.size[0], 4)[::-1]
        cov = common.raster_text(40, 512, (0, 512, 0, 40), n + '.glb', (256, 20), 22, maxw=480, font=common.FONT_SANS_BOLD, ss=2)
        a[:40, :, :3] = a[:40, :, :3] * 0.35
        a[:40, :, :3] = a[:40, :, :3] * (1 - cov[..., None]) + cov[..., None]
        tiles.append(a)
    rows = [np.concatenate(tiles[i:i + 5], 1) for i in (0, 5)]
    sheet = np.concatenate(rows, 0)
    H, W = sheet.shape[:2]
    img = bpy.data.images.new('sheet', W, H, alpha=True)
    img.pixels.foreach_set(sheet[::-1].ravel())
    img.filepath_raw = f'{PREV}/contact_sheet.png'; img.file_format = 'PNG'; img.save()
    print('SHEET', img.filepath_raw, W, H)


if __name__ == '__main__':
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    names = [a for a in argv if a != 'sheet'] or FILES
    for n in names:
        render(n)
    if not argv or 'sheet' in argv:
        render('jack_o_lantern', dark=True, suffix='_dark', az=15)
        render('candles', dark=True, suffix='_dark', az=15)
        contact_sheet()
