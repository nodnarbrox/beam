Pod::Spec.new do |s|
  s.name = 'libtorrent_flutter'
  s.version = '2.0.1'
  s.summary = 'Beam libtorrent FFI bridge'
  s.homepage = 'https://github.com/nodnarbrox/beam'
  s.license = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author = 'Beam contributors'
  s.source = { :path => '.' }
  s.platform = :osx, '14.0'
  s.dependency 'FlutterMacOS'
  s.vendored_libraries = 'liblibtorrent_flutter.dylib', 'libssl.3.dylib', 'libcrypto.3.dylib'
end
