# Tasks: 037 Installable Spool Agent Harness

Status per item: `[x]` built, with the sha and the check; `[ ]` open.

- [x] T001 `do_spl_desk_pin`: box key + pin without seating an agent; modes
      self (ROOT_KEY_JSON) / admin (BOX_PUBKEY) / check (hub-sync, exit 3
      pending); writes `<state>/desk/<tenant>/<box>/pinned` for
      `do_spl_desk_up`. `d4d14c1`; `csi-spl-orc/src/bash/tests/desk-pin.tst.sh` (22 PASS)
- [x] T002 `install.sh`: vendor CLIs, yq + Go into tools, spool build, the
      `spool-agent` shim + config, the mirror hooks merge, the seat (pinned /
      PENDING / failed). `38edf9f`; `spool-install/tests/test-install.sh`
      (36 PASS at `c5c05a0`), gated in the orc CI job by `tests/spool-install.tst.sh`
- [x] T003 this spec and the index row
- [x] T004 live proof on this box, dev only, 2026-09-25, n=1, throwaway
      HOME + a fresh clone at `<tmp>/csi/csi-spl` of trunk `a0115e5`..`c5c05a0`:
      - install `--cli claude,grok,agy --tenant t1 --box box-proof-037` ->
        rc 0; the real vendor installers left claude 2.1.282, grok 1.0.41,
        agy 1.2.11; the first spool build fetched the Go modules (empty
        GOMODCACHE) and built spool 0.4.8; hooks one per event; seat PENDING
        with the admin line
      - the admin line (`do_spl_desk_pin` BOX_PUBKEY, t1 root key) -> pinned
      - `install.sh --update --cli none` (no tenant/box/hub given) -> "seated",
        `pinned` = the same key as the pending run
      - `do_spl_desk_up DESK_AGENT=CLE-37` from that HOME, no root key ->
        `roster_announced: true` on the dev hub; `do_spl_desk_down` -> the
        sidecar gone
      - `PIN_REVOKE=1` -> revoked; CONTROL: the check mode then reads
        not pinned (rc 3). Throwaway HOME removed.
      Found and fixed on the way: a bare re-run forgot the saved tenant/box
      (`8da778f`); `--update` ran the OLD file (`c5c05a0`); a named revoke
      (`5c3226f`, desk-pin.tst.sh 26 PASS)
- [ ] T005 OPEN (owner): a hub-side join token so a pending user needs no
      admin shell. Not built without a go.
