# Claude self sign-in in a workspace's seat (switch off)

Spec [159](../../specs/159-byo-ai-keys/spec.md) section 4.3, row T8, leak
path L23. Owner HUM-10, Q-3 A (msg `36279386`): build the sign-in behind a
switch that stays **off** until Anthropic confirms in writing (owner action
O1). Turning it on is row T10, for one pilot workspace, and not this page.

`<W>` is the workspace slug. `sk-test-0000` and the tests' fakes are the
only tokens anywhere in the tree.

## 1. The switch

cnf `env.box.claude_self_signin_tenants` in
`csi-spl-cnf/csi-spl/all.env.yaml`: the space-separated workspaces whose
`biz_owner` or `admin` may sign in with their own Claude subscription on a
fleet box. It ships **empty, so the sign-in is off everywhere**, on dev and
prd. `do_spl_ws_claude_signin SIGNIN_CMD=in` refuses every workspace it does
not name, exit 3, before it touches anything.

## 2. The action

`cd csi-spl-orc && ./run -a do_spl_ws_claude_signin`, dry run unless
`DRY_RUN=0`. It runs as `<W>`'s own OS user (the one
`do_spl_fleet_ws_host` makes, see [fleet workspace
hosting](fleet-workspace-hosting.md)): W's desk calls it. It refuses root,
the fleet's agent user and any other caller.

| `SIGNIN_CMD` | what it does |
|---|---|
| `status` (default) | signed in or not, and the modes of the directory and the sign-in file; never a file's content |
| `in` | the switch must name `<W>`. Makes the sign-in directory (0700) and starts the **unmodified** CLI's own login, `claude auth login --claudeai`, with `CLAUDE_CONFIG_DIR` = that directory, in tmux session `signin-<W>` on `<W>`'s own socket (`tmux -L spool-claude-signin`). Every other credential variable is unset for it. The person signs in through Anthropic's own flow; nothing in the spool sees the token. Refused when `<W>` is already signed in, or a sign-in already runs |
| `out` | sign-out: ends that tmux session, runs the CLI's own `auth logout`, removes the directory. It runs with the switch **off** too: turning the switch off cleans up (spec 159 4.4). The person can also end the session on Anthropic's side |

## 3. Where the token lives, and what never reads it

The sign-in directory is `<runtime>/spool-claude`, `<runtime>` =
`<W>`'s `/run/user/<uid>` (`XDG_RUNTIME_DIR`). The action refuses a runtime
directory that is not tmpfs, not owned by `<W>`, or inside `$HOME`. The CLI
writes its sign-in file there (`.credentials.json`, mode 0600).

| reader | why it never reads the directory |
|---|---|
| token-burn collector (`do_spl_token_burn_collect`) | it reads `<home>/.claude/projects`; the directory is outside every home |
| session export (`spool-session-export.py`) | the same: it searches `<home>/.claude/projects` and `<home>/.grok` |
| desk mirror (`spool-mirror.py`) | it posts from the CLI's hooks; the sign-in directory holds no settings file, so no hook runs in it |
| this action's log | it prints paths and modes, never a file's content |

The test plants a fake token in the directory and proves the collector and
the export read 0 of it; the same transcript under `$HOME/.claude` is found
by both (the red control). The transcripts of W's later claude seats, and
their cost rows, are row T6's; T10 checks the whole path on the pilot.

## 4. If the token reaches a message anyway (L23)

- **Box**: the redaction pass every mirror post and session export goes
  through (`csi-spl-orc/src/bash/features/spawn-agents/lib/spool_redact.py`)
  replaces the token's shape, `sk-ant-oat01-…` (access) and `sk-ant-ort01-…`
  (refresh), with `<redacted:claude-oauth-token>`.
- **Hub**: a body holding that shape is refused `422 vendor_token_in_body`
  at every body write: a box send (`spool send`, the mirror), a box edit, a
  browser send and a browser edit
  (`csi-spl-api/src/go/spool-hub-api/internal/hub/vendor_token.go`). Nothing
  of it is stored, fanned out or logged. The hub refuses rather than
  rewrites: a box body is signed, and a changed body would no longer verify.
  Spec 127 L9's hub redaction (row H2, per-workspace key fingerprints) is not
  built yet; when it is, it takes this shape over.

## 5. Tests

- `csi-spl-orc/src/bash/tests/ws-claude-signin.tst.sh`: the switch ships off
  (cnf all, dev, prd) and refuses rc 3; caller and runtime refusals; the
  sign-in start and sign-out on a fake CLI; status prints no token; the L23
  exclusion with its red control.
- `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-redact.sh`:
  the `claude-oauth-token` rows.
- `TestVendorTokenInBodyRefused`
  (`csi-spl-api/src/go/spool-hub-api/internal/hub/vendor_token_test.go`): the
  four write paths refuse, nothing stored, the hub log holds no fake; a
  non-matching body is stored. Each path's guard removed turns its case red.

## 6. Not built here

- The hub asking W's desk to start the sign-in from the Agent keys page, and
  relaying the vendor's link and the person's code: the page is row T7
  (hidden while the switch is off), the request route waits for spec 127's
  hub rows.
- Turning the switch on, and the real sign-in: row T10, after O1.
