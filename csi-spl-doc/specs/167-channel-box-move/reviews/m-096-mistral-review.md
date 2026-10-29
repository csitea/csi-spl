review: m-096 mistral PASS 9a48fb4d4
ran: git cat-file -e origin/master:<path>, grep -n <section>
read: csi-spl-doc/specs/167-channel-box-move/spec.md
log: csi-spl-doc/specs/167-channel-box-move/reviews/m-096-mistral-review.md

---

### Findings

#### 1. Owner requirements coverage
- **Shell action**: `do_spl_channel_box_move` is defined and executable by the owner or administrator.
- **Everything moves**: Configs, data, binaries, sources, seats, spool, and desk are covered in sections 4.3-4.6.
- **AI ball pass**: Handoff, receiver ack, and sender retire are described in sections 4.6-4.8.
- **Way back**: The `back` action is defined in section 4.9.
- **Cleanup**: The source is cleaned after the last ack and retire (section 4.8).

#### 2. Cited paths, actions, and spec sections
- All cited paths, actions, and spec sections exist on `origin/master` (verified with `git cat-file -e` and `grep -n`).
- Owner poll answers (D1-D4) are folded exactly as described.

#### 3. Secrets handling, slow uplink controls, and source continuity
- **Secrets**: Never move without the owner's GO per move; moved over SSH; never deleted on the source.
- **Slow uplink controls**: Resumable copy with checksums; bundles before big copies.
- **Source continuity**: Source keeps working until the target proves it runs; failure before S8 releases the hold.

#### 4. Cases, controls, and poll form hygiene
- **Cases**: Cases C1-C18 have red controls, build rows name files and vendors, and comply with the data rule.
- **Poll form**: Single form with radio buttons; asks only open questions.

#### 5. Repo hygiene
- No real box/host/person/customer names or customer paths found.

---

### Verdict
The spec meets all requirements and adheres to repo hygiene rules. No gaps or issues found.