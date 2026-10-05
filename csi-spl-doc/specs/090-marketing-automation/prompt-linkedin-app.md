# Prompt: 090 LinkedIn developer app, end to end

This is the prompt that, handed to one Claude agent on the owner's PC at the start, would have produced the LinkedIn app and every stored copy of its credentials ([`linkedin-app-setup.md`](./linkedin-app-setup.md)) in one pass. It is written after the fact. On 2026-10-05 the same work took about an hour across one blocker post, a hand-run `make` with a typo, and four follow-up messages added mid-task (the browser, `~/.linked-in`, KeePassXC, `csi-spl-all`). Every one of those is in the prompt below, so nothing has to be added while the agent is working.

Use it as written for the next app of this kind (X, Facebook Pages, an email provider), changing only section 1.

---

## 1. Goal

Create the **LinkedIn developer app** that spec 090 needs (`csi-spl-doc/specs/090-marketing-automation/tasks.md` T002 "Needs from the owner") and store its client id and client secret everywhere listed in section 4. Work on the owner's PC, the box where the owner's desktop and KeePassXC database are.

- App name **Spool Hub**, LinkedIn Page **Csitea**, privacy policy `https://spool-hub.ai/privacy`, logo `csi-spl-wui/src/public/icons/icon-512.png`.
- Products: **Share on LinkedIn** and **Sign In with LinkedIn using OpenID Connect**.
- Redirect URLs, for dev and prd, both path forms: `https://spool-hub.ai` / `https://dev.spool-hub.ai` + `/api/v1/marketing/linkedin/callback` and `/v1/marketing/linkedin/callback`.
- I agree to the LinkedIn API Terms of Use for this app and its two products. You may tick those boxes for me.

## 2. The browser: I log in, you click

Open a **visible** Chrome on my desktop with a remote-debugging port and a dedicated profile, at `https://www.linkedin.com/developers/apps`, and tell me when it is up. The `chrome` / `firefox` MCP servers are headless, so do not use them for this. I log in myself (password + code). You never ask for, read or type my LinkedIn password or code, and you never take them from KeePassXC. After I say "logged in", drive the window with playwright-core over CDP.

## 3. Secrets: never through the chat

Read the client id and Primary Client Secret from the Auth page and **pipe** them into each store. Never print them, never post them, never commit them, never put them in a command line that lands in a log. Verify every write by comparing sha256 hashes, never by showing the value.

## 4. Where to store them

| # | store | how |
|---|---|---|
| 1 | Secret Manager `csi-spl-dev` and `csi-spl-prd`: the existing empty slots `csi-spl-hub-marketing-linkedin-client-id` / `-client-secret` | `gcloud secrets versions add --data-file=-`, each env with its OWN SA key `~/.gcp/.csi/key-csi-spl-<env>.json`, throwaway `CLOUDSDK_CONFIG`, `--account` on every call; never the owner account |
| 2 | Secret Manager `csi-spl-all`: the same two secret names | the `csi-spl-all` SA key; enable `secretmanager.googleapis.com` there first if it is off, and create the two secrets |
| 3 | a local file | `~<AGENT_USER>/.linked-in/.csi/client_id` and `client_secret`, dirs 0700, files 0600 |
| 4 | my KeePassXC database (path in my latest screenshot) | one entry `LinkedIn-app-Spool-Hub-csi-spl`: username = client id, password = client secret, URL = the app's Auth page. Open it with the key file I select for this run. Back the database up first |

## 5. Then

1. Write `csi-spl-doc/specs/090-marketing-automation/linkedin-app-setup.md` (what exists, where every value lives, how to redo and rotate it) and save this prompt next to it. Push to master with the release-note trailers.
2. Post one short "done" reply in topic `f0c3927e` so the 090 lanes flip `marketing.linkedin.inject` and apply 030.
3. Ask me only what you cannot decide: which LinkedIn Page if Csitea is not offered, and the KeePassXC key file to open the database.
