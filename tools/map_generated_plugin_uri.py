"""Give Flutter's generated Dart plugin registrant a neutral package URI.

Run after flutter pub get and before a release build with --no-pub. The extra
package maps the same generated directory; no plugin source or behavior changes.
Flutter's compiler converts its registrant file URI through this package map,
avoiding embedding the host username in the AOT snapshot.
"""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
config = root / '.dart_tool/package_config.json'
data = json.loads(config.read_text())
name = 'beam_generated_plugins'
data['packages'] = [p for p in data['packages'] if p['name'] != name]
data['packages'].append({'name': name, 'rootUri': 'flutter_build/', 'packageUri': '',
                         'languageVersion': '3.12'})
config.write_text(json.dumps(data, indent=2) + '\n')
print('Mapped generated plugin registrant to package:' + name)
