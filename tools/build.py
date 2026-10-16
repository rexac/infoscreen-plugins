#!/usr/bin/env python3
"""The storefront (site/), dist/index.json and dist/packages/<id>-<version>.tar.gz, one package per
app in plugins/ (after tools/check.py).  The packages are reproducible: sorted, owned by root, one mtime.

    tools/build.py [BASE_URL]      (default https://enceka.github.io/infoscreen-plugins)

The index, as e5-infoscreen's `plugin store` / `plugin get` read it:
    { "api_version": 1, "generated": "...", "plugins": [ { "id", "version", "api_version", "name",
      "description", "order", "input_method", "backend", "size", "sha256", "url" } ] }
"""
import gzip, hashlib, html, io, json, os, shutil, sys, tarfile, time
from check import check, NATIVE_FILES

BASE = (sys.argv[1] if len(sys.argv) > 1 else 'https://enceka.github.io/infoscreen-plugins').rstrip('/')
HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.join(HERE, '..')
SRC = os.path.join(TOP, 'plugins')
OUT = os.path.join(TOP, 'dist')
MTIME = 1735689600                    # 2025-01-01: the same bytes for the same files


def package(d, id, version):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.GNU_FORMAT) as t:
        for root, dirs, files in os.walk(d):
            dirs.sort()
            rel_root = os.path.relpath(root, d)
            arc_root = id if rel_root == '.' else f'{id}/{rel_root}'
            ti = tarfile.TarInfo(arc_root); ti.type = tarfile.DIRTYPE; ti.mode = 0o755; ti.mtime = MTIME
            t.addfile(ti)
            for n in sorted(files):
                p = os.path.join(root, n)
                ti = tarfile.TarInfo(f'{arc_root}/{n}')
                ti.size = os.path.getsize(p)
                rel = os.path.relpath(p, d).replace(os.sep, '/')
                ti.mode = 0o755 if (id, rel) in NATIVE_FILES else 0o644
                ti.mtime = MTIME
                ti.uid = ti.gid = 0; ti.uname = ti.gname = 'root'
                with open(p, 'rb') as f:
                    t.addfile(ti, f)
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode='wb', mtime=MTIME) as g:
        g.write(buf.getvalue())
    return gz.getvalue()


def main():
    # Do not package changed native payloads without passing the same review gate as CI.
    for rid in sorted(os.listdir(SRC)):
        d = os.path.join(SRC, rid)
        if os.path.isdir(d):
            errors, _ = check(d)
            if errors:
                raise SystemExit(rid + ': ' + '; '.join(errors))
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(os.path.join(OUT, 'packages'))
    shutil.copytree(os.path.join(TOP, 'site'), OUT, dirs_exist_ok=True)
    storefront = os.path.join(OUT, 'index.html')
    with open(storefront, encoding='utf-8') as f:
        page = f.read().replace('__STORE_BASE_URL__', html.escape(BASE, quote=True))
    with open(storefront, 'w', encoding='utf-8') as f:
        f.write(page)
    index = []
    for id in sorted(os.listdir(SRC)):
        d = os.path.join(SRC, id)
        if not os.path.isdir(d):
            continue
        with open(os.path.join(d, 'manifest.json'), encoding='utf-8') as f:
            m = json.load(f)
        data = package(d, id, m['version'])
        name = f'{id}-{m["version"]}.tar.gz'
        with open(os.path.join(OUT, 'packages', name), 'wb') as f:
            f.write(data)
        index.append({'id': id, 'version': m['version'], 'api_version': m['api_version'],
                      'name': m['name'], 'description': m.get('description'), 'order': m.get('order', 50),
                      'input_method': m.get('input_method') is True,
                      'backend': os.path.isfile(os.path.join(d, 'backend.uc')),
                      'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                      'url': f'{BASE}/packages/{name}'})
        print(f'{name}: {len(data)} bytes')
    index.sort(key=lambda p: (p['order'], p['id']))
    with open(os.path.join(OUT, 'index.json'), 'w', encoding='utf-8') as f:
        json.dump({'api_version': 2, 'generated': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                   'plugins': index}, f, ensure_ascii=False, indent=1)
        f.write('\n')
    print(f'dist/index.json: {len(index)} apps, base {BASE}')


if __name__ == '__main__':
    main()
