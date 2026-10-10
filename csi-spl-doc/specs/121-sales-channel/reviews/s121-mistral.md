signed against 6eded1d95

---

### 1. Anonymous-visitor identity
**Agree**: The spec correctly identifies the need for a per-visitor channel and isolation.
**Change**: 
- The spec does not define how a returning visitor finds their channel on a new device. Proposal:
  - A **visitor token** (UUIDv4) is minted on first contact and stored in a `HttpOnly`, `Secure`, `SameSite=Lax` cookie (`spool_visitor_id`). Lifetime: 30 days.
  - On a new device, the visitor must provide an email or phone number to link their token to a recoverable identity. The hub sends a one-time link to restore their channel.
  - The token is invalidated after 30 days of inactivity or on explicit logout.

---

### 2. Per-visitor isolation at the RLS level
**Agree**: RLS is the correct enforcement mechanism.
**Change**:
- The spec does not include the **RLS-negative test**. Proposal:
  - Add a test case in `csi-spl-api/src/go/spool-hub-api/tests/rls_visitor_test.go`:
    ```go
    func TestVisitorRLSNegative(t *testing.T) {
        visitorA := createVisitor(t, "visitor_a")
        visitorB := createVisitor(t, "visitor_b")
        channelA := createChannel(t, visitorA.ID, "csitea")
        createMessage(t, channelA.ID, visitorA.ID, "Hello from A")

        // Visitor B must NOT see Visitor A's message
        _, err := db.Exec("SELECT * FROM messages WHERE channel_id = $1", channelA.ID)
        if err == nil {
            t.Fatal("Visitor B read Visitor A's message: RLS violation")
        }
    }
    ```
  - The test must run in CI and fail the build if RLS is misconfigured.

---

### 3. Abuse, spam, and rate limits
**Agree**: Reusing the demo workspace pattern is pragmatic.
**Missing**:
- **Per-IP limits**: 10 messages/hour, 100/day. Tracked in Redis with a TTL of 24h.
- **Per-visitor limits**: 5 messages/hour, 50/day. Tracked via the visitor token.
- **Message size**: 2000 characters max. Reject larger messages at the API level.
- **Bot handling**: 
  - CAPTCHA on the first message (reCAPTCHA v3, threshold 0.7).
  - If a visitor triggers 3 rate limits in 24h, require CAPTCHA for every message.
  - If a visitor triggers 5 rate limits in 24h, ban the IP for 24h.

---

### 4. Embed security and repo split
**Agree**: The iframe + CSP approach is correct.
**Change**:
- **CSP**: `frame-ancestors https://csitea.net https://*.csitea.net` (allow subdomains).
- **CORS**: `Access-Control-Allow-Origin: https://csitea.net` for all embed endpoints.
- **Repo split**:
  - The embed script (`spool-embed.js`) and its TypeScript source live in **`csi-web`** (the `csitea.net` repo).
  - The hub API endpoints (`/embed/chat`, `/embed/messages`) and their RLS policies live in **this repo** (`csi-spl`).
  - The hub serves the embed script at `/embed/spool-embed.js` for version pinning.

---

### 5. No personal data leaks into tenant workspaces
**Agree**: The spec correctly restricts visitor data to the `csitea` workspace.
**Missing**:
- **Data flow**:
  - Visitor questions land in their private channel in the `csitea` workspace.
  - Staff (owner) is notified via a **dedicated triage channel** (`#csitea-triage`) in the `csitea` workspace. The triage channel is readable by all staff agents.
  - The triage channel shows the visitor's question, their token ID, and a link to their private channel.
  - **Never** expose the visitor's IP, email, or phone number in the triage channel or any tenant workspace.

---

### 6. Ordering and payment flow
**Agree**: Reusing `csi-rel` context is correct.
**Missing**:
- **Order flow**:
  1. Visitor selects a service from the catalogue in the chat widget.
  2. The hub generates a **quote** (PDF) and sends it to the visitor via the chat.
  3. The visitor clicks "Pay Now" in the chat, which opens a Stripe Checkout session.
  4. On successful payment, the hub:
     - Marks the order as `paid` in `csi-rel`'s `orders` table.
     - Posts a confirmation message in the visitor's private channel.
     - Notifies staff in the triage channel.
- **Payment provider**: Stripe (recommended). The `csi-rel` repo already supports Stripe; no new integration is needed.

---

### Addendum 4: B2B embed and metering
**New requirements**:
1. **Embed security**:
   - Each business customer gets a **unique embed token** (JWT, signed with a secret key, 30-day expiry).
   - The token is passed as a query parameter (`?embed_token=<JWT>`) in the iframe src.
   - The hub validates the token and enforces `frame-ancestors` per customer.
   - The token is invalidated if the customer's subscription lapses.

2. **Metering and billing**:
   - **Tokens**: Track LLM token usage per customer in a `metering` table.
   - **Agent time**: Track wall-clock time per agent per customer in the same table.
   - **Billing**: At month-end, generate an invoice from the `metering` table and charge via Stripe Billing.

3. **Per-customer isolation**:
   - Each customer gets their own **workspace** (`customer_<id>`) in the hub.
   - The customer's embed token grants access only to their workspace.
   - RLS policies enforce isolation.

4. **Abuse limits**:
   - **Per-customer limits**: 100,000 tokens/month (soft limit; configurable per customer).
   - **Per-IP limits**: 100 messages/hour (hard limit).
   - **Bot handling**: Same as the public flow (CAPTCHA, rate limits, IP bans).

---

### New owner questions (Addendum 4)
1. **Selling access to single channels**:
   - **A**: Paid private channel (recommended). The customer pays a monthly fee for a dedicated channel in their workspace.
   - **B**: Free private channel. The customer gets a private channel for free, but pays for token/agent usage.

2. **Embed token lifetime**:
   - **A**: 30 days (recommended).
   - **B**: 7 days.
   - **C**: 90 days.

3. **Metering granularity**:
   - **A**: Per-message (recommended). Track tokens and agent time per message.
   - **B**: Per-session. Track aggregate usage per visitor session.

---

### Proposals for missing sections
1. **Anonymous-visitor identity recovery**:
   - Add a `/recover` endpoint to the hub API. The visitor provides their email or phone number, and the hub sends a one-time link to restore their channel.

2. **RLS-negative test**:
   - Add the test case to `csi-spl-api/src/go/spool-hub-api/tests/rls_visitor_test.go` (see above).

3. **Abuse limits**:
   - Implement Redis-based rate limiting in `csi-spl-api/src/go/spool-hub-api/middleware/rate_limit.go`.

4. **Embed token validation**:
   - Add a `validateEmbedToken` function in `csi-spl-api/src/go/spool-hub-api/auth/embed_token.go`.

5. **Metering table**:
   - Add the `metering` table to `csi-spl-api/src/go/spool-hub-api/migrations/002_metering.up.sql`.
