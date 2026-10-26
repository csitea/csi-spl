# mistral-agent-setup.ISG — install & setup guide (for mistral agents)

> Generated from qto doc `ccadbfd0-747e-4f20-8e94-af65410af664`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

> **Not yet verified.** Written 2026-10-08 from [spec 110](../../../specs/110-mistral-vendor/spec.md)
> v1.0, before the first live `m-` seat. Nothing below was measured inside a
> Vibe session. The live proof is spec 110 task T014 (`m-004` answers a
> spool task, n = 1 per box); record what it finds in section 9.

Mistral Vibe (the `vibe` CLI, PyPI `mistral-vibe`) is the fifth agent kind,
letter `m`. It takes grok's share of the lane mix (spec 110 D1).

<a id="ws-doc-bee4011c-a683-46d3-8773-ca32c4cb5275"></a>
## 0. A person joining with a mistral agent on their own machine

Use the installer exactly as in the Claude guide 0.1, with `--cli mistral`
(or `--cli claude,mistral`), then start the agent with `spool-agent mistral`.
Both wait for spec 110 T004 (install) and T005 (spawn adapter).

MCP (the Claude guide 6.0): `do_spl_agent_mcp_install` writes the spool
server as one `[[mcp_servers]]` stdio entry in `~/.vibe/config.toml`
(spec 110 T008). Untested in a live Vibe session: try `spool_recv` first; if
it fails, use the desk actions of the Claude guide section 6.

<a id="ws-doc-7224e5d5-e0ed-43f7-bd34-23f7743a57bd"></a>
## 1. What this installs

The same as for Claude: a seat in the box's desk, a notice strip, a prompt
poke, and the `csi-spl-orc` desk actions. See `claude-agent-setup.ISG.md` §1.
Plus, for the agent user only:

| path | holds |
|---|---|
| `~/.local/bin/vibe` | the CLI, at the cnf pin `env.box.mistral_vibe.version` |
| `~/.vibe/config.toml` | `active_model` (cnf `env.box.mistral_vibe.model`) and the spool MCP entry; no secret |
| `~/.vibe/.env` | `MISTRAL_API_KEY=…`, mode `0600`; the auth marker lane-mix reads |
| `~/.vibe/trusted_folders.toml` | each worktree, written by `trust-workdir.sh` |
| `~/.vibe/logs/session/` | the transcripts, mode `0700`, pruned by `spl-session-prune.sh` |

<a id="ws-doc-7071cbae-35de-4c30-9e6b-c7af029a00a2"></a>
## 2. Prerequisites

<a id="ws-doc-75ee20b6-80bd-4241-a982-f649eb2d7165"></a>
### 2.1 An id in the window name

Agent ids follow the grammar in [spec 061 section 0](../../../specs/061-agent-id-rename/spec.md#0-the-marker-the-old-form-ends-2026-10-03):
`^[acgmq]-[0-9]{3}$` (`m-004`..`m-999` lane agents; `m-001`..`m-003` are
reserved and never handed out; mistral has no legacy prefix).

The seat is keyed by the id in the window name (`m-004`, or `<ID>@<box-tag>`).
`/mistral-spawn` names the window; a hand-started vibe needs its window
renamed to carry the id, or it is never seated. Vibe cannot name a session,
so the window name is the only name a human reads.

<a id="ws-doc-d45961cf-2188-43c4-aad2-42dcf073f703"></a>
### 2.2 Python and the installer

The agent user needs python 3.12 or newer, and `uv` or `pipx` on its PATH.
An older python makes the install fail fast and name the fix.

<a id="ws-doc-9b057e73-45ed-41bb-8dd0-c81442990dae"></a>
### 2.3 Sudo to the box user

Identical to the Claude guide §2.3: the desk tree is `0700` and owned by the
box user.

<a id="ws-doc-dba723cb-a10d-41e9-bec6-ad0ea88bbb3e"></a>
### 2.4 Pinned desk

As in the Claude guide 0.1: a NEW box needs the tenant admin's pin.

<a id="ws-doc-a2fbc860-a4b1-48be-ae54-a30dd0ef9b22"></a>
## 3. Credentials

One Mistral key per box (Team plan, one seat per box, spec 110 D3), named
after the box (e.g. `spool-<box>`), so one box can be revoked alone.

- **Enter it with the named action, never by pasting into a fleet window.**
  A key pasted into `vibe --setup` inside an agent tmux window lands in the
  scrollback that other scripts capture.

  ```
  cd /opt/csi/csi-spl/csi-spl-orc && ./run -a do_set_mistral_key
  ```

  It reads the key without echo and writes `~/.vibe/.env` as the agent user
  with mode `0600`.
- The browser sign-in (`vibe --setup`) is allowed only in a plain ssh
  session as the agent user, never in a fleet window.
- The launcher runs `env -u MISTRAL_API_KEY vibe …`: an exported key would
  beat `.env` and silently swap the account.
- The key never goes into git, a brief, a spool message, a log or a command
  line.
- Before any key is entered, the three preconditions of spec 110 section 5
  hold: both training toggles (Vibe and API) are off, the ToS clause on
  automated use is quoted, and the API retention period is quoted.

**Data rule (spec 110 D2).** A mistral lane may take personal-data and
secret work, as a claude lane does. Every prompt and tool result leaves the
box (spec 110 section 6).

<a id="ws-doc-67d0801f-2f1f-4ee5-8802-d4c11ef68e91"></a>
## 4. Install steps

```
cd /opt/csi/csi-spl/csi-spl-orc && DRY_RUN=1 ./run -a do_install_mistral_vibe
```

```
cd /opt/csi/csi-spl/csi-spl-orc && ./run -a do_install_mistral_vibe
```

The first prints the plan; the second installs `mistral-vibe==<pin>` for the
agent user (never `curl | bash`), checks the flag contract (`--auto-approve`,
`--resume`, `--continue`, `-p` in `vibe --help`), writes `config.toml` and
prints the installed version next to the pin. Then seat the desk exactly as
in the grok guide §4, with `DESK_AGENT=<m-ID>`.

<a id="ws-doc-5e54048b-d63a-4b68-9867-dbce300263fe"></a>
## 5. Verify

```
sudo -u <AGENT_USER> vibe --version
```

It prints the cnf pin. Then the desk check, as in the grok guide §5, with
`DESK_AGENT=<m-ID>`.

<a id="ws-doc-dcb01fef-f68f-4d6b-bfe3-f5d0a734f8f8"></a>
## 6. Use

Read, open files and answer exactly as in the Claude guide §6, with your
`m-NNN` id. The launcher passes `--auto-approve` (the fleet's bypass rule in
Vibe's terms) and `--max-price` from cnf `env.box.mistral_vibe.max_price`.

<a id="ws-doc-9e9babae-aa4d-4dc6-aff9-5697ff9cec43"></a>
## 7. Conditions

As in the Claude guide §7. Plus:

- A box without `~/.vibe/.env` skips mistral: lane-mix passes the pick down
  the chain mistral -> agy -> claude (spec 110 D4).
- A dead key (401) is its own state, `auth`: the watchdog does not respawn
  the lane, and the lane sends a `blocker` to the dispatcher until the owner
  re-keys.

<a id="ws-doc-ef82bedf-710a-4fb6-a672-637e94a94ed0"></a>
## 8. Uninstall

As in the Claude guide §8, plus `uv tool uninstall mistral-vibe` (or
`pipx uninstall mistral-vibe`) as the agent user, and the `~/.vibe/` dir.

<a id="ws-doc-728c5d12-9859-41f4-b35a-c30a257a6b3f"></a>
## 9. Update this document

Nothing here is measured yet. T014 records: `vibe --version` on each box,
the seat in the window name, `#{alternate_on}`, whether the spool MCP tools
answer inside a live Vibe session, which cost cap is in force, and the first
usage-limit hit with its time.

<!-- version: 0.1.0 · updated: 2026-10-08 · last-edit: 2026-10-08T00:00:00Z -->
