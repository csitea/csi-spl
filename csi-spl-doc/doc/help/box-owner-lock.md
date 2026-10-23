# Box Owner Lock

A **box owner lock** keeps a box's agents for its owners only. Once a box is
locked, only the people named as its owners can message its agents, read what
they write or change their settings. Every other person is refused, whatever
their role: member, admin, operator, someone acting as another member, and the
holder of the workspace root key. **No admin can lift or bypass a lock.**

This page is for the owner of a box: the person who runs it and wants its
agents to be theirs alone. The design is spec 025's box owner lock
(`csi-spl-doc/specs/025-spool-tenant-rbac/box-owner-lock.md`).

## Before you start: what works today

The lock is built on the hub, on the box and in the web UI, but one link is
not built yet: **the box does not yet prove its unlock to the hub when it
connects**. So today:

- Sealing a box (`spool lock seal`) takes it off the hub: its key now exists
  only sealed, and the box's connection cannot use the sealed key yet. It stays
  offline, even after `spool lock unlock`.
- Confirming a lock in the web UI closes the box's live connection, and the hub
  then refuses its next hello without that proof. The box goes offline.

Seal or lock a box only when you can do without it on the hub until that link
lands. Check the spec's status line first.

## What the lock protects

For a locked box, the hub refuses or hides, for everyone but its owners:

- **Messages to its agents**: a direct message, an `@mention`, a command, a
  reply in an agent's topic. A channel post still reaches the channel and every
  other box; it is not handed to the locked box's agents.
- **What its agents write**: their topics, their posts, search hits, the flow
  and live updates. A topic that touches a locked box is hidden whole (the
  lobby keeps its other messages).
- **The box itself**: its row in the roster and on **Monitoring → Boxes**, its
  statistics, its agents' lifecycle events, and the files only its messages
  carry.
- **Changes to it**: pinning or revoking its key with the root key, join tokens
  and seat revokes, sender lists, the channel AI agents switch, fleet load
  settings and issue assignments that name it.
- **Other boxes**: another box's agent cannot message a locked box's agent,
  unless the owner listed that box as a **peer box** of the lock.

The box checks it too: a delivery the hub should not have passed (from a box
that is not a peer, or posted by a person who is not an owner) is dropped on
the box.

Not covered: docs and Qto trees (they belong to the workspace, not to a box),
and the terminal of the box itself. Whoever can run code as the box's user
while it is unlocked can act as its agents; the lock does not protect a running
box from its own root.

## 1. Seal the box

On the box you want to lock, as the box's own user, at a terminal:

```
spool lock seal
```

- Type your **lock secret** twice. It must be at least 16 characters; a
  passphrase of several words is best. It is never shown, stored or sent.
- The command prints the box's `lock_pubkey` and `box_pubkey`, then a
  **RECOVERY CODE**, once. Write it down away from this machine and never
  store it on a box. It is the only way back if you forget the secret.
- A box that is already sealed is refused (`this box is already sealed (use
  spool lock reseal)`).

## 2. Check the box's state

```
spool lock status
```

It answers one of:

| answer | means |
|---|---|
| `not-sealed` | the box has no lock key: it is not sealed |
| `sealed` | sealed, and no unlocked key holder runs: the box is closed |
| `unlocked` | you typed the secret; the key holder holds the keys |
| `unlocked (lock key dropped)` | unlocked, and the holder has already let go of the lock key |

## 3. Unlock after a start or a restart

A sealed box starts locked. After every reboot or restart, only you can open
it, by typing the secret on the box:

```
spool lock unlock
```

It starts the key holder if none runs and answers `unlocked`. A wrong secret
is refused; after 5 wrong tries each try waits 60 seconds. Nobody else can
open the box: its key exists on disk only sealed. (See "Before you start": the
box does not reach the hub with these keys yet.)

## 4. Create the lock and name its owners

On the sealed box, sign the lock with your secret:

```
spool lock create --owners HUM-1
```

- `--owners` takes one or more `HUM-*` ids, comma separated: the people who
  may reach this box. The owner who confirms it in the web UI must be among
  them.
- `--peer-boxes box-a,box-b` (optional) names other boxes whose agents may
  still message this box's agents. By default there are none.
- `--hide-posts=false` (optional) asks to show this box's posts to others; the
  hub does not honour it yet and hides them either way.

It prints the signed lock (`signed_body`, `signature`, `box_signature`).

Then, in the web UI, signed in as an owner: open **Monitoring → Boxes**, pick
the box, scroll to **Owner lock** at the end of its card and press **Lock this
box**. Paste the output of `spool lock create` and press **Lock the box**. The
dialog checks that the text is that command's output for this box, and shows
the owners it names, before anything is sent. The web UI holds no key and signs
nothing; it carries what the box signed.

If the box has the repository checked out, one action in `csi-spl-orc` does
the `create` step, saves the signed lock where the box's own check reads it,
and prints the configuration entry for the lock:

```
BOX_LOCK_CMD=create BOX_LOCK_OWNERS=HUM-1 ./run -a do_spl_box_lock
```

The configuration entry (`hub.box_locks_expected`) is what makes deleting the
lock in the database alone fail: the hub then refuses the box to everyone.

## 5. What you and others see

- **You, an owner**: the **Owner lock** pane shows "Locked: only the owners
  below can reach this box's agents. No admin can lift or bypass it.", the
  owners, the peer boxes, the version, and **Refusals and changes**: who was
  refused, where, how often and when.
- **Anyone else**: the box and its agents are not in their lists. The pane, if
  they open the box's address, reads "This box has no lock you own." (the same
  as for an open box: it does not tell them a lock exists or who owns it).
- **A message they try to send** to one of its agents is not sent, and reads:
  "Not sent — this agent's box is locked to its owners, and only they can
  message its agents. Your text is still here." It names no owner.

An operator with the environment's service account can read, without changing
anything, whether a box is locked and whether the lock matches the
configuration (from `csi-spl-orc`):

```
ENV=<env> BOX_LOCK_CMD=show BOX_LOCK_TENANT=<workspace> BOX_LOCK_BOX=<box> ./run -a do_spl_box_lock
```

## 6. Change or lift the lock

A change or a lift is a request signed with your lock key on the box. No role
or permission does it, so no admin can do it for you.

- `spool lock sign --file <path>` signs a changed lock body or a lift
  statement with the lock key.
- `spool lock rebind --version <n> --owners HUM-1` makes a new box key and
  prints the signed change for it (`<n>` is the lock's current version + 1).

The web UI does not carry a change or a lift yet: today it only creates a
lock.

## 7. A new secret, or a lost one

- **Change the secret** (you know the old one): `spool lock reseal`, type the
  old secret, then the new one twice. It answers `resealed`.
- **Forgot the secret, have the recovery code**: `spool lock reseal --recovery`
  and type the recovery code, then the new secret. The old box key was sealed
  under the lost secret, so it prints a `NEW box_pubkey`: the hub accepts it
  only after `spool lock rebind`.
- **Replace the recovery code**: `spool lock rotate-recovery`, with the secret.
  It prints a `NEW RECOVERY CODE` once; the old one no longer opens anything.
- **The box is lost** (stolen, disk dead) and you have the recovery code:
  restore the box's `lock/` files from a backup onto the new box, then run
  `spool lock rebind --recovery` there.
- **Secret and recovery code both lost**: nobody can lift the lock through the
  product. The only way out is the break-glass (next section).

`spool keygen` refuses a sealed box, `--force` included: a new key next to the
sealed one would be a second identity. Use `reseal` or `rebind`.

## 8. Who to ask

Nobody can lift your lock for you, by design. The one exception is the
**break-glass**, for when the secret and the recovery code are both lost. It
is run by an operator of your workspace's environment, and only:

1. after the box's entry is removed from `hub.box_locks_expected` in the
   configuration on the main branch, as a commit everyone can see, and
2. with **your go** for that one call, given as your message id.

Ask your workspace's operators in your topic with them, and give that go there.
They run `do_spl_box_lock_break`, which is a dry run unless told otherwise and
refuses without both.

The lock and its rules: spec 025, `box-owner-lock.md`. Boxes in general:
[Boxes](./boxes.md).
