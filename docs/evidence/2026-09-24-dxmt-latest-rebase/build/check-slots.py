#!/usr/bin/env python3
# Map every winemetal PE thunk's UNIX_CALL(N) to the unix table entry at N.
import re, sys, os
root = sys.argv[1]
u = open(os.path.join(root, 'src/winemetal/unix/winemetal_unix.c')).read()
def table(name):
    m = re.search(r'const void \*%s\[\] = \{(.*?)\n\};' % name, u, re.S)
    return [e.lstrip('&') for e in re.findall(r'^\s*(&?[A-Za-z0-9_]+|NULL)\s*,', m.group(1), re.M)]
nat, wow = table('__wine_unix_call_funcs'), table('__wine_unix_call_wow64_funcs')
print('native', len(nat), 'wow64', len(wow))
bad = 0
if len(nat) != len(wow): print('LENGTH MISMATCH'); bad += 1
t = open(os.path.join(root, 'src/winemetal/winemetal_thunks.c')).read()
# function bodies: find "Name(...) {" then the UNIX_CALL within
for m in re.finditer(r'\n([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{]*\)\s*\{(.*?)\n\}', t, re.S):
    fn, body = m.group(1), m.group(2)
    for c in re.findall(r'(?:WINE_)?UNIX_CALL\((\d+),', body):
        n = int(c)
        ent = nat[n] if n < len(nat) else '<out of range>'
        base = re.sub(r'^_rmg_|^_', '', ent)
        norm = lambda x: x.lower().replace('_', '')
        ok = norm(base) == norm(fn) or norm(base).endswith(norm(fn)) or norm(fn).endswith(norm(base))
        w = wow[n] if n < len(wow) else '<oor>'
        wbase = re.sub(r'^_rmg_|^_|_wow64$', '', w).replace('_wow64', '')
        wok = norm(wbase) == norm(base) or norm(wbase).endswith(norm(base)) or norm(base).endswith(norm(wbase))
        if not ok or not wok:
            print('CHECK slot %3d thunk %-50s native %-50s wow64 %s' % (n, fn, ent, w)); bad += 1
print('suspicious:', bad)
