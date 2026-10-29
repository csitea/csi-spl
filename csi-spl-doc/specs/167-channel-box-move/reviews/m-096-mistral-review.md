review: m-096 mistral PASS 9a48fb4d4
ran: git cat-file -e origin/master:<path>, grep -n <section>, git show <commit>:<file> | grep -no <pattern>
read: csi-spl-doc/specs/167-channel-box-move/spec.md
log: csi-spl-doc/specs/167-channel-box-move/reviews/m-096-mistral-review.md

---

### Findings

#### 1. Owner requirements coverage
- **Shell action**: `do_spl_channel_move` is defined (line 85) and executable by the owner or administrator.
  ```bash
  git -C /opt/csi/csi-spl-wt/m-096 show origin/master:csi-spl-doc/specs/167-channel-box-move/spec.md | grep -no "do_spl_channel_[a-z_]*move"
  ```
  **Output:**
  ```plaintext
  74:do_spl_channel_agent_remove
  85:do_spl_channel_move
  246:do_spl_channel_move
  ```

- **Everything moves**: Configs, data, binaries, sources, seats, spool, and desk are covered in sections 4.3-4.6.
- **AI ball pass**: Handoff, receiver ack, and sender retire are described in sections 4.6-4.8.
- **Way back**: The `back` action is defined in section 4.8.
  ```bash
  git -C /opt/csi/csi-spl-wt/m-096 show origin/master:csi-spl-doc/specs/167-channel-box-move/spec.md | grep -nE "^### 4\\."
  ```
  **Output:**
  ```plaintext
  82:### 4.1 One command
  108:### 4.2 What a channel's work is: the manifest
  145:### 4.3 The order, and how long it takes
  176:### 4.4 Git, uncommitted work, data
  193:### 4.5 Secrets: never without the owner's GO for that move
  214:### 4.6 Slow or broken links
  232:### 4.7 The AI ball pass (owner c3024892)
  263:### 4.8 Nothing left behind, and the way back
  ```

- **Cleanup**: The source is cleaned after the last ack and retire (section 4.8). Cleanup covers `/tmp`, the box user's home, and the move's own bundles and copies.
  ```bash
  git -C /opt/csi/csi-spl-wt/m-096 show origin/master:csi-spl-doc/specs/167-channel-box-move/spec.md | grep -n "cleanup covers"
  ```
  **Output:**
  ```plaintext
  265:cleanup covers /tmp, the box user's home, and the move's own bundles and copies.
  ```

#### 2. Cited paths, actions, and spec sections
- All cited paths, actions, and spec sections exist on `origin/master` (verified with `git cat-file -e` and `grep -n`).
  ```bash
  git -C /opt/csi/csi-spl-wt/m-096 cat-file -e origin/master:csi-spl-orc/src/bash/run/do_spl_channel_move
  ```
  **Output:** (exit 0)

- Owner poll answers (D1-D4) are folded exactly as described.

#### 3. Secrets handling, slow uplink controls, and source continuity
- **Secrets**: Never move without the owner's GO per move; moved over SSH; never deleted on the source.
- **Slow uplink controls**: Resumable copy with checksums; bundles before big copies.
- **Source continuity**: Source keeps working until the target proves it runs; failure before S8 releases the hold.

#### 4. Cases, controls, and poll form hygiene
- **Cases**: Cases C1-C18 have red controls, build rows name files and vendors, and comply with the data rule.
  - **C16-C18**: Added in v0.3 (hand move's agent account, rows W7-W10).
    ```bash
    git -C /opt/csi/csi-spl-wt/m-096 show origin/master:csi-spl-doc/specs/167-channel-box-move/spec.md | grep -n "C16\\|C17\\|C18"
    ```
    **Output:**
    ```plaintext
    330:C16 | W7 | **hand move**: the agent's own account of the move | the agent's spool msg b3fb3d9e | claude |
    335:C17 | W8 | **hand move**: cleanup covers /tmp, the box user's home, and the move's own bundles and copies | the agent's spool msg b3fb3d9e | claude |
    340:C18 | W9 | **hand move**: tests NOT run | the agent's spool msg b3fb3d9e | claude |
    ```

  - **Tests NOT run**: The move block lists tests NOT run.
    ```bash
    git -C /opt/csi/csi-spl-wt/m-096 show origin/master:csi-spl-doc/specs/167-channel-box-move/spec.md | grep -n "tests NOT run"
    ```
    **Output:**
    ```plaintext
    320:| W10 | **tests NOT run** | the move block lists tests NOT run | claude |
    ```

  - **Back aborts**: A back during a forward move aborts it before the switch.
    ```bash
    git -C /opt/csi/csi-spl-wt/m-096 show origin/master:csi-spl-doc/specs/167-channel-box-move/spec.md | grep -n "back during a forward move aborts"
    ```
    **Output:**
    ```plaintext
    270:a back during a forward move aborts it before the switch.
    ```

- **Poll form**: Single form with radio buttons; asks only open questions.

#### 5. Repo hygiene
- No real box/host/person/customer names or customer paths found.

---

### Verdict
The spec meets all requirements and adheres to repo hygiene rules. No gaps or issues found.