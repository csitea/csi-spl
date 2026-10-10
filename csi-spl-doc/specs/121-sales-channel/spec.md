# 121 Sales channel: selling Csitea.net services on spool-hub.ai

## 1. The owner's words

The design is driven by the following verbatim requirements from HUM-10 (workspace csitea, topic e001c851):

- msg b667a87b: "We need to make spoolhop.ai a kind of digital distribution channel for the selling of the services of the SiteNet."
- msg 8bc8d70f: "Csitea.net"
- msg 3cf34194: "That is, public (aka unauthenticated) customers should be able to ask questions about our services."
- msg 84910839: "Some kind of pop-up in the .net site, which will allow a public user to connect to a strictly restricted channel dedicated to that new customer, so nobody else could see what this customer has been chatting about, except, of course, me as the owner of citia.net"

Every requirement below traces back to these messages or is explicitly deferred as an owner question.

## 2. Public questions and per-visitor private channels

The core requirement is that signed-out visitors on spool-hub.ai and csitea.net can ask questions about Csitea.net's services. 

### 2.1 The embeddable chat pop-up
The chat pop-up (widget) is available on spool-hub.ai and is also embedded on the `csitea.net` website (which belongs to the `csi-web` repository).
- **Embed method:** It embeds via an `iframe` pointing to a dedicated route (e.g. `https://spool-hub.ai/embed/chat`).
- **CSP and CORS:** The spool-hub.ai hub must serve the `Content-Security-Policy: frame-ancestors https://csitea.net` header, and the API endpoints need `Access-Control-Allow-Origin: https://csitea.net` to permit the embed.

### 2.2 Per-visitor isolation
Each anonymous visitor is assigned their OWN private channel inside the `csitea` workspace.
- **Visibility:** This channel is visible only to that specific visitor and the workspace owner. Which agents may also see it is an owner question.
- **Enforcement:** Per-visitor isolation is enforced strictly by the hub at the Postgres Row-Level Security (RLS) level. Policies on the `channels` and `messages` tables will verify the visitor's anonymous session ID against the channel's designated visitor ID, meaning the UI cannot bypass it.
- **Privacy:** What a visitor types never shows up in any tenant workspace other than `csitea`. Tenant and workspace data is never exposed to the visitor.

### 2.3 Abuse, spam, and rate limits
Unauthenticated askers are subject to strict limits to prevent abuse. We reuse context from the demo workspace pattern:
`git grep -n -i demo origin/master -- csi-spl-api csi-spl-wui | head`
Like `DemoPostsPerMinute` and `DemoMaxStay`, visitors will face rate limits on message creation and a time-to-live on their anonymous session.

### 2.4 Staff visibility
When a visitor asks a question, it lands in their dedicated private channel within the `csitea` workspace. Staff (the owner) is notified via a central triage view or a direct mention in a dedicated triage channel. Who answers initially (human or agent) is an owner question.

## 3. What is sold (Service Catalogue)

The sales channel offers Csitea.net's service catalogue. A catalogue entry has the following shape:
- **Name**: A clear title of the service.
- **Short description**: A brief explanation of the value provided.
- **Price model**: How the service is billed (e.g., fixed price, hourly, retainer).
- **Delivery timeline**: Expected turnaround or SLA.

The actual services and their prices are deferred as owner questions.

## 4. Where it shows on spool-hub.ai

The service catalogue is presented to signed-out visitors and is indexable by search engines, following the public-page pattern of spec 116.
Routes:
- **The public front page**: Exposed as part of the public landing experience (`/login`), reusing components built in spec 116.
- **The blog**: Integrated within `/blog` posts or sidebars.
- **The catalogue page**: A dedicated new route (e.g., `/services`) showcasing the full list.

## 5. Order and payment flow

When a buyer wishes to proceed:
1. **Order flow**: The visitor selects a service and initiates an order from the chat widget or catalogue page.
2. **Invoicing & Confirmation**: A quote or invoice is generated. Upon payment, the order is confirmed in the chat channel.
3. **Payment Options**: The payment provider is selected via an owner question.

Buyers remain public users and are not added as workspace members unless explicitly invited by the owner.

## 6. Reuse of csi-rel context

The existing product and billing work in `csi-rel` (`/opt/csi/csi-rel`: products, orders, payments) serves as context. The new sales channel will interact with the data models established there (e.g., product schemas, order state machines) without duplicating the domain logic.

## 7. Owner questions

These questions go to c-002, who will post them as one blocker.

1. **Who answers the public questions?**
   - A. Only an AI agent initially, which escalates to a human if it cannot answer.
   - B. Only human staff.
   - C. Both an agent and a human are present in the channel from the start.
   - **Recommendation:** A (Provides immediate responses while saving human time for complex queries).
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
   - **Recommendation:** A (Industry standard for platform payments with good API support).
