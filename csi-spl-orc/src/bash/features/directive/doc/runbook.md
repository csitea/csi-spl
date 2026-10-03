# Signed owner directives — runbook

Two scripts under `csi-spl-orc/src/bash/features/directive/scripts/`, for letting the owner
issue an instruction from **any** box and have **any other** box act on it, with
the relaying agent unable to forge or alter what it carries.

| tool | does | exit |
|---|---|---|
| `directive-sign.sh --keygen` | creates the one owner key, interactively, with a passphrase | 0 |
| `directive-sign.sh [--minutes N] <box> "<text>"` | prints a clearsigned envelope on stdout | 0 signed, 2 usage |
| `directive-verify.sh --check-key` | is the pinned key sane to trust **on this box** | 0 sane, 78 refused |
| `directive-verify.sh [--show] < envelope` | verifies one envelope, records its nonce | 0 verified, 78 refused, 2 usage |

There is no `feature.sh`: nothing is installed into a box's home, so `./box list`
does not show it.

---

## 1. What problem this solves

### 1.1 Why a relayed instruction is refused

An agent on another box saying *"the owner told me to tell you X"* is refused,
and that refusal is **not weakened by this feature**.

The problem was never identity. The relaying agent genuinely is the owner's
agent, genuinely authenticated, genuinely relaying in good faith. A stronger
login changes nothing. The gap is **fidelity and scope**: a relayed sentence
cannot show that it is what the owner said, complete, and still in scope. It
could be a paraphrase that drifted, an instruction applied to the wrong target an
hour later, or something the relaying agent was itself talked into.

### 1.2 What signing changes

The owner signs the instruction. The relay becomes a **courier carrying something
it cannot forge or alter**, so relaying stops being an authority claim and the
refusal stops applying.

### 1.3 What is still refused, afterwards

A peer agent's plain prose saying the owner said something. With signing
available there is no reason to send one: signing is a single command.

---

## 2. The one new secret

### 2.1 Why the existing keys cannot be reused

The per-box `git-rel.<box>` keys are **transport** keys. They are
present on every box, so they prove a file was not tampered with in flight and
say nothing about **who wrote it**. Any box holding one could have produced the
message.

An authority key has the opposite requirement.

### 2.2 One key, copied — not one key per box

Generate **once**. Copy the secret half to every box the owner may sit at, and
the public half to every box that must obey. Every box pins **one** fingerprint.

Running `--keygen` separately on each box creates **different** keys with
different fingerprints, and every verifier would then have to pin all of them.
That is the wrong model.

The passphrase is not configured per box. It is a property of the key, so it
travels with the key.

### 2.3 Who holds what

| box | holds | can |
|---|---|---|
| a box the owner types at | secret + public | sign **and** verify |
| a box that only obeys | public only | verify |

A box holding both is expected and allowed — see §4.2 for why that is safe and
what makes it unsafe.

---

## 3. Setup

### 3.1 Create the key, once

```
bash csi-spl-orc/src/bash/features/directive/scripts/directive-sign.sh --keygen
```

It prompts for a passphrase. Choose one you will actually type. Do not store it
on any box.

### 3.2 Export the public half

```
gpg --export --armor <fingerprint>
```

### 3.3 Import it on every verifying box

```
gpg --import < owner-directive.pub.asc
```

### 3.4 Pin the fingerprint on every box

```
export DIRECTIVE_FPR=<fingerprint>
```

Verification without a pinned fingerprint verifies nothing: **any** key in the
keyring would pass, including one an agent generated a minute earlier.

`DIRECTIVE_FPR` is an **allow-list**, whitespace- or comma-separated. The owner
holds one key per box they sit at — better than copying one secret half around
the fleet — so a verifier must be able to pin every one of them. Each entry must
independently pass `--check-key`; the check refuses the whole list if one
sibling is unsound, because the verifier accepts a signature from any member and
the weakest entry therefore sets the real security of the list.

**On a configured box you do not need to export it at all.** Put it in that box's
spool box config (`$SPOOL_ROOT/box.env`) and the scripts read it (parse-only). An
explicit `DIRECTIVE_FPR=…` on the command line still wins. When signing, the list
is narrowed to the one key whose secret half is actually on that box.

### 3.5 Check the key is sane on this box

```
bash csi-spl-orc/src/bash/features/directive/scripts/directive-verify.sh --check-key
```

Must exit 0. On a verifying box it reports the secret half absent. On a signing
box it reports that unattended signing was refused by gpg.

---

## 4. Use

### 4.1 Sign

```
bash csi-spl-orc/src/bash/features/directive/scripts/directive-sign.sh bx1 "rebuild the bx2 pack and report the sha256"
```

gpg prompts; the owner types the passphrase. A shorter lifetime than the 60
minute default:

```
bash csi-spl-orc/src/bash/features/directive/scripts/directive-sign.sh --minutes 15 bx1 "..."
```

### 4.2 The passphrase is typed every time, and that is the product

A cached passphrase means an agent on that box **can sign in the owner's name
right now**. This was caught by a control while building:

```
fresh passphrase-protected key, never used    ->  ACCEPTED
the same key, immediately after one signature ->  REFUSED
```

To trade some of that away knowingly, set a TTL in `gpg-agent.conf`. Start at
zero and loosen only if the friction is real.

### 4.3 Relay it

The envelope is text. Paste it into a relay message, put it on a USB stick, mail
it. The carrier cannot alter it.

### 4.4 Verify

```
bash csi-spl-orc/src/bash/features/directive/scripts/directive-verify.sh < envelope.asc
```

Instruction text only, for scripting:

```
bash csi-spl-orc/src/bash/features/directive/scripts/directive-verify.sh --show < envelope.asc
```

---

## 5. What the verifier checks

Five things, each a complete bypass if skipped. Refusals exit **78**. There is no
silent pass.

| # | check | why it is not optional |
|---|---|---|
| 1 | signature valid against the **pinned** fingerprint | "some key in the keyring" is a key an agent can add |
| 2 | addressed to **this** box | a directive for another box is not this one's to act on |
| 3 | not expired | bounds the damage of a captured passphrase |
| 4 | nonce unused | a valid envelope cannot be replayed by anyone who saw it |
| 5 | `--check-key` | a key that signs unattended makes every signature meaningless |

---

## 6. The envelope

```
to: bx1
nonce: <32 hex>
issued: 2026-09-16T12:00:00Z
expires: 2026-09-16T13:00:00Z
---
the instruction text
```

Clearsigned. The nonce ledger defaults to
`${SPOOL_ROOT:-/var/spool-hub}/directives/used-nonces`, one nonce per line.

---

## 7. The honest limit

If the passphrase is typed on a box where agents run with sudo, an agent there
could capture it and forge **future** directives. The nonce and expiry bound the
damage; they do not remove it.

This is the trade for typing on the keyboard in front of you rather than on a
device the agents do not run on. It is still strictly better than an
unauthenticated relay, which is the only alternative and which is refused
outright.

If a directive ever matters more than that trade, sign it somewhere the agents do
not run.

---

## 8. Tests

```
bash csi-spl-orc/src/bash/features/directive/scripts/selftest-core.sh
```

```
bash csi-spl-orc/src/bash/features/directive/scripts/selftest-anyany.sh
```

13 assertions over two suites, each generating throwaway keys in a temporary
`GNUPGHOME` and removing them.

| suite | asserts |
|---|---|
| core, 8 | valid verifies · replay refused · wrong box refused · expired refused · tampered body refused · impostor key refused · signing box with a passphrase accepted · verify-only box accepted |
| any-to-any, 5 | signing box accepted · passphrase-less key refused · verify-only box accepted · envelope for bx2 refused on bx1 · same envelope accepted on bx2 |

The impostor assertion matters most: a **different** key producing a **correctly
shaped** envelope must fail.

---

## 9. A design decision reversed mid-build

`--check-key` originally **refused any box holding the secret half**, reasoning
that a box which can both sign and verify checks its own homework. True,
prudent-looking, and it blocked the actual requirement — the owner must be able
to sign from whichever box they are at, so the secret travels with the owner and
will sit on boxes that also verify.

The real control was never **where** the key sits. It is whether an agent can use
it **unattended**. The check now attempts a signature with an empty passphrase
and refuses if that succeeds.

That change exposed a second distinction the first version hid: a key with **no
passphrase** and a key whose passphrase is merely **cached** both sign unattended
and look identical to a naive probe. They are different problems — the first is
fatal, the second is a live but recoverable exposure. The check now flushes the
agent cache and re-probes. Still signs means no passphrase (refuse); stops
signing means it was cached (warn, flush, continue).

One core assertion is marked **superseded** rather than deleted, with the reason
in the test body, so nobody restores the old behaviour believing it a regression.
