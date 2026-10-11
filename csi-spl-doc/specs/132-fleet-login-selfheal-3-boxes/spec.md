# Fleet Login Self-Heal on 3 Boxes

This spec solves the problem of keeping every Claude agent logged in and self-repairing across 3 boxes (box-1, box-2, and 1 upcoming cloud box for a new workspace). 

## 1. Separate Weekly-Quota from Login Outages
The system distinguishes between a dead login (expired session) and a usage-limit ceiling.
- **Login outage**: The terminal footer reads "Login expired" or "Please run /login". The agent cannot proceed without a valid token.
- **Quota outage**: The terminal footer reads "hit your ... limit". The agent must wait.
- **Detection logic**: The self-heal cron job separates these states and only applies the repair sequence (stop + restore) to login outages. Quota outages are reported (e.g., `limit` count in the alert) but left alone.

## 2. End Copying a Login Between Boxes
Currently, boxes share one Claude login by copying the token. This practice will end:
- A person runs `/login` once per box (using a browser) at box creation or after a revoke.
- Each box independently renews its own token.
- There is no copying of credentials (`~/.claude/credentials.json`) across boxes.

## 3. PROOF Step
Before fully dropping the single-refresher fallback, we must prove that multiple boxes can renew independently on the same account without invalidating one another.
- **Test**: Two boxes are signed in separately to the same Claude account. They must successfully renew their tokens for 48 hours without breaking each other.
- **Fallback**: If independent renewals break the other box's session, the system falls back to the repair agent's single-refresher push (where one designated box acts as the refresher and pushes the credential to the 2 peers via `SPOOL_LOGIN_PEERS`). What happens if the refresher is down: the peers will eventually expire until the refresher box comes back online and pushes a new token. Unreachable peer: the push fails, and the peer expires.

## 4. Transition from Today
Today, box-2 runs on a COPY of box-1's login. 
- The single-refresher push mechanism (where box-1 pushes its token to box-2) must stay **on** until a person has manually run `/login` on box-2 to establish its own independent session.

## 5. What a Person Must Do
| Action | When | Who / How |
|---|---|---|
| **First Login** | At box creation (or after a revoke) | A person runs `/login` once per box from the terminal, completing the browser flow. |
| **Quota/Accounts Decision** | When adding boxes/workspaces | A person decides whether to use the same Claude account across all 3 boxes or provision separate accounts to avoid shared weekly quotas. |

## 6. Code: Detect, Stop, Restore, Alert
The repair agent lane provides the self-heal action (`do_spl_agent_login_check`, run every minute by box cron).
- **Detect**: Scans live agents for stuck panes (last answer is an API error + pane footer shows expired/limit). Probes Claude CLI (`claude -p`).
- **Stop**: For each stuck login seat, stops the pane wrapper and sends TERM/KILL to its `claude` PID. (Re-checks the pane right before kill; respects a per-seat 10-minute cool-down).
- **Restore**: Runs `do_spl_agent_identity_restore` once per tick per stuck seat. Does NOT run `/login`.
- **Alert**: Sends one spool message to the dispatch lease holder with counts before and after. Deduplicated by state (alert sent when the state changes or an action is taken).
- **Concurrency**: A per-box `flock` ensures only one instance of the repair script runs at a time.
