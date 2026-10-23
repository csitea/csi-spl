# Bug-fix round 4 - mistral reviewer verdict

Epic: SPL-2402
Spec: csi-spl-doc/specs/011-spool-project-refactor
Reviewer: m-833@sat (mistral)
Plan: v0.1, commit `5796b1aa031c353ffd391cc47a34d2eb549e0e9d`

## Verdict

| row | defect | verdict | evidence |
|---|---|---|---|
| 01 | `spool keygen` refuses sealed box | **Agree** | Red control: `go test -count=1 -run TestZZKeygenOnSealedBox -v ./cmd/spool` on `3f48f3afe` exits 0 and writes a clear key beside the sealed one. Output:
```
after seal: sealed=true clear-key-exists=false
keygen rc=0 out="C0CGGmNKdjnEcZl1BsqjpUpMZjmRGHpnfVNl5NLF7I0=\n" err="" clear-key-exists=true
FAIL
```
`n=1`. |
| 02 | GC start falls back on limit | **Agree with changes** | Red control: GC starts grok and writes `grok` to the run file, even when grok is at its limit. Output:
```
START 20261023T0132Z-gc-test-box grok %900
RED: GC run file says grok, not claude (fallback did not trigger)
```
`n=1`. **Change**: The plan's fix scope is correct, but the red control should also test that the fallback vendor (`claude`) is written to the run file when grok is at its limit. |
| 03 | Quota reads grok limit screen | **Agree** | Red control: `printf '  ┃  You hit your weekly limit.\n' | spl_box_quota_parse grok` returns empty on `3f48f3afe`. `n=1`. |

## Re-checked entries (plan sections 4/5/6)

| section | entry | command | result |
|---|---|---|---|
| 4 | CI signatures (19 failed runs) | `cd csi-spl-iac && CI_GATE_RUNS=50 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 4 failures in `orc: hermetic action tests 3/3`, all due to `FATAL WUI entry point(s) not in env.dns.mapped_tenants`. Last green: run `39880532611` on `c89e8f060`. **Not a defect**: Configuration issue, already noted in the plan. |
| 5 | Overlay provision (local flake) | `cd csi-spl-orc && bash src/bash/tests/spl-private-overlay-sync.tst.sh` | 18/18 PASS. **Not a defect**: Already noted in the plan. |

## Proof of the run
- Session log: `<vibe-logs>/session/unified/39d996a9-ff8e-a40a-c30f-6bf275c7823e/journal/`.
- All controls run on `3f48f3afe` in scratch directories, never in the repo.
- `n=1` per control, as measured today.