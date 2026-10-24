# Spec 153 v1.1 (Monitoring Lanes Tab, O1 = B) — agy Seat Review & Verdict

Seat: `a-960@sat` (agy, cross-vendor review seat).  
Epic: `SPL-2403`. Issues: `SPL-3075` (spec 153), `SPL-3210` (v1.1 O1 = B), `SPL-3161` (seat tracked issue).  
Spec reviewed: `csi-spl-doc/specs/153-monitoring-lanes-tab/spec.md`.  
Commit reviewed: `b5c78e2e7` (v1.1 by author `c-995@sat`, +110/-6).  
Verified on tree: `origin/master` at `b5c78e2e7`.  

---

## 1. Summary of Verdicts

| # | Check / Requirement | Verdict | Notes |
|---|---|---|---|
| 1 | Diff review (`b5c78e2e7~1` to `b5c78e2e7`) | **OK** | 1 file, +110/-6; records owner O1 = B, adds 3.6, C25-C30, row B6 |
| 2.1 | `spawn-core.inc.sh:277-308` | **OK** | Lane ties to customer workspace only via `fleet_lanes.topic` |
| 2.2 | `hub/box_lane.go:22-23,128-131,154` | **OK** | Rows stored in box's tenant; short id resolves only in that tenant |
| 2.3 | rdb `0096_fleet_lanes.sql:33-39` | **OK** | `fleet_lanes` has forced RLS per tenant with operator bypass |
| 2.4 | Store calls (`fleet_lane_postgres.go:55,89`, `issue_discussions.go:358`, `privacy.go:129`) | **OK** | All required store functions exist with matching signatures and semantics |
| 2.5 | `rbac/rbac.go:70,153,207-215` and `hub/embed_staff.go:63` | **OK** | Gate `TenantOwner || Has(rbac.Admin)` matches existing pattern |
| 2.6 | WUI `access.mjs:33-43` vs `hub/rbac.go:96-100` | **OK** | `normalizeMe` currently drops `roles` despite hub sending `meBody.roles` |
| 3.a | 403 Gate design | **OK** | Exactly owner or admin in workspace W; plain member gets 403 and no tab |
| 3.b | Cross-workspace isolation & `scope` text | **OK** | No leakage across tenants; `scope` does not filter or leak rows |
| 3.c | Build row B6 file list & ordering | **OK** | Complete and correctly sequenced after B2, B3, and B4 |
| 3.d | Red controls (C25-C30) | **OK** | C25-C26b, C28-C30 fail on master today; C27 is a passing regression check |

Final verdict: **SIGN**. All requirements verified OK with 0 defects.

---

## 2. Empirical Verification of Code Claims

### 2.1 `spawn-core.inc.sh:277-308` — Lane ties to workspace only via `fleet_lanes.topic`
- **Claim**: A lane is tied to a workspace only through `fleet_lanes.topic`.
- **Line verification**:
  ```bash
  git show origin/master:csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh | sed -n '277,308p'
  ```
  Output:
  ```bash
  _spawn_lane_put() {
    local scope="${SPAWN_LANE_SCOPE:-}" repo="" log
    local topic="${SPAWN_LANE_TOPIC:-${LANE_ISSUE_TOPIC:-}}" issue=""
    if [ -z "$topic" ] && [ -n "$BRIEF" ] && [ -r "$BRIEF" ]; then
      topic="$(grep -oE '([Tt]opic[: ]+`?|/t/)[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?([^0-9A-Za-z-]|$)' "$BRIEF" 2>/dev/null |
        head -1 | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?' | head -1)"
    fi
    if [ -n "$BRIEF" ] && . "${_SP_DIR}/../lib/lane-issue.inc.sh" 2>/dev/null; then
      issue="$(li_key_of_agent "$SPOOL_ROOT" "$TITLE")"
      [ -n "$issue" ] || issue="${SPAWN_ISSUE:-$(li_key_from_brief "$BRIEF")}"
    fi
    [[ "$issue" =~ ^[A-Z][A-Z0-9]{1,9}-[0-9]{1,9}$ ]] || issue=""
    if [ -z "$scope" ] && [ -n "$BRIEF" ] && [ -r "$BRIEF" ]; then
      scope="$(grep -m1 -E '^#+ ' "$BRIEF" 2>/dev/null | sed -E 's/^#+ +//; s/^Brief: *//')"
    fi
    if [ -z "${SPAWN_LANE_FILES:-}" ] && [ -n "$BRIEF" ] && [ -r "$BRIEF" ]; then
      SPAWN_LANE_FILES="$(grep -m1 -E '^Files: *' "$BRIEF" 2>/dev/null | sed -E 's/^Files: *//' |
        tr ',' '\n' | sed -E 's/^[ `]+//; s/[ `.]+$//' | grep -v '^$' | paste -sd, -)"
    fi
    scope="${scope:-$SLUG}"
    [ -n "$REPO" ] && repo="$(basename "$REPO")"
    _sp_plan lane "lane-map.sh put --agent ${TITLE} --repo ${repo:-<none>} --branch ${BRANCH:-<none>} --scope '${scope}' --files '${SPAWN_LANE_FILES:-}' --topic '${topic}' --issue '${issue}'"
    _sp_live || return 0
    log="${SPOOL_ROOT}/${TITLE}/lane.log"
    ( timeout 60 bash "${_SP_DIR}/lane-map.sh" put --agent "$TITLE" --repo "$repo" --branch "$BRANCH" \
        --scope "$scope" --files "${SPAWN_LANE_FILES:-}" --topic "$topic" --issue "$issue" >"$log" 2>&1 & ) 2>/dev/null
  }
  ```
- **Verdict**: **HOLDS**. The row stores no foreign tenant ID; `topic` is the only link connecting a lane to a discussion topic.

### 2.2 `hub/box_lane.go:22-23,128-131,154` — Rows live in writing box's tenant; short ID resolves only there
- **Claim**: Rows live in the tenant of the box that wrote it (`x.tenant`). An 8-hex short ID resolves only among that tenant's topics.
- **Line verification**:
  ```bash
  git show origin/master:csi-spl-api/src/go/spool-hub-api/internal/hub/box_lane.go | sed -n '22,23p;128,131p;154p'
  ```
  Lines 22-23:
  ```go
  // A put's topic given as an 8-hex short id is stored as the one topic of the
  // tenant it starts, or "" when none or several do (spec 153 3.4): a short id
  ```
  Lines 128-131:
  ```go
  		if l.Topic, ae = s.laneTopic(ctx, x.tenant, l.Topic); ae != nil {
  			return laneAnswer{}, ae
  		}
  		got, err := s.o.Store.PutFleetLane(ctx, x.tenant, l, x.box, now)
  ```
  Line 154 (inside `laneTopic`):
  ```go
  func (s *Server) laneTopic(ctx context.Context, tenant, topic string) (string, *issueErr) {
  ```
  And lines 162-168:
  ```go
  	ids, err := d.TopicsByPrefix(ctx, tenant, topic, 2)
  	if err != nil {
  		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("fleet lane topic prefix")
  		return "", &issueErr{http.StatusInternalServerError, "internal", "lane map unavailable"}
  	}
  	if len(ids) != 1 {
  		return "", nil
  	}
  	return ids[0], nil
  ```
- **Verdict**: **HOLDS**. `PutFleetLane` writes under `x.tenant` (the operator tenant for fleet boxes). `TopicsByPrefix` resolves short prefixes strictly within `x.tenant`. A customer workspace topic therefore requires its full UUID to be matched in `fleet_lanes`.

### 2.3 `0096_fleet_lanes.sql:33-39` — RLS per tenant
- **Claim**: `fleet_lanes` is tenant-scoped by RLS; customer workspaces cannot read operator rows directly.
- **Line verification**:
  ```bash
  git show origin/master:csi-spl-rdb/src/sql/postgres/spool-hub/0096_fleet_lanes.sql | sed -n '33,39p'
  ```
  Output:
  ```sql
  ALTER TABLE fleet_lanes ENABLE ROW LEVEL SECURITY;
  ALTER TABLE fleet_lanes FORCE ROW LEVEL SECURITY;
  CREATE POLICY tenant_scope ON fleet_lanes
      USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
      WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
  CREATE POLICY operator_scope ON fleet_lanes
      USING (current_setting('app.rls_scope', true) = 'operator')
      WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
  ```
- **Verdict**: **HOLDS**. Forced RLS restricts access to rows matching `app.tenant_id` unless operating under `operator` scope. A customer workspace session cannot read operator `fleet_lanes` rows.

### 2.4 Store calls exist with required semantics
- **Claim**: `fleet_lane_postgres.go:55,89`, `issue_discussions.go:358`, `privacy.go:129` provide all necessary join logic.
- **Line verification**:
  - `store/fleet_lane_postgres.go:55`:
    ```go
    func (s *Postgres) ListFleetLanes(ctx context.Context, tenant, fleet string, now time.Time) ([]FleetLane, error)
    ```
  - `store/fleet_lane_postgres.go:89`:
    ```go
    func (s *Postgres) FleetLaneIssues(ctx context.Context, tenant string, topics []string, numbers []int) (map[string][]int, map[int]string, error)
    ```
  - `store/issue_discussions.go:358`:
    ```go
    func (s *Postgres) DiscussionStates(ctx context.Context, tenant string, tasks []string) (map[string]DiscussionState, error)
    ```
    Queries `messages` with `m.tenant_id = $1` (enforcing tenant scoping).
  - `hub/privacy.go:129`:
    ```go
    func (s *Server) canReadTopic(ctx context.Context, tenant, task, human string) (ok, found bool, err error)
    ```
    Evaluates `topicDoor` (`topicLockHidden` and `topicVerdict`) to enforce access privacy.
- **Verdict**: **HOLDS**. All 4 methods exist and provide the exact capabilities specified.

### 2.5 `rbac/rbac.go:70,153,207-215` & `hub/embed_staff.go:63` — Owner and admin definition & gate pattern
- **Claim**: `TenantOwner` is true for system role `biz_owner`; `Admin` is `"admin"`; the gate `TenantOwner || Has(rbac.Admin)` is established at `embed_staff.go:63`.
- **Line verification**:
  - `internal/rbac/rbac.go:70`: `Admin = "admin"`
  - `internal/rbac/rbac.go:153`: `{ID: BizOwner, TenantOwner: true, Perms: withMember(...)}`
  - `internal/rbac/rbac.go:207-215`:
    ```go
    type Access struct {
    	HumanID     string
    	Role        string
    	Roles       []string
    	TenantOwner bool
    	Perms       map[string]bool
    }

    func (a Access) Has(role string) bool {
    	for _, r := range a.Roles {
    		if r == role {
    			return true
    		}
    	}
    	return false
    }
    ```
  - `internal/hub/embed_staff.go:63`:
    ```go
    	if a, err := s.access(r.Context(), hum, t.ID); err != nil || !(a.TenantOwner || a.Has(rbac.Admin)) {
    		writeForbidden(w, permEmbedStaff, "only the workspace owner or an admin manages visitor channels")
    		return nil, "", false
    	}
    ```
- **Verdict**: **HOLDS**. `TenantOwner || Has(rbac.Admin)` correctly captures workspace owners and admins.

### 2.6 WUI `access.mjs:33-43` vs `hub/rbac.go:96-100` — `normalizeMe` role handling
- **Claim**: `normalizeMe` keeps `role` (singular primary) and `tenantOwner` but drops `roles`, whereas `GET /v1/view/me` sends `meBody.roles`.
- **Line verification**:
  - `hub/rbac.go:96-100`:
    ```go
    	// Roles is the member's whole role set, the primary (Role) first (025
    	// §10.2 rule 6); null = door-off guest.
    	Roles       []string `json:"roles"`
    	TenantOwner *bool    `json:"tenant_owner"`
    ```
  - `csi-spl-wui/src/utils/access.mjs:33-43`:
    ```javascript
    export function normalizeMe(body) {
      const b = body && typeof body === 'object' ? body : {}
      return {
        humanId: typeof b.human_id === 'string' ? b.human_id : null,
        role: typeof b.role === 'string' && b.role ? b.role : null,
        tenantOwner: b.tenant_owner === true,
        permissions: Array.isArray(b.permissions) ? b.permissions.filter((p) => typeof p === 'string') : null,
        channelOrder: Array.isArray(b.channel_order) ? normalizeChannelOrder(b.channel_order) : null,
        actAs: normalizeActAs(b.act_as),
        topicArchivePolicy: archivePolicyOf(b.topic_archive_policy),
      }
    }
    ```
- **Verdict**: **HOLDS**. `normalizeMe` currently omits `roles`, preventing secondary `admin` roles from being recognized in the client until B6 updates it.

---

## 3. Design Judgment

### 3.a 403 Gate Design
- The endpoint `GET /v1/view/lanes` checks `TenantOwner || Has(rbac.Admin)` on the authenticated caller session within workspace W.
- A non-admin/non-owner member (e.g., primary `developer` without secondary `admin`) receives HTTP 403 `forbidden`.
- Operator service accounts are rejected on this route (they use `GET /v1/operator/fleet-lanes` instead).
- On the client, `visibleMonitoringTabs` checks `who.staff === true` (`tenantOwner` or `roles.includes('admin')`) or `who.operator === true`.
- Plain members do not see the tab (C26).

### 3.b Cross-Workspace Isolation & Scope Text Weighing
1. **Row Isolation**:
   - Active lanes are retrieved from the operator scope.
   - For a caller in workspace W, candidate lane topics are verified via `DiscussionStates(ctx, W, topics)`. Because `DiscussionStates` filters by `m.tenant_id = W`, any topic not belonging to W yields `DiscussionGone` and is omitted.
   - Candidate topics are further verified via `canReadTopic(ctx, W, topic, caller)`. If false (e.g. private channel/DM where caller is not a member), the lane is omitted.
2. **Key / Box Isolation**:
   - `agent_box` is blanked (`""`) in `/v1/view/lanes` to prevent disclosing internal fleet box tags.
   - Operator issue keys on `fleet_lanes.issue_key` are excluded; only W's issues linked to the topic via `FleetLaneIssues(ctx, W, ...)` are returned.
3. **Weighing the Author's Question on `scope` Text**:
   - `scope` is the task brief's title or slug.
   - A lane is selected *if and only if* its topic is an accessible topic in workspace W.
   - Lanes working on operator topics or topics belonging to workspace W2 will never match W's topics under `DiscussionStates`, so their `scope` text is never exposed to W.
   - Conversely, any lane working on W's topic was spawned for W's task, and its scope describes W's work.
   - Therefore, `scope` cannot cause cross-tenant leakage.

### 3.c Build Row B6 File List & Ordering
- **Sequence**: B6 is sequenced strictly after B2, B3, and B4 on master.
- **Completeness**:
  - `hub/fleet_lanes_view.go` (extracts active predicate and row mapping)
  - `hub/workspace_lanes_view.go` + `_test.go` (new workspace endpoint)
  - `hub/server.go` (route registration)
  - `hub/openapi.json` (OpenAPI specification)
  - `wui/utils/access.mjs` + unit test (`roles` preservation)
  - `wui/utils/monitoring-tabs.mjs` (`staff: true` support)
  - `wui/pages/monitoring.vue` (pass `staff`)
  - `wui/pages/monitoring/lanes/index.vue` (dual route selection)
  - `wui/utils/spool-client-lazy.mjs` (client API method)
  - `csi-spl-wui/tests/unit/monitoring-tabs.test.mjs`
  - B4 lanes e2e test suite
- **Disjointness**: All files are disjoint from concurrent tracks; sequential dependencies on B4 files are clearly documented. No store, rdb, or orc modifications required.

### 3.d Red Controls (C25-C30)
- **C25, C25b**: `GET /v1/view/lanes` returns 404 on master today; fails until endpoint is implemented.
- **C26**: Route returns 404 (not 403); lanes tab is not rendered for staff without B4/B6.
- **C26b**: `normalizeMe` currently strips `roles`; unit test fails on master today.
- **C27**: Regression control (C) ensuring `GET /v1/operator/fleet-lanes` continues to pass as in B3.
- **C28, C29, C30**: Filtering of unrelated/short-id topics, operator issue keys, and unreadable topics all rely on `/v1/view/lanes`, failing (404) on master today.

---

## 4. Signature

All 10 verification areas have been checked empirically against the codebase on `origin/master` (`b5c78e2e7`). The design is sound, robustly isolates tenants, and defines verifiable red controls.

**SIGN**: `a-960@sat` (agy cross-vendor review seat) signs **Spec 153 v1.1** (`b5c78e2e7`).
