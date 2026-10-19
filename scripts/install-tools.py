"""Install pinned Linux security tools after verifying release archive digests."""

import hashlib
import io
import json
import platform
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / 'scripts/tool-versions.json').read_text())
if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'AMD64'):
    raise SystemExit('Pinned binaries currently support Linux x86_64 only; see docs/development.md')
OUT = ROOT / '.tools/bin'
OUT.mkdir(parents=True, exist_ok=True)
for tool in MANIFEST['tools']:
    name = tool['name']
    if name not in {'actionlint', 'trivy', 'trufflehog'}:
        raise SystemExit(f'Unexpected tool name: {name}')
    destination = OUT / name
    if destination.exists():
        print(f'{name}: installed')
        continue
    print(f'{name}: downloading {tool["version"]}')
    archive = urllib.request.urlopen(tool['url'], timeout=60).read()
    digest = hashlib.sha256(archive).hexdigest()
    if digest != tool['sha256']:
        raise SystemExit(f'{name}: archive SHA-256 mismatch')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        member = next((m for m in tar.getmembers() if m.name == name and m.isfile()), None)
        if member is None:
            raise SystemExit(f'{name}: binary not found in archive')
        destination.write_bytes(tar.extractfile(member).read())
    destination.chmod(0o755)
    print(f'{name}: verified and installed')
