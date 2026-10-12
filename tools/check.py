#!/usr/bin/env python3
"""Check every app in plugins/ before it is published: the manifest, the files, the style, and what an app on
the E5's info screen must not do.  Errors fail the check (CI stops the pull request); notes are for the
reviewer.  The rules are in README.md.

    tools/check.py [plugins/<id> ...]      (all of plugins/ without arguments)
"""
import json, os, re, sys

API_VERSION = 2                      # the newest the screen has (e5-infoscreen docs/API.md)
MAX_BYTES = 2 * 1024 * 1024          # per app, all files (the screen takes 20 MB; the store wants small ones)
ID = re.compile(r'^[a-z0-9][a-z0-9_-]{0,31}$')
VERSION = re.compile(r'^\d+(\.\d+){0,3}$')
TEXT = {'.html', '.js', '.css', '.json', '.uc', '.svg', '.txt', '.md'}
BINARY = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.woff2', '.ico'}
SETTING_TYPES = {'toggle', 'choice', 'number'}
# the frontend runs in the screen's own page origin: nothing from elsewhere, no code from strings
FRONT_BAD = [
    (re.compile(r'''<script[^>]+src\s*=\s*["']?\s*(https?:)?//''', re.I), 'a script from another host'),
    (re.compile(r'''<link[^>]+href\s*=\s*["']?\s*(https?:)?//''', re.I), 'a stylesheet from another host'),
    (re.compile(r'''\b(fetch|XMLHttpRequest|WebSocket|EventSource|import)\s*\(?\s*["'`](https?|wss?):''', re.I),
     'a request to another host (go through a backend)'),
    (re.compile(r'\beval\s*\('), 'eval()'),
    (re.compile(r'\bnew\s+Function\s*\('), 'new Function()'),
    (re.compile(r'\bdocument\.write\s*\('), 'document.write()'),
    (re.compile(r'''\bset(Timeout|Interval)\s*\(\s*["'`]'''), 'setTimeout/setInterval with a string'),
]
# a backend runs as root: what the reviewer has to look at
BACK_NOTE = [
    (re.compile(r'\b(system|popen)\s*\(|\bctx\.sh(_json)?\s*\('), 'runs commands'),
    (re.compile(r'\bwritefile\s*\(|\bopen\s*\([^)]*["\'][wa]'), 'writes files'),
    (re.compile(r'\b(remove|unlink|rmdir)\s*\('), 'deletes files'),
    (re.compile(r'\bctx\.at(_console)?\s*\('), 'sends AT commands to the modem'),
    (re.compile(r'\bctx\.uci\s*\('), 'reads or writes uci configuration'),
]


def lbl_ok(v, field, errs):
    if not isinstance(v, dict) or not isinstance(v.get('zh'), str) or not v['zh'].strip() \
            or not isinstance(v.get('en'), str) or not v['en'].strip():
        errs.append(f'manifest: "{field}" needs "zh" and "en" texts')


def check(d):
    errs, notes = [], []
    rid = os.path.basename(os.path.normpath(d))
    mf = os.path.join(d, 'manifest.json')
    try:
        with open(mf, encoding='utf-8') as f:
            m = json.load(f)
    except FileNotFoundError:
        return [f'no manifest.json'], notes
    except (ValueError, UnicodeDecodeError) as e:
        return [f'manifest.json: {e}'], notes
    if not isinstance(m, dict):
        return ['manifest.json is not an object'], notes
    if not ID.match(str(m.get('id', ''))):
        errs.append(f'manifest: id {m.get("id")!r} is not lower-case letters, digits, - and _ (32 at most)')
    elif m['id'] != rid:
        errs.append(f'manifest: id {m["id"]!r} is not the directory\'s name {rid!r}')
    av = m.get('api_version')
    if not isinstance(av, int) or not 1 <= av <= API_VERSION:
        errs.append(f'manifest: api_version must be 1..{API_VERSION}')
    if not VERSION.match(str(m.get('version', ''))):
        errs.append('manifest: version must be dotted numbers, e.g. "1.0" -- the screen compares them')
    lbl_ok(m.get('name'), 'name', errs)
    lbl_ok(m.get('description'), 'description', errs)
    entry = m.get('entry', 'index.html')
    if not isinstance(entry, str) or entry.startswith('/') or '..' in entry.split('/') \
            or not os.path.isfile(os.path.join(d, entry)):
        errs.append(f'manifest: entry {entry!r} is not a file of the app')
    if 'order' in m and not isinstance(m['order'], int):
        errs.append('manifest: order must be a number')
    for i, s in enumerate(m.get('settings', []) or []):
        where = f'manifest: settings[{i}]'
        if not isinstance(s, dict):
            errs.append(f'{where} is not an object'); continue
        if s.get('type') not in SETTING_TYPES:
            errs.append(f'{where}: type must be one of {sorted(SETTING_TYPES)}')
        u = str(s.get('uci', ''))
        if not re.match(rf'^e5-plugin-{re.escape(rid)}\.[A-Za-z0-9_]+\.[A-Za-z0-9_]+$', u):
            errs.append(f'{where}: uci must be e5-plugin-{rid}.<section>.<option>, not {u!r}')
        lbl_ok(s.get('label'), f'settings[{i}].label', errs)
    unknown = set(m) - {'id', 'api_version', 'version', 'name', 'description', 'entry', 'order', 'settings', 'notifications', 'input_method'}
    if unknown:
        notes.append(f'manifest: fields the screen does not use: {", ".join(sorted(unknown))}')

    total = 0
    for root, dirs, files in os.walk(d):
        for n in dirs + files:
            p = os.path.join(root, n)
            rel = os.path.relpath(p, d)
            if n.startswith('.'):
                errs.append(f'{rel}: hidden files do not belong in an app')
            if os.path.islink(p):
                errs.append(f'{rel}: a link (the screen refuses packages with links)')
        for n in files:
            p = os.path.join(root, n)
            rel = os.path.relpath(p, d)
            if os.path.islink(p):
                continue
            total += os.path.getsize(p)
            ext = os.path.splitext(n)[1].lower()
            if ext not in TEXT | BINARY and n != 'LICENSE':
                errs.append(f'{rel}: file type {ext or "(none)"} is not allowed')
                continue
            if ext in BINARY:
                continue
            raw = open(p, 'rb').read()
            try:
                text = raw.decode('utf-8')
            except UnicodeDecodeError:
                errs.append(f'{rel}: not UTF-8'); continue
            if '\r' in text:
                errs.append(f'{rel}: CR line ends (LF only)')
            if text and not text.endswith('\n'):
                errs.append(f'{rel}: no newline at the end')
            for ln, line in enumerate(text.split('\n'), 1):
                if line != line.rstrip():
                    errs.append(f'{rel}:{ln}: trailing whitespace'); break
            if ext == '.uc':
                found = sorted({why for rx, why in BACK_NOTE if rx.search(text)})
                notes.append(f'{rel} (runs as root): {", ".join(found) if found else "nothing flagged"}')
                continue
            if ext in {'.html', '.js'}:
                for ln, line in enumerate(text.split('\n'), 1):
                    for rx, why in FRONT_BAD:
                        if rx.search(line):
                            errs.append(f'{rel}:{ln}: {why}')
    if total > MAX_BYTES:
        errs.append(f'{total} bytes: more than {MAX_BYTES} for one app')
    return errs, notes


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.join(here, '..', 'plugins')
    dirs = sys.argv[1:] or sorted(os.path.join(base, n) for n in os.listdir(base)
                                  if os.path.isdir(os.path.join(base, n)))
    bad = 0
    for d in dirs:
        errs, notes = check(d)
        name = os.path.basename(os.path.normpath(d))
        print(f'{"FAIL" if errs else "ok  "} {name}')
        for e in errs:
            print(f'     error: {e}')
        for n in notes:
            print(f'     note:  {n}')
        bad += bool(errs)
    print(f'{len(dirs)} apps, {bad} with errors')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
