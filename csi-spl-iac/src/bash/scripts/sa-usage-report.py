#!/usr/bin/env python3
"""Markdown report of one principal's Cloud Audit Log entries.

Input: the slim entries JSON of `gcloud logging read` and the project's
auditConfigs (do_gcp_report_sa_usage). Output: entries per log type, distinct
methods and permissions per service with counts, and per caller class. The
caller class comes from the user agent only; IPs are never read.
"""

import collections
import json
import sys


def caller_class(ua):
    u = (ua or "").lower()
    if "terraform" in u:
        return "terraform"
    if (
        "command/gcloud" in u
        or "gcloud-python" in u
        or u.startswith("google-cloud-sdk")
    ):
        return "gcloud"
    if "gsutil" in u:
        return "gsutil"
    if "go-http-client" in u or "google-api-go-client" in u or "gl-go/" in u:
        return "go-client"
    if "firebase" in u:
        return "firebase-tools"
    if "docker" in u:
        return "docker"
    if not u:
        return "(no user agent)"
    return "other"


def log_type(name):
    return name.rsplit("%2F", 1)[-1].rsplit("/", 1)[-1] if name else "(none)"


def insights_section(w, ins_f, target, cmd_ins):
    w("## IAM recommender: exercised permissions per role (second source)\n")
    w(f"Produced by: `{cmd_ins}`\n")
    try:
        ins = json.load(open(ins_f))
    except (OSError, ValueError):
        ins = {"error": "unreadable"}
    if isinstance(ins, dict):
        w(
            "- **unreadable**: the insight list could not be read; this is NOT"
            " an empty list.\n"
        )
        return
    mine = [
        i
        for i in ins
        if (i.get("content") or {}).get("member") == f"serviceAccount:{target}"
    ]
    if not mine:
        w(
            f"- {len(ins)} insights in the project, none for this principal (the"
            " recommender needs a role binding held 90 days or more).\n"
        )
        return
    w(
        "| role | exercised | inferred | role holds | observed |\n|---|---:|---:|---:|---|"
    )
    for i in sorted(mine, key=lambda x: x["content"].get("role", "")):
        c = i["content"]
        w(
            f"| `{c.get('role', '?')}` | {len(c.get('exercisedPermissions') or [])}"
            f" | {len(c.get('inferredPermissions') or [])}"
            f" | {c.get('currentTotalPermissionsCount', '?')} | {i.get('observationPeriod', '?')} |"
        )
    w("")
    for i in mine:
        c = i["content"]
        ex = sorted(
            p.get("permission", "?") for p in c.get("exercisedPermissions") or []
        )
        inf = sorted(
            p.get("permission", "?") for p in c.get("inferredPermissions") or []
        )
        w(f"### `{c.get('role', '?')}`: exercised ({len(ex)})\n")
        for p in ex:
            w(f"- `{p}`")
        if inf:
            w(f"\nInferred, not yet exercised ({len(inf)}):\n")
            for p in inf:
                w(f"- `{p}`")
        w("")


def main(
    entries_f,
    audit_f,
    proj,
    target,
    since,
    days,
    cmd_read,
    cmd_audit,
    ins_f=None,
    cmd_ins=None,
):
    entries = json.load(open(entries_f)) or []
    try:
        audit = (json.load(open(audit_f)) or {}).get("auditConfigs") or []
    except (ValueError, AttributeError):
        audit = []
    by_log = collections.Counter()
    by_svc = collections.Counter()
    methods = collections.defaultdict(collections.Counter)
    perms = collections.defaultdict(collections.Counter)
    denied = collections.defaultdict(collections.Counter)
    callers = collections.defaultdict(collections.Counter)
    first, last = None, None
    for e in entries:
        pp = e.get("protoPayload") or {}
        svc = pp.get("serviceName") or "(none)"
        ts = e.get("timestamp") or ""
        first = ts if first is None or ts < first else first
        last = ts if last is None or ts > last else last
        by_log[log_type(e.get("logName", ""))] += 1
        by_svc[svc] += 1
        methods[svc][pp.get("methodName") or "(none)"] += 1
        cc = caller_class(
            (pp.get("requestMetadata") or {}).get("callerSuppliedUserAgent")
        )
        callers[cc][svc] += 1
        for a in pp.get("authorizationInfo") or []:
            perm = a.get("permission")
            if not perm:
                continue
            (perms if a.get("granted") else denied)[svc][perm] += 1

    w = print
    w(f"# SA usage: `{target}` in `{proj}`\n")
    w(
        f"Window: {days} days, since {since}. Entries: **{len(entries)}**"
        f" (first {first or '-'}, last {last or '-'}).\n"
    )
    w(f"Produced by: `{cmd_read}`\n")
    w("## Audit logs enabled (data access)\n")
    w(f"Produced by: `{cmd_audit}`\n")
    if not audit:
        w(
            "- no auditConfigs: only Admin Activity (always on) and the services that log"
            " data access by default (BigQuery) are recorded; reads of other services"
            " are NOT in this report.\n"
        )
    for c in audit:
        kinds = ", ".join(
            sorted(x.get("logType", "?") for x in c.get("auditLogConfigs") or [])
        )
        w(f"- `{c.get('service', '?')}`: {kinds}")
    w("\n## Entries per log type\n")
    w("| log | entries |\n|---|---:|")
    for k, n in by_log.most_common():
        w(f"| {k} | {n} |")
    w("\n## Per caller class (user agent) and service\n")
    w("| caller | service | entries |\n|---|---|---:|")
    for cc in sorted(callers):
        for s, n in callers[cc].most_common():
            w(f"| {cc} | {s} | {n} |")
    w("\n## Per service: methods and granted permissions\n")
    for svc, n in by_svc.most_common():
        w(f"### {svc} ({n} entries)\n")
        w("| method | calls |\n|---|---:|")
        for m, k in methods[svc].most_common():
            w(f"| `{m}` | {k} |")
        w("")
        if perms[svc]:
            w("| permission (granted) | checks |\n|---|---:|")
            for m, k in sorted(perms[svc].items()):
                w(f"| `{m}` | {k} |")
            w("")
        if denied[svc]:
            w("| permission (DENIED) | checks |\n|---|---:|")
            for m, k in sorted(denied[svc].items()):
                w(f"| `{m}` | {k} |")
            w("")
    allp = sorted({p for s in perms.values() for p in s})
    w(f"## All distinct granted permissions ({len(allp)})\n")
    for p in allp:
        w(f"- `{p}`")
    if ins_f:
        w("")
        insights_section(w, ins_f, target, cmd_ins or "?")
    return 0


if __name__ == "__main__":
    if len(sys.argv) not in (9, 11):
        sys.exit(
            "usage: sa-usage-report.py entries.json audit.json proj target since days cmd_read cmd_audit"
            " [insights.json cmd_insights]"
        )
    sys.exit(main(*sys.argv[1:]))
