# Feature Specification: Edit a Sent Message + Append-Only Revision Register

**Feature ID**: `032-spool-message-edit` · **Milestone**: M3 · **Status**: Implemented
**Created**: 2026-09-22 · **Lane**: MESSAGE-EDIT (hub + DB: CLE-3443 · browser: CLE-3445 under `../005-spool-wui`)
**Authority**: `./contracts/message-edit-v1.md`

Status vocabulary follows `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

## The owner's request, verbatim (2026-09-22)

> we need to add the WUI capability to edit the msgs , slack wise , once a msg in the 3rd
> panel is selected , if one presses the e shortcut the msg becomes once again a textbox
> and after once writes the new msg ( the old msg should be shown there ) and hits the
> enter the msg is sent ..

> but there should be a register in the db that the msg was updaed , aka both the old and
> the new msg should be stored ( for later feature to be able to compare those msgs )

The second message is the hard constraint: **an edit is not an overwrite**. Both the old
and the new body survive, because the owner has already named the feature that will read
them — comparing the two.

## Clarifications

### Session 2026-09-22 (integrator rulings, CLE-00)

- **Authorisation: the author only, and no time window.** **OWNER-STATED, 2026-09-22**:
  *"of course msgs sent by bots should not be editable"*. It began as an integrator ruling
  the same morning — the owner said "slack wise" but did not ask for Slack's editing window,
  and a silent expiry produces a bug report rather than a feature — and the owner then stated
  the rule themselves when they found the `e` affordance being offered on bot messages. The
  no-time-window half remains the integrator's; the owner has not spoken to it.
- **Escape cancels the edit.** Recorded as **INFERRED**, not owner-stated.
- **Spec home**: this dir, moved out of `020-spool-message-v2` on the morning it was
  written (`contracts/message-edit-v1.md` §9).

### Decided by this lane, from the code rather than from preference

- **The edit marker is hub metadata, not a message field.** `edited_at` / `edited_by` /
  `revision` ride on the view element and the live frame beside `cursor` and
  `received_at`, never inside the inner `v:1`/`v:2` object. 020's freeze is therefore
  untouched, and no signature covers a field an edit changes.
- **A box-signed message cannot be edited over this endpoint** (409 `not_editable`). Not
  policy — arithmetic: the envelope's Ed25519 signature covers the canonical inner bytes
  and the hub holds no key that could re-sign for another box. It refuses nothing the
  owner asked for, because every row the `e` shortcut can reach is browser-authored.
- **The live frame is a new type, `message_edited`.** Reusing `type: "message"` would be
  silently dropped by the browser's own merge (contract §3.1 carries the command and its
  output; three readers ran it independently).

## User stories

### US1 — the owner fixes a typo (P1)

A signed-in member selects their own message in the third panel, presses `e`, the card
becomes a textbox pre-filled with the current body, they change it and press Enter. The
message updates **in place** — same position in the thread, same timestamp — and is
marked as edited.

**Acceptance**: `PATCH /v1/messages/{msg_id}` returns 200 with the new body and
`edited_at`; the thread read back over `/v1/view/threads/{task_id}` shows the new body,
the same `cursor` and the same `received_at`.

### US2 — nothing is lost (P1)

Every body the message has ever had is still in the database after any number of edits,
each with who wrote it and when.

**Acceptance**: after two edits, `message_revisions` holds three rows for that `msg_id`
(revisions 1, 2, 3) — the original body included, captured at the first edit.

### US3 — a second open session sees it (P1)

A member with the thread open in another tab sees the new text without a reload and
without refetching the thread.

**Acceptance**: a `message_edited` frame reaches every socket that would have received
the original `message` frame, including the editor's own other tabs.

### US4 — nobody edits anybody else's message (P1)

**Acceptance**: a member's `PATCH` against another member's message is refused 403
`not_author`, and the stored body is unchanged. The guard is **shown refusing** by a test
that fails if the guard is removed.

## Functional requirements

| id | requirement | status |
|---|---|---|
| FR-ED-001 | `PATCH /v1/messages/{msg_id}` replaces a message's body (contract §1) | Implemented |
| FR-ED-002 | `message_revisions` is append-only: an edit INSERTs, nothing UPDATEs a body out of existence (contract §7) | Implemented |
| FR-ED-003 | The first edit captures the ORIGINAL body as revision 1 in the same transaction | Implemented |
| FR-ED-004 | Only the author may edit; no time window (contract §4) | Implemented |
| FR-ED-005 | A box-signed envelope is refused 409 `not_editable` (contract §4 rule 7) | Implemented |
| FR-ED-006 | An empty or whitespace-only body is refused 400 `empty_body` | Implemented |
| FR-ED-007 | `edited_at` / `edited_by` / `revision` appear on the view element and on the frame; omitted while never edited (contract §2.1) | Implemented |
| FR-ED-008 | A `message_edited` frame reaches the `message` audience of that message (contract §3) | Implemented |
| FR-ED-009 | An edit does NOT move the message: `ts`, `received_at` and `cursor` are unchanged | Implemented |
| FR-ED-010 | `message_revisions` is under the same tenant RLS as `messages`, fail-closed (0021 NULLIF form) | Implemented |
| FR-ED-011 | Revisions are purged with their message by the retention sweep | Implemented |

The status column was still `Planned` after `tasks.md` T001–T009 were marked
Implemented (`d8ecb2a`, `0026_message_revisions.sql`, `internal/hub/edit.go`).
Code prevails. FR-ED-005 also refuses a human channel post once the hub has
signed it with the box-wui key (`internal/hub/wui.go` fan-out, then
`internal/hub/edit.go` rule 7), because `env_sig` is no longer empty. That
interaction is left as-is; changing it would be a behaviour change, not a
spec correction.

## Non-goals

- **The compare feature itself.** The owner named it as a *later* feature; this spec
  stores what it will read and deliberately invents no endpoint for it
  (contract §7, last paragraph).
- **Editing a box-authored message**, from the browser or anywhere else.
- **Deleting a message.** Not asked for.
- **A time window on editing.** Ruled out above.
- **The browser half** — selection model, the `e` binding, the inline editor, Escape,
  the `(edited)` marker and its i18n string, the browser e2e. Those are `../005-spool-wui`
  (lane CLE-3445), which consumes `./contracts/message-edit-v1.md` and invents no field
  names.

## Success criteria

- SC-001: after an edit, the old body is readable from the database and the new body is
  what every reader sees.
- SC-002: `not_author`, `empty_body` and `not_editable` each have a test that FAILS when
  its guard is removed. A guard nobody has watched refuse is not a guard.
- SC-003: the migration rolls before the image that needs it, on dev and prd
  (contract §8), and the intermediate state is safe because the old image reads and
  writes neither the new table nor the new columns.

<!-- version: 0.2.1 · updated: 2026-09-23 · last-edit: 2026-09-23T07:23:09Z -->
