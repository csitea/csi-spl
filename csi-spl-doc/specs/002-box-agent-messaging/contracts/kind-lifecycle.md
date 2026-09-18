# Contract: `kind` and `task_id`

See `csi-spl-doc/doc/md/SPEC-spool-task-lifecycle.md` (binding).

Summary locked here so 002 implementers do not skip the vision doc:

- `task_id` is the thread. CLI mints if `--task` omitted.
- `kind`: `task` (request), `result` (success), `reject` (will not), `note`
  (no completion claim).
- Spool does not enforce sequencing in 002; agents SHOULD finish with one
  `result` or `reject`.
- `to` is unicast. No `cc` in `v:1`.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
