# Tasks: 037 Installable Spool Agent Harness

Status per item: `[x]` built, with the sha and the check; `[ ]` open.

- [x] T001 `do_spl_desk_pin`: box key + pin without seating an agent; modes
      self (ROOT_KEY_JSON) / admin (BOX_PUBKEY) / check (hub-sync, exit 3
      pending); writes `<state>/desk/<tenant>/<box>/pinned` for
      `do_spl_desk_up`. `d4d14c1`; `csi-spl-orc/src/bash/tests/desk-pin.tst.sh` (22 PASS)
- [x] T002 `install.sh`: vendor CLIs, yq + Go into tools, spool build, the
      `spool-agent` shim + config, the mirror hooks merge, the seat (pinned /
      PENDING / failed). `38edf9f`; `spool-install/tests/test-install.sh`
      (32 PASS), gated in the orc CI job by `tests/spool-install.tst.sh`
- [x] T003 this spec and the index row
- [ ] T004 live proof on this box, dev only, in a throwaway HOME: install,
      PENDING seat, the admin pin, the re-run that reads seated, then the pin
      revoked
- [ ] T005 OPEN (owner): a hub-side join token so a pending user needs no
      admin shell. Not built without a go.
