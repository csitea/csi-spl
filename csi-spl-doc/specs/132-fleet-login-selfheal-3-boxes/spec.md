# Multi-Agent Fleet Login Self-Heal on 3 Boxes

This spec solves the problem of keeping every agent kind (`claude`, `grok`, `mistral`, `agy`, `qwen`) logged in and self-repairing across 3 boxes (box-1, box-2, and 1 upcoming cloud box for a new workspace). 

## 1. Separate Weekly-Quota from Login Outages
The system distinguishes between a dead login (expired session) and a usage-limit ceiling.
- **Login outage**: The terminal footer reads "Login expired" or "Please run /login". The agent cannot proceed without a valid token.
- **Quota outage**: The terminal footer reads "hit your ... limit". The agent must wait.
- **Detection logic**: The self-heal cron job separates these states and applies the repair sequence (stop + restore) to login outages. Quota outages are reported (e.g., `limit` count in the alert). They are left alone while the box probe says `limited` or `expired`, but if the box probe says `ok` (the limit has lifted but the pane is stale), they are stopped and restored.

## 2. End Copying a Login Between Boxes
Currently, boxes share one Claude login by copying the token. This practice will end:
- A person runs `/login` once per box (using a browser) at box creation or after a revoke.
- Each box independently renews its own token. This relies on the ASSUMPTION that independent tokens per `/login` on one account do not invalidate each other, which the 48h proof step decides.
- There is no copying of the credential file across boxes.

## 3. PROOF Step
Before fully dropping the single-refresher fallback, we must prove that multiple boxes can renew independently on the same account without invalidating one another.
- **Outages**: The design must beat the outage 17:45Z to 18:16-18:22Z (31 to 37 min, all claude seats on the box) and the 8 needless restarts at 18:31Z. Detection must occur within 1 tick (cron `* * * * *`), with 0 restarts of a seat that is no longer stuck.
- **Renewal interval**: The access token lives ~8 h (479 min, n=1). The proof will measure it (delta between successive `expiresAt` with a sha prefix change, via `agent-login-cred.sh stat`).
- **Test**: Two boxes are signed in separately to the same Claude account. The `/login` on box-2 and removing `SPOOL_LOGIN_PEERS` on box-1 must be ONE step before the 48h start, to prevent box-1 from pushing over box-2.
- **Criteria**: 
  - 48h wall clock with `SPOOL_LOGIN_PEERS` empty on both.
  - >=5 renewals seen per box (sha prefix differs every sample, proving independence).
  - 0 ticks with `probe=expired` (`LOGIN_PROBE_EVERY` 300 s -> 576 probes per box in 48 h).
  - 0 ticks with `stuck_login > 0` (2880 ticks per box).
  Fail = any of these, state the first failing sample's time.
- **Proof command**: **[To be built]**. The proof can be read off the per-box cron log `agent-login-check/cron.log` and `agent-login-cred.sh stat`.
- **Fallback**: If independent renewals break the other box's session, the system falls back to today's single-refresher push (where one designated box acts as the refresher and pushes the credential to the 2 peers via `SPOOL_LOGIN_PEERS`).
- **Refresher-down / Peer-unreachable**: 
  - *Peer unreachable*: Refresher warns ("no credential to compare ... unreachable") and alerts the dispatch lease holder once per state.
  - *Refresher silent (early warning)*: Every box warns when its credential expiry is <60 min and not renewed. The dispatch lease holder relays this to a person, who runs the vendor's login on that box (no agent can repair a dead login).

## 4. Transition from Today
Today, box-2 runs on a COPY of box-1's login. 
- The single-refresher push mechanism must stay **on** until a person has manually run `/login` on box-2 to establish its own independent session. The peer list is emptied in that same step.
- **3rd Cloud Box**: The new box joins via `do_spl_box_deploy install`, which installs the crons (including `agent-login-check`). Its `SPOOL_LOGIN_PEERS` stays empty (it is not a refresher) and it is not added to box-1's peers. First login per vendor is done by a person (claude `/login`, grok/agy browser or device login, mistral/qwen keys). It has joined when its first tick logs `probe=ok`.

## 5. What a Person Must Do
| Action | When | Who / How |
|---|---|---|
| **First Login** | At box creation (or after a revoke) | A person runs the login once per box: `/login` for Claude, browser/device login for Grok and Agy, and provides keys for Mistral and Qwen. |
| **Quota/Accounts Decision** | When adding boxes/workspaces | A person decides whether to use the same Claude account across all 3 boxes or provision separate accounts to avoid shared weekly quotas. |

## 6. Code: Detect, Stop, Restore, Push, Alert
The repair agent lane provides the self-heal action (`do_spl_agent_login_check`, run every minute by `box-crons`).
- **Detect**: Scans live agents for stuck panes. Probes Claude CLI (`claude -p`).
- **Stop**: For each stuck login seat, stops the pane wrapper and sends TERM/KILL to its `claude` PID. (Re-checks the pane right before kill; respects a per-seat 10-minute cool-down, default).
- **Restore**: Runs `do_spl_agent_identity_restore` once per tick per stuck seat (no `/login`). A re-check happens right before the stop to prevent needless restarts.
- **Push**: The peer push helper pushes the credential to peers in `SPOOL_LOGIN_PEERS` (only accepts a Claude login).
- **Alert**: Sends one spool message to the dispatch lease holder deduplicated by state.
- **Concurrency**: A per-box `flock` ensures one instance runs at a time.

## 7. Multi-Agent Authentication & Self-Heal
The login check currently scans `claude` seats only. The dead-login patterns for other kinds exist in the watchdog (`S2 kind=auth`) and start check, which detect but do not repair. (Note: dead banners without fixtures are unmeasured; a task is needed to add fixtures).

| Agent Kind | Sign-In Method | Renewal | "Dead Login" / "Quota Hit" Pane Text | Cross-Box Copying | Self-Heal Action |
|---|---|---|---|---|---|
| **Claude** (`c-`) | Browser login (`/login`) | Auto (token lives ~8h); `/login` only on revoke/fail | **Dead:** `please run /login` or `oauth (session\|token) (has )?expired` <br>**Quota:** `(you[^[:space:]]* )?hit your ([a-z]+ )?limit\|usage limit reached` | Unproven (proof decides). A hypothesis is that they invalidate each other. | Scan + Restore (`do_spl_agent_identity_restore`) |
| **Grok** (`g-`) | Browser or device login (API key is fallback) | Target, not built: same as Claude (probe, early warning, repair) | **Dead:** `invalid api key` (unmeasured) <br>**Quota:** watchdog stall regex | Unmeasured | Watchdog `S2 kind=auth` alerts dispatch holder -> person logs in -> restore |
| **Mistral** (`m-`, vibe) | API key (env) | No refresh step in tree | **Dead:** `invalid api key (from env var MISTRAL_API_KEY)`<br>**Quota:** `rate limits exceeded` | Works (static key) | Watchdog `S2 kind=auth` alerts dispatch holder -> person re-keys -> restore |
| **Agy** (`a-`) | Google login only (keys ignored) | Target, not built: same as Claude (probe, early warning, repair) | **Dead:** login-required line (unmeasured) <br>**Quota:** watchdog stall regex | Unmeasured | Watchdog `S2 kind=auth` needs to recognize Agy's login-required banner. Once detected -> alerts dispatch holder -> person logs in -> restore |
| **Qwen** (`q-`) | API key (env) with auth-type pin | No refresh step in tree | **Dead:** `invalid api key` (unmeasured) <br>**Quota:** watchdog stall regex | Works (static key) | Same as Mistral |

## 8. Hourly Rotation
`do_spl_lane_rotate` probes the login status before rotating. 
- **Claude:** The gate defers a claude seat while the probe is not ok. The tick skips the seat and sends one note (it does not block until repair finishes).
- **Gap:** The gate is claude-only. Mistral, grok, agy, and qwen take the same branch and rotate into a dead login (the per-vendor probe should feed rotation too).
