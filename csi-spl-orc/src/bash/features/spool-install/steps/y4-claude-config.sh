#!/usr/bin/env bash
# y4-claude-config.sh — install.sh step (spec 069 lane Y4): the fleet's
# standing orders into ~/.claude/CLAUDE.md and its fleet settings into
# ~/.claude/settings.json, rendered from spool-install/assets/claude.
#
#   CLAUDE.md: the fragments of assets/claude/claude-md/NN-<slug>.md, joined
#     in NN order, go into ONE block between
#       <!-- spool-install: begin claude-md ... -->
#       <!-- spool-install: end claude-md sha256=<hex> -->
#     Everything outside the block (the owner's personal fragments: Slack,
#     HTML docs, doc-hub - spec 069 Q4) is never touched, except that a
#     fragment an older renderer wrote under the SAME NN
#     (`<!-- fragment <layer>/NN-<slug> -->` ... `<!-- /fragment -->`) is
#     taken over: removed and named, so no rule is there twice. A re-run
#     rewrites the block only while its sha256 still matches (untouched); a
#     hand-edited block is left alone and named (--force-skills replaces it,
#     the old file kept as CLAUDE.md.bak-spool-install).
#   settings.json: assets/claude/settings/NN-<slug>.json deep-merged in NN
#     order over the current file (other keys kept, ours win), and the marker
#     env.SPOOL_INSTALL_SETTINGS=sha256=<hex of the merged fragments>.
#     The mirror hooks are step 5 of install.sh, not this step.
#
# Placeholders ({{KEY}}) and where their values come from - never a literal:
#   AGENT_USER    SPOOL_AGENT_USER, else the user running install.sh
#   AGENT_HOME    that user's home (passwd)
#   BOX_USER      SPOOL_BOX_USER, else the owner of this checkout
#   BOX_HOME      that user's home (passwd)
#   TMUX_SOCKET   SPOOL_TMUX_SOCKET, else /tmp/tmux-<uid of BOX_USER>/default
#   BOX_TAG       SPOOL_BOX_TAG (env, else the spool-agent config), else <tag>
#   AGENT_CEILING SPOOL_AGENT_CEILING, else 40
#
# Env: SPOOL_INSTALL_CLAUDE_CONFIG=0 skips the step;
#      SPOOL_INSTALL_CLAUDE_ASSETS overrides the assets dir (tests).
# Reads install.sh's DRY, FORCE_SKILLS and ROOT when set.

spool_install_claude_config() {
  [ "${SPOOL_INSTALL_CLAUDE_CONFIG:-1}" = 0 ] && return 0
  local here assets root agent_user box_user box_tag
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  assets="${SPOOL_INSTALL_CLAUDE_ASSETS:-$here/../assets/claude}"
  root="${ROOT:-$(cd "$here/../../../../.." && pwd)}"
  agent_user="${SPOOL_AGENT_USER:-$(id -un)}"
  box_user="${SPOOL_BOX_USER:-$(stat -c %U "$root" 2>/dev/null || id -un)}"
  box_tag="${SPOOL_BOX_TAG:-}"
  if [ -z "$box_tag" ] && declare -F cfg_get >/dev/null; then box_tag="$(cfg_get SPOOL_BOX_TAG)"; fi
  python3 - "$assets" "$HOME" "${DRY:-0}" "${FORCE_SKILLS:-0}" \
    "AGENT_USER=$agent_user" \
    "AGENT_HOME=$(getent passwd "$agent_user" | cut -d: -f6)" \
    "BOX_USER=$box_user" \
    "BOX_HOME=$(getent passwd "$box_user" | cut -d: -f6)" \
    "TMUX_SOCKET=${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u "$box_user" 2>/dev/null)/default}" \
    "BOX_TAG=${box_tag:-<tag>}" \
    "AGENT_CEILING=${SPOOL_AGENT_CEILING:-40}" <<'EOF_PY'
import hashlib, json, os, re, sys
assets, home, dry, force = sys.argv[1:5]
vals = dict(a.split("=", 1) for a in sys.argv[5:])
FRAG = re.compile(r"^(\d{2})-[a-z0-9][a-z0-9-]*\.(md|json)$")
BEGIN = ("<!-- spool-install: begin claude-md (csi-spl fleet rules; edit "
         "spool-install/assets/claude/claude-md, not this block) -->\n")
END = re.compile(r"<!-- spool-install: end claude-md sha256=([0-9a-f]{64}) -->\n?")
def say(m): print("spool-install: claude-config: " + m, file=sys.stderr)
def sha(s): return hashlib.sha256(s.encode()).hexdigest()
def fragments(sub, ext):
    d = os.path.join(assets, sub)
    out = []
    for fn in sorted(os.listdir(d)):
        m = FRAG.match(fn)
        if not m or m.group(2) != ext:
            sys.exit("spool-install: claude-config: %s/%s is not NN-<slug>.%s" % (d, fn, ext))
        out.append((m.group(1), fn[:-len(ext) - 1], os.path.join(d, fn)))
    return out
def subst(text, where):
    def one(m):
        k = m.group(1)
        if not vals.get(k):
            sys.exit("spool-install: claude-config: %s: {{%s}} has no value" % (where, k))
        return vals[k]
    return re.sub(r"\{\{([A-Z_]+)\}\}", one, text)
def write(path, text):
    if dry == "1":
        print("would: write %s" % path); return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp.%d" % os.getpid()
    open(tmp, "w").write(text)
    os.replace(tmp, path)
def backup(path, text):
    if dry != "1" and not os.path.exists(path + ".bak-spool-install"):
        open(path + ".bak-spool-install", "w").write(text)

# ── CLAUDE.md ────────────────────────────────────────────────────────────────
frags = fragments("claude-md", "md")
nums = {n for n, _, _ in frags}
parts = ""
for n, slug, p in frags:
    body = subst(open(p).read(), p)
    if not body.endswith("\n"): body += "\n"
    parts += "<!-- fragment spool-install/%s -->\n%s<!-- /fragment -->\n" % (slug, body)
block = BEGIN + parts + "<!-- spool-install: end claude-md sha256=%s -->\n" % sha(parts)
md = os.path.join(home, ".claude", "CLAUDE.md")
cur = open(md).read() if os.path.exists(md) else ""
i = cur.find(BEGIN)
e = END.search(cur, i) if i >= 0 else None
if i >= 0 and e:
    head, old, tail = cur[:i], cur[i:e.end()], cur[e.end():]
    if sha(old[len(BEGIN):e.start() - i]) != e.group(1) and old != block:
        if force != "1":
            say("%s: the spool-install block was edited by hand: left alone (--force-skills replaces it)" % md)
            block = old
        else:
            backup(md, cur)
else:
    head, tail = "", cur
    gen = re.match(r"<!-- generated by [^\n]*-->\n", tail)
    if gen: head, tail = gen.group(0), tail[gen.end():]
# A fragment an older renderer wrote under one of our NN is ours now.
LEGACY = re.compile(r"<!-- fragment (?!spool-install/)[a-z]+/(\d{2})-[a-z0-9-]+ -->\n.*?<!-- /fragment -->\n", re.S)
def take(m):
    if m.group(1) in nums:
        say("%s: took over %s" % (md, m.group(0).split("\n", 1)[0][5:-4]))
        return ""
    return m.group(0)
head, tail = LEGACY.sub(take, head), LEGACY.sub(take, tail)
new = head + block + tail
if new == cur:
    say("%s: already current" % md)
else:
    if cur and i < 0: backup(md, cur)
    write(md, new)
    say("%s: %d fleet fragment(s) rendered" % (md, len(frags)))

# ── settings.json ────────────────────────────────────────────────────────────
def merge(a, b):
    for k, v in b.items():
        a[k] = merge(a.get(k) if isinstance(a.get(k), dict) else {}, v) if isinstance(v, dict) else v
    return a
ours = {}
for n, slug, p in fragments("settings", "json"):
    try:
        merge(ours, json.loads(subst(open(p).read(), p)))
    except json.JSONDecodeError as x:
        sys.exit("spool-install: claude-config: %s: %s" % (p, x))
merge(ours, {"env": {"SPOOL_INSTALL_SETTINGS": "sha256=" + sha(json.dumps(ours, sort_keys=True))}})
st = os.path.join(home, ".claude", "settings.json")
raw = open(st).read() if os.path.exists(st) else ""
try:
    cur_s = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError as x:
    sys.exit("spool-install: claude-config: %s is not valid JSON (%s): left alone" % (st, x))
new_s = merge(json.loads(json.dumps(cur_s)), ours)
if new_s == cur_s:
    say("%s: already current" % st)
else:
    if raw: backup(st, raw)
    write(st, json.dumps(new_s, indent=2, ensure_ascii=False) + "\n")
    say("%s: fleet settings merged" % st)
EOF_PY
}
