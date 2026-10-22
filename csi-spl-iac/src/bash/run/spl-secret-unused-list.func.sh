#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
# shellcheck source=spl-secret-age-report.func.sh
declare -F spl_secret_age_dump >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-secret-age-report.func.sh"
#------------------------------------------------------------------------------
# @description READ-ONLY dry-run list of the unused credentials of one env and
# @description of this box (SPL-1945 row 2, owner Q3: the list is shown to the
# @description owner before anything is removed; SPL-2896). It deletes nothing.
# @description One markdown table, one row per candidate: class, where it is,
# @description age in days, verdict and the evidence behind the verdict.
# @description   sa-key       every user-managed key of the env project's SAs
# @description                (key id prefix, 8 chars): the project key file
# @description                (do_gcp_sa_key_file) = IN-USE; another key file
# @description                on this box = UNUSED when no code names it, else
# @description                IN-USE; no file on this box = CHECK (a CI secret
# @description                or another box may hold it).
# @description   secret-empty a Secret Manager secret with 0 enabled versions
# @description                = EMPTY (code that declares it is cited: its
# @description                removal is a terraform change).
# @description   gh-token     the GitHub token files: IN-USE when code reads them.
# @description   seat-backup  a backup copy of a Claude or Mistral credential
# @description                file that still holds a credential field = BACKUP.
# @description "Code" is `git grep` over the repo minus *.md and this action;
# @description the evidence cell cites the pattern and the files it hit.
# @description Last use of a key is not read: the Policy Analyzer API is off,
# @description and enabling it is an owner go. Metadata only: no `versions
# @description access`; of a key file only its key id is read; of any other
# @description file only whether a credential field NAME occurs. No value is
# @description ever printed. Runs as the env's project SA in a private gcloud
# @description config, never the owner account. Exit 0, or 1 when a list fails.
# @param ENV - required: dev or prd
# @param SECRET_UNUSED_REPO (optional) - the repo grepped for consumers, default $APP_PATH
# @param SECRET_UNUSED_BOX (optional) - the box name in the table, default
# @param   SPOOL_DESK_BOX, else that line of $SPOOL_BOX_ENV (/var/spool-hub/box.env), else hostname -s
# @param SECRET_UNUSED_NOW (optional) - the UTC instant ages count to (tests), default now
# @example ENV=prd ./run -a do_spl_secret_unused_list
#------------------------------------------------------------------------------
do_spl_secret_unused_list() {
  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  do_require_bin python3 git || return 1
  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID" d="$_spl_sdk_dir/dump" repo="${SECRET_UNUSED_REPO:-$APP_PATH}" pkey
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { do_log "FATAL no git repo to grep for consumers at $repo"; return 1; }
  pkey="$(do_gcp_sa_key_file)" || { do_log "FATAL no project SA key for $p on this box"; return 1; }
  do_gcp_pin_account || return 1
  spl_secret_age_dump "$p" "$GCP_ACCOUNT" "$d" || return 1
  spl_secret_unused_table "$d" "$p" "${pkey#"$HOME"/}" "$repo" "$(spl_secret_unused_box)"
}

# spl_secret_unused_table <dump dir> <project> <project key file, relative to
# $HOME> <repo> <box> - the markdown table from the dump and this box's files
spl_secret_unused_table() {
  python3 - "$1" "$2" "$HOME" "$3" "$4" "$5" "${SECRET_UNUSED_NOW:-}" "$ORG" <<'PY'
import datetime as dt, glob, json, os, re, subprocess, sys
d, proj, home, pkey, repo, box, now, org = sys.argv[1:]
now = dt.datetime.fromisoformat(now.replace("Z", "+00:00")) if now else dt.datetime.now(dt.timezone.utc)
def ld(f):
    with open(os.path.join(d, f)) as fh: return json.load(fh)
def age(s): return (now - dt.datetime.fromisoformat(s.replace("Z", "+00:00")[:19] + "+00:00")).days if s else "-"
def fage(f): return (now - dt.datetime.fromtimestamp(os.path.getmtime(f), dt.timezone.utc)).days
def esc(s): return re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", s)
def code(pat):
    r = subprocess.run(["git", "-C", repo, "grep", "-lE", pat, "--", ".", ":!*.md", ":!*spl-secret-unused-list*"],
                       capture_output=True, text=True)
    hits = [os.path.basename(x) for x in r.stdout.split()]
    return hits, f"`git grep -lE '{pat}'` (no *.md) -> {len(hits)}" + (": " + ", ".join(hits[:4]) if hits else "")
rows = []
def row(cls, where, a, verdict, why): rows.append((cls, where, a, verdict, why))

# this env's key files on this box: key id -> file; only the id field is read
files = {}
for f in sorted(glob.glob(os.path.join(home, f".gcp/.{org}/key-{proj}*.json"))):
    try:
        with open(f) as fh: files[json.load(fh).get("private_key_id", "")] = os.path.relpath(f, home)
    except (OSError, ValueError): pass
for sa in sorted(os.listdir(os.path.join(d, "sa"))):
    for k in sorted(ld(f"sa/{sa}"), key=lambda k: k.get("validAfterTime", "")):
        kid, a = k["name"].split("/")[-1], age(k.get("validAfterTime", ""))
        where = f"{proj} / {sa[:-5].split('@')[0]} / key {kid[:8]}"
        dis = " (disabled)" if k.get("disabled") else ""
        f = files.get(kid)
        if f == pkey:
            row("sa-key", f"{where} / ~/{f}", a, "IN-USE", "the project key file do_gcp_account reads" + dis)
        elif not f:
            row("sa-key", where, a, "CHECK", "no key file on this box holds it: a CI secret or another box may; last use not read" + dis)
        else:
            sfx = os.path.basename(f)[len(f"key-{proj}"):-len(".json")]
            hits, why = code(f"key-[^ \"']*{esc(sfx)}\\.json" if sfx else esc(os.path.basename(f)))
            row("sa-key", f"{where} / ~/{f}", a, "IN-USE" if hits else "UNUSED", "code naming the file " + why + dis)

for s in sorted(ld("secrets.json"), key=lambda s: s["name"]):
    sid = s["name"].split("/")[-1]
    if any(v.get("state") == "ENABLED" for v in ld(f"secret/{sid}.json")): continue
    hits, why = code(esc(sid))
    row("secret-empty", f"{proj} / Secret Manager {sid}", age(s.get("createTime", "")), "EMPTY",
        "0 enabled versions: no value to read; code naming it " + why)

for rel in (".github/token", ".github/.csi/rcs"):
    f = os.path.join(home, rel)
    if not os.path.isfile(f): continue
    hits, why = code(esc(rel))
    row("gh-token", f"{box} ~/{rel}", fage(f), "IN-USE" if hits else "UNUSED",
        "code reading it " + why + "; a hand use (GH_TOKEN in a shell) is not visible to a grep")

CRED = re.compile(rb'"(accessToken|refreshToken)"|[A-Z_]*API_KEY\s*=')
for live in (".claude/.credentials.json", ".vibe/.env", ".mistral/crs"):
    base = os.path.join(home, live)
    for f in sorted(glob.glob(base + ".*")):
        sfx = f[len(base) + 1:]
        if not os.path.isfile(f) or sfx.endswith("trust-lock"): continue
        try:
            with open(f, "rb") as fh:
                if not CRED.search(fh.read(1 << 20)): continue
        except OSError: continue
        m = re.match(r"[A-Za-z-]*[A-Za-z]", sfx)
        fam = m.group(0) if m else sfx
        hits, why = code(esc(fam) if "-" in fam else esc(os.path.basename(live) + "." + fam))
        live_ok = "present" if os.path.isfile(base) else "MISSING"
        row("seat-backup", f"{box} ~/{os.path.relpath(f, home)}", fage(f), "BACKUP",
            f"a copy of ~/{live} (live file {live_ok}, the seat reads only that); code naming the suffix " + why)

print(f"## {proj} and box {box} (home of {os.environ.get('USER', '?')}): unused credential candidates (dry run, nothing removed)\n")
print("| # | class | where | age d | verdict | evidence |\n|---|---|---|---|---|---|")
for i, r in enumerate(rows, 1): print(f"| {i} | " + " | ".join(str(x) for x in r) + " |")
print("\n" + ", ".join(f"{v}: {sum(1 for r in rows if r[3] == v)}" for v in ("UNUSED", "EMPTY", "BACKUP", "CHECK", "IN-USE")))
PY
}

# spl_secret_unused_box - the box name for the table: SPOOL_DESK_BOX, else its
# line in the box env file, else the short hostname
spl_secret_unused_box() {
  local b="${SECRET_UNUSED_BOX:-${SPOOL_DESK_BOX:-}}" f="${SPOOL_BOX_ENV:-/var/spool-hub/box.env}"
  [[ -n "$b" || ! -r "$f" ]] || b="$(sed -n "s/^SPOOL_DESK_BOX=[\"']\{0,1\}\([a-z0-9-]*\).*/\1/p" "$f" | tail -1)"
  printf '%s' "${b:-$(hostname -s)}"
}
