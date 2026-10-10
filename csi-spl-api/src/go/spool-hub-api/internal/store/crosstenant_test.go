package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Cross-tenant suite, store half (specs/017 FR-SEC-015). Postgres
// only (hub-pg.tst.sh, 10 ci hub job). Two tenants hold data in EVERY table
// that carries tenant_id - the list comes from the catalogue, and a table the
// seed does not fill fails the suite, so a new tenant table (RBAC, search,
// keys, M2/M4, ...) must be seeded here before it can ship. The hub half,
// the HTTP / WS / files / search paths, is internal/hub crosstenant_test.go.

// crossSeed is what seedTenantAll wrote for one tenant.
type crossSeed struct {
	tenant, marker, msgID, taskID, channelID, humanID, checkoutID string
}

// seedTenantAll fills every tenant table for a fresh tenant, through the
// store API where one exists (so through inTenant) and as the operator only
// for the rows the paid webhook writes.
func seedTenantAll(t *testing.T, pg *Postgres) crossSeed {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	s := crossSeed{tenant: uid("t-")}
	co := testCheckout(t, s.tenant) // payment_checkouts: a hold comes before its tenant
	co.Email = "buyer-" + s.tenant + "@example.com"
	if err := pg.HoldCheckout(ctx, co, now, time.Hour); err != nil {
		t.Fatal(err)
	}
	s.checkoutID = co.ID
	if err := pg.CreateTenant(ctx, Tenant{ID: s.tenant, RootPubKey: pubkey()}); err != nil { // tenants + tenant_hosts (0015 trigger)
		t.Fatal(err)
	}
	s.marker = "secret" + strings.ReplaceAll(s.tenant, "-", "")
	s.taskID = uuid4()
	s.channelID = uid("ch-")
	if err := pg.PutPin(ctx, s.tenant, "box-a", pubkey(), false, now, now); err != nil { // pins
		t.Fatal(err)
	}
	if err := pg.PutPin(ctx, s.tenant, "box-old", pubkey(), false, now, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.RevokePin(ctx, s.tenant, "box-old", now.Add(time.Second), now.Add(time.Second)); err != nil { // pins_history
		t.Fatal(err)
	}
	if err := pg.TouchBox(ctx, s.tenant, "box-a", now); err != nil { // boxes
		t.Fatal(err)
	}
	// roster + agent_seats (rdb 0107): CLE-01 enters box-a's roster, so
	// SetRoster seats it - the one agent_seats row of the catalogue gate.
	if err := pg.SetRoster(ctx, s.tenant, "box-a", []string{"CLE-01"}, now); err != nil {
		t.Fatal(err)
	}
	m := msgFor(s.tenant, s.taskID, "box-a", now, now, "env-"+s.tenant) // messages
	m.Body = "the " + s.marker + " plan"
	if _, err := pg.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	s.msgID = m.MsgID
	if err := pg.Enqueue(ctx, s.tenant, m.MsgID, "box-a", now, now.Add(time.Hour), 0); err != nil { // deliveries
		t.Fatal(err)
	}
	// message_revisions (rdb 0026): one edit writes revisions 1 and 2, so the
	// register holds rows for both tenants. The marker stays in the body, so
	// the search leak checks below are unaffected by the rewrite.
	if _, err := pg.ApplyEdit(ctx, s.tenant, m.MsgID, Edit{Body: "the " + s.marker + " plan, revised",
		Msg: m.Msg, Env: m.Env, EditedBy: "CLE-01", EditedAt: now.Add(time.Second)}); err != nil {
		t.Fatal(err)
	}
	// message_kind_changes (rdb 0060): one kind change, so the register holds
	// rows for both tenants.
	if _, err := pg.SetKind(ctx, s.tenant, m.MsgID, "blocker", "CLE-01", now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	// fallback_deliveries (rdb 0067, SPL-997): the message went to a
	// fallback agent, so the table holds a row for both tenants.
	if err := pg.RecordFallback(ctx, FallbackDelivery{TenantID: s.tenant, MsgID: m.MsgID, Channel: "",
		Box: "box-a", Agent: "CLE-01", DeliveredAt: now}); err != nil {
		t.Fatal(err)
	}
	// message_reactions (rdb 0037): one emoji on the message, so the table
	// holds a row for both tenants. The glyph is not the search marker.
	if err := pg.AddReaction(ctx, s.tenant, m.MsgID, "HUM-1", "👍", now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	// message_moderation (rdb 0128, specs/077 T016): the message hidden, so
	// the table holds a row for both tenants.
	if err := pg.SetHidden(ctx, s.tenant, m.MsgID, true, "HUM-1", now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	// fleet_leases (rdb 0094, CLE-77911): one lease row per tenant.
	if _, err := pg.CASFleetLease(ctx, s.tenant, "main", "dispatch", "CLE-02@pc", "box-a", 0, now); err != nil {
		t.Fatal(err)
	}
	// fleet_lanes (rdb 0096, CLE-77920): one lane row per tenant.
	if _, err := pg.PutFleetLane(ctx, s.tenant, FleetLane{Fleet: "main", AgentID: "CLE-02", AgentBox: "box-a", State: "live"}, "box-a", now); err != nil {
		t.Fatal(err)
	}
	// shared_memory_lessons (rdb 0146, spec 102 T020): one lesson per tenant.
	if _, _, err := pg.AddLesson(ctx, s.tenant, "lesson", "a trap", "box-a", now); err != nil {
		t.Fatal(err)
	}
	// agent_id_aliases (rdb 0101, spec 061): one alias per tenant.
	if _, _, err := pg.PutAgentAlias(ctx, s.tenant, AgentAlias{OldID: "CLE-02", NewID: "c-004", Kind: "claude", BoxID: "box-a"}, now); err != nil {
		t.Fatal(err)
	}
	// fleet_asks (rdb 0097, CLE-77929): one open ask per tenant.
	if _, _, err := pg.PutFleetAsk(ctx, s.tenant, FleetAsk{Fleet: "main", AskID: uuid4(), Role: "orch", Kind: "blocker", From: "CLE-02"}, "box-a", now); err != nil {
		t.Fatal(err)
	}
	// message_answers (rdb 0111, spec 068 4.2): the message is to CLE-07, so
	// rdb 0110 made CLE-07@box-a responsible on gen 0; one answer per tenant.
	if _, err := pg.ClaimAnswer(ctx, s.tenant, Answer{Answers: m.MsgID, AnswerMsgID: uuid4(), Seat: "CLE-07@box-a", AnsweredAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := pg.CreateChannel(ctx, Channel{TenantID: s.tenant, ChannelID: s.channelID, Name: "c" + s.marker[:12], CreatedBy: "CLE-01", CreatedAt: now}); err != nil { // channels
		t.Fatal(err)
	}
	if err := pg.InviteChannelAgent(ctx, s.tenant, s.channelID, "box-a", "CLE-01", now); err != nil { // channel_subscriptions
		t.Fatal(err)
	}
	hum, err := pg.Admit(ctx, Identity{Provider: "google", Subject: "sub-" + s.tenant, Email: s.tenant + "@example.com", Name: "FirstName LastName"},
		s.tenant, AdmitPolicy{BootstrapOwner: true}, now) // tenant_memberships
	if err != nil {
		t.Fatal(err)
	}
	s.humanID = hum
	if err := pg.GrantBoxOperator(ctx, s.tenant, "box-a", hum, hum, now); err != nil { // box_operators (rdb 0040)
		t.Fatal(err)
	}
	if err := pg.AddChannelHumans(ctx, s.tenant, s.channelID, []string{hum}, hum, now); err != nil { // channel_humans
		t.Fatal(err)
	}
	if _, _, err := pg.TakeQuota(ctx, s.tenant, hum, "agent_turn", now, 20); err != nil { // quota_counts (rdb 0127, specs/077 T013)
		t.Fatal(err)
	}
	// demo_bans (rdb 0130, specs/077 T016 part B): a second member, banned,
	// so the table holds rows for both tenants.
	banned := "ban-" + s.tenant + "@example.com"
	if err := pg.PutInvite(ctx, Invite{TenantID: s.tenant, Email: banned, Role: "developer", InvitedBy: hum,
		ExpiresAt: now.Add(24 * time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	banHum, err := pg.Admit(ctx, Identity{Provider: "google", Subject: "sub-" + banned, Email: banned}, s.tenant, AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := pg.BanMember(ctx, s.tenant, banHum, hum, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.AppendDemoAudit(ctx, DemoAudit{TenantID: s.tenant, At: now, Action: DemoAuditPost, HumanID: hum,
		MsgID: m.MsgID, Body: "audited"}); err != nil { // demo_post_audit (rdb 0131, specs/077 T025)
		t.Fatal(err)
	}
	if err := pg.PutInvite(ctx, Invite{TenantID: s.tenant, Email: "inv-" + s.tenant + "@example.com", Role: "developer", InvitedBy: hum,
		ExpiresAt: now.Add(24 * time.Hour)}, now); err != nil { // tenant_invites
		t.Fatal(err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error { // tenant_seat_periods: the paid webhook's row
		_, err := tx.Exec(ctx, `INSERT INTO tenant_seat_periods (tenant_id, period_start, seats_users, seats_bots, checkout_id, amount_cents, paid_at)
			VALUES ($1, date_trunc('month', now())::date, 1, 1, $2, 100, now())`, s.tenant, co.ID)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error { // rbac_roles: a tenant's own role (025 phase 2 shape)
		_, err := tx.Exec(ctx, `INSERT INTO rbac_roles (role_id, tenant_id, description) VALUES ($1, $2, 'cross-tenant seed')`,
			"r_"+strings.ReplaceAll(s.tenant, "-", "_"), s.tenant)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	// issue_labels, issues, issue_counters (rdb 0047): one labelled issue.
	if _, err := pg.CreateIssueLabel(ctx, IssueLabel{TenantID: s.tenant, Name: "bug", CreatedBy: hum}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.CreateIssue(ctx, Issue{TenantID: s.tenant, Title: "issue " + s.tenant, Labels: []string{"bug"},
		TaskID: uuid4(), CreatedBy: hum, Parent: testEpic(t, pg, s.tenant, now)}, now); err != nil {
		t.Fatal(err)
	}
	// member_clones (rdb 0088, specs/054): a technical clone human of the
	// seeded member and its act-as row, so the table holds a row for both
	// tenants. humans is hub-wide (no RLS); the clone row is tenant-scoped.
	var cloneHum string
	if err := pg.pool.QueryRow(ctx, `INSERT INTO humans (display_name, technical, created_at)
		VALUES ($1, true, $2) RETURNING human_id`, "clone of "+hum, now).Scan(&cloneHum); err != nil {
		t.Fatal(err)
	}
	if err := pg.inTenant(ctx, s.tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO member_clones
			(clone_hum, tenant_id, target_hum, created_by, role, expires_at)
			VALUES ($1, $2, $3, $4, 'developer', $5)`,
			cloneHum, s.tenant, hum, hum, now.Add(time.Hour))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	// agent_join_tokens (rdb 0119, specs/073): one open token minted by the
	// seeded member for itself; the hash is unique per tenant.
	if err := pg.inTenant(ctx, s.tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO agent_join_tokens (token_hash, tenant_id, created_by, for_human, expires_at)
			VALUES (encode(sha256(convert_to($1, 'UTF8')), 'hex'), $1, $2, $2, $3)`, s.tenant, hum, now.Add(time.Hour))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	// member_activity (rdb 0091, CLE-77799): one audit row for the seeded
	// member, so the every-table cross-tenant gate holds a row for both tenants.
	if err := pg.AppendMemberActivity(ctx, MemberActivity{TenantID: s.tenant, SubjectHum: hum, ActorHum: hum, Kind: "role_changed", Detail: "developer", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	// read_marks (rdb 0098, CLE-77930): one channel mark of the seeded member.
	if err := pg.SaveReadMarks(ctx, s.tenant, hum, map[string]ReadMark{"ch:lobby": {At: now, MsgID: "m"}}, now); err != nil {
		t.Fatal(err)
	}
	// flow_watches + flow_events (rdb 0104, spec 062): the seeded member
	// watches the seeded thread and has one event on the seeded message.
	if err := pg.inTenant(ctx, s.tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO flow_watches (tenant_id, task_id, member_id, since) VALUES ($1, $2, $3, $4)`,
			s.tenant, s.taskID, hum, now); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO flow_events (tenant_id, member_id, msg_id, task_id, kind, at, expires_at)
			VALUES ($1, $2, $3, $4, 'reply', $5, $6) ON CONFLICT DO NOTHING`, s.tenant, hum, s.msgID, s.taskID, now, now.Add(time.Hour))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	// agent_lifecycle_config + agent_lifecycle_events (rdb 0105, spec 063):
	// one patched key (which also appends the config_change event).
	if _, _, err := pg.PatchAgentLifecycleConfig(ctx, s.tenant, LifecyclePatch{"notes_tail_lines": 20}, hum, now); err != nil {
		t.Fatal(err)
	}
	// wui_perf_samples (rdb 0106, spec 066): one sample.
	if err := pg.InsertPerfSamples(ctx, s.tenant, []PerfSample{{At: now, SessionID: uuid4(), Metric: "inp",
		ValueMs: 1, Device: "phone", Outcome: "ok"}}); err != nil {
		t.Fatal(err)
	}
	// box_stats (rdb 0117): one load + memory sample.
	if err := pg.AppendBoxStat(ctx, s.tenant, BoxStat{Box: "sat", WriterBox: "box-seed", At: now, CPUs: 1}); err != nil {
		t.Fatal(err)
	}
	// box_beats (rdb 0147, spec 102 10.2): one beat.
	if err := pg.AppendBoxBeat(ctx, s.tenant, BoxBeat{Box: "sat", BeatAt: now, PID: 1}); err != nil {
		t.Fatal(err)
	}
	// box_facts (rdb 0140): one box's fact sheet.
	if err := pg.PutBoxFacts(ctx, s.tenant, BoxFactSheet{Box: "sat", ReportedAt: now, Sheet: []byte(`{"os":{"name":"Debian GNU/Linux"}}`)}); err != nil {
		t.Fatal(err)
	}
	// human_status (rdb 0141, spec 096 L1): the seeded member is Unavailable
	// with a note. No store API yet (L2), so a row under inTenant.
	if err := pg.inTenant(ctx, s.tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO human_status (tenant_id, human_id, status, note, until_at, set_by)
			VALUES ($1, $2, 'unavailable', $3, $4, $2)`, s.tenant, hum, "in a meeting", now.Add(time.Hour))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	// calendar_events (rdb 0125, spec 089 T003): one public event of the
	// seeded member.
	ev, err := pg.CreateCalendarEvent(ctx, s.tenant, CalendarEvent{Title: "release", Kind: "release", StartsAt: now,
		EndsAt: now.Add(time.Hour), CreatorType: "human", CreatorID: hum}, now)
	if err != nil {
		t.Fatal(err)
	}
	// calendar_guests (rdb 0139, spec 097 T002): the seeded member is the
	// guest of that event. No store API yet (T007), so a row under inTenant.
	if err := pg.inTenant(ctx, s.tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO calendar_guests (tenant_id, event_id, guest_type, guest_id, invited_by)
			VALUES ($1, $2, 'human', $3, $3)`, s.tenant, ev.ID, hum)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	// operator_audit (rdb 0115, spec 074): one operator action on this workspace.
	if err := pg.AppendOperatorAudit(ctx, OperatorAudit{At: now, TenantID: s.tenant, ActorTenant: "op-seed",
		ActorHum: hum, Action: AuditCreate}); err != nil {
		t.Fatal(err)
	}
	// repo_doc_edits, repo_doc_authors, repo_doc_author_notices (rdb 0142,
	// spec 075 repo-edit T02): one queued edit of the seeded member, their
	// git identity and its consent. No store API yet (T06), so rows under inTenant.
	if err := pg.inTenant(ctx, s.tenant, func(tx pgx.Tx) error {
		email := hum + "@example.com"
		if _, err := tx.Exec(ctx, `INSERT INTO repo_doc_edits (edit_id, tenant_id, human_id, actor_kind, path, base_blob,
			overlay_key, text_sha256, author_name, author_email, author_source, status, next_try_at, first_saved_at)
			VALUES ($1::uuid, $2, $3, 'member', 'README.md', 'blob0', '.edits/README.md/' || $1 || '.md', 'sha0',
			'FirstName LastName', $4, 'signin', 'queued', $5, $5)`, uuid4(), s.tenant, hum, email, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO repo_doc_authors (tenant_id, human_id, git_name, git_email)
			VALUES ($1, $2, 'FirstName LastName', $3)`, s.tenant, hum, email); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO repo_doc_author_notices (tenant_id, human_id, git_name, git_email)
			VALUES ($1, $2, 'FirstName LastName', $3)`, s.tenant, hum, email)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	// topic_heads, topic_head_parts (rdb 0144, spec 099): the triggers write
	// them from the messages above. topic_head_tenants is the backfill mark,
	// which only topic_head_backfill sets: one row under inTenant.
	if _, err := pg.execTenant(ctx, s.tenant, `INSERT INTO topic_head_tenants (tenant_id, backfilled_at) VALUES ($1, $2)`,
		s.tenant, now); err != nil {
		t.Fatal(err)
	}
	// hours_minutes, hours_entries, hours_periods (rdb 0151, spec 107): one
	// row of each for the seeded member (hours_rls_test.go).
	if err := seedHours(ctx, pg, s.tenant, hum, now); err != nil {
		t.Fatal(err)
	}
	// workspace_doc, workspace_doc_item, workspace_doc_rev_log (rdb 0157,
	// spec 113 T001): a doc with its root and one rev-log entry, then its
	// workspace_doc_node pair. No store API
	// yet (T002), so raw rows under inTenant.
	if err := pg.inTenant(ctx, s.tenant, func(tx pgx.Tx) error {
		var doc string
		if err := tx.QueryRow(ctx, `INSERT INTO workspace_doc (tenant_id, title, rev) VALUES ($1, 'seed', 1) RETURNING id::text`,
			s.tenant).Scan(&doc); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ($1, $2, NULL, 1)`,
			s.tenant, doc); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor) VALUES ($1, $2, 1, '{"kind":"create"}', $3)`,
			s.tenant, doc, hum); err != nil {
			return err
		}
		// workspace_doc_node (rdb 0165, spec 120): the hidden root (1, 4) and
		// the doc's node (2, 3). No store API yet, so raw rows.
		_, err := tx.Exec(ctx, `WITH r AS (INSERT INTO workspace_doc_node (tenant_id, lft, rgt, kind) VALUES ($1, 1, 4, 'root') RETURNING id)
			INSERT INTO workspace_doc_node (tenant_id, lft, rgt, parent_id, parent_kind, kind, doc_id) SELECT $1, 2, 3, r.id, 'root', 'doc', $2::uuid FROM r`,
			s.tenant, doc)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	// tenant_agent_split_kind (rdb 0163, spec 115 RDB-1): the secret kind,
	// claude 100 with mistral the backup. No store API yet (HUB-1), so raw
	// rows under inTenant.
	if err := pg.inTenant(ctx, s.tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO tenant_agent_split_kind (tenant_id, kind, vendor, weight, is_backup)
			VALUES ($1, 'secret', 'claude', 100, false), ($1, 'secret', 'mistral', 0, true)`, s.tenant)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return s
}

// tenantTables lists every table with a tenant_id column, from the catalogue.
func tenantTables(t *testing.T, pg *Postgres) []string {
	t.Helper()
	var out []string
	rows, err := pg.pool.Query(context.Background(), `SELECT c.relname FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
		WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	if err := scanRows(rows, func(r pgx.Rows) error {
		var n string
		out = append(out, n)
		return r.Scan(&out[len(out)-1])
	}); err != nil {
		t.Fatal(err)
	}
	if len(out) == 0 {
		t.Fatal("no tenant_id table in the catalogue")
	}
	return out
}

// countOf counts tenant's rows in tb as the operator (the ground truth).
func countOf(t *testing.T, pg *Postgres, tb, tenant string) int {
	t.Helper()
	var n int
	if err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT count(*) FROM `+pgx.Identifier{tb}.Sanitize()+` WHERE tenant_id = $1`, tenant).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	return n
}

// appendOnlyTables refuse every UPDATE and DELETE outside their purge
// (rdb 0131 demo_post_audit).
var appendOnlyTables = map[string]bool{"demo_post_audit": true}

// TestCrossTenantEveryTable: with A and B seeded in every tenant table, A's
// scope sees none of B's rows in any of them, and A's unscoped UPDATE /
// DELETE / a B-stamped INSERT change none of them. CONTROL: B's rows are
// there (counted as the operator), and A sees its own.
func TestCrossTenantEveryTable(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := seedTenantAll(t, pg)
	b := seedTenantAll(t, pg)
	tables := tenantTables(t, pg)
	before := map[string]int{}
	for _, tb := range tables {
		before[tb] = countOf(t, pg, tb, b.tenant)
		if before[tb] == 0 {
			t.Errorf("%s: seedTenantAll wrote no row for tenant B - a new tenant table must be seeded in crosstenant_test.go", tb)
		}
		if countOf(t, pg, tb, a.tenant) == 0 {
			t.Errorf("%s: no row for tenant A", tb)
		}
	}
	if t.Failed() {
		t.FailNow()
	}
	for _, tb := range tables {
		id := pgx.Identifier{tb}.Sanitize()
		err := pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
			var other, own int
			if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE tenant_id <> $1), count(*) FILTER (WHERE tenant_id = $1) FROM `+id, a.tenant).Scan(&other, &own); err != nil {
				return err
			}
			if other != 0 {
				t.Errorf("%s: A's scope reads %d row(s) of other tenants", tb, other)
			}
			if own == 0 {
				t.Errorf("%s: A's scope reads none of its own rows (control)", tb)
			}
			return nil
		})
		if err != nil {
			t.Fatalf("%s read: %v", tb, err)
		}
		// Writes that forget WHERE tenant_id touch only A's rows: RETURNING
		// names every row the statement reached. Each runs in a transaction
		// that is rolled back, so A's seed stays for the next table.
		for _, w := range []string{
			`UPDATE ` + id + ` SET tenant_id = tenant_id RETURNING tenant_id`,
			`DELETE FROM ` + id + ` RETURNING tenant_id`,
		} {
			var reached, foreign int
			rolledBack := errors.New("rollback")
			err := pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
				if err := tx.QueryRow(ctx, `WITH w AS (`+w+`) SELECT count(*), count(*) FILTER (WHERE tenant_id IS DISTINCT FROM $1) FROM w`, a.tenant).Scan(&reached, &foreign); err != nil {
					return err
				}
				return rolledBack
			})
			if appendOnlyTables[tb] { // refused outright: stronger than reaching only A's rows
				if err == nil || errors.Is(err, rolledBack) || !strings.Contains(err.Error(), "append-only") {
					t.Errorf("%s: %s from A's scope: %v, want the append-only refusal", tb, w, err)
				}
				continue
			}
			if !errors.Is(err, rolledBack) {
				t.Errorf("%s: %s: %v", tb, w, err)
				continue
			}
			if foreign != 0 || reached == 0 {
				t.Errorf("%s: %s from A's scope reached %d row(s), %d not A's (want >0 and 0)", tb, w, reached, foreign)
			}
		}
		if n := countOf(t, pg, tb, b.tenant); n != before[tb] {
			t.Errorf("%s: B had %d row(s), now %d", tb, before[tb], n)
		}
		// A B-stamped row from A's scope: refused by WITH CHECK.
		err = pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE `+id+` SET tenant_id = $1 WHERE tenant_id = $2`, b.tenant, a.tenant)
			return err
		})
		if err == nil {
			t.Errorf("%s: A re-stamped its own row(s) as B's", tb)
		}
	}
}

// TestCrossTenantStoreAPI: every tenant-scoped store read called with A's
// tenant and B's ids returns nothing of B's. CONTROL: B's own call finds it.
func TestCrossTenantStoreAPI(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a := seedTenantAll(t, pg)
	b := seedTenantAll(t, pg)

	if ok, err := pg.HasMessage(ctx, b.tenant, b.msgID); err != nil || !ok {
		t.Fatalf("control: B's own message: %v %v", ok, err)
	}
	if ok, err := pg.HasMessage(ctx, a.tenant, b.msgID); err != nil || ok {
		t.Errorf("HasMessage(A, B's msg) = %v %v", ok, err)
	}
	if env, err := pg.TaskEnvelopes(ctx, a.tenant, b.taskID); err != nil || len(env) != 0 {
		t.Errorf("TaskEnvelopes(A, B's task) = %d %v", len(env), err)
	}
	if msgs, err := pg.ViewTopic(ctx, a.tenant, TopicMsgQuery{TaskID: b.taskID, Limit: 50, Now: now}); err != nil || len(msgs) != 0 {
		t.Errorf("ViewTopic(A, B's task) = %d %v", len(msgs), err)
	}
	if got, err := pg.ReactionsFor(ctx, a.tenant, []string{b.msgID}); err != nil || len(got) != 0 {
		t.Errorf("ReactionsFor(A, B's msg) = %v %v", got, err)
	}
	if got, err := pg.ReactionsFor(ctx, b.tenant, []string{b.msgID}); err != nil || len(got[b.msgID]) != 1 {
		t.Errorf("control: ReactionsFor(B, B's msg) = %v %v", got, err)
	}
	if st, err := pg.DeliveryState(ctx, a.tenant, b.msgID, "box-a"); err == nil && st != "" {
		t.Errorf("DeliveryState(A, B's msg) = %q", st)
	}
	if ok, err := pg.ClaimSent(ctx, a.tenant, b.msgID, "box-a", now); err == nil && ok {
		t.Error("ClaimSent(A, B's msg) claimed B's delivery")
	}
	if st, _ := pg.DeliveryState(ctx, b.tenant, b.msgID, "box-a"); st != "queued" {
		t.Errorf("B's delivery after A's claim attempt: %q", st)
	}
	if ok, err := pg.ChannelKnown(ctx, a.tenant, b.channelID); err != nil || ok {
		t.Errorf("ChannelKnown(A, B's channel) = %v %v", ok, err)
	}
	if mem, err := pg.ChannelMembers(ctx, a.tenant, b.channelID); err != nil || len(mem) != 0 {
		t.Errorf("ChannelMembers(A, B's channel) = %v %v", mem, err)
	}
	if role, err := pg.MemberRole(ctx, b.humanID, a.tenant); err == nil && role != "" {
		t.Errorf("MemberRole(B's human, A) = %q", role)
	}
	if hs, err := pg.TenantHumans(ctx, a.tenant); err != nil {
		t.Fatal(err)
	} else {
		for _, h := range hs {
			if h.HumanID == b.humanID {
				t.Errorf("TenantHumans(A) lists B's human %s", b.humanID)
			}
		}
	}
	rs, err := pg.SearchMessages(ctx, a.tenant, sq(t, b.marker, now))
	if err != nil || len(rs) != 0 {
		t.Errorf("SearchMessages(A, B's marker) = %d %v", len(rs), err)
	}
	if rs, err := pg.SearchMessages(ctx, b.tenant, sq(t, b.marker, now)); err != nil || len(rs) != 1 {
		t.Errorf("control: SearchMessages(B, B's marker) = %d %v", len(rs), err)
	}
	if ps, err := pg.SeatPeriods(ctx, a.tenant); err != nil || len(ps) != 1 {
		t.Errorf("SeatPeriods(A) = %d %v, want A's own 1", len(ps), err)
	}
	if pins, err := pg.ListPins(ctx, a.tenant); err != nil {
		t.Fatal(err)
	} else if len(pins) != 1 {
		t.Errorf("ListPins(A) = %d pins, want A's own 1", len(pins))
	}
	if r, err := pg.Roster(ctx, a.tenant); err != nil || len(r) != 1 {
		t.Errorf("Roster(A) = %v %v", r, err)
	}
	if n, err := pg.CountMembers(ctx, a.tenant); err != nil || n != 1 {
		t.Errorf("CountMembers(A) = %d %v, want 1", n, err)
	}
	// Writes through the API with A's tenant and B's ids change nothing of B.
	if err := pg.RevokePin(ctx, a.tenant, "box-a", now.Add(time.Minute), now.Add(time.Minute)); err != nil {
		t.Fatal(err) // A revokes its OWN box-a; B's box-a must survive
	}
	if _, err := pg.GetPin(ctx, b.tenant, "box-a"); err != nil {
		t.Errorf("B's box-a pin after A revoked its own box-a: %v", err)
	}
	if err := pg.Unclaim(ctx, a.tenant, b.msgID, "box-a"); err != nil && !errors.Is(err, ErrNotFound) {
		t.Errorf("Unclaim(A, B's msg): %v", err)
	}
}
