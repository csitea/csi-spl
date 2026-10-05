# Grok review of spec 091

Reviewed `spec.md` v0.2.0. The file's last change is `c526b38d64e4e642e2b30800d8b57119349f76a5`. The tree this comparison was written against is that commit plus this file. Docs only. This file does not change the spec.

The independent pass came first, from the migrations at `65d92246` (0001 through 0124), before this lane read `spec.md` or any other opinion. v0.1.0 (`d300b411f0972f8b376d24fbb886ec43a12c7398`) was the first comparison. v0.2.0 landed before this opinion was pushed, and this text is the comparison against v0.2.0. Reviewer: grok, lane g-308. Author: c-307. Topic `67b63c88-9de3-40d9-a54e-66aae05e4583`.

The product word in this file is workspace. The spec already keeps the code identifiers in their own spellings.

## Where v0.2.0 already holds

These match the independent pass, including the parts v0.2.0 added from the other review. I am not asking to reopen them.

- The public object is a projection built by named queries that list their columns. `pg_dump` and `SELECT *` are refused by a grep test. A later column that the allow-list does not classify fails the export (C3).
- The source is the prd Spool Hub workspace, id from configuration. One workspace row. Abort on zero or two.
- Column grants for a `NOSUPERUSER NOBYPASSRLS` login that is not the migration owner. A session pinned to that workspace. A workspace predicate on every query. C2 re-reads every exported row on a second connection pinned by row security alone, so a row read around the fence fails before staging.
- Direct messages, private channels, deleted channels, archived channels, every message of an archived task, revisions, envelopes, files, invites, credentials, join tokens, payment, fleet, boxes, pins, operator audit, RBAC rows, and every other workspace's rows stay out. The canary fixture (C5) plants a marker in each of those and fails if any marker reaches the file.
- Members ship as their existing opaque id, and only when they author or are the addressee of an exported message. Display name is that id. Email is empty. Role is member. Q1b stays no.
- The loader creates the first admin from an operator-supplied address and a password it generates and prints once. No loaded member can sign in. The loader mints a new root key. It refuses a database that already has a workspace, and it refuses any statement in the file other than `COPY` data.
- Two accounts. The export account writes staging and cannot write the public bucket. The publish account cannot read the database. Publish runs only after three PASS verdicts on the same sha256, from three lane kinds. A failed day leaves the previous object up.
- The three methods differ. The content lane gets sha256 hashes of the other workspaces' ids and display names, from a separate names step, and that list is deleted and never published. I withdraw the temp-file list.
- Issues stay out of v1. I withdraw the request to include them.
- A scan hit in a body drops that message, the drop is counted, the scan runs again, and the second scan must be clean. Above 1% the day fails.
- Gate and verifier output name the table, the primary key, and the class. They do not quote the matched text. Runner logs stay free of the candidate and of the name list.
- Q2, Q4, Q5, Q6, Q8, and Q9 stand as the draft recommends them. Q1 stays an owner question.

## What still has to change

I will treat the spec as agreed once these three are in it.

### 1. Fence 2 has to hold when the operator scope is set

Section 5.2 tells the job not to set the operator scope. The operator policy applies to every role, and any login can set that scope for its own transaction. Column `SELECT` on messages then returns every workspace. Fence 3 is the query text. C2 catches a foreign row afterwards, on a second connection that behaves. Principle 2 says each fence is enough on its own. Fence 2 is enough on its own only when the export role cannot widen it.

Add a `RESTRICTIVE` policy that applies only to `spool_public_export`. The workspace id on the row must equal the single id in a one-row table that role cannot update. The hub's role is not this role. The §9.3 fence test sets the operator scope on purpose and still sees one workspace.

### 2. A `COPY` target has to be an allow-listed table

Section 9.1 refuses DDL, `SET`, and function bodies. A `COPY` of a credential table is still a `COPY`, and step 3 runs it under the operator scope, which can read those tables.

Each `COPY` target is a table in §4.1, and the column list is the public columns of that table. Any other target is a refused file. The empty-database check and the inserts are the same transaction.

### 3. Release-note rows are estate-wide text

Section 4.1 copies `release_notes` with every column. The table has no workspace column. Its text is about every workspace's changes. Section 7 already links the seed from the release notes, which is what the owner asked for. A scan hit outside a message body fails the whole day (§5.5 item 3), so one internal name in a note means that day never publishes.

Leave the table out. A fresh checkout fills it from the public git history through the existing ingest. The other acceptable form is the message rule: a hit drops that note, the drop is counted, and it does not fail the day. Either form is agreement.

## Record these in the same edit

- A member id in `from_id` or `to_id` that is not a member of this workspace drops the message and counts it. The member section already refuses to invent a person for them. The id should not remain in the message.
- A message whose expiry time is already past stays out.
- The first file, and any file with no predecessor, skips the ±50% count check.
- The reading lane reports `n`. It reads every message new since the previous file, plus a sample of 200. Principle 4 already says a pattern list cannot prove a paraphrase is absent. The same sentence covers the sample. The proof that no other workspace's rows were copied is the restore lane, C2, C5, and the policy in item 1.
- Dev publishes on the gate alone only when that workspace is synthetic. A dev database that holds real workspaces uses the same three lanes.
- The dataset-topic post is verifier output under §5.6, so it carries the class and the key and not the matched text. The channel of that topic is on the never-export list.

## Points still open

No consensus yet. Agreement waits on items 1 to 3 against draft `c526b38d64e4e642e2b30800d8b57119349f76a5`. The six record-these lines can land in the same edit. Q1 stays open for the owner.
