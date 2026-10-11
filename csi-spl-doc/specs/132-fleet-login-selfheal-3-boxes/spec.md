# Multi-Agent Fleet Login Self-Heal on 3 Boxes

This spec solves the problem of keeping every agent kind (`claude`, `grok`, `mistral`, `agy`, `qwen`) logged in and self-repairing across 3 boxes (box-1, box-2, and 1 upcoming cloud box for a new workspace). 

## 1. Separate Weekly-Quota from Login Outages
The system distinguishes between a dead login (expired session) and a usage-limit ceiling.
- **Login outage**: The terminal footer reads "Login expired" or "Please run /login". The agent cannot proceed without a valid token.
- **Quota outage**: The terminal footer reads "hit your ... limit". The agent must wait.
- **Detection logic**: The self-heal cron job separates these states and only applies the repair sequence (stop + restore) to login outages. Quota outages are reported (e.g., `limit` count in the alert) but left alone.

## 2. End Copying a Login Between Boxes
Currently, boxes share one Claude login by copying the token. This practice will end:
- A person runs `/login` once per box (using a browser) at box creation or after a revoke.
- Each box independently renews its own token. This relies on the ASSUMPTION that independent tokens per `/login` on one account do not invalidate each other, which the 48h proof step decides.
- There is no copying of the credential file across boxes.

## 3. PROOF Step
Before fully dropping the single-refresher fallback, we must prove that multiple boxes can renew independently on the same account without invalidating one another.
- **Outages**: Past outages (~17:45Z, 18:16-18:22Z, 18:31Z) must not repeat.
- **Renewal interval**: (currently unmeasured, will be determined during proof).
- **Test**: Two boxes are signed in separately to the same Claude account.
- **Criteria**: They must successfully renew their tokens for 48 hours without breaking each other (0 agent drops during this period).
- **Proof command**: `./run -a do_spl_agent_login_proof`
- **Fallback**: If independent renewals break the other box's session, the system falls back to the repair agent's single-refresher push (where one designated box acts as the refresher and pushes the credential file to the 2 peers via `SPOOL_LOGIN_PEERS`).
- **Refresher-down / Peer-unreachable**: If the refresher is down or a peer is unreachable, the push fails and peers eventually expire. Detection relies on the watchdog, which will alert the dispatch lease holder so a human can act.

## 4. Transition from Today
Today, box-2 runs on a COPY of box-1's login. 
- The single-refresher push mechanism (where box-1 pushes its token to box-2) must stay **on** until a person has manually run `/login` on box-2 to establish its own independent session.
- **3rd Cloud Box**: The new box will join the self-heal automatically via the same installer. A person will SSH into the box and run `/login` to establish its first session.

## 5. What a Person Must Do
| Action | When | Who / How |
|---|---|---|
| **First Login** | At box creation (or after a revoke) | A person runs `/login` once per box from the terminal, completing the browser flow. |
| **Quota/Accounts Decision** | When adding boxes/workspaces | A person decides whether to use the same Claude account across all 3 boxes or provision separate accounts to avoid shared weekly quotas. |

## 6. Code: Detect, Stop, Restore, Alert
The repair agent lane provides the self-heal action (`do_spl_agent_login_check`, run every minute by box cron).
- **Detect**: Scans live agents for stuck panes (last answer is an API error + pane footer shows expired/limit). Probes Claude CLI (`claude -p`).
- **Stop**: For each stuck login seat, stops the pane wrapper and sends TERM/KILL to its `claude` PID. (Re-checks the pane right before kill; respects a per-seat 10-minute cool-down).
- **Restore**: Runs `do_spl_agent_identity_restore` once per tick per stuck seat. Does NOT run `/login`. A re-check of the pane state happens before each stop to prevent unnecessary restarts (e.g., avoiding the 18:31Z incident where 8 agents were restarted for nothing).
- **Alert**: Sends one spool message to the dispatch lease holder with counts before and after. Deduplicated by state (alert sent when the state changes or an action is taken).
- **Concurrency**: A per-box `flock` ensures only one instance of the repair script runs at a time.

## 7. Multi-Agent Authentication & Self-Heal
The system supports multiple agent kinds. Their login, quota, and repair behaviors differ:

| Agent Kind | Sign-In Method | Renewal | "Dead Login" / "Quota Hit" Pane Text | Cross-Box Copying | Self-Heal Action |
|---|---|---|---|---|---|
| **Claude** (`c-`) | Browser login (OAuth) | Manual; runs `/login` on expiry | **Dead:** `please run /login` or `oauth token (has )?expired`<br>**Quota:** `hit your (session )?limit` or `usage limit reached` | Breaks it (independent tokens per `/login`) | Self-heal wrapper stops and restores the pane |
| **Grok** (`g-`) | API key (config.toml) | Never (manual re-key) | **Dead:** `invalid api key`<br>**Quota:** `hit your weekly limit` | Works (static key) | N/A (current script targets `claude` only) |
| **Mistral** (`m-`, vibe) | API key (`.vibe/.env`) | Never (manual re-key) | **Dead:** `invalid api key (from env var MISTRAL_API_KEY)`<br>**Quota:** `rate limits exceeded` | Works (static key) | N/A (current script targets `claude` only) |
| **Agy** (`a-`) | API key | Never (manual re-key) | **Dead:** `invalid api key`<br>**Quota:** `usage limit reached` | Works (static key) | N/A (current script targets `claude` only) |
| **Qwen** (`q-`) | API key (`.qwen/settings.json`, `.qwen/.env`) | Never (manual re-key) | **Dead:** `invalid api key`<br>**Quota:** `usage limit reached` | Works (static key) | N/A (current script targets `claude` only) |

## 8. Hourly Rotation
The hourly rotation script for every agent (queued on the lane) must probe the login status before rotating. If the login is dead, it must wait for the self-heal repair sequence to restore it before proceeding with the rotation.
