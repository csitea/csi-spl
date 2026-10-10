# wd-situations fixtures

Pane screens for `wd-situations.tst.sh` (spec 093 section 6). Each is read as
the `pane` file of a situation script's context dir. The 2026-10-05 login
screen and its transcripts are T001's, read from `../fleet-lease/`.

| file | what it is | used by |
|---|---|---|
| `modal-auto-mode.pane` | the auto-mode offer as a dialog below the transcript | S7 hit (modal=1) |
| `modal-mention.pane` | the same words quoted in the transcript, idle prompt below | S7 control: no hit |
| `modal-default-mode.pane` | "Make auto mode your default permission mode?", cursor on Yes | S7 hit (modal=2 cursor=yes) |
| `modal-default-mode-no.pane` | the same dialog after Down: cursor on "No, keep bypass permissions" | S7 cursor=no, the Enter |
| `modal-default-quote.pane` | the same dialog quoted in a reply, idle prompt below | S7 control: no hit, no key |
| `trust.pane` | the trust screen (a blocking screen, no Escape) | S7 hit (modal=0) |
| `working.pane` | a turn in progress: the spinner `(12s · ...)` | S2 / S1 spinner rows |
| `limit-reset.pane` | a usage-limit banner with a reset time, idle | S2 kind=limit |
| `idle.pane` | an idle pane with an empty input box | S3, S1 controls |
| `vibe-idle-plan.pane` | vibe 2.26.0 idle at its `>` prompt after a Stop, todo summary `▶ 1/7 · ...` (m-617, 2026-10-09, path and text trimmed) | S1 plan hit |
| `vibe-idle-done.pane` | the same with the list complete, `☑ 7/7 · All todos complete` | S1 plan control |
| `s9-unknown-dialog.pane` | `modal-default-mode.pane` (the 2026-10-06 frozen pane) with its dialog words replaced by words no list contains | S9 hit (spec 102 8.3); S7 control 1: no hit |
| `limit-session.jsonl` | a claude transcript tail on its session limit (c-817, 2026-10-10, ids trimmed): a good reply, then two pokes, each answered by the synthetic `isApiErrorMessage` entry "You've hit your session limit · resets 3:20pm (Europe/Helsinki)", and no Stop | the hook (UserPromptSubmit sets api_error), S2 kind=limit from the transcript, section 12 |
