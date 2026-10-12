# SPEC: Task lifecycle and `kind`

Status: binding addendum  
Related: `specs/002-box-agent-messaging/contracts/message-schema.md`

`v:1` has `task_id` and `kind ∈ {task, result, note, reject}`. 002 stores them
as strings. This spec says what they **mean**, so agents do not invent a second
workflow on top of spool.

---

## 1. A task is a thread, not a job object

There is no separate “task” resource in 002. A `task_id` (UUIDv4) is the
thread key: every message has its own `task_id`.

Who mints it:

- `spool-send --task <uuid>` uses the caller’s id (must be UUIDv4).
- If `--task` is omitted, the CLI mints one and returns it.

**Threading & `parent_task_id` (M3 channels & threads):**
- Every message minted on the bus carries a unique `task_id` (UUIDv4).
- Top-level channel messages have no parent (`parent_task_id: null`).
- Threaded replies include `parent_task_id: <root_task_id>` (UUIDv4) referencing the root message of the thread.
- This maintains 100% backward compatibility: M1/M2 single-thread CLI interactions treat `task_id` as the thread key, while M3 channels use `parent_task_id` to nest replies under a root message.

---

## 2. `kind` semantics

| kind | Means | Who may send |
|---|---|---|
| `task` | command: please do this | **any pinned peer** in the tenant |
| `result` | I did it (success) | typically the `to` of a prior task; not hub-enforced |
| `reject` | I will not / cannot | typically the assignee; not hub-enforced |
| `note` | commentary; no completion claim | any pinned peer |

There is no controller role. Claude may command Grok; Grok may command
Antigravity; two Claude ids may command each other. The hub only checks:
`from` is pinned, `sig` verifies, `to` is a well-formed id (need not be
online). If `to` is not pinned, the message still stores (assignee may be
pinned later); recv as an unpinned `as` still fails until that id is pinned.

`result`/`reject` is an ordinary peer send to whoever should hear it (usually
the original commander). The hub does not auto-reply. Spool **does not
enforce** a state machine (a `result` without a prior `task` is still stored). 003 MAY record `tasks.last_kind` for
the WUI. Agents SHOULD:

- Open work with `kind=task`.
- Finish with exactly one `result` or `reject` from the assignee.
- Use `note` for questions, progress, and human remarks.

Multiple `result`s on one `task_id` are allowed (partial deliveries) but the
WUI treats the **latest** `result`/`reject` as the thread status.

---

## 2.1 Peer mesh

Any pinned agent may send `task` to any other agent id in the tenant. The
protocol does not know “human vs worker” except as id prefixes. Prefix does
not grant extra rights.

## 3. Unicast only

`to` is one agent id. Want two assignees? Two `task` messages (two `msg_id`s,
optionally the same `task_id` if they share a thread, or two task ids if they
do not). v1 does not have `cc`.

---

## 4. Body

UTF-8 text. Not HTML. Markdown is allowed as text, not rendered by spool.
Empty body is allowed if `files` is non-empty; empty body and empty files is
allowed but pointless (`note` with a ping).

Limits: `contracts/limits.md`.

---

## 5. Human on the thread

Humans view via `spool-tail` or the WUI. They are not required to have an
agent id. If a human must **send**, pin a `HUM-*` id and use the same CLI.
The WUI v1 is read-only (see `SPEC-spool-wui.md`).

---

## 6. A spool task is not an issue

Decided in [spec 135](../../specs/135-work-process/spec.md) v1.0 (owner
HUM-10, t1 5ea2e615). A `task_id` thread is the talk; the hub **issue**
(`SPL-n`) is the tracked record of the work and its status. They link, they
do not merge:

| | spool thread (`task_id`) | hub issue (`SPL-n`) |
|---|---|---|
| holds | the discussion, briefs, results, notes | condensed data: what is done or being done, the restart card, checkpoints |
| status | none enforced (section 2) | `eval` -> `todo` -> `wip` -> `done`, plus `blocked`, `onhold`, `qas`, `diss` (spec 135 section 5) |
| link | the taker posts the issue key back in the topic | `Source: /t/<uuid>` at the top of the description |
| ends | a human closes the topic | `done` when its citing commit lands (hourly closer), or `diss` with a reason |

- One issue per discussion an agent takes, filed from the first answer (Q1).
- A question to the owner stays a message in the thread; it files no issue,
  and the issue it holds up is `blocked` + `needs-owner` (Q2).
- A lane's final `result` message does not close its issue; the landed
  citing commit does (Q3). An `answer` issue closes with a comment linking
  the posted answer.

<!-- version: 0.2.0 · updated: 2026-10-12 · last-edit: 2026-10-12T20:20:00Z -->
