# SPEC: They pay GCP, you provision (later enterprise SKU)

Status: **later** — not M1, not M2 public MVP.  
M2 stays: they pay **you** (csi-rel payment copy); you run a **multi-tenant**
hub on **your** Cloud Run.

This SKU: they put a **credit card on Google Cloud**; **you** still run
terraform / `./run` and create the objects. You do **not** put their card
on *your* billing account (that is reseller-only).

---

## 1. Business case (why bother)

| | **M2 hosted SaaS** (they pay you) | **This SKU: BYO GCP billing** |
|---|---|---|
| Who Google charges | You | **Them** |
| Your margin | Software + infra spread | Software / retainers only (infra is their bill) |
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

## 2. How GCP actually lets you do it

You never see the PAN. They create a **Billing Account** (card or invoice).
They grant **your deploy identity** rights to **spend that account** and
**create resources**.

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

### What does not work

- Putting their card on **your** Cloud Billing (unless you are a **Google
  Cloud Partner / reseller** — different contract, PCA, months).
- One shared Cloud Run project with *their* billing (billing is
  per-project; mixed tenants on one bill is *your* SaaS, not BYO).
- Asking them to type a GCP card into the M2 Stripe checkout.

### Partner / Marketplace (optional later)

- **Reseller**: you bill them, you pay Google, they still think it’s
  “GCP.” Heavy.
- **Cloud Marketplace SaaS**: Google charges their GCP bill, pays you;
  you provision. Good if you already have Marketplace; not M2.

---

## 3. Product rules

- **SKU name** (cnf): `hosted` (M2) vs `dedicated` (this).
- Dedicated = **one GCP project per customer** (or per env). Same spool
  protocol; **not** shared `tenant_id` rows on your hub (or a hub that
  only that project runs).
- Your runbooks still **owner go** for apply. Their IAM grant is the
  “credit card present” signal, not Stripe.
- If they revoke the SA, mesh in that project dies; your hosted M2
  tenants are unaffected.
- Quote **their** GCP SKUs (Run, SQL, GCS) as a separate estimate; your
  fee is license/support.

---

## 4. When

After M2 is selling hosted. Do not block public MVP on folder grants.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T22:15:00Z -->
