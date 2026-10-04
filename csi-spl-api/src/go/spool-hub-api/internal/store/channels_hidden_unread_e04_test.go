package store

import (
	"context"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestHiddenUnreadReadsEachArchivedLineOnce pins the shape measured on prd t1
// (perf edition 20261004, E04). The archived set used to be joined back to
// messages on the primary key, one probe per hidden line. Planting that join
// fails this test.
func TestHiddenUnreadReadsEachArchivedLineOnce(t *testing.T) {
	sql := newChannelStats("t1").hiddenUnreadRead(nil, time.Now(), "HUM-1", "00000000-0000-4000-8000-000000000001").sql
	if strings.Contains(sql, "m.msg_id = h.msg_id") {
		t.Fatal("hidden unread joins messages a second time on msg_id")
	}
	if !strings.Contains(sql, "m.channel, m.from_id, m.expires_at") {
		t.Fatal("hidden unread dropped channel, from_id and expires_at off the archived pass")
	}
}

// TestChannelUnreadViewJSON is the byte-compare of the channel view on one
// seeded fixture (archived, marked, hidden, an own line, a lobby thread, a
// child of an archived task). Memory and Postgres must print the same JSON.
func TestChannelUnreadViewJSON(t *testing.T) {
	ds := drivers(t)
	pg, ok := ds["postgres"]
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	mem := ds["memory"]
	now := time.Now().UTC().Truncate(time.Microsecond)
	gotM := unreadViewJSON(t, mem, now)
	gotP := unreadViewJSON(t, pg, now)
	if gotM != gotP {
		t.Fatalf("view JSON differs\nmemory   %s\npostgres %s", gotM, gotP)
	}
}

// Fixed ids so the two stores seed the same rows and the JSON can be compared
// byte for byte. Not uuid4(): that would differ per store.
const (
	viewKept  = "10000000-0000-4000-8000-000000000001"
	viewGone  = "10000000-0000-4000-8000-000000000002"
	viewLobby = "10000000-0000-4000-8000-000000000003"
	viewLive  = "10000000-0000-4000-8000-000000000004"
	viewArch  = "10000000-0000-4000-8000-000000000005"
	viewOther = "10000000-0000-4000-8000-000000000006"
)

// unreadViewJSON seeds s at now and returns the canonical view JSON. The
// fixture's unread is devel (marked) 2, ops (no mark) 2, lobby 2.
func unreadViewJSON(t *testing.T, s Store, now time.Time) string {
	t.Helper()
	ctx := context.Background()
	tid := newTenant(t, s)
	lobby := viewLobby
	var n int
	line := func(ago time.Duration, task, ch, from, typed, parent string) Message {
		n++
		m := msgFor(tid, task, "box-wui", now, now.Add(-ago), "e")
		m.MsgID = "20000000-0000-4000-8000-" + leftPad(n)
		m.Channel, m.FromID, m.TypedBy, m.ParentTaskID = ch, from, typed, parent
		m.ReceivedAt = now.Add(-ago)
		return m
	}
	insert := func(ms ...Message) {
		t.Helper()
		for _, m := range ms {
			if _, err := s.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
		}
	}
	kept, gone := viewKept, viewGone
	mark := line(10*time.Minute, kept, "devel", "CLE-07", "", "")
	goneCard := line(9*time.Minute, gone, "devel", "CLE-07", "", "")
	keptCard := line(8*time.Minute, kept, "devel", "CLE-07", "", "")
	insert(mark, goneCard, keptCard,
		line(7*time.Minute, gone, "devel", "CLE-07", "", ""),
		line(6*time.Minute, kept, "devel", "CLE-07", "", ""))
	if _, err := s.SetArchived(ctx, tid, goneCard.MsgID, "HUM-1", now.Add(-5*time.Minute), true); err != nil {
		t.Fatal(err)
	}
	insert(line(4*time.Minute, gone, "devel", "CLE-07", "", ""),
		line(3*time.Minute, kept, "devel", "HUM-1", "", ""),
		line(2*time.Minute, kept, "devel", "CLE-07", "HUM-1", ""))
	expired := line(time.Minute, kept, "devel", "CLE-07", "", "")
	expired.ExpiresAt = now.Add(-time.Second)
	insert(expired)

	liveOps, archOps := viewLive, viewArch
	archCard := line(9*time.Minute, archOps, "ops", "CLE-07", "", "")
	insert(line(10*time.Minute, liveOps, "ops", "CLE-07", "", ""), archCard,
		line(8*time.Minute, archOps, "ops", "CLE-07", "", ""))
	if _, err := s.SetArchived(ctx, tid, archCard.MsgID, "HUM-1", now.Add(-5*time.Minute), true); err != nil {
		t.Fatal(err)
	}
	insert(line(5*time.Minute, liveOps, "ops", "CLE-07", "", ""),
		line(4*time.Minute, liveOps, "ops", "HUM-1", "", ""),
		line(3*time.Minute, archOps, "ops", "HUM-1", "", ""),
		line(90*time.Second, viewOther, "ops", "CLE-07", "", archOps))

	lobbyCard := line(9*time.Minute, lobby, "lobby", "CLE-07", "", "")
	insert(line(10*time.Minute, lobby, "lobby", "CLE-07", "", ""), lobbyCard)
	if _, err := s.SetArchived(ctx, tid, lobbyCard.MsgID, "HUM-1", now.Add(-5*time.Minute), true); err != nil {
		t.Fatal(err)
	}
	insert(line(3*time.Minute, lobbyCard.MsgID, "lobby", "CLE-07", "", ""),
		line(2*time.Minute, lobby, "lobby", "CLE-07", "", ""))

	reads := map[string]ReadMark{"devel": {At: mark.ReceivedAt, MsgID: mark.MsgID}}
	stats, err := s.ViewChannelStats(ctx, tid, now, reads, "HUM-1", lobby)
	if err != nil {
		t.Fatal(err)
	}
	type row struct {
		ChannelID string `json:"channel_id"`
		Count     int    `json:"count"`
		Unread    int    `json:"unread"`
		Posters   int    `json:"posters"`
		LastMsgID string `json:"last_msg_id"`
		LastAt    string `json:"last_at"`
	}
	out := make([]row, 0, len(stats))
	unread := map[string]int{}
	for _, st := range stats {
		at := ""
		if !st.LastAt.IsZero() {
			at = strconv.FormatInt(st.LastAt.UTC().UnixMicro(), 10)
		}
		out = append(out, row{st.ChannelID, st.Count, st.Unread, st.Posters, st.LastMsgID, at})
		unread[st.ChannelID] = st.Unread
	}
	// The list is newest-activity first. Compare it sorted by id so the byte
	// check is the rows, not the sort.
	sort.Slice(out, func(i, j int) bool { return out[i].ChannelID < out[j].ChannelID })
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if unread["devel"] != 2 || unread["ops"] != 2 || unread["lobby"] != 2 {
		t.Fatalf("unread devel/ops/lobby = %d/%d/%d, want 2/2/2", unread["devel"], unread["ops"], unread["lobby"])
	}
	return string(raw)
}

// leftPad is 12 lowercase hex digits, the tail of a uuid.
func leftPad(n int) string {
	s := strconv.FormatInt(int64(n), 16)
	return strings.Repeat("0", 12-len(s)) + s
}

// hiddenUnreadBufferBudget is the shared-buffer ceiling of one hidden-unread
// read over hiddenUnreadTopics archived topics (16 lines each). On an
// analyzed postgres:16 of this seed the one-pass read touched 3900 shared
// buffers; the planted primary-key rejoin touched 8750 and fails the budget
// (n=1). The planner did not choose messages_pkey for either shape at this
// size; the shape test is what fails that plant when the rejoin text returns.
const (
	hiddenUnreadTopics        = 2000
	hiddenUnreadLinesPerTopic = 16
	hiddenUnreadBufferBudget  = 6000
)

// TestHiddenUnreadBufferBudget (Postgres): building the archived set and
// counting it touch at most hiddenUnreadBufferBudget shared buffers, and the
// plan does not probe messages_pkey once per hidden line.
func TestHiddenUnreadBufferBudget(t *testing.T) {
	pg := perfStore(t, "")
	ctx := context.Background()
	tid := perfTenant(t, pg)
	t.Cleanup(func() {
		_ = pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, tid)
			return err
		})
	})
	now := time.Now().UTC().Truncate(time.Second)
	n := hiddenUnreadTopics * hiddenUnreadLinesPerTopic
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id,
			to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at, archived_at)
			SELECT $1,
				('10000000-0000-4000-8000-' || lpad(to_hex(g), 12, '0'))::uuid,
				('10000000-0000-4000-8000-' || lpad(to_hex(((g - 1) / $5) * $5 + 1), 12, '0'))::uuid,
				'devel', $2::timestamptz, 'box-a', 'CLE-01', 'box-b', 'HUM-2', 'note', 'b', '{"v":1}', 'sig',
				convert_to('x', 'UTF8'), $2::timestamptz - (g || ' seconds')::interval, $3::timestamptz,
				CASE WHEN (g - 1) % $5 = 0 THEN $2::timestamptz ELSE NULL::timestamptz END
			FROM generate_series(1, $4) g`, tid, now, now.Add(30*24*time.Hour), n, hiddenUnreadLinesPerTopic)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.pool.Exec(ctx, `ANALYZE messages`); err != nil {
		t.Fatal(err)
	}
	cs := newChannelStats(tid)
	r := cs.hiddenUnreadRead(nil, now, "HUM-1", "00000000-0000-4000-8000-0000000000aa")
	var sum int
	if err := pg.queryTenant(ctx, tid, r.sql, r.args, func(rows pgx.Rows) error {
		var ch string
		var n int
		if err := rows.Scan(&ch, &n); err != nil {
			return err
		}
		if ch == "devel" {
			sum = n
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if sum != n {
		t.Fatalf("hidden lines in devel = %d, want %d", sum, n)
	}
	indexes, buffers, ms := explainUnread(t, pg, tid, r.sql, r.args)
	pkeys := 0
	for _, name := range indexes {
		if name == "messages_pkey" {
			pkeys++
		}
	}
	t.Logf("PERF hidden unread: topics=%d lines=%d shared buffers=%d pkey lookups=%d exec=%.2f ms indexes=%v", hiddenUnreadTopics, n, buffers, pkeys, ms, indexes)
	if pkeys > 1 {
		t.Fatalf("plan looks hidden lines up on messages_pkey %d times; the archived pass must carry the line", pkeys)
	}
	if buffers > hiddenUnreadBufferBudget {
		t.Fatalf("hidden unread touched %d shared buffers, budget %d", buffers, hiddenUnreadBufferBudget)
	}
}

// explainUnread runs EXPLAIN (ANALYZE, BUFFERS) of sql in the tenant scope and
// returns every index the plan uses plus the root shared-buffer total.
func explainUnread(t *testing.T, pg *Postgres, tenant, sql string, args []any) ([]string, int, float64) {
	t.Helper()
	ctx := context.Background()
	var raw []byte
	if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SET LOCAL statement_timeout = '20s'`); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) `+sql, args...).Scan(&raw)
	}); err != nil {
		t.Fatal(err)
	}
	var doc []struct {
		Plan struct {
			SharedHit  int               `json:"Shared Hit Blocks"`
			SharedRead int               `json:"Shared Read Blocks"`
			Plans      []json.RawMessage `json:"Plans"`
			IndexName  string            `json:"Index Name"`
		} `json:"Plan"`
		ExecutionTime float64 `json:"Execution Time"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	var indexes []string
	var walk func(node json.RawMessage)
	walk = func(node json.RawMessage) {
		var n struct {
			IndexName string            `json:"Index Name"`
			Plans     []json.RawMessage `json:"Plans"`
		}
		if err := json.Unmarshal(node, &n); err != nil {
			t.Fatal(err)
		}
		if n.IndexName != "" {
			indexes = append(indexes, n.IndexName)
		}
		for _, c := range n.Plans {
			walk(c)
		}
	}
	root, err := json.Marshal(doc[0].Plan)
	if err != nil {
		t.Fatal(err)
	}
	walk(root)
	return indexes, doc[0].Plan.SharedHit + doc[0].Plan.SharedRead, doc[0].ExecutionTime
}
