"""Remove a local build-root prefix from ELF read-only diagnostic strings.

Replacement has identical byte length, preserving ELF offsets and instructions.
Only .rodata is changed; executable code, symbols and relocations are untouched.
"""
import argparse
from pathlib import Path
import struct

def sanitize(path, build_root):
    data = bytearray(path.read_bytes())
    if data[:4] != b'\x7fELF' or data[5] != 1:
        raise ValueError('Expected little-endian ELF')
    is64 = data[4] == 2
    offset = struct.unpack_from('<Q' if is64 else '<I', data, 40 if is64 else 32)[0]
    size, count, names_index = struct.unpack_from('<HHH', data, 58 if is64 else 46)
    def section(index):
        start = offset + index * size
        name = struct.unpack_from('<I', data, start)[0]
        pos, length = struct.unpack_from('<QQ' if is64 else '<II', data, start + (24 if is64 else 16))
        return name, pos, length
    _, names_pos, names_size = section(names_index)
    names = data[names_pos:names_pos + names_size]
    old = build_root.replace('\\', '/').encode()
    new = b'/beam/build/'
    if len(old) < len(new):
        raise ValueError('Build root is too short')
    new = new[:-1] + b'_' * (len(old) - len(new)) + b'/'
    changed = 0
    for index in range(count):
        name, pos, length = section(index)
        end = names.find(0, name)
        if bytes(names[name:end]) != b'.rodata':
            continue
        value = bytes(data[pos:pos + length])
        changed += value.count(old)
        data[pos:pos + length] = value.replace(old, new)
    if old in data:
        raise ValueError('Build-root bytes outside .rodata; refusing to write')
    path.write_bytes(data)
    return changed

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('library', type=Path)
    p.add_argument('--build-root', required=True)
    a = p.parse_args()
    print('Normalized diagnostic paths:', sanitize(a.library, a.build_root))
