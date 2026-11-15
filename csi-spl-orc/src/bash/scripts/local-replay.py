#!/usr/bin/env python3
"""local-replay.py: the replay-set harness of spec 176 section 4.8 (T0.1,
SPL-5556). It picks past LANDED lanes of one task kind with a known answer,
prepares a throwaway repo per lane at the lane's base tree plus its brief,
and judges what a candidate (client + model endpoint) left in those repos.
It runs no model and reaches no network. do_spl_local_replay calls it.

  local-replay.py pick    --kind K --n N --briefs DIR --repo R --ref REF
                          [--i18n M] [--max-lines L] [--keymap FILE]
  local-replay.py prepare --kind K --out DIR --repo R --ref REF  (rows on stdin)
  local-replay.py run     --kind K --out DIR --candidate CMD [--timeout S]
  local-replay.py judge   --kind K --out DIR [--label TEXT] [--harness SHA]
  local-replay.py keys    --briefs DIR --repo R --ref REF [--n MAX]
  local-replay.py keymap  --briefs DIR --issues FILE

The past-lane source (pick): the spawn's brief store (`Kind:` and `Issue:`
lines of each brief) joined to git (the commits on REF whose subject scope
cites that key). The brief is the exact prompt the lane got; git is the
answer that landed. The hub's issues do not keep the brief, so they cannot
replace the store; a brief with no `Issue:` line (the spawn filed its key)
joins through --keymap, a `<brief file name><TAB><KEY>` file.

keys prints the keys worth a hub lookup, newest landing first: cited back
to back on REF and claimed by no brief's `Issue:` line. keymap reads the hub
issues of those keys (FILE: one `spool issue get` JSON document per line)
and prints `<brief file name><TAB><KEY>` for each brief whose heading is the
issue's title, the way do_spl_lane_issue titles an issue it files (the
heading without `#`, a leading `Brief:`, cut at 200). A title two briefs
share maps neither.

A lane qualifies when its brief is not a review brief, no other brief claims
its key, its citing commits sit back to back on REF's first-parent line
(base = the parent of the first, landed = the last) and the diff is not
empty and at most --max-lines changed lines. Newest landing first.

pick prints one TSV row per case: slice key brief base landed files lines.
slice is the kind, or `i18n` for the multilingual slice: up to --i18n lanes
of kind i18n added to every other kind's set (spec 176 4.8, 4.4).

prepare writes <out>/<kind>/: set.env (kind, ref sha, n), manifest.tsv (the
rows), answers/<key>.patch (the landed diff, outside every case), and per
case cases/<key>/ with brief.md, case.env and wt/, a fresh git repo of the
base tree with one commit, so no later commit is in reach of the candidate.

run executes CMD once per case with cwd wt/ and REPLAY_BRIEF, REPLAY_WT,
REPLAY_CASE_DIR, REPLAY_KEY in its environment.

judge commits what the candidate left in wt/ (its own commits count too)
and writes cases/<key>/candidate.patch (base commit..HEAD), then one verdict per case: FAIL (no change), PASS (the same
patch-id as the landed answer), else the R7 review line in cases/<key>/
review.line decides (PASS or FAIL, its sha must be the candidate commit),
else R7-PENDING with cases/<key>/r7-request.md for the cross-vendor
reviewer. It writes <out>/<kind>/report.md (version, tree, n; one file per
kind) and results.tsv. Exit 0 when every case has a verdict, 3 when one
waits on its review.
"""

import argparse
import io
import json
import os
import re
import subprocess
import sys
import tarfile

KEY_RX = r"[A-Z][A-Z0-9]{0,9}-[1-9][0-9]*"
ISSUE_RX = re.compile(
    r"^[-*_ >]*Issue[*_ ]*:[*_` ]*(" + KEY_RX + r")(?:[^0-9].*)?$", re.M
)
KIND_RX = re.compile(r"^[-*_ >]*Kind[*_ ]*:[*_` ]*([a-z][a-z0-9_]*)", re.M)
CLASS_RX = re.compile(r"^[-*_ >]*Class[*_ ]*:[*_` ]*([a-z_]+)", re.M)
REVIEW_HEAD_RX = re.compile(
    r"reviewer|review only|\breview of\b|^#+\s*(?:lane brief:\s*)?(?:R7\s+)?review\b",
    re.I,
)
SUBJ_RX = re.compile(r"^[a-z]+!?\(([^)]*)\)!?:")
LINE_RX = re.compile(r"review: (\S+)@(\S+) (\S+) (PASS|FAIL) ([0-9a-f]{7,40})\b")
ID = ["-c", "user.name=local-replay", "-c", "user.email=local-replay@localhost"]


def git(repo, *args):
    p = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    if p.returncode != 0:
        raise SystemExit(
            "FATAL git %s: %s"
            % (" ".join(args[:3]), p.stderr.decode(errors="replace").strip())
        )
    return p.stdout


def parse_brief(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    kind = KIND_RX.search(text)
    head = next((ln for ln in text.splitlines() if ln.startswith("#")), "")
    cls = CLASS_RX.search(text)
    key = ISSUE_RX.search(text)
    kind = kind.group(1) if kind else ""
    review = (
        kind in ("review", "reviews")
        or bool(REVIEW_HEAD_RX.search(head))
        or (cls is not None and cls.group(1) == "review")
    )
    return {"kind": kind, "key": key.group(1) if key else "", "review": review}


def brief_index(briefs, keymap):
    """key -> [paths of the non-review briefs that claim it]; kind per path."""
    extra = {}
    if keymap:
        for ln in open(keymap, encoding="utf-8"):
            parts = ln.rstrip("\n").split("\t")
            if len(parts) >= 2 and re.fullmatch(KEY_RX, parts[1]):
                extra[parts[0]] = parts[1]
    by_key, kinds = {}, {}
    for name in sorted(os.listdir(briefs)):
        if not name.endswith(".md"):
            continue
        path = os.path.join(briefs, name)
        b = parse_brief(path)
        if not b or b["review"]:
            continue
        key = b["key"] or extra.get(name, "")
        if key and b["kind"]:
            by_key.setdefault(key, []).append(path)
            kinds[path] = b["kind"]
    return by_key, kinds


def landed_runs(repo, ref):
    """key -> (base, landed, newest index) when the key's citing commits sit
    back to back on ref's first-parent line; None when they interleave."""
    out = git(repo, "log", "--first-parent", "--format=%H%x09%P%x09%s", ref).decode(
        errors="replace"
    )
    seen = {}
    for i, ln in enumerate(out.splitlines()):
        sha, parents, subj = (ln.split("\t", 2) + ["", ""])[:3]
        m = SUBJ_RX.match(subj)
        if not m:
            continue
        for key in set(re.findall(r"\b" + KEY_RX + r"\b", m.group(1))):
            seen.setdefault(key, []).append((i, sha, parents.split(" ")[0]))
    runs = {}
    for key, hits in seen.items():
        idx = [h[0] for h in hits]
        runs[key] = (
            None
            if idx != list(range(idx[0], idx[0] + len(idx))) or not hits[-1][2]
            else (hits[-1][2], hits[0][1], idx[0])
        )
    return runs


def diff_size(repo, base, landed):
    files = lines = 0
    for ln in (
        git(repo, "diff", "--numstat", base, landed)
        .decode(errors="replace")
        .splitlines()
    ):
        a, d, _ = ln.split("\t", 2)
        files += 1
        lines += (int(a) if a.isdigit() else 0) + (int(d) if d.isdigit() else 0)
    return files, lines


def candidates(kind, by_key, kinds, runs, repo, max_lines):
    rows = []
    for key, paths in by_key.items():
        if len(paths) != 1 or kinds[paths[0]] != kind or not runs.get(key):
            continue
        base, landed, newest = runs[key]
        files, lines = diff_size(repo, base, landed)
        if files and lines <= max_lines:
            rows.append((newest, key, paths[0], base, landed, files, lines))
    rows.sort()
    return rows


def brief_title(path):
    for ln in open(path, encoding="utf-8", errors="replace"):
        if re.match(r"^#+ ", ln):
            return re.sub(r"^Brief: *", "", re.sub(r"^#+ +", "", ln.rstrip("\n")))[:200]
    return ""


def cmd_keys(a):
    by_key, _ = brief_index(a.briefs, "")
    runs = sorted(
        (r[2], k)
        for k, r in landed_runs(a.repo, a.ref).items()
        if r and k not in by_key
    )
    for _, key in runs[: a.n]:
        print(key)
    return 0


def issue_of(doc):
    r = doc.get("result", doc) if isinstance(doc, dict) else {}
    r = r.get("issue", r) if isinstance(r, dict) else {}
    return (
        (r.get("key") or "", r.get("title") or "") if isinstance(r, dict) else ("", "")
    )


def cmd_keymap(a):
    by_title = {}
    for name in sorted(os.listdir(a.briefs)):
        path = os.path.join(a.briefs, name)
        b = parse_brief(path) if name.endswith(".md") else None
        if b and not b["review"] and not b["key"] and b["kind"]:
            by_title.setdefault(brief_title(path), []).append(name)
    for ln in open(a.issues, encoding="utf-8"):
        try:
            key, title = issue_of(json.loads(ln))
        except ValueError:
            continue
        names = by_title.get(title.strip()[:200], [])
        if key and len(names) == 1:
            print("%s\t%s" % (names[0], key))
    return 0


def cmd_pick(a):
    if not a.briefs or not os.path.isdir(a.briefs):
        raise SystemExit("FATAL --briefs %r is no directory" % a.briefs)
    by_key, kinds = brief_index(a.briefs, a.keymap)
    runs = landed_runs(a.repo, a.ref)
    rows = [
        (a.kind,) + r[1:]
        for r in candidates(a.kind, by_key, kinds, runs, a.repo, a.max_lines)[: a.n]
    ]
    if a.kind != "i18n" and a.i18n > 0:
        rows += [
            ("i18n",) + r[1:]
            for r in candidates("i18n", by_key, kinds, runs, a.repo, a.max_lines)[
                : a.i18n
            ]
        ]
    for r in rows:
        print("\t".join(str(x) for x in r))
    return 0


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def fresh_repo(repo, base, wt):
    """A new git repo holding only the base tree, in one commit."""
    os.makedirs(wt)
    with tarfile.open(
        fileobj=io.BytesIO(git(repo, "archive", "--format=tar", base))
    ) as t:
        if hasattr(tarfile, "data_filter"):
            t.extractall(wt, filter="tar")
        else:
            t.extractall(wt)
    git(wt, "init", "-q")
    git(wt, "add", "-A")
    git(wt, *ID, "commit", "-q", "--no-verify", "-m", "base %s" % base)


def cmd_prepare(a):
    rows = [ln.rstrip("\n").split("\t") for ln in sys.stdin if ln.strip()]
    top = os.path.join(a.out, a.kind)
    if os.path.exists(os.path.join(top, "manifest.tsv")):
        raise SystemExit(
            "FATAL %s already holds a set; pick another REPLAY_DIR or remove it" % top
        )
    os.makedirs(os.path.join(top, "answers"), exist_ok=True)
    os.makedirs(os.path.join(top, "cases"), exist_ok=True)
    ref = git(a.repo, "rev-parse", a.ref).decode().strip()
    for slc, key, brief, base, landed, files, lines in rows:
        case = os.path.join(top, "cases", key)
        os.makedirs(case)
        write(
            os.path.join(case, "brief.md"),
            open(brief, encoding="utf-8", errors="replace").read(),
        )
        write(
            os.path.join(case, "case.env"),
            "slice=%s\nkey=%s\nbase=%s\nlanded=%s\nbrief=%s\nfiles=%s\nlines=%s\n"
            % (slc, key, base, landed, brief, files, lines),
        )
        with open(os.path.join(top, "answers", key + ".patch"), "wb") as f:
            f.write(git(a.repo, "diff", "--binary", base, landed))
        fresh_repo(a.repo, base, os.path.join(case, "wt"))
        print(
            "PREPARED %s %s base %s landed %s (%s files, %s lines)"
            % (slc, key, base[:9], landed[:9], files, lines)
        )
    write(os.path.join(top, "manifest.tsv"), "".join("\t".join(r) + "\n" for r in rows))
    write(
        os.path.join(top, "set.env"),
        "kind=%s\nref=%s\nref_sha=%s\nn=%d\n" % (a.kind, a.ref, ref, len(rows)),
    )
    print("SET %s n=%d ref %s -> %s" % (a.kind, len(rows), ref[:9], top))
    return 0 if rows else 1


def read_env(path):
    out = {}
    for ln in open(path, encoding="utf-8"):
        k, _, v = ln.rstrip("\n").partition("=")
        out[k] = v
    return out


def cases_of(top):
    if not os.path.exists(os.path.join(top, "manifest.tsv")):
        raise SystemExit(
            "FATAL no prepared set in %s (run REPLAY_CMD=prepare first)" % top
        )
    return [
        ln.split("\t")[1]
        for ln in open(os.path.join(top, "manifest.tsv"), encoding="utf-8")
        if ln.strip()
    ]


def cmd_run(a):
    if not a.candidate:
        raise SystemExit("FATAL --candidate is empty")
    top, rc = os.path.join(a.out, a.kind), 0
    for key in cases_of(top):
        case = os.path.join(top, "cases", key)
        env = dict(
            os.environ,
            REPLAY_BRIEF=os.path.join(case, "brief.md"),
            REPLAY_WT=os.path.join(case, "wt"),
            REPLAY_CASE_DIR=case,
            REPLAY_KEY=key,
        )
        try:
            code = subprocess.run(
                ["bash", "-c", a.candidate],
                cwd=env["REPLAY_WT"],
                env=env,
                timeout=a.timeout,
            ).returncode
        except subprocess.TimeoutExpired:
            code = 124
        print("RAN %s rc=%d" % (key, code))
        rc = rc or (1 if code else 0)
    return rc


def patch_id(data):
    p = subprocess.run(["git", "patch-id", "--stable"], input=data, capture_output=True)
    return p.stdout.split(b" ")[0].decode() if p.stdout else ""


def judge_case(top, key):
    case = os.path.join(top, "cases", key)
    wt = os.path.join(case, "wt")
    git(wt, "add", "-A")
    if git(wt, "diff", "--cached", "--name-only", "HEAD").strip():
        git(wt, *ID, "commit", "-q", "--no-verify", "-m", "candidate for %s" % key)
    root = git(wt, "rev-list", "--max-parents=0", "HEAD").decode().split()[0]
    patch = git(wt, "diff", "--binary", root, "HEAD")
    with open(os.path.join(case, "candidate.patch"), "wb") as f:
        f.write(patch)
    if not patch.strip():
        return "FAIL", "", "no change", ""
    sha = git(wt, "rev-parse", "HEAD").decode().strip()
    answer = open(os.path.join(top, "answers", key + ".patch"), "rb").read()
    if patch_id(patch) == patch_id(answer):
        return "PASS", sha, "same patch-id as the landed answer", ""
    line_file = os.path.join(case, "review.line")
    m = (
        LINE_RX.search(open(line_file, encoding="utf-8").read())
        if os.path.exists(line_file)
        else None
    )
    if m and sha.startswith(m.group(5)):
        return (
            m.group(4),
            sha,
            "R7 review",
            "%s@%s %s" % (m.group(1), m.group(2), m.group(3)),
        )
    write(os.path.join(case, "r7-request.md"), r7_request(case, key, sha, m))
    return (
        "R7-PENDING",
        sha,
        "stale review line (other sha)" if m else "waits on the R7 review",
        "",
    )


def r7_request(case, key, sha, stale):
    env = read_env(os.path.join(case, "case.env"))
    return (
        "# R7 review request: local-model replay of %s\n\n"
        "Judge whether the candidate diff answers the brief as well as a lane would.\n\n"
        "- brief: `%s/brief.md`\n- candidate repo: `%s/wt`, commit `%s` (base tree = `%s`)\n"
        "- candidate diff: `%s/candidate.patch`\n- the landed answer, for reference: `%s` (base `%s`)\n\n"
        "Write one line into `%s/review.line`, the fleet's R7 form, then re-run the judge:\n\n"
        "`review: <id>@<box> <vendor> PASS|FAIL %s ran: <commands> | read: <output> | log: <id>@<box>:<path>`\n%s"
        % (
            key,
            case,
            case,
            sha,
            env.get("base", ""),
            case,
            env.get("landed", ""),
            env.get("base", ""),
            case,
            sha,
            "\nThe line there names another sha; the candidate changed since.\n"
            if stale
            else "",
        )
    )


def cmd_judge(a):
    top = os.path.join(a.out, a.kind)
    rows = []
    for key in cases_of(top):
        env = read_env(os.path.join(top, "cases", key, "case.env"))
        verdict, sha, why, reviewer = judge_case(top, key)
        rows.append(
            (env["slice"], key, env["base"], env["landed"], sha, verdict, why, reviewer)
        )
        print("JUDGED %s %s: %s (%s)" % (env["slice"], key, verdict, why))
    write(os.path.join(top, "results.tsv"), "".join("\t".join(r) + "\n" for r in rows))
    write(os.path.join(top, "report.md"), report(top, a, rows))
    print("REPORT %s" % os.path.join(top, "report.md"))
    return 3 if any(r[5] == "R7-PENDING" for r in rows) else 0


def report(top, a, rows):
    s = read_env(os.path.join(top, "set.env"))
    out = [
        "# Local-model replay report: kind `%s`\n" % a.kind,
        "Spec 176 section 4.8. The pass bar per kind is the owner's choice from this report.\n",
        "| field | value |",
        "|---|---|",
        "| version | candidate `%s`; harness `%s` |"
        % (a.label or "unnamed", a.harness or "unknown"),
        "| tree | set picked from `%s` = `%s`; each case at its own base, below |"
        % (s.get("ref"), s.get("ref_sha")),
        "| n | %d |" % len(rows),
    ]
    for slc in sorted({r[0] for r in rows}):
        part = [r for r in rows if r[0] == slc]
        cnt = {
            v: sum(1 for r in part if r[5] == v) for v in ("PASS", "FAIL", "R7-PENDING")
        }
        out.append(
            "| slice `%s` | n=%d PASS=%d FAIL=%d R7-PENDING=%d |"
            % (slc, len(part), cnt["PASS"], cnt["FAIL"], cnt["R7-PENDING"])
        )
    out += [
        "",
        "| slice | key | base | landed | candidate | verdict | why | reviewer |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        out.append(
            "| %s | %s | `%s` | `%s` | `%s` | %s | %s | %s |"
            % (r[0], r[1], r[2][:9], r[3][:9], r[4][:9] or "-", r[5], r[6], r[7] or "-")
        )
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("pick", "prepare", "run", "judge", "keys", "keymap"):
        p = sub.add_parser(name)
        p.add_argument("--kind", required=name not in ("keys", "keymap"), default="")
        p.add_argument("--repo", default=".")
        p.add_argument("--ref", default="origin/master")
        p.add_argument("--out", default="")
        p.add_argument("--n", type=int, default=5)
        p.add_argument("--briefs", default="")
        p.add_argument("--keymap", default="")
        p.add_argument("--i18n", type=int, default=1)
        p.add_argument("--max-lines", type=int, default=1500)
        p.add_argument("--candidate", default="")
        p.add_argument("--timeout", type=int, default=3600)
        p.add_argument("--label", default="")
        p.add_argument("--harness", default="")
        p.add_argument("--issues", default="")
    a = ap.parse_args()
    return {
        "pick": cmd_pick,
        "prepare": cmd_prepare,
        "run": cmd_run,
        "judge": cmd_judge,
        "keys": cmd_keys,
        "keymap": cmd_keymap,
    }[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
