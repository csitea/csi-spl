# SPEC: They pay GCP, you provision (later enterprise SKU)

> Generated from qto doc `c843c4b6-5980-4338-bb3a-ffc85f61734d`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Status: **later** — not M1, not M2 public MVP.  
M2 stays: they pay **you** (csi-rel payment copy); you run a **multi-tenant**
hub on **your** Cloud Run.

This SKU: they put a **credit card on Google Cloud**; **you** still run
terraform / `./run` and create the objects. You do **not** put their card
on *your* billing account (that is reseller-only).

---

<a id="ws-doc-022338b3-3543-49c9-85ac-7b8229783e4a"></a>
## 0. Who this is *not* for (non-technical buyers)

**Do not ask a founder / office manager to “create a GCP account and put
the company card on Google.”** That is several consoles, IAM, billing
accounts, and org policy. They will bounce. **That buyer is M2 only.**

| Buyer | What they see | What they pay |
|---|---|---|
| **Everyone (M2)** | Your site: social login + **one checkout** (copy csi-rel). Like any SaaS. | **You.** Card on *your* page. No Google Cloud. |
| **Their IT / cloud team (this SKU)** | A **short grant checklist** (below), not terraform. | Google (infra) + you (M4 seats later). |

Website copy for normal humans (M2):

> Sign in with Google (or Facebook / Microsoft / LinkedIn / xAI). Pick a
> plan. Pay. You get a private hub address and a key. Your agents talk.
> You never open Google Cloud.

Website copy for the dedicated SKU (only shown to “use our GCP”):

> Your cloud team creates a billing account (or uses the one you already
> have). They click **Grant access** so Spool can create a project on
> *your* bill. We install the hub. You still pay Spool a license; Google
> bills the machines.

If they do not already live in Google Cloud, **do not sell dedicated.**
Hosted M2 is the product that succeeds.

The only *simpler* “they pay Google” path later is **Cloud Marketplace
Subscribe** (Google already has their billing). Still not for people with
zero GCP. Optional; not M2.

<a id="ws-doc-a45c3285-c5b3-43eb-951c-78d954ff33a6"></a>
### Cloud Marketplace in one page

You list **Spool** as a **SaaS** product in Producer Portal (partner
onboarding, weeks). Customer in Google Cloud Console clicks **Subscribe**,
picks a plan (monthly seats fit “subscription”). Google **charges their
existing GCP billing account** and **pays you** (payout ~21st of month,
minus Marketplace fee — currently on the order of a few percent of the
software price). You get a **Procurement API** “account active” event and
**provision the tenant** (same as M2 webhook). Usage-based seats: you
**report metrics** to Service Control (user-count, bot-count).

That is **software billed by Google**, not “they create a project and we
terraform.” Infra for **hosted** M2 still sits on **your** Cloud Run (you
still pay Run/SQL). Marketplace does **not** by itself put Cloud Run in
*their* project — that remains the dedicated IAM-grant SKU.

Buyer still must **already have GCP billing**. Non-technical users without
a Cloud org still use **M2 card-on-you**.

<a id="ws-doc-7c05fdcb-692e-4880-ad99-0390490a432f"></a>
## 1. Business case (why bother)

| | **M2 hosted SaaS** (they pay you) | **This SKU: BYO GCP billing** |
|---|---|---|
| Who Google charges | You | **Them** |
| Your margin | M2 tenant fee (+ **M4 seats** when that ships) + infra | **M4 seats**; infra is their GCP bill |
| Credit risk | You float GCP until they pay | Google floats it; they fight Google on spend |
| Procurement | Card on *your* checkout | Card on **GCP**; legal likes “data in our cloud” |
| Isolation | `tenant_id` on shared Cloud Run | **Dedicated project** (or folder) per customer |
| Ops | One cluster, many tenants | N projects; your SA must keep working |
| Lock-out | You own the project | They can remove your SA tomorrow |
| Fit | SMB / public MVP | Enterprise, regulated, “run in our org” |

**Do both, sequenced:** M2 pays the lights. This SKU is for buyers who
refuse to put data on your bill or want GCP invoice/commit.

You cannot honestly say “enter your GCP card in *my* Stripe.” Either they
pay you (M2) or they pay Google (this). Mixing cards is how you get
chargebacks and ToS pain.

---

<a id="ws-doc-1c231f6e-2c1d-4bb3-8555-9fa57cb699ee"></a>
## 2. How GCP actually lets you do it

You never see the PAN. They create a **Billing Account** (card or invoice).
They grant **your deploy identity** rights to **spend that account** and
**create resources**.

<a id="ws-doc-dd28717a-1045-47bf-a4af-7315b021373e"></a>
### Recommended grant (least privilege)

Customer (their Org Admin / Billing Admin):

1. Billing account `B` with their card.
2. Folder `spool/` (or a project they pre-create).
3. Invite your **automation SA** (from your org, or a SA they create and
   hand to you):
   - on **B**: `roles/billing.user` (attach new projects to B) — **not**
     `billing.admin`
   - on the **folder**: `roles/resourcemanager.projectCreator` +
     `roles/resourcemanager.folderEditor` (or Owner on one project if they
     refuse folder create)
   - after project exists: `roles/editor` or a custom role that can Cloud
     Run, Cloud SQL, GCS, Secret Manager, Artifact Registry — **not**
     `billing.admin`, **not** org policy admin unless you must

You:

4. Same **007 terraform steps** as hosted, targeting **their**
   `project_id` / folder (cnf per tenant). `do_spl_tenant_create` is
   replaced by `do_spl_dedicated_apply` (owner go).
5. DNS: either they delegate a zone, or you CNAME `customer.spool-hub.ai`
   → their Cloud Run (their cert). Product DNS stays cnf.
6. Your SA key/WIF lives in **your** Secret Manager; their card never does.

If they will only attach billing to a project **they** created: skip
projectCreator; they paste `project_id` + grant Editor; you apply 007
inside it.

<a id="ws-doc-82a0ad3d-e1a9-4b11-be0a-4764b468721d"></a>
### Project IDs (`{org}-{app}-{env}-{YYYYMMDDHH}`)

Mint GCP project ids as:

`{org}-{app}-{env}-{YYYYMMDDHHmm}`  (**M4**, stamp = **UTC minute of buy**)

Canonical example: **`csi-spl-dev-202609171743`**
(`csi` + `spl` + `dev` + `2026-09-17 17:43` UTC).

Length 24. GCP max 30. `prd`: `csi-spl-prd-202609171743`.

**Collision with a reserved/short global id is negligible.** `csi-spl-dev`
alone may be taken; the hour stamp is not. Same org+app+env **same UTC minute**, two creates: retry next minute or a 2-char nonce.

Stamp is **minute of buy** (`YYYYMMDDHHmm`), M4. Same org+app+env **same
UTC minute** → retry.

**Two customers may pick the same `org` and `app`.** Allowed.
`acme`+`bot` at 12:00 UTC and another at 13:00 →
`acme-bot-prd-2026100112` vs `acme-bot-prd-2026100113`. Same hour → retry.

**The unique public name is the DNS tenant id**, not org/app:

| Token | Unique across customers? |
|---|---|
| `org` (3 letters) | **No** |
| `app` (3 letters) | **No** |
| GCP `project_id` | Yes (hour stamp; Google-global) |
| **DNS tenant id** | **Yes** — Host on `*.spool-hub.ai` / `*.dev.spool-hub.ai`. First-come; taken slug → 409. |

Pretty host is **not** derived from org+app (that would collide). Customer
picks or we mint a distinct slug. Store `tenant_id` (DNS slug), `org`, `app`,
and `project_id` as **separate** fields.

This does **not** change M2 hosted (no GCP project per customer).



<a id="ws-doc-29923b47-755f-44ef-b65c-89316056feb5"></a>
### What their IT actually clicks (no terraform on their desk)

We send **one page** (or a Google “grant this SA” link), not a runbook:

1. Open Google Cloud Billing (they already have it, or Google’s “add a
   card” wizard — **their** IT, not our consumer checkout).
2. Confirm the company card / invoice is on that billing account.
3. Click **Grant** (we pre-fill): give Spool’s deploy account
   “Billing user” on that account and “create project” on one folder
   **or** “Editor” on one empty project they created.
4. Paste the project id (or we create it). We apply. They get the hub URL
   by email like M2.

If step 3 is refused, **fall back to hosted M2**. Do not debug IAM on a
sales call with a non-technical buyer.

<a id="ws-doc-70e426ac-0203-4a8a-a95e-15eae57bfc52"></a>
### What does not work

- Putting their card on **your** Cloud Billing (unless you are a **Google
  Cloud Partner / reseller** — different contract, PCA, months).
- One shared Cloud Run project with *their* billing (billing is
  per-project; mixed tenants on one bill is *your* SaaS, not BYO).
- Asking them to type a GCP card into the M2 Stripe checkout.

<a id="ws-doc-57575665-04c0-459a-9c20-d1b34b8c66fc"></a>
### Partner / Marketplace (optional later)

- **Reseller**: you bill them, you pay Google, they still think it’s
  “GCP.” Heavy.
- **Cloud Marketplace SaaS**: Google charges their GCP bill, pays you;
  you provision. Good if you already have Marketplace; not M2.

---

<a id="ws-doc-2c73e346-e383-4009-982c-3f67641046b9"></a>
## 3. Product rules

- **SKU name** (cnf): `hosted` (M2) vs `dedicated` (this).
- Dedicated = **one GCP project per customer** (or per env). Same spool
  protocol; **not** shared `tenant_id` rows on your hub (or a hub that
  only that project runs).
- Your runbooks still **owner go** for apply. Their IAM grant is the
  “credit card present” signal, not Stripe.
- If they revoke the SA, mesh in that project dies; your hosted M2
  tenants are unaffected.
- Quote **their** GCP SKUs (Run, SQL, GCS) as a separate estimate.
  **Your software fee (when M4 exists) is monthly licenses per user and
  per bot** (`SPEC-spool-m4-seats.md`). Not an M2 change.

---

<a id="ws-doc-acec7f1c-4416-4f33-82d2-b34573c8aad9"></a>
## 4. When

After M2 is selling hosted. Do not block public MVP on folder grants.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T23:55:00Z -->
