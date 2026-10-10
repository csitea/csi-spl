signed against 6eded1d95

### Section Review
- **Section 1 (The owner's words):** agree
- **Section 2 (Public questions and per-visitor private channels):** missing
- **Section 3 (What is sold):** missing
- **Section 4 (Where it shows on spool-hub.ai):** agree
- **Section 5 (Order and payment flow):** change (needs flow for Addendum 4 B2B monetization)
- **Section 6 (Reuse of csi-rel context):** agree
- **Section 7 (Owner questions):** change (needs options, recommendations, and Addendum 4 question)

### Concrete Proposals for Missing Elements

1. **Anonymous-visitor identity**: A cryptographically signed HttpOnly cookie (`guest_token`) containing a UUID is issued upon first interaction, with a 30-day lifetime. On a new device, a new independent visitor identity is created (no cross-device linking without a full account).
2. **Per-visitor isolation at the RLS level**: Add a `visitor_id` column to `channels` and `messages`. The Postgres RLS policy for the anonymous role asserts `visitor_id = current_setting('request.jwt.claim.visitor_id', true)`. The RLS-negative test must prove that an anonymous visitor querying `messages` receives only their own channel's messages, while another visitor's token returns 0 rows. (The owner role reads all).
3. **Abuse, spam, and rate limits**: Enforce bucketed rate limits in Redis: 5 msgs/min per visitor, 20 msgs/hour per IP, with a max message size of 1000 characters. For B2B embeds (Addendum 4), rate limits are scoped per customer API key/tenant. Use a ReCAPTCHA v3 or similar invisible challenge upon session start to thwart bots.
4. **Embed security and mechanics (Addendum 4)**: Embed via `iframe`. `spool-hub.ai` dynamically serves `Content-Security-Policy: frame-ancestors <customer-domain>` based on the customer's registered domains. The embedding site passes an auth token (for B2B authenticated users) or relies on the guest cookie (for anonymous visitors) to the iframe URL.
5. **Data leak prevention and triage**: Anonymous channels are parented under the `csitea` workspace (or the respective B2B customer's tenant workspace), fully isolated from other tenants. Questions land in a designated 'Triage' view for staff, populated by a materialized view or tag queries, ensuring they never pollute unrelated tenant channels.
6. **Order and payment flow**: Generate payment intents via the payment provider using product references mapped from `csi-rel`. Order state transitions occur only upon receiving cryptographically verified webhooks from the payment provider. For Addendum 4, integrate token and agent time metering by emitting usage events to the billing engine for B2B customers. (Code from `csi-rel` is never copied, only its data shapes are referenced).

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
3. **What are the actual services and their prices?**
   - A. Define a small initial list directly in the hub's database.
   - B. Sync from an external catalogue or document.
   - **Recommendation:** A (Keeps the implementation simple and native to the hub).
4. **Which payment provider should we use?**
   - A. Stripe.
   - B. PayPal.
   - C. Bank transfer / Manual invoicing only.
   - **Recommendation:** A (Industry standard for platform payments with robust API support).
5. **(New) Does the 121 spec include selling access to single private channels? (Addendum 4)**
   - A. Yes, offer a paid private channel.
   - B. No, keep channel access free and only sell services/tokens.
   - **Recommendation:** A (Aligns directly with the B2B model and provides an immediate monetization path for agent access).
