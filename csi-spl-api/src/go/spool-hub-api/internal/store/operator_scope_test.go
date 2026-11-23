package store

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strings"
	"testing"
)

// operatorCallers is every store method allowed to run under the operator
// RLS scope (asOperator: every tenant's rows), with why the tenant cannot be
// named first (specs/017 FR-SEC-014). Some ARE reached from an HTTP route;
// each such route is keyed by something other than a tenant id the caller
// could choose. A new asOperator caller fails TestOperatorScopeCallers until
// it is added here with its reason, i.e. until someone has reviewed it.
var operatorCallers = map[string]string{
	"Sweep":                      "retention sweeper (hub goroutine), global by design; no route",
	"ClaimDueTopicLoops":         "discussion loop time ticker (spec 182 4.2 step 5, row L1; the goroutine is row L2's runTopicLoopTimer): claims the due loops of every workspace; no route",
	"ApplyChannelMove":           "channel workspace move P4 (spec 169 T5, SPL-4595): one transaction writes <DST> and deletes from <SRC>; owner-only operator endpoint (T7)",
	"ChannelMoveProofRead":       "channel workspace move P7 (spec 169 T7, SPL-4598): the proofs read <SRC> and the hub-wide tables, READ ONLY, in one snapshot; owner-only operator endpoint, behind the GO",
	"ApplyChannelCopy":           "channel workspace copy (spec 169 T11, SPL-4595): one transaction reads <SRC> and writes <DST>, <SRC> untouched; owner-only operator endpoint (T7)",
	"AutoMarketingChannels":      "blog share sweep (spec 090, SPL-1634, hub goroutine): the active auto-publish channels of every workspace, never a token; no route",
	"StuckMarketingPosts":        "blog share sweep (spec 090, SPL-1634, hub goroutine): fails posts left dispatching by a dead hub, never retried; no route",
	"MetaMarketingChannels":      "Meta dispatch sweep (spec 090 T034, SPL-4424, hub goroutine): the active Facebook Page and Instagram channels of every workspace, never a token; no route",
	"XMarketingChannels":         "X dispatch sweep (spec 090 X row, SPL-5194, hub goroutine): the active X channels of every workspace, never a token; no route",
	"LinkedInPageChannels":       "LinkedIn Company Page dispatch sweep (spec 090 T041, SPL-5258, hub goroutine): the active LinkedIn Page channels of every workspace, never a token; no route",
	"ClaimGcalConnection":        "google calendar sync cycle (spec 149 B2/B6a, SPL-3170, hub goroutine): leases the connection due longest of every workspace, never a token; no route",
	"GcalHubCalendars":           "google calendar sync cycle (spec 149 2.10, SPL-5782, hub goroutine): the hub calendar ids of one Google account, which spans workspaces, so the read-only half skips them; never a token; no route",
	"GcalConnectionByWatch":      "google calendar push (spec 149 B2/B7, SPL-3170): the push names a channel id, not a workspace; never a token",
	"ContactsSyncOf":             "contacts erase-one (spec 154 2.6, seat note N4, SPL-3447): the person's one binding may be in another workspace, invisible from the session's; keyed by the session's own human, never a contact value",
	"takeContactsSyncOff":        "contacts switch-on (spec 154 2.2 step 3, SPL-6279): the person's binding that is off may be in another workspace, invisible from the session's; deletes it only while off and inserts the session's own, one transaction, keyed by the session's own human and workspace, never a contact value",
	"ClaimContactsSync":          "contacts sync cycle (spec 154 v1.2 2.5 B8a, SPL-3460, hub goroutine): leases the binding due longest of every workspace whose Google connection is connected, never a contact value; no route",
	"MarkContactsPurgePending":   "contacts 30-day purge (spec 154 2.6 W4, SPL-3447, hub sweeper goroutine): the status line of the bindings of the persons the purge door named, in any workspace, never a contact value; no route",
	"pruneCommitted":             "Sweep's committed-delivery prune (spec 059 S4), global by design; no route",
	"backfillSearchSig":          "Sweep's search_sig backfill (rdb 0135): signs pre-trigger long rows of every tenant, global by design; no route",
	"ConsumerLag":                "consumer lag report (spec 059 S4), fleet-wide by design; no route",
	"SweepClones":                "act-as clone expiry (hub sweeper goroutine), global by design; no route",
	"ClaimInvoiceReminders":      "monthly invoice reminder tick (spec 181 B12, hub goroutine): every workspace's unpaid invoice past its due date, claimed once; no route",
	"OverdueInvoices":            "GET /v1/operator/invoices/overdue (spec 181 B13, gap G14): every workspace's unpaid invoice past its due date, READ ONLY; the operator workspace's admin only (operatorActor)",
	"SweepDemo":                  "demo stay sweep (specs/077 T009, hub sweeper goroutine): ended demo seats of the cnf demo workspace, then their humans only when no membership is left anywhere; no route",
	"SweepMemberActivity":        "Activity-log auth-row retention sweep (hub sweeper goroutine), global by design; no route",
	"RecordUseMinute":            "hours of use (rdb 0289, SPL-5709): hub_use_minutes is the person's row across every workspace, no tenant_id; the workspace row stays inTenant",
	"HubUseMinutesOf":            "hours of use (rdb 0289, SPL-5709): hub_use_minutes for the members of the caller's workspace only, behind its owner/admin gate",
	"HubUseTotal":                "hours of use (rdb 0289, SPL-5709): the hub total over every workspace, the operator workspace's admins only",
	"SweepUseMinutes":            "hours-of-use retention sweep (rdb 0289, hub sweeper goroutine), global by design; no route",
	"PruneLifecycleEvents":       "agent_lifecycle_events 90-day retention (hub sweeper goroutine, spec 063 12), global by design; no route",
	"PrunePerfSamples":           "wui_perf_samples 30-day retention (hub sweeper goroutine, spec 066 4), global by design; no route",
	"PruneBoxStats":              "box_stats 30-day retention (hub sweeper goroutine, rdb 0117), global by design; no route",
	"SweepFileStreams":           "file_stream_lines 7-day retention (hub sweeper goroutine, spec 160 3.7 row B6): reads only the ids of the workspaces that keep lines; every delete runs in that workspace's own scope; no route",
	"PruneFileStreamGlobAudit":   "file_stream_glob_audit 365-day retention (hub sweeper goroutine, spec 160 3.8.9 row B9, rdb 0242): one delete of the rows past the retention, no row read; no route",
	"PruneBoxBeats":              "box_beats 2-day retention (hub sweeper goroutine, rdb 0147), global by design; no route",
	"RecordSamples":              "lane_op fleet_tokens_push (spec 140 3.4, rdb 0199): the instance's estate rows (no tenant_id) under the pushing box's session box; only a box of the operator workspace reaches it",
	"ListBuckets":                "GET /v1/operator/fleet-tokens (spec 140 3.5) for the operator admin / service account, and the push's surge check: the instance's estate rows, no tenant_id",
	"ListDays":                   "fleet token daily rollups (spec 140 3.6, rdb 0199): the instance's estate rows, no tenant_id; no route",
	"WorkspaceTokenMonth":        "GET /v1/tenant/costs (spec 140 3.10, rdb 0229): the fleet burn rows have no tenant_id under RLS (operator scope, like 0199); the read filters on work_tenant, the hub passes the caller's own workspace (any member) or every one (the operator workspace's admin only)",
	"PruneOldBuckets":            "fleet token rollup + 30/365-day retention (hub sweeper goroutine, spec 140 3.6), global by design; no route",
	"RepriceUnpriced":            "spool fleet-tokens-reprice (SPL-2405, spec 140 T010): prices the instance's unpriced estate minutes (rdb 0199, no tenant_id) of named models once; operator action do_spl_token_burn_reprice only, no route",
	"CreateCategory":             "POST /v1/operator/categories (spec 143 4.5, rdb 0204): one node of the instance's estate tree (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"UpdateCategory":             "PUT /v1/operator/categories/{path...} (spec 143 4.5, rdb 0204): one node of the estate tree by path (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"CategoryTokens":             "GET /v1/reporting/tokens/by-category (spec 143 4.4): the instance's token burn (rdb 0199, no tenant_id) joined with the requests of the operator workspace only (tenant_id = the hub's operator tenant, never the caller's choice); only the operator admin / service account (fleetLoadCaller) reaches it",
	"ListPaidItems":              "GET /v1/operator/fleet-tokens/paid and the effective-price read (SPL-2342, rdb 0205): the operator's paid items, the instance's estate rows (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"CreatePaidItem":             "POST /v1/operator/fleet-tokens/paid (SPL-2342, rdb 0205): one estate row (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"UpdatePaidItem":             "PATCH /v1/operator/fleet-tokens/paid/{id} (SPL-2342, rdb 0205): one estate row by id (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"DeletePaidItem":             "DELETE /v1/operator/fleet-tokens/paid/{id} (SPL-2342, rdb 0205): one estate row by id (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"ListCostEntries":            "GET /v1/operator/cost-entries (SPL-4383, rdb 0245): the operator's Cloud infra and HR cost entries, the instance's estate rows (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"CreateCostEntry":            "POST /v1/operator/cost-entries (SPL-4383, rdb 0245): one estate row (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"DeleteCostEntry":            "DELETE /v1/operator/cost-entries/{id} (SPL-4383, rdb 0245): one estate row by id (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"CostLabelMaster":            "GET /v1/operator/cost-entries and the cost reads (SPL-5546, rdb 0285): the estate's master label locale, one estate row (no tenant_id); the cost entries' doors (costEntryGate) and GET /v1/tenant/costs reach it",
	"CostEntryLabels":            "GET /v1/operator/cost-entries (SPL-5546, rdb 0285): every cost entry's labels per locale, estate rows (no tenant_id); the cost entries' doors (costEntryGate) reach it",
	"SetCostEntryLabels":         "PATCH /v1/operator/cost-entries/{id}/labels (SPL-5546, rdb 0285): one estate entry's labels per locale (no tenant_id); costs.write in the operator workspace or the operator write gate (costEntryGate)",
	"CostEntryLabelMarks":        "GET /v1/operator/cost-entries (SPL-6141, rdb 0303, spec 123 16.6.4): each estate entry's label rows' origin and stale mark (no tenant_id, no text); the cost entries' doors (costEntryGate) reach it",
	"SetMachineCostLabels":       "the hub's translation on save and agy's review route (SPL-6141, rdb 0303, spec 123 16.6.4): machine label rows of one estate text or hr component (no tenant_id), a hand row skipped in SQL; the operator write gate reaches it",
	"MissingCostLabels":          "the hub's fill of the missing cost labels (SPL-6141, spec 123 16.6.2 point 3): every estate text and hr component short of a locale (no tenant_id, no amount); the operator write gate reaches it",
	"UnreviewedCostLabels":       "the nightly review read (SPL-6141, spec 123 16.6.3): the estate's unreviewed machine label rows (no tenant_id, no amount); only the operator service account reaches it",
	"CostLabelsIn":               "GET /v1/tenant/costs (SPL-5546, rdb 0285): the estate entries' labels in the reader's locale, text only (no amount); the membersActor costs.read gate reaches it, and a workspace answer shows only the labels of items split to it",
	"HRComponentLabelsIn":        "GET /v1/operator/hr-components (SPL-5546, rdb 0285): the hr components' labels in the reader's locale, estate rows (no tenant_id); the cost entries' doors (costEntryGate) reach it",
	"ListHRComponents":           "GET /v1/operator/hr-components (SPL-5433, rdb 0280): the hr cost components, estate rows (no tenant_id); the cost entries' doors (costEntryGate) reach it",
	"ListHRPeople":               "GET /v1/operator/hr-people and the hr line checks (SPL-5433, rdb 0280): estate rows (no tenant_id); the names only with app.costs_names for a costs.write caller",
	"CreateHRPerson":             "POST /v1/operator/hr-people (SPL-5433, rdb 0280): one estate person and its name (no tenant_id); a costs.write member of the operator workspace only",
	"CostPeriodState":            "GET /v1/operator/cost-periods/{month} and the hr writes' lock check (SPL-5433, rdb 0280): one estate month's lock (no tenant_id)",
	"SetCostPeriod":              "POST /v1/operator/cost-periods/{month}/close|reopen (SPL-5433, rdb 0280): one estate month's lock (no tenant_id); the operator admin / service account (fleetLoadCaller) only",
	"ListHRRates":                "GET /v1/operator/hr-rates and GET /v1/operator/hr-payroll/{month} (SPL-5433 step c, rdb 0284): a year's employer contribution rates, estate rows (no tenant_id); the hr reads' doors",
	"SetHRRate":                  "PUT /v1/operator/hr-rates/{year}/{component} (SPL-5433 step c, rdb 0284): one estate rate (no tenant_id); costs.write (costEntryGate) or the operator admin",
	"DeleteHRRate":               "DELETE /v1/operator/hr-rates/{year}/{component} (SPL-5433 step c, rdb 0284): one estate rate (no tenant_id); costs.write (costEntryGate) or the operator admin",
	"ListHRWorkerRates":          "GET /v1/operator/hr-worker-rates and GET /v1/operator/hr-payroll/{month} (SPL-5433 step d, rdb 0286): a year's employee share bands, estate rows (no tenant_id); the hr reads' doors",
	"SetHRWorkerRates":           "PUT /v1/operator/hr-worker-rates/{year}/{kind} (SPL-5433 step d, rdb 0286): one year's bands of one share (no tenant_id); costs.write (costEntryGate) or the operator admin",
	"ListHRTaxCards":             "GET /v1/operator/hr-tax-cards and the payroll's worker side (SPL-5433 step d, rdb 0286): estate rows (no tenant_id), app.costs_names set; a costs.write caller only",
	"SetHRTaxCard":               "PUT /v1/operator/hr-tax-cards/{person_id}/{year} (SPL-5433 step d, rdb 0286): one estate tax card (no tenant_id), app.costs_names set; a costs.write caller only",
	"DeleteHRTaxCard":            "DELETE /v1/operator/hr-tax-cards/{person_id}/{year} (SPL-5433 step d, rdb 0286): one estate tax card (no tenant_id), app.costs_names set; a costs.write caller only",
	"ListHRPayslips":             "GET /v1/operator/hr-payroll/{month}'s worker side (SPL-5433 step d, rdb 0286): estate rows (no tenant_id), app.costs_names set; a costs.write caller only",
	"SetHRPayslip":               "PUT /v1/operator/hr-payslips/{month}/{person_id} (SPL-5433 step d, rdb 0286): one estate payslip (no tenant_id), app.costs_names set; a costs.write caller only",
	"DeleteHRPayslip":            "DELETE /v1/operator/hr-payslips/{month}/{person_id} (SPL-5433 step d, rdb 0286): one estate payslip (no tenant_id), app.costs_names set; a costs.write caller only",
	"CostAllocations":            "GET /v1/operator/cost-allocations and the cost reads (SPL-5291, rdb 0275): every estate item's split, operator-scope rows (no tenant_id) that name the workspaces a share goes to",
	"PutCostAllocation":          "PUT /v1/operator/cost-allocations and /v1/tenant/cost-allocations (SPL-5291, rdb 0275): one estate item's split across workspaces; a customer admin's write is checked against the stored split inside the transaction",
	"CostSplits":                 "GET /v1/operator/cost-splits and the cost reads (SPL-5768, rdb 0293): the instance's token and person splits, operator-scope rows (no tenant_id) that name the workspaces a share goes to",
	"PutCostSplit":               "PUT /v1/operator/cost-splits (SPL-5768, rdb 0293): one token or person split across workspaces, replaced in one transaction",
	"CostViewRules":              "GET /v1/operator/cost-view-rules and the cost reads (SPL-6086, rdb 0304): every workspace's view rules, operator-scope rows (no tenant_id) that name the workspace whose view it is",
	"PutCostViewRules":           "PUT /v1/operator/cost-view-rules (SPL-6086, rdb 0304): one workspace's view rules, replaced whole in one transaction",
	"CostEstateLineKnown":        "PUT /v1/operator/cost-allocations (SPL-5291): whether any month holds the estate item (cost_lines, tenant_id NULL) has no tenant to name; answers a bool, never a row",
	"ListFleetDeskBoxes":         "GET /v1/operator/fleet-desks (spec 158 4.2.2, rdb 0230): the instance's fleet desk boxes, estate rows (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"PutFleetDeskBox":            "PUT /v1/operator/fleet-desks/{box} (spec 158 4.2.2, rdb 0230): one estate row by box id (no tenant_id), only for a box with a live pin in the operator workspace; only the operator admin / service account (fleetLoadCaller) reaches it",
	"DeleteFleetDeskBox":         "DELETE /v1/operator/fleet-desks/{box} (spec 158 4.2.5, rdb 0230): one estate row by box id (no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"ListFleetWorkspaces":        "GET /v1/fleet/workspaces (spec 158 4.2.3, row T7): every workspace with fleet_seating true and whether the box is pinned in each, so no single tenant can be named first; only a listed fleet desk box that proved its operator-workspace key reaches it (fleetBoxAdmit)",
	"FleetVendorDays":            "GET /v1/operator/fleet-tokens/effective (SPL-2342): the fleet token burn per day and vendor (rdb 0199 estate rows, no tenant_id); only the operator admin / service account (fleetLoadCaller) reaches it",
	"WorkspaceBurnDays":          "GET /v1/tenant/costs ai_share (SPL-3810, spec 143 costs-redesign 3.3.1): the fleet burn rows per day, agent type and work_tenant (rdb 0199/0229, no tenant_id); the share needs every workspace's tokens as its denominator, and only the asked workspace's shaped share leaves the store",
	"secondFXDays":               "GET /v1/tenant/costs ai_paid / ai_share (SPL-3810): the second currency's hub-wide daily rates (rdb 0200, no tenant column); reads no tenant's row",
	"FleetPaidFXRate":            "GET /v1/operator/fleet-tokens/effective (SPL-2342): one hub-wide exchange rate (rdb 0200, no tenant column) for a paid item's currency; reads no tenant's row",
	"SetTenantHost":              "tenant host reconciler (operator action / hub-tenant); no route",
	"Memberships":                "auth session (026 tenant from identity): the SESSION's own human_id, across that human's tenants",
	"LiveInviteTenants":          "sign-in that named no tenant (SPL-1230): the SESSION's own provider-verified address, its live invites across tenants",
	"noMemberElsewhere":          "open demo admission (specs/077 T007): the signing-in identity's OWN human, whether it is a member outside the demo workspace; a bool",
	"HoldCheckout":               "POST /v1/checkout: the tenant does not exist yet (slug hold)",
	"checkoutAsOperator":         "GetCheckout / CheckoutByProviderRef: unguessable checkout id or a verified webhook's provider ref",
	"ApplyPayment":               "verified payment webhook (signature checked before the store)",
	"SetClaimLink":               "paid webhook / claim mail, keyed by the checkout id",
	"ClaimCheckout":              "POST /v1/checkout/claim: checkout id + the claim secret's hash",
	"SubmitWorkspaceOrder":       "POST /v1/checkout/private-workspace (spec 181 B2): the tenant does not exist yet; the order creates it",
	"ListWorkspaces":             "GET /v1/operator/workspaces (spec 074): every workspace by design; only an admin of the operator workspace reaches it",
	"SetAgentCaps":               "PUT/DELETE /v1/operator/workspaces/{id}/agent-caps (spec 147, rdb 0212): writes ONE named workspace's caps + audit rows (WHERE tenant_id = $1); rdb 0212 lets only the operator scope write them; only an admin of the operator workspace reaches it",
	"OperatorTenant":             "which workspace is the operator one (rdb 0116, spec 074): one flagged row of the instance, unknown until read; returns its id only",
	"keyLiveElsewhere":           "POST /v1/pins/join (spec 073 T003, spec 108 3.1): whether a box key is live in any other workspace; a bool, never which workspace",
	"TenantsMissingPublicNotice": "retention sweeper + hub start (rdb 0173): which tenants lack the #public notice; a primary-key probe per tenant, returns tenant ids only; no route",
	"TenantsMissingIssueBacklog": "retention sweeper + hub start (rdb 0194): which tenants link their issues to the Issue backlog topic while it is missing; returns tenant ids only; no route",
	"ClaimOperatorTenant":        "hub start (spec 074): flags the cnf operator workspace while no row is flagged; no route",

	// spec 075 repo-edit (T06): the repo-doc edit queue, rdb 0142.
	"RepoDocEditsEnvDay":    "PUT /v1/docs/{path} (spec 075 repo-edit 5.1): the env-wide daily save cap; a count only, no row leaves",
	"ClaimRepoDocEdits":     "repo-edit worker (spec 075 T10, the env's one pusher, hub goroutine): claims due edits of every workspace; no route",
	"PushedRepoDocEdit":     "repo-edit worker: its verdict on a claimed edit, keyed by edit_id; no route",
	"RetryLaterRepoDocEdit": "repo-edit worker: its verdict on a claimed edit, keyed by edit_id; no route",
	"FailRepoDocEdit":       "repo-edit worker: its verdict on a claimed edit, keyed by edit_id; no route",
	"ConflictRepoDocEdit":   "repo-edit worker: its verdict on a claimed edit, keyed by edit_id; no route",
	"ReclaimRepoDocEdits":   "repo-edit worker: stuck-pushing reclaim of every workspace; no route",
	"PushedRepoDocEdits":    "repo-edit worker: the published sweep over every workspace's pushed edits; no route",
	"PublishRepoDocEdits":   "repo-edit worker: the published sweep, keyed by commit sha; no route",
	"NextRepoDocEditDue":    "repo-edit worker: when the earliest queued edit of any workspace falls due, its next wake-up; a timestamp only; no route",
	"RepoDocEditStatuses":   "repo-edit worker (T10): the 30-day overlay sweep, keyed by the edit_ids of bucket objects; statuses only; no route",
	"RepoDocOverlays":       "GET /v1/docs/{path} + tree.json (spec 075 T08): the newest live overlay of a repo doc path; the docs bucket is env-wide, every workspace reads the same doc",

	// spec 107 T007: the hours freeze sweep.
	"hoursSweepTenants":     "hours freeze sweep (hub sweeper goroutine): the workspace ids to sweep, each then swept in its own scope; no route",
	"BlockerTenants":        "blocker -> issue sweep (hub goroutine): the live workspace ids, each then swept in its own scope; no route",
	"pruneAgedHoursMinutes": "hours_minutes 45-day retention (spec 107 1.7, hub sweeper goroutine), global by design; no route",

	// spec 123 lane 4: the box feed of cost tracking.
	"PutCostDay":    "POST /v1/operator/cost/day (spec 123 4.3, 4.6): estate cost rows (tenant_id NULL) of one day and source; only the operator service account (operatorAuth) reaches it; answers counts, never a row",
	"CostMonthRead": "GET /v1/tenant/costs (spec 123 5.1, Q-1 = A): the estate cost rows (tenant_id NULL) have no tenant to name; only when the caller's workspace is the operator workspace (Estate set by the hub), and it reads that workspace's own rows beside them; any other workspace reads under inTenant",
	"CostCloudDays": "GET /v1/tenant/costs/cloud (SPL-4187, spec 123 5.5): one estate GCP project's lines (tenant_id NULL, source gcp) per day and kind have no tenant to name; the hub reaches it only for the operator workspace's admin, every other caller reads 403 before the store",
	"PutFXRates":    "POST /v1/operator/fx/rates (SPL-2108): hub-wide exchange rates (rdb 0200, no tenant column); only the operator service account (operatorAuth) reaches it; answers a count",
	"FXCurrencies":  "the second-currency setting's check and GET /v1/tenant/fx/currencies (SPL-2108): the quotes of the hub-wide rates (rdb 0200, no tenant column); reads no tenant's row",

	// spec 143 T025 + T027 (SPL-2788): the deploy record, rdb 0202 estate_deploys (no tenant column).
	"PutEstateDeploy":    "POST /v1/operator/deploys (spec 143 2.3.2): one workspace's deploy row (rdb 0267), written only by the operator scope; only the operator service account (operatorAuth) reaches it",
	"PutReleaseNotes":    "POST /v1/operator/release-notes (spec 171 Lane 2, SPL-5108): release_notes rows of the one workspace and repo the hub resolved (rdb 0267), written only by the operator scope once row B-3 adds RLS; only the operator service account (operatorAuth) reaches it",
	"LatestEstateDeploy": "the hub's deploy reconcile check (hub goroutine, spec 143 2.3.2): the newest deploy row of (tenant, env, component), WHERE tenant_id names the operator workspace; no route",
	"PutSoftwareProject": "PUT /v1/operator/workspaces/{id}/projects/{project} (spec 143 releases-projects.md 4.5, SPL-5772): one workspace's software_projects rows, which rdb 0266 lets only the operator scope write; only the operator service account (operatorAuth) reaches it",
	"PutWorkspaceRepo":   "PUT /v1/operator/workspaces/{id}/repos (spec 143 releases-projects.md 4.5, row B-6): one workspace's workspace_repos row, which rdb 0266 lets only the operator scope write; the slug check reads every workspace's rows so one repo stays in one workspace; only the operator service account (operatorAuth) reaches it",
	// spec 143 releases-projects.md row B-6b (SPL-5808): the hub's own GitHub sync, a hub goroutine of no workspace.
	"RepoSyncTargets":         "the repo sync loop (hub goroutine, row B-6b): every workspace_repos row it reads from GitHub, never a credential; no route",
	"PutRepoSyncState":        "the repo sync loop (row B-6b): the cursor and outcome on the one row it synced, which rdb 0266 lets only the operator scope write; no route",
	"UnversionedReleaseNotes": "the repo sync loop (row B-6b): the sha and time of one workspace repo's rows with no version, WHERE tenant_id and repo_slug name the row it synced; no route",
	"SetReleaseVersions":      "the repo sync loop (row B-6b): the version of one workspace repo's rows a new tag covers, only where none is set, WHERE tenant_id and repo_slug name the row it synced; no route",
	"FillEstateDeploy":        "the hub's deploy reconcile check (hub goroutine, spec 143 2.3.2): writes the operator workspace's deploy row the workflow missed, resolving its primary repo in the same transaction; no route",

	// spec 121 T102: the visitor's request names no workspace until one row is read.
	"EmbedCustomer":       "/v1/embed/<embed-id>/*, /embed/v1/chat?e= (spec 121 4.1, 5): the embed id in the URL, unique hub-wide, names its workspace; that one embed row",
	"EmbedVisitorByToken": "visitor bearer (spec 121 4.1): embed id + the 256-bit token's sha256; that one live visitor row, whose channel scopes the rest of the request",
	"EmbedRetentionDue":   "visitor channel retention (spec 121 4.4, hub sweeper goroutine): due visitors of every workspace; each is removed under its own channel scope (RetireEmbedVisitor); no route",
	// spec 121 T206: the relink names no workspace either.
	"EmbedRelinkVisitor": "POST /v1/embed/<embed-id>/relink[/redeem] (spec 121 4.1): embed id + the address, or + the visitor id of a link whose mac the hub then checks; that one live visitor row and its token hash, never returned to the caller",
	// spec 121 T105: the embed abuse limits and the token sweep (embed_abuse.go).
	"embedScope": "/v1/embed/<embed-id>/visitor mint (spec 121 6): before the mint the visitor has no channel to scope by; the workspace is the URL embed's (EmbedCustomer) and every statement names it in its WHERE: the address's counters and bans, the embed's live-visitor count. After the mint it runs inChannel",
	"SweepEmbed": "embed token sweep (spec 121 4.1, hub sweeper goroutine): expired visitor tokens, stale embed counters and lapsed automatic bans of every workspace, global by design; no route",
	// spec 160 3.7 (SPL-3888): the workspaces-that-stream cap of a file streams announce.
	"fileStreamWorkspaces": "file streams announce (spec 160 3.7 max_workspaces, box lane frame): a count of the workspaces that stream and whether the box's own is one, inside the box tenant's announce transaction; no row of another workspace is read out",

	// spec 181 row B7 (SPL-6329): the operator join-token mint for a private VM.
	"MintOperatorJoinToken": "POST /v1/operator/workspaces/{id}/join-tokens (spec 181 B7, 4.2): the box id check reads the pins and open join tokens of EVERY workspace (a private VM serves one workspace, Q-3 A); it writes ONE named workspace's token + its operator_audit row (tenant_id = the URL id); only an admin of the operator workspace reaches it",

	// spec 181 row B9 (SPL-6344): a private workspace's cancel and its 30-day purge.
	"CancelWorkspace":    "POST /v1/operator/workspaces/{id}/cancel (spec 181 B9, 4.5; operatorAuth, the env SA): writes the operator-only workspace_cancellations row and operator_audit for ONE named private workspace (the URL id), and revokes that workspace's own pins and open join tokens",
	"PurgeDueWorkspaces": "workspace purge tick (spec 181 B9, Q-12 C, hub goroutine): lists the cancellations of EVERY workspace whose 30 days have passed; no route",
	"purgeWorkspace":     "workspace purge tick (spec 181 B9, Q-12 C): DELETE FROM tenants for ONE cancelled workspace past purge_after with no unpaid invoice, its purged_at and its operator_audit row; no route",
}

// operatorEntries are the only functions that set the operator scope:
// asOperator (a transaction), asOperatorQuery (one read as one batch) and
// asOperatorInTx (one read inside the caller's open transaction). A caller of
// any of them is an operator caller.
var operatorEntries = map[string]bool{"asOperator": true, "asOperatorQuery": true, "asOperatorInTx": true, "asOperatorSnapshot": true}

// TestOperatorScopeCallers: the set of functions in this package that call
// an operatorEntries function equals operatorCallers. CONTROL: the parse finds
// every entry's own definition, so an empty result cannot pass for "no callers".
func TestOperatorScopeCallers(t *testing.T) {
	fset := token.NewFileSet()
	files, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	defined := map[string]bool{}
	for _, f := range files {
		name := f.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			if operatorEntries[fd.Name.Name] {
				defined[fd.Name.Name] = true
				continue
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if sel, ok := n.(*ast.SelectorExpr); ok && operatorEntries[sel.Sel.Name] {
					found[fd.Name.Name] = true
				}
				// The raw operator setting belongs to asOperator and Migrate only.
				if id, ok := n.(*ast.Ident); ok && id.Name == "pgScopeOperator" && fd.Name.Name != "Migrate" {
					t.Errorf("%s sets the operator scope directly (pgScopeOperator): use asOperator and list it in operatorCallers", fd.Name.Name)
				}
				return true
			})
		}
	}
	for entry := range operatorEntries {
		if !defined[entry] {
			t.Fatalf("control: %s's definition was not found - the scan reads the wrong files", entry)
		}
	}
	var extra, gone []string
	for fn := range found {
		if _, ok := operatorCallers[fn]; !ok {
			extra = append(extra, fn)
		}
	}
	for fn := range operatorCallers {
		if !found[fn] {
			gone = append(gone, fn)
		}
	}
	sort.Strings(extra)
	sort.Strings(gone)
	if len(extra) > 0 {
		t.Errorf("new asOperator caller(s) %v: every tenant's rows - add each to operatorCallers with why it cannot use inTenant", extra)
	}
	if len(gone) > 0 {
		t.Errorf("operatorCallers lists %v, which no longer call asOperator: drop them", gone)
	}
}
