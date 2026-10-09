"""Rebuild Beam's patched Android bridge from source and prepared dependencies."""
import argparse
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--ndk', type=Path, required=True)
p.add_argument('--dependencies', type=Path, required=True)
p.add_argument('--libtorrent-static', type=Path, required=True)
p.add_argument('--abi', choices=['armeabi-v7a', 'arm64-v8a', 'x86_64'], default='armeabi-v7a')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
host = 'windows-x86_64' if __import__('os').name == 'nt' else 'linux-x86_64'
compiler = a.ndk / 'toolchains/llvm/prebuilt' / host / 'bin' / ('clang++.exe' if host.startswith('windows') else 'clang++')
target = {'armeabi-v7a': 'armv7a-linux-androideabi24', 'arm64-v8a': 'aarch64-linux-android24', 'x86_64': 'x86_64-linux-android24'}[a.abi]
ssl = a.dependencies / ('openssl-' + a.abi)
flags = ['--target=' + target, '-shared', '-fPIC', '-O3', '-std=c++17', '-static-libstdc++',
         '-ffile-prefix-map=' + root.as_posix() + '=.',
         '-ffile-prefix-map=' + a.dependencies.as_posix() + '=dependencies']
flags += ['-D' + x for x in ['TORRENT_BRIDGE_EXPORTS', 'TORRENT_NO_DEPRECATE', 'TORRENT_SSL_PEERS',
                            'TORRENT_USE_LIBCRYPTO', 'TORRENT_USE_OPENSSL', 'BOOST_ASIO_ENABLE_CANCELIO',
                            'BOOST_ASIO_NO_DEPRECATED', 'OPENSSL_NO_SSL2']]
flags += ['-I' + str(x) for x in [a.dependencies / 'libtorrent-src/include', a.dependencies / 'boost_1_84_0', ssl / 'include']]
flags += [str(root / 'packages/libtorrent_flutter/src/torrent_bridge.cpp'), str(a.libtorrent_static),
          str(ssl / 'lib/libssl.a'), str(ssl / 'lib/libcrypto.a'), '-llog', '-latomic', '-ldl', '-lm', '-pthread',
          '-Wl,--no-undefined', '-Wl,-z,max-page-size=16384', '-Wl,-soname,liblibtorrent_flutter.so', '-o', str(a.output)]
a.output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([str(compiler), *flags], check=True)
print('Rebuilt patched bridge for ' + a.abi)
