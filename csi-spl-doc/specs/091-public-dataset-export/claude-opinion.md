# 091 public dataset export: claude reviewer opinion

Reviewer: c-288 (claude). Author: c-307 (claude, `spec.md`). Peers: g-308 (grok), a-287 (agy).
Written before reading the author's draft. It is grounded in the schema under
`csi-spl-rdb/src/sql/postgres/spool-hub/` (124 migrations) as of origin/master `6e4d54d14`.

## 1. What the owner asked, in one line

Every day, publish one file to a separate, fully public bucket. The file holds the Spool Hub
workspace's public data and nothing else. On an empty database, the repo's migrations plus this
file give a working instance with exactly one workspace. Three different vendors (agy, grok,
claude) each check on their own that no other workspace's data is in it. The build starts only
after the panel agrees.

## 2. The verdict I would sign

**Export a projection, not a dump.** The file must be built by named queries that each list
their output columns, run under a role that can read only what those queries need. It must never
come from `pg_dump` of a workspace with rows filtered out afterwards. A dump carries every column,
every later column and every JSON blob by default. A projection carries only what someone wrote
down. Section 4 shows why that difference decides whether this is safe.

## 3. Where the schema leaks if we are careless (concrete, from the migrations)

| # | Leak path | Where it lives | Why a workspace filter does not catch it |
|---|---|---|---|
| L1 | Members' emails | `humans.email`, `human_identities.email`, the invites table's `email` | `humans` and `human_identities` have **no workspace column**. They are global, so a `WHERE workspace = X` filter cannot apply to them. They join in through memberships. A naive "everyone who posted" join exports the real address. |
| L2 | Sign-in secrets | `password_credentials`, `human_keys`, `email_verification_tokens`, `password_reset_tokens`, `agent_join_tokens` | These are global or per human. They must never be read at all, not read and then blanked. |
| L3 | Raw envelope | `messages.msg` (jsonb, the whole v:1 object) and `messages.files` (jsonb) | `body` can be clean while `msg` still holds the original from/to, file names, signed URLs or a signature. A column allow-list that lets `msg` through has let everything through. |
| L4 | Direct messages | `messages.channel IS NULL` (from/to addressing) | A DM has no channel, so a filter that only drops private channels keeps every DM. |
| L5 | Private channels | `channels.is_private` | Messages join to channels by id. A message in a private channel, or a reply whose parent is there, leaks if the filter runs only on the parent. |
| L6 | Edited and archived text | `message_revisions.body`, `messages.archived_at` | Edit history keeps the text a member took back. An archived message was hidden on purpose. Neither belongs in a public file. |
| L7 | Quoted private content | `body` of a public message that quotes or pastes a DM, a token, an email or a private link | No column rule catches it. Only a content scan of the output does (section 6). |
| L8 | Infrastructure names | `messages.from_box/to_box`, `boxes`, `box_stats`, `roster`, the fleet tables | Box names and hostnames are internal estate data. The hygiene rules already ban them from the repo, so the dataset must not reintroduce them. |
| L9 | Business data | the billing, payment, seat-period and webhook tables, the operator audit table | Not about workspace content at all. They stay out entirely. |
| L10 | Other workspaces through shared ids | `typed_by`, `admitted_by`, `invited_by`, `HUM-N` ids in bodies | A Spool Hub message can name a person who also belongs to another workspace. Exporting that id is fine. Exporting the person's row, display name or other memberships is not (see 5.3). |
| L11 | New columns later | any `ALTER TABLE … ADD COLUMN` | A projection ignores them by construction. A dump exports them silently. A gate must fail when a public table gains a column nobody has classified (section 6, check C3). |

## 4. The allow-list must be an allow-list in three places, not one

1. **Tables:** a checked-in manifest (for example `public-dataset.manifest.yaml`) lists every table
   that may appear. Any table not in it is never queried.
2. **Columns:** for each listed table, every output column is named. `SELECT *` is forbidden in the
   export code. A test greps for it, and C3 below proves it at run time.
3. **Rows:** each table has one named predicate: the workspace, plus public channel, plus not
   archived, plus not a DM, plus the parent public.

The manifest also has to classify **every** column of every listed table as `public` or `withheld`.
A column that is in neither list fails the build. That is what turns "we forgot the new column"
from a silent leak into a red gate.

What I would put on the public side at first, and nothing more:

- the Spool Hub workspace row: id, name, display host taken from cnf (`{{cnf:...}}`), never a literal;
- its **public** channels: id, name, description;
- messages in those channels: id, thread id, parent, channel, timestamp, kind, `body`, and the
  author as a pseudonymous handle (5.3). Not `msg`, not `files`, not `from_box/to_box`, not the edit history;
- reactions and pins on those messages, as counts or by handle;
- issues and labels of that workspace, if the owner counts them as public (ask, do not assume);
- release notes (`release_notes` is global but holds only release text; it is already public in the
  WUI footer), including the links to the release notes the owner asked for;
- RBAC role and permission definitions (schema data, needed to boot).

## 5. The bootstrap seed (owner addition, msg 113d2463)

### 5.1 One file, one command

- The artifact is a SQL file of `INSERT`s (or `COPY` blocks) and nothing else: no DDL, no `SET ROLE`,
  no `ALTER`, no function bodies. The loader rejects any other statement. The schema comes from the
  repo's migrations, never from the file.
- Load it with one named action, for example `./run -a do_spl_dataset_load`. It takes a database URL
  and the path or URL of the file, checks the sha256 against the published `.sha256` (and, ideally, a
  signature), runs the migrations if needed, loads the file inside one transaction, and then creates
  the first admin.
- Version pairing: the file's header records the migration number it was made at. Loading into a
  database at a different migration fails, and the error names the release to check out. It must not
  fail halfway with a missing column.

### 5.2 Credentials: none exported, the first admin is made at load time

- No row from any credential, key, token, session or identity table is exported, not even blanked.
  "Blank it" code is one bug away from "copy it".
- Every exported person is created with **no way to sign in**: no password, no key, no identity
  link, and a non-routable placeholder email such as `<handle>@example.invalid`, or NULL where the
  schema allows it.
- `do_spl_dataset_load` creates one new human from `SPL_ADMIN_EMAIL`, required with no default and
  failing fast if missing. That human is the owner of the Spool Hub workspace and gets a one-time
  sign-in link or password printed once. That is the only account that can sign in.

### 5.3 People are pseudonyms, not profiles

- An exported author is `HUM-N` plus a display handle. Ask the owner whether the real display names
  of Spool Hub members may be public. The default is a handle derived from the id. **No email, no
  `human_identities` row, no last-login time, no preferences columns** (the global `humans` table
  holds per-person UI settings such as `link_previews`, which are none of the public's business).
- Only people who **authored or reacted to an exported row** are exported. Membership alone is not
  enough, and other workspaces' members never appear.
- **Consent:** the members of Spool Hub must know their public posts are published daily, with an
  opt-out that removes their posts or replaces their name with a handle. The owner decides this. The
  spec should carry it as an owner question, not settle it on its own.

## 6. Verification: enforce it twice in the database, check it three ways after

### 6.1 Two independent database controls (both, not either)

- **Query filter:** every manifest query carries `WHERE <workspace column> = $spoolhub`, read from
  cnf, never a literal.
- **RLS session:** the export connection runs as a dedicated read-only role with
  `app.rls_scope` **unset** (never `'operator'`; the `operator_scope` policies would let that scope
  read across workspaces), with the RLS workspace setting set to Spool Hub, and **without** BYPASSRLS
  or table ownership. Ownership defeats FORCE RLS for the owner role (`spool_hub`), so the export must
  not run as the migration owner.
- That role is granted `SELECT` only on the manifest's tables, and where possible only on the
  manifest's columns (`GRANT SELECT (col, …)`). Postgres then refuses a withheld column even if the
  code asks for it. This is the strongest single control, and the spec should require it.
- For the global tables (`humans`, `release_notes`), RLS does not scope by workspace. The column
  grant plus a membership join is the control, and the gate below must check it separately.

### 6.2 Machine gates in the export action (it does not publish unless all pass)

| id | Check | Fails when |
|---|---|---|
| C1 | Workspace column of every exported row | any value other than Spool Hub |
| C2 | Re-read every row on a second connection with RLS set to Spool Hub, then compare | any row missing (it was read around RLS) |
| C3 | Columns in the file vs the manifest's `public` list, **and** every live column of a listed table vs `public ∪ withheld` | an extra column, or an unclassified new column |
| C4 | Content scan of the output: emails, JWT/PEM/`-----BEGIN`, gcloud/AWS/GitHub/Slack token shapes, `sig` fields, signed-URL query strings, IPv4/IPv6, bucket paths, box and host names from cnf, invite codes | any hit not on a reviewed, checked-in exceptions list |
| C5 | Canary rows: CI seeds a second workspace, a private channel, a DM, an archived message and an edited message, each carrying a unique marker string | any marker appears in the file |
| C6 | Round trip: fresh Postgres, migrate, load, boot the hub, `SPL_ADMIN_EMAIL` signs in, the workspace count is 1, no other human can sign in | any step fails |

C5 is the test that matters most. It proves absence by planting things that must be absent, rather
than by listing what we guessed might leak. C4 alone is a ban list, and a ban list cannot prove
absence (the repo's own rule).

### 6.3 The three-vendor check (owner item 3)

- After C1..C6 pass, the candidate file is written to a **private** staging bucket, never the public one.
- agy, grok and claude each check that exact candidate (pinned by its sha256) **separately**: each
  runs its own check in its own lane, without seeing the others' verdicts, and writes a signed
  verdict file `<vendor>.verdict.json` {sha256, verdict, n_rows_checked, checks_run, tree sha}.
  Each must at least sample message bodies for quoted private content (L7), which no regex does well.
- Publishing is a separate step. It copies from staging to public **only** when three PASS verdicts
  for the same sha256 exist, from three different vendors. Two verdicts from the same vendor do not
  count as two.
- Practical question for the owner: an LLM check of every daily file costs three agent runs a day.
  My proposal: the full three-vendor check runs on the **first** publish and again whenever the
  manifest, the export code or the migration number changes. On days when only rows change, the
  machine gates C1..C6 decide alone. The owner should say yes or no to this, since it softens his
  "verified multiple times".

## 7. The public bucket

- It is a new bucket in its own project or at least its own terraform step, made through the
  tf-runner (no ad hoc gcloud), with `allUsers:objectViewer` and **nothing else** in it: no backups,
  no relay objects, no logs.
- Only the publish step's service account (a new one, per environment) may write to it. That account
  can read staging and write public, and it has no database access. The export account can read the
  database and write staging, and it cannot write public. No account does both.
- Object versioning is on, with a retention rule, so a bad file can be withdrawn and replaced. A
  public file may already have been downloaded, so withdrawal is damage control, not a fix. This is
  why the gate comes before publish.
- Layout: `daily/<YYYY-MM-DD>/spoolhub-<migration>-<sha256>.sql.gz` plus `.sha256`, plus `latest.json`
  pointing at the newest file that passed. The release note for the commit links to the file, as the
  owner asked.
- Only `prd` publishes. `dev` runs the same export and gates into a dev bucket for testing, and must
  never be described as public data.

## 8. Things I would ask the author to state explicitly

1. Projection plus column grants, not `pg_dump` (section 2).
2. `msg` and `files` jsonb, `from_box/to_box` and edit history are withheld by name.
3. DMs (`channel IS NULL`) and private channels are excluded by predicate, and C5 proves it.
4. The export role is not the owner role and never sets the operator scope.
5. An unclassified new column fails the build (C3).
6. The three-vendor gate is enforced by the publish step on a sha256, not by convention.
7. Owner questions: real display names or handles; are issues public; consent and opt-out; how often
   the three-vendor check runs.

## 9. Round 1: compared with spec.md v0.1.0 (`d300b411`)

### 9.1 Already in the spec, or agreed for v0.2.0

The spec already does the core of sections 2 to 6: a projection with column grants (§5.1), the
envelope, `files`, the box names and the edit history withheld (§4.1, §4.2), direct messages and
private channels excluded by predicate, and an export role that is not the owner and never sets the
operator scope. The author has agreed to fold these into v0.2.0: C2 (re-read under RLS), C3 (an
unclassified column = FATAL), C5 (canary rows), a separate publish account, a statement whitelist in
the loader, archived messages left out, and the display-name question for the owner. Where the spec is
stronger than my draft I take its version: the three verifiers each use a different method (§8.2),
verdicts are bound to a hub message (§8.4), and the daily boot test runs against the published file (§9.3).

On C3: the column grants in §5.1 already make a new column unreadable, so C3 is not the leak fence.
Its value is that a new column is noticed and classified on purpose rather than quietly missing.

### 9.2 New in round 1 (not in either draft)

| # | Point | Why | Ask |
|---|---|---|---|
| R1-1 | **CI logs and artifacts are public.** §5.4 runs the export on a GitHub-hosted runner, and this repo is public (spec 044). Its workflow logs, and any uploaded artifact, can be read by anyone. | A gate FATAL that prints the matched text, a `set -x`, or an `upload-artifact` of the candidate publishes unverified data before any verifier sees it. | Gate and verifier messages name only table, primary key and class, never the matched text. The candidate never goes to a workflow artifact, only to private staging. Add a test that greps the workflow for `upload-artifact` and `set -x`. |
| R1-2 | **Who reads the other workspaces' names?** §5.5.3 and §8.2 (grok) match against every other workspace's id and display name. The export role cannot read them under FORCE RLS, by design. | Reading them under the export role breaks fence 1 or 2. | A separate step, whose only grant is the id and display-name columns of the workspaces table, writes the list to private staging. The export role stays fenced. |
| R1-3 | **The name hashes must never be published.** Workspace names are short and easy to guess, so a sha256 of one can be reversed by trying common names. | A published hash list tells the world which workspaces exist. | The hash list stays in staging and is deleted when the candidate is published or dropped. §8.4 copies only the file, the manifest and the verdicts, and a check proves no hash list is among them. |
| R1-4 | **An archived task, not an archived row.** `0065_messages_archived.sql`: `archived_at` is set only on the card, and it means the whole task is archived (except in the lobby, where it hides that one row). | A filter of `archived_at IS NULL` on each row keeps every reply of an archived topic. | Exclude every message whose task's card is archived (lobby: that row only). Ask the owner whether archived **channels** (`0092`) are also out. The safe default is yes. |
| R1-5 | **What the canaries must cover** (C5 and the §9.3 fixture). | A canary only proves absence for the path it plants. | The fixture plants a unique marker in: a second workspace's channel with the **same `channel_id`** as a Spool Hub one; a private channel; a direct message; a reply in an archived task; an earlier revision; `msg`, `env`, `env_sig` and `files` of a public message; the email of a human who belongs to **both** workspaces; an invite; a box name. No marker may appear in the output. |

### 9.3 Open after round 1

R1-1 to R1-5, plus the agreed v0.2.0 items until they land in spec.md.
