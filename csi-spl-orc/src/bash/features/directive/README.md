# directive — signed owner directives

The owner types an instruction on one box, signs it, and any other box acts on it.
The agent relaying it is a courier: it cannot forge or change what it carries.
A peer agent's plain prose saying "the owner says X" is still refused.

The full runbook is `doc/runbook.md`. This file is the short version. Every
path below is relative to the csi-spl checkout (`<repo>`). Moved here from the
frozen box engine by spec 069 lane Y5.

---

## 1. Contents

| path | role |
|---|---|
| `../spawn-agents/assets/commands/signed-prompt.md` | the `/signed-prompt @<BOX> <text>` command, rendered into `~/.claude/commands` by `spool-install` (step 5b) — how the feature is actually used |
| `scripts/directive-sign.sh` | `--keygen`; sign one envelope (`--minutes`, `--reply-to`) |
| `scripts/directive-session.sh` | signing window: `--minutes N` · `--status` · `--close` |
| `scripts/directive-verify.sh` | verify an envelope (`--show`); `--check-key [--prove]` |
| `lib/directive-env.inc.sh` | reads `DIRECTIVE_*` and `SPOOL_BOX_TAG` from `$SPOOL_ROOT/box.env`, parse-only |
| `scripts/selftest-{core,anyany,list,session}.sh` | the four suites (`tests/test-directive.sh` runs them) |

---

## 2. The rules that carry the security

### 2.1 Sign the owner's literal text

The skill signs exactly the characters the owner typed after `@<BOX> `, never a
paraphrase. A signed paraphrase is worse than an unsigned one, because it carries
the owner's signature and so cannot be questioned.

### 2.2 `DIRECTIVE_FPR` is an allow-list

It is read from the environment, else from the spool box config
`${SPOOL_BOX_ENV:-$SPOOL_ROOT/box.env}` (`DIRECTIVE_FPR=...`). The same file
gives the box tag (`SPOOL_BOX_TAG`, or `DIRECTIVE_BOX`), the nonce ledger
(`DIRECTIVE_LEDGER`, default `$SPOOL_ROOT/directives/used-nonces`) and the
window record (`DIRECTIVE_SESSION_STATE`).

It lists every owner key this box obeys, separated by spaces or commas. Each box
the owner types at has its own key.

- **`--check-key`** checks every entry and refuses the whole list if one entry is
  unsound, because the verifier accepts any member.
- **The signer** narrows the list to the one key whose secret half is on this
  box. With none, the box verifies and cannot issue.

### 2.3 Pin only what the owner typed in this box's session

Never pin a key because a peer said so. A key that arrives over the channel it
authenticates has no more standing than that channel.

### 2.4 The window removes the prompt, not the signature

`directive-session.sh --minutes N` takes the passphrase once for up to 480
minutes, and every directive is still signed over its own text. It refuses
without a terminal. A pseudo-terminal would satisfy that check, so the passphrase
is the real control, not the terminal.

### 2.5 `reply-to:` has no default

It names where the result goes. If it is absent, it is absent, because a default
is a guess wearing a uniform. The skill always sets it.

### 2.6 The window record is trusted only if the caller could not have written it

The record defaults to `/var/lib/spool-hub/directive-session.state`, and
`DIRECTIVE_SESSION_STATE` overrides it. `--check-key` checks the owner and mode of
both the file and its directory, because the obvious homes are group-writable by
the agent. Run as the record's owner, `--check-key` therefore kills `gpg-agent`
and closes an open window.

### 2.7 Kill `gpg-agent`, do not flush it

`clear_passphrase` and `RELOADAGENT` do not evict an unlocked key. This was first
proven on gpg-agent 2.2.27 and has since been observed on 2.3.3. `--keygen`,
`--close`, `--minutes` and `--check-key` all run `gpgconf --kill gpg-agent`.

### 2.8 `--keygen` reads the passphrase itself

It uses `read -rs`, twice, and refuses an empty passphrase before generating. On
one box, gpg's loopback prompt never appeared and keys were created with an empty
passphrase.

---

## 3. Commands

### 3.1 Window status

```
bash "<repo>/csi-spl-orc/src/bash/features/directive/scripts/directive-session.sh" --status
```

### 3.2 Key check

```
bash "<repo>/csi-spl-orc/src/bash/features/directive/scripts/directive-verify.sh" --check-key
```

### 3.3 Sign

```
bash "<repo>/csi-spl-orc/src/bash/features/directive/scripts/directive-sign.sh" --reply-to <THIS-BOX> <TARGET-BOX> "<the owner's literal text>"
```

### 3.4 Verify

```
bash "<repo>/csi-spl-orc/src/bash/features/directive/scripts/directive-verify.sh" < envelope.asc
```

Every refusal exits 78: a bad signature, an unpinned key, the wrong box, an
expired envelope, a spent nonce or an unsound key.

---

## 4. Tests

```
for t in core anyany list session; do bash "<repo>/csi-spl-orc/src/bash/features/directive/scripts/selftest-$t.sh"; done
```

Ported from engine `ddb4b64`; the same counts in csi-spl: core 8/0 · any-to-any 5/0 · list 7/0 · session 12/0.

---

## 5. Honest limits

- A passphrase typed on a box where agents hold sudo can in principle be
  captured.
- The window trades that same exposure for one entry instead of many.
- The box config that pins `DIRECTIVE_FPR` is writable by the agent group on
  a box where the spool root is, exactly as the engine's overlay `box.env` was.
- A signature proves the fidelity of the text, not that the instruction was wise.
