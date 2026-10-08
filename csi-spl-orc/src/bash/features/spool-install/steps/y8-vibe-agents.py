#!/usr/bin/env python3
"""y8-vibe-agents.py - the renderer behind y8-vibe-agents.sh (spec 110);
run it through that wrapper: PARTS-DIR AGENTS-MD DRY FORCE KEY=value...
"""
import hashlib, os, re, sys, time

parts_dir, md, dry, force = sys.argv[1:5]
vals = dict(a.split("=", 1) for a in sys.argv[5:])
FRAG = re.compile(r"^(\d{2})-[a-z0-9][a-z0-9-]*\.md$")
BEGIN = ("<!-- spool-install: begin agents-md (csi-spl fleet rules, the same parts as "
         "~/.claude/CLAUDE.md; edit spool-install/assets/claude/claude-md, not this block) -->\n")
END = re.compile(r"<!-- spool-install: end agents-md sha256=([0-9a-f]{64}) -->\n?")
def say(m): print("spool-install: vibe-agents: " + m, file=sys.stderr)
def sha(s): return hashlib.sha256(s.encode()).hexdigest()
def subst(text, where):
    def one(m):
        k = m.group(1)
        if not vals.get(k):
            sys.exit("spool-install: vibe-agents: %s: {{%s}} has no value" % (where, k))
        return vals[k]
    return re.sub(r"\{\{([A-Z_]+)\}\}", one, text)
def backup_stamped(text):
    """The whole old file to <md>.bak-spool-install-<UTC stamp> (exclusive
    create), BEFORE the replace; an older backup is never overwritten."""
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    for k in range(1, 100):
        b = "%s.bak-spool-install-%s%s" % (md, stamp, "" if k == 1 else "-%d" % k)
        try:
            fd = os.open(b, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        with os.fdopen(fd, "w") as f:
            f.write(text)
        return b
    sys.exit("spool-install: vibe-agents: %s: no free backup name for %s: nothing replaced" % (md, stamp))

# The same parts, in the same NN order and wrapping, as y4's CLAUDE.md block.
names = sorted(os.listdir(parts_dir))
parts = ""
for fn in names:
    if not FRAG.match(fn):
        sys.exit("spool-install: vibe-agents: %s/%s is not NN-<slug>.md" % (parts_dir, fn))
    p = os.path.join(parts_dir, fn)
    body = subst(open(p).read(), p)
    if not body.endswith("\n"): body += "\n"
    parts += "<!-- fragment spool-install/%s -->\n%s<!-- /fragment -->\n" % (fn[:-3], body)
block = BEGIN + parts + "<!-- spool-install: end agents-md sha256=%s -->\n" % sha(parts)

cur = open(md).read() if os.path.exists(md) else None
if cur is None:
    new = block
else:
    i = cur.find(BEGIN)
    e = END.search(cur, i) if i >= 0 else None
    if i >= 0 and e:
        old = cur[i:e.end()]
        if sha(old[len(BEGIN):e.start() - i]) != e.group(1) and old != block and force != "1":
            say("%s: the spool-install block was edited by hand: left alone (--force-skills replaces it)" % md)
            sys.exit(0)
        new = cur[:i] + block + cur[e.end():]
    else:
        # someone else's AGENTS.md: ours goes first, theirs is kept after it
        new = block + ("\n" + cur if cur else "")
if new == cur:
    say("%s: already current" % md)
    sys.exit(0)
if dry == "1":
    print("would: write %s" % md)
    say("%s: would render %d fleet fragment(s)%s" % (md, len(names), ", the old file kept first" if cur is not None else ""))
    sys.exit(0)
kept = backup_stamped(cur) if cur is not None else None
d = os.path.dirname(md)
if not os.path.isdir(d):
    os.makedirs(d, mode=0o700)
tmp = md + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f:
    f.write(new)
if cur is not None:
    os.chmod(tmp, os.stat(md).st_mode & 0o7777)
os.replace(tmp, md)
say("%s: %d fleet fragment(s) rendered%s" % (md, len(names), ", the old file kept as %s" % kept if kept else ""))
