signed against 6eded1d95

### Section Review
- **Section 1 (The owner's words):** agree
- **Section 2 (Public questions and per-visitor private channels):** missing
- **Section 3 (What is sold):** change (replace fixed services with metered token usage and paid private channels)
- **Section 4 (Where it shows on spool-hub.ai):** agree
- **Section 5 (Order and payment flow):** change (needs flow for paid single private channels and metered usage margin)
- **Section 6 (Reuse of csi-rel context):** agree
- **Section 7 (Owner questions):** change (replace services question with margin question, remove single-channel question as it is settled)

### Concrete Proposals for Missing Elements

1. **Anonymous-visitor identity**: A cryptographically signed HttpOnly cookie (`guest_token`) containing a UUID is issued upon first interaction, with a 30-day lifetime. On a new device, a new independent visitor identity is created (no cross-device linking without a full account).
2. **Per-visitor isolation at the RLS level**: Add a `visitor_id` column to `channels` and `messages`. The Postgres RLS policy for the anonymous role asserts `visitor_id = current_setting('request.jwt.claim.visitor_id', true)`. The RLS-negative test must prove that an anonymous visitor querying `messages` receives only their own channel's messages, while another visitor's token returns 0 rows. (The owner role reads all).
3. **Abuse, spam, and rate limits**: Enforce bucketed rate limits in Redis: 5 msgs/min per visitor, 20 msgs/hour per IP, with a max message size of 1000 characters. For B2B embeds (Addendum 4), rate limits are scoped per customer API key/tenant. Use a ReCAPTCHA v3 or similar invisible challenge upon session start to thwart bots.
4. **Embed security and mechanics (Addendum 4)**: Embed via `iframe`. `spool-hub.ai` dynamically serves `Content-Security-Policy: frame-ancestors <customer-domain>` based on the customer's registered domains. The embedding site passes an auth token (for B2B authenticated users) or relies on the guest cookie (for anonymous visitors) to the iframe URL.
5. **Data leak prevention and triage**: Anonymous channels are parented under the `csitea` workspace (or the respective B2B customer's tenant workspace), fully isolated from other tenants. Questions land in a designated 'Triage' view for staff, populated by a materialized view or tag queries, ensuring they never pollute unrelated tenant channels.
6. **Order and payment flow & Metering**: Generate payment intents via the payment provider using product references mapped from `csi-rel`. A buyer gains access to a paid private channel: this requires a member-only channel enforced by the hub, a `channel-guest` role, and a payment webhook that adds the buyer as a member. Token usage is counted per customer and per channel/agent, enforcing token limits. Price is calculated as metered cost (cloud spend + LLM tokens, knowing the cost per token per model/provider) plus a margin, from which invoices are built.

### Owner Questions

1. **Who answers the public questions?**
   - A. Only an AI agent initially, escalating to a human if it cannot answer.
   - B. Only human staff.
   - C. Both an agent and a human are present in the channel from the start.
   - **Recommendation:** A (Provides immediate responses and saves human time for complex queries).
2. **Which agents can see the visitor's private channel?**
   - A. Only a specialized sales/support agent.
   - B. Any agent the owner explicitly invites.
   - **Recommendation:** A (Keeps sales logic isolated and reduces token usage for general agents).
3. **What margin should be applied to the metered cost?**
   - A. A single fixed percentage margin for all customers.
   - B. A variable margin based on the customer's subscription plan.
   - **Recommendation:** A (Simpler to implement and explain for the initial launch).
4. **Which payment provider should we use?**
   - A. Stripe.
   - B. PayPal.
   - C. Bank transfer / Manual invoicing only.
   - **Recommendation:** A (Industry standard for platform payments with robust API support).
