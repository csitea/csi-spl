#!/usr/bin/env python3
"""Analyze the IAM dumps do_gcp_audit_iam writes. READ-ONLY, no GCP call.

usage: iam-analyze.py <cnf.json> <before.json> [<after.json>]

<cnf.json> is the env's effective cnf (all + <env> merged, as JSON): every
service-account id a step owns is read from it, none is written here.
Prints markdown: each binding and the step that owns it (UNOWNED = no step
owns it: report, never delete), user-held and deleted principals, the grants
the steps expect but the policy lacks, and the before/after diff when two
dumps are given.
"""

import json
import re
import sys


def flat(doc):
    rows = set()
    for res, pol in doc["policies"].items():
        if not isinstance(pol, dict):
            continue
        for b in pol.get("bindings", []) or []:
            for m in b.get("members", []):
                rows.add((res, b["role"], m))
    return rows


def ids(cnf):
    e = cnf["env"]
    st = e.get("steps", {})
    g = lambda d, k: (d or {}).get(k) or ""
    return {
        "project": e["gcp"]["gcp_project"],
        "hub": g(e.get("hub"), "runtime_sa_account_id"),
        "relay": g(st.get("020-gcp-relay-bucket"), "relay_sa_account_id"),
        "fb": g(st.get("016-firebase-deploy-iam"), "deploy_sa_account_id"),
        "fb_roles": (st.get("016-firebase-deploy-iam") or {}).get("deploy_roles") or [],
        "ci": g(st.get("017-github-wif-deploy"), "deploy_sa_account_id"),
        "dsn_secret": g((e.get("hub") or {}).get("secret_env"), "SPOOL_HUB_DB_DSN"),
    }


def sa(i, name):
    return f"serviceAccount:{name}@{i['project']}.iam.gserviceaccount.com"


def owner(res, role, m, i):
    rules = [
        (
            res == "project" and role == "roles/owner" and m == sa(i, i["project"]),
            "gcp-003 (IaC SA)",
        ),
        (
            bool(i["fb"]) and res == "project" and m == sa(i, i["fb"]),
            "016 firebase deploy SA",
        ),
        (
            res == "project"
            and role == "roles/cloudsql.client"
            and m == sa(i, i["hub"]),
            "030 hub runtime",
        ),
        (
            res.startswith("secret:")
            and role == "roles/secretmanager.secretAccessor"
            and m == sa(i, i["hub"]),
            "030 hub runtime",
        ),
        (
            res == "bucket:files"
            and role == "roles/storage.objectUser"
            and m == sa(i, i["hub"]),
            "030 hub runtime",
        ),
        (
            res == "bucket:relay"
            and role == "roles/storage.objectUser"
            and m == sa(i, i["relay"]),
            "020 relay SA",
        ),
        (res == "run-service" and role == "roles/run.invoker", "030 invoker"),
        (
            bool(i["ci"])
            and res == "run-service"
            and role == "roles/run.developer"
            and m == sa(i, i["ci"]),
            "017 deploy SA",
        ),
        (
            bool(i["ci"])
            and res == "artifact-repo"
            and role == "roles/artifactregistry.writer"
            and m == sa(i, i["ci"]),
            "017 deploy SA",
        ),
        (
            res.startswith("sa:")
            and role == "roles/iam.workloadIdentityUser"
            and m.startswith("principalSet://"),
            "016/017 WIF trunk principal",
        ),
        (
            bool(i["ci"])
            and res == f"sa:{i['hub']}@{i['project']}.iam.gserviceaccount.com"
            and role == "roles/iam.serviceAccountUser"
            and m == sa(i, i["ci"]),
            "017 deploy acts as hub",
        ),
        (
            m.startswith("serviceAccount:service-")
            or (
                "gserviceaccount.com" in m
                and bool(
                    re.search(
                        r"@(cloudservices|gcp-sa-|serverless-robot|cloudbuild|compute-system)",
                        m,
                    )
                )
            ),
            "Google-managed service agent",
        ),
    ]
    for ok, name in rules:
        if ok:
            return name
    return "UNOWNED"


def expected(i):
    exp = [("project", "roles/owner", sa(i, i["project"]), "gcp-003")]
    if i["hub"]:
        exp.append(("project", "roles/cloudsql.client", sa(i, i["hub"]), "030"))
        exp.append(("bucket:files", "roles/storage.objectUser", sa(i, i["hub"]), "030"))
        if i["dsn_secret"]:
            exp.append(
                (
                    f"secret:{i['dsn_secret']}",
                    "roles/secretmanager.secretAccessor",
                    sa(i, i["hub"]),
                    "030",
                )
            )
    if i["relay"]:
        exp.append(
            ("bucket:relay", "roles/storage.objectUser", sa(i, i["relay"]), "020")
        )
    for r in i["fb_roles"] if i["fb"] else []:
        exp.append(("project", r, sa(i, i["fb"]), "016"))
    return exp


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    i = ids(json.load(open(sys.argv[1])))
    before = json.load(open(sys.argv[2]))
    rows = flat(before)
    print(
        f"## {before['project']} IAM ({before['tag']}, {before['taken_utc']}, as {before['as']}): {len(rows)} bindings\n"
    )
    err = [
        k for k, v in before["policies"].items() if isinstance(v, dict) and "error" in v
    ]
    if err:
        print(f"**Unreadable policies** (cannot tell, not 'empty'): {', '.join(err)}\n")
    print("| policy | role | member | owner step | flag |\n|---|---|---|---|---|")
    for res, role, m in sorted(rows):
        o = owner(res, role, m, i)
        flag = []
        if m.startswith("user:"):
            flag.append("USER-HELD")
        if m.startswith("deleted:"):
            flag.append("DELETED-PRINCIPAL")
        if o == "UNOWNED":
            flag.append("no tf step owns it: report, do not delete")
        print(f"| {res} | {role} | `{m}` | {o} | {'; '.join(flag)} |")
    miss = [e for e in expected(i) if e[:3] not in rows]
    print(
        "\n### expected by a step but absent\n\n| policy | role | member | step |\n|---|---|---|---|"
    )
    for res, role, m, st in miss:
        print(f"| {res} | {role} | `{m}` | {st} |")
    if not miss:
        print("| (none) | | | |")
    if len(sys.argv) > 3:
        after = json.load(open(sys.argv[3]))
        a = flat(after)
        print(f"\n## diff {before['tag']} -> {after['tag']} ({after['taken_utc']})\n")
        print(
            "| policy | role | member | before | after | owner step |\n|---|---|---|---|---|---|"
        )
        for res, role, m in sorted(rows ^ a):
            print(
                f"| {res} | {role} | `{m}` | {'yes' if (res, role, m) in rows else '-'} | "
                f"{'yes' if (res, role, m) in a else '-'} | {owner(res, role, m, i)} |"
            )
        if not (rows ^ a):
            print("| (no change) | | | | | |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
