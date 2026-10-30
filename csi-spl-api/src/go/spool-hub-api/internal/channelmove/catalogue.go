// SPDX-License-Identifier: AGPL-3.0-only

// Package channelmove moves or copies a whole channel into another workspace
// (spec 169). This file is its inventory in code (row T1): every table that
// carries tenant_id, what a move does with it, and the predicate that finds
// the rows of the channel's set. catalogue_test.go is the gate C2: a tenant
// table with no entry here fails the build, so a table added later cannot be
// missed by the move.
package channelmove

// Class says what a move does with a table's rows (spec 169 sections 4, 5.1).
type Class string

const (
	// Moved: the rows Set finds are inserted under <DST> and, for a move,
	// deleted in <SRC> (insert in catalogue order, delete in reverse, F5).
	Moved Class = "moved"
	// Rewritten: no row is carried to <DST>; staying <SRC> rows that Refs
	// finds are updated (a column nulled, an id removed) or deleted there.
	Rewritten Class = "rewritten"
	// Recomputed: an aggregate, recomputed for both workspaces after P4.
	Recomputed Class = "recomputed"
	// Refuse: a row Set finds is a shared item the move cannot carry, so
	// plan refuses the move while one exists (spec 169 5.1b, Q6).
	Refuse Class = "refuse"
	// NotChannel: holds nothing about spool channels; the move leaves it.
	NotChannel Class = "not-channel"
)

// Entry is one tenant table. Set and Refs are SQL boolean expressions over
// the table's own columns and the binds below, with no tenant_id term: the
// caller adds `tenant_id = <SRC>` and runs it asOperator.
type Entry struct {
	Table  string
	Class  Class
	Set    string   // Moved: the rows of the set; Refuse: the rows that stop the move
	Refs   string   // rows outside the set that point into it (applied with NOT (Set))
	Needs  []string // Moved: tables the move does not carry whose matching <DST> row must exist first (an FK)
	Reason string   // the spec row it follows, or why the table is left
}

// Binds are the frozen id lists of the journal (section 8.3) a predicate may
// name as @<bind>, with their Postgres types. `plan` (T4) computes them in
// <SRC> in one read transaction.
var Binds = map[string]string{
	"channel":    "text",   // M1 the channel id
	"tasks":      "uuid[]", // M2 every task id of the set (topics, threads, sub-tasks)
	"msgs":       "uuid[]", // M2 every msg id of the set
	"mark_keys":  "text[]", // read_marks keys of the set: 'ch:<channel>' and 't:<task>' per task
	"events":     "uuid[]", // calendar_events.event_id of rows whose topic_id is an M2 task
	"jobs":       "text[]", // hours_jobs.job_id of jobs whose task_id is an M2 task
	"targets":    "text[]", // M6c hours targets: 'ch:<channel>', 't:<task>', 'cal:<event>', 'job:<job>'
	"numbers":    "int[]",  // M7 the <SRC> issue numbers of the set
	"issue_keys": "text[]", // M7 their <SRC> keys (<prefix>-<number>)
	"docs":       "uuid[]", // M8 workspace_doc ids of the set
	"nodes":      "uuid[]", // workspace_doc_node ids of those docs
	"ids":        "text[]", // every id above as text: audit rows whose ref names one (5.2)
	"id_likes":   "text[]", // '%<id>%' for each of @ids: audit rows whose free text quotes one (5.2)
}

// Catalogue is every tenant_id table, Moved entries in insert order (a parent
// before the rows that reference it). The gate holds it to the migrations.
// Spec 169 v0.5 (79e135594) settled the calls the spec text left open.
var Catalogue = concat(movedTables, rewrittenTables, recomputedTables, refuseTables, notChannelTables)

var movedTables = []Entry{
	{Table: "channels", Class: Moved, Set: `channel_id = @channel`, Reason: "M1"},
	{Table: "messages", Class: Moved,
		Set:    `channel = @channel OR task_id = ANY(@tasks) OR parent_task_id = ANY(@tasks) OR msg_id = ANY(@msgs)`,
		Refs:   `moved_from_channel = @channel OR moved_from_task = ANY(@tasks) OR moved_from_parent = ANY(@tasks) OR ref_task_id = ANY(@tasks)`,
		Reason: "M2 incl. mirror_of copies; Refs: M6b moved_from_* and M9 DM ref_task_id set to NULL in <SRC>"},
	{Table: "message_revisions", Class: Moved, Set: `msg_id = ANY(@msgs)`, Reason: "M3"},
	{Table: "message_reactions", Class: Moved, Set: `msg_id = ANY(@msgs)`, Reason: "M3"},
	{Table: "message_kind_changes", Class: Moved, Set: `msg_id = ANY(@msgs)`, Reason: "M3"},
	{Table: "message_moderation", Class: Moved, Set: `msg_id = ANY(@msgs)`, Reason: "M3"},
	{Table: "message_answers", Class: Moved, Set: `answers = ANY(@msgs) OR answer_msg_id = ANY(@msgs)`, Reason: "M3 polls and their answers"},
	{Table: "deliveries", Class: Moved, Set: `msg_id = ANY(@msgs)`, Reason: "M3"},
	{Table: "delivery_live_acks", Class: Moved, Set: `msg_id = ANY(@msgs)`, Reason: "M3 (rdb 0186)"},
	{Table: "fallback_deliveries", Class: Moved, Set: `msg_id = ANY(@msgs) OR channel_id = @channel`, Reason: "M3"},
	{Table: "read_marks", Class: Moved, Set: `mark_key = ANY(@mark_keys) OR msg_id = ANY(@msgs::text[])`,
		Reason: "M3; carried for kept members, deleted for the rest (Q5)"},
	{Table: "channel_humans", Class: Moved, Set: `channel_id = @channel`, Reason: "M5; kept members only, the rest deleted (Q5)"},
	{Table: "channel_invites", Class: Moved, Set: `channel_id = @channel`, Needs: []string{"tenant_invites"},
		Reason: "M5 (5.1b): kept emails only, after their <DST> tenant invite is written (Q5); deleted otherwise"},
	{Table: "channel_subscriptions", Class: Moved, Set: `channel_id = @channel`, Reason: "M5"},
	{Table: "dedicated_agents", Class: Moved, Set: `scope_type = 'channel' AND scope_id = @channel`, Reason: "M5 channel seats, moved in P4 (W2)"},
	{Table: "topic_heads", Class: Moved, Set: `task_id = ANY(@tasks)`,
		Refs:   `last_msg_id = ANY(@msgs) OR dm_last_msg_id = ANY(@msgs)`,
		Reason: "M6; Refs: heads of staying topics, recomputed from the remaining rows"},
	{Table: "topic_head_parts", Class: Moved, Set: `task_id = ANY(@tasks) OR channel = @channel`,
		Refs: `last_msg_id = ANY(@msgs)`, Reason: "M6; Refs: recomputed like topic_heads"},
	{Table: "topic_priorities", Class: Moved, Set: `task_id = ANY(@tasks)`, Reason: "M6"},
	{Table: "flow_watches", Class: Moved, Set: `task_id = ANY(@tasks)`, Reason: "M6"},
	{Table: "flow_events", Class: Moved, Set: `task_id = ANY(@tasks) OR msg_id = ANY(@msgs)`, Reason: "M6"},
	{Table: "calendar_events", Class: Moved, Set: `event_id = ANY(@events)`, Reason: "M6 events whose topic_id is an M2 task"},
	{Table: "calendar_guests", Class: Moved, Set: `event_id = ANY(@events)`, Reason: "child of calendar_events (FK, cascade)"},
	{Table: "hours_jobs", Class: Moved, Set: `job_id = ANY(@jobs)`, Reason: "M6 (rdb 0216) jobs that name an M2 topic"},
	{Table: "hours_plan", Class: Moved, Set: `job_id = ANY(@jobs)`, Reason: "child of hours_jobs (FK, cascade): plan slots follow their job"},
	{Table: "hours_minutes", Class: Moved, Set: `target = ANY(@targets)`,
		Reason: "M6c (5.1a), only its t: and ch: targets exist (rdb 0218); kept members only; a row in a frozen or approved <SRC> period makes plan refuse (Q8, T4)"},
	{Table: "hours_entries", Class: Moved, Set: `target = ANY(@targets)`, Reason: "M6c (5.1a), as hours_minutes"},
	{Table: "hours_entry_spans", Class: Moved, Set: `target = ANY(@targets)`, Reason: "M6c (5.1a), child of hours_entries (FK)"},
	{Table: "hours_adjustments", Class: Moved, Set: `target = ANY(@targets)`, Reason: "M6c (5.1a), as hours_minutes"},
	{Table: "issues", Class: Moved, Set: `number = ANY(@numbers)`, Reason: "M7, renumbered under <DST>'s prefix (F6)"},
	{Table: "issue_events", Class: Moved, Set: `number = ANY(@numbers)`, Reason: "M7"},
	{Table: "issue_opens", Class: Moved, Set: `number = ANY(@numbers)`, Reason: "M7"},
	{Table: "issue_discussions", Class: Moved, Set: `number = ANY(@numbers)`, Reason: "M7"},
	{Table: "workspace_doc", Class: Moved, Set: `id = ANY(@docs)`, Reason: "M8"},
	{Table: "workspace_doc_item", Class: Moved, Set: `doc_id = ANY(@docs)`, Reason: "M8"},
	{Table: "workspace_doc_node", Class: Moved, Set: `doc_id = ANY(@docs)`, Reason: "M8, re-placed under a folder named for the channel"},
	{Table: "workspace_doc_acl", Class: Moved, Set: `node_id = ANY(@nodes)`, Reason: "M8"},
	{Table: "workspace_doc_rev_log", Class: Moved, Set: `doc_id = ANY(@docs)`, Reason: "M8"},
	{Table: "spec_sync_map", Class: Moved, Set: `issue_number = ANY(@numbers) OR qto_doc_id = ANY(@docs)`,
		Reason: "M7 (rdb 0208); a row a staying issue or doc also needs is a shared item: plan refuses (5.5, Q6)"},
	{Table: "usage_events", Class: Moved, Set: `channel_id = @channel`, Reason: "M10"},
	{Table: "token_budgets", Class: Moved, Set: `channel_id = @channel`, Reason: "M10"},
	{Table: "workspace_events", Class: Moved, Set: `origin_ref = ANY(@ids) OR message LIKE ANY(@id_likes)`, Reason: "5.2 events about the set"},
	{Table: "operator_audit", Class: Moved, Set: `detail::text LIKE ANY(@id_likes)`, Reason: "5.2 audit rows about the set"},
	{Table: "demo_post_audit", Class: Moved,
		Set:    `msg_id = ANY(@msgs) OR task_id = ANY(@tasks::text[]) OR channel = @channel`,
		Reason: "5.2 audit rows about the set"},
	{Table: "sql_query_audit", Class: Moved, Set: `query_text LIKE ANY(@id_likes) OR error_message LIKE ANY(@id_likes)`,
		Reason: "5.2 audit rows about the set"},
}

var rewrittenTables = []Entry{
	{Table: "tenant_memberships", Class: Rewritten, Refs: `@channel = ANY(channel_order)`,
		Reason: "M5: the channel id is removed from every <SRC> channel_order"},
	{Table: "fleet_lanes", Class: Rewritten, Refs: `issue_key = ANY(@issue_keys)`, Reason: "M11: old issue keys rewritten to the new ones"},
	{Table: "fleet_asks", Class: Rewritten, Refs: `issue_key = ANY(@issue_keys)`, Reason: "M11: old issue keys rewritten to the new ones"},
	{Table: "gcal_event_map", Class: Rewritten, Refs: `event_id = ANY(@events)`,
		Reason: "5.1a: not carried (its connection is a <SRC> member's); before P4, T5 claims the connection and deletes the Google event, then P4's cascade drops the row"},
}

var recomputedTables = []Entry{
	{Table: "message_period_counts", Class: Recomputed, Reason: "5.1 aggregate counter (C9)"},
	{Table: "quota_counts", Class: Recomputed, Reason: "5.1 aggregate counter (C9)"},
	{Table: "topic_head_tenants", Class: Recomputed, Reason: "5.1 aggregate counter (C9)"},
	{Table: "tenant_change_stamps", Class: Recomputed, Reason: "5.1 change stamps bumped so cached views refetch"},
	{Table: "issue_counters", Class: Recomputed, Reason: "F6: <DST>'s counter advances by the renumbered issues"},
}

var refuseTables = []Entry{
	{Table: "embed_visitors", Class: Refuse, Set: `channel_id = @channel`,
		Reason: "5.1b: embed_customers.embed_id is hub-wide and in the iframe URL, so <DST> cannot hold the parent; plan refuses (Q6), a copy does not carry it"},
}

var notChannelTables = concat(
	notChannel("the workspace itself, its hosts, billing and settings",
		"tenants", "tenant_hosts", "tenant_seat_periods", "payment_checkouts", "tenant_agent_caps",
		"tenant_agent_split_kind", "agent_lifecycle_config", "embed_customers",
		"demo_bans", "workspace_vendor_keys", "workspace_vendor_key_boxes", "workspace_vendor_key_settings",
		"workspace_vendor_key_audit", "member_activity", "member_clones"),
	notChannel("workspace membership and roles; channel membership is channel_humans",
		"tenant_invites", "tenant_invite_roles", "tenant_member_roles", "tenant_role_grants", "rbac_roles",
		"human_status", "agent_sender_lists", "agent_sender_allow"),
	notChannel("boxes, keys and desks; a seat's <DST> desk is proved in P2b (W2), not moved",
		"boxes", "pins", "pins_history", "roster", "agent_seats", "agent_join_tokens", "agent_id_aliases",
		"box_beats", "box_facts", "box_lock_audit", "box_locks", "box_operators", "box_stats"),
	notChannel("DM agents: a DM is two parties', not a channel's (M9)", "dm_agents"),
	notChannel("box file streams, keyed by box and path", "file_stream_folders", "file_stream_glob_audit",
		"file_stream_globs", "file_stream_lines", "file_streams"),
	notChannel("fleet state keyed by fleet, agent and box; lanes and asks are rewritten above",
		"fleet_leases", "od_pool", "agent_lifecycle_events", "shared_memory_lessons"),
	notChannel("costs keyed by agent, model and day", "cost_lines"),
	notChannel("hours of members, keyed by member and day; rows that name the set move (M6c, hours_jobs)",
		"hours_changes", "hours_crew_members", "hours_crews", "hours_days", "hours_holidays", "hours_member_pins",
		"hours_ops", "hours_periods", "hours_standard_days", "hours_terminals"),
	notChannel("a member's Google link; watch_channel_id is a calendar push channel, not a spool channel",
		"gcal_connections", "contacts_sync"),
	notChannel("the workspace's label catalogue; T5b creates each missing label_id of a moved issue in <DST>", "issue_labels"),
	notChannel("marketing_*.channel_id is a social-media channel (rdb 0187), not a spool channel",
		"marketing_channel_tokens", "marketing_channels", "marketing_metric_definitions",
		"marketing_metric_samples", "marketing_post_events", "marketing_posts"),
	notChannel("repo-doc edits name a git path and ref; T8's free-text scan (5.2) reads target_ref",
		"repo_doc_author_notices", "repo_doc_authors", "repo_doc_edits"),
	notChannel("browser timing samples keyed by session", "wui_perf_samples"),
)

// notChannel returns NotChannel entries that share one reason.
func notChannel(reason string, tables ...string) []Entry {
	out := make([]Entry, len(tables))
	for i, t := range tables {
		out[i] = Entry{Table: t, Class: NotChannel, Reason: reason}
	}
	return out
}

func concat(groups ...[]Entry) []Entry {
	var out []Entry
	for _, g := range groups {
		out = append(out, g...)
	}
	return out
}

// Lookup returns the entry of a table.
func Lookup(table string) (Entry, bool) {
	for _, e := range Catalogue {
		if e.Table == table {
			return e, true
		}
	}
	return Entry{}, false
}
