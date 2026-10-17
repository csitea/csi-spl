# Security baselines: what may be listed, and how a list grows

Owner security scan, revised list, action 10 (t1 topic 62eaacb9, msg
4a5b93de): "add a CI gate that fails if any security baseline file grows
without a linked ticket ID". Issue SPL-2153, epic SPL-2151.

## 1. The files

Each scanner gate passes the findings its baseline or allow-list names, and
fails on any other finding.

| file | scanner | gate |
|---|---|---|
| `.gosec-baseline.txt` | gosec (hub Go, HIGH) | `do_sec_gosec`, wf 62 |
| `.semgrep-baseline.txt` | semgrep | `do_sec_semgrep`, wf 61 |
| `.eslint-security-baseline.txt` | eslint-plugin-security (WUI) | `do_sec_eslint`, wf 63 |
| `.shellcheck-warning-baseline.txt` | shellcheck WARNING level | `do_sec_shellcheck`, wf 67 |
| `.trivyignore.yaml` | trivy config (terraform) | `do_sec_scan` iac, wf 15 |
| `.gitleaks.toml` | gitleaks (secrets) | `do_sec_scan` secrets, wf 15 |
| `osv-scanner.toml` | OSV-Scanner (lockfiles) | wf 70 |
| `.hadolint.yaml` | hadolint (Dockerfiles) | `do_sec_hadolint`, wf 66 |
| `.zap/rules.tsv` | OWASP ZAP baseline (DAST) | wf 68 |
| `csi-spl-iac/src/terraform/.checkov.baseline` | checkov (terraform) | `do_sec_checkov`, wf 65 |

The list lives in one place: `_BG_FILES` in
`csi-spl-iac/src/bash/run/check-baseline-growth.func.sh`.

## 2. A new entry names its ticket

`cd csi-spl-iac && ./run -a do_check_baseline_growth` (10 ci job
`baseline-growth`) compares each file at a fixed anchor commit (origin/master
when the gate landed, so the entries already there stay as they are) with
HEAD. A changed block that adds an entry passes only when one of its added
lines carries `SPL-<n>`:

- on the entry itself, as a trailing comment:
  `G402|internal/x/y.go|1  # SPL-1234 test-only TLS client`; the count gates
  read the row with its comment, and a regenerate (`*_WRITE_BASELINE=1`)
  keeps the comment while the row stays;
- or on a comment line right beside it: `# SPL-1234: why this is accepted`.

A count that goes down, a deleted row, a moved row and a comment-only change
pass. The checkov baseline is JSON and has no comments, so a new check id
there needs `SPL-<n>` in the message of a commit that touched the file.

Test, with its red controls (a planted row without a ticket fails, naming the
file and line): `csi-spl-iac/src/bash/tests/check-baseline-growth.tst.sh`.

## 3. The gitleaks allow-list

`.gitleaks.toml` adds no rule of its own (gitleaks default rules, `useDefault =
true`). Its allow-list holds exact values, each with a comment that says what
it is:

- five **test-only fixtures**: made-up plaintexts (`not-a-key`,
  `secret-key-bytes-not-a-real-key`, ...) in unit tests. They are not a
  pattern to copy: a real key, token or password never goes in a test, a doc
  or this list, it goes in Secret Manager;
- two **public identifiers** in cnf: Stripe publishable keys and the LinkedIn
  OAuth Client ID, public by their provider's design;
- one **doc phrase** (`LANE_MIX_KIND=secret`), anchored to that text.

A real credential still fails: the gate's control plants an AKIA key in a
throwaway repo and requires gitleaks to exit 1.
