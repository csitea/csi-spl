package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// channelCountsOracleSQL is the channel counts statement before SPL-1127
// (array_agg ... ORDER BY and count(DISTINCT)), kept as the oracle.
const channelCountsOracleSQL = `SELECT channel, count(*)::int, max(received_at),
		(array_agg(msg_id::text ORDER BY received_at DESC, msg_id::text DESC))[1], count(DISTINCT from_id)::int
	FROM messages WHERE tenant_id = $1 AND channel IS NOT NULL AND expires_at > $2 GROUP BY channel`

// SPL-1127: ViewChannelStats' counts (count, newest time, newest msg_id,
// posters) equal the pre-change statement's on Postgres, over channels with
// several posters, messages sharing their newest received_at (the msg_id
// tie-break), expired rows and DMs that must not count.
func TestChannelCountsMatchTheOracle(t *testing.T) {
	var pg *Postgres
	for _, s := range drivers(t) {
		if p, ok := s.(*Postgres); ok {
			pg = p
		}
	}
	if pg == nil {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	tid := newTenant(t, pg)
	put := func(channel, from string, at, expires time.Time) {
		t.Helper()
		m := Message{TenantID: tid, MsgID: uuid4(), TaskID: uuid4(), Channel: channel, TS: at,
			FromBox: "box-a", FromID: from, ToBox: "box-b", ToID: "HUM-9", Kind: "note", Body: "b",
			Files: []byte("[]"), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte("env-" + uuid4()),
			ReceivedAt: at, ExpiresAt: expires}
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	live := now.Add(time.Hour)
	for i := 0; i < 40; i++ {
		ch := []string{"tasks", "lobby", "ops", "qa"}[i%4]
		put(ch, fmt.Sprintf("HUM-%d", i%7), now.Add(-time.Duration(i)*time.Minute), live)
	}
	tie := now.Add(time.Minute)
	for i := 0; i < 5; i++ { // five messages share ops' newest received_at
		put("ops", "CLE-07", tie, live)
	}
	put("qa", "HUM-1", now.Add(2*time.Minute), now.Add(-time.Second)) // expired: never counted
	put("", "HUM-2", now.Add(3*time.Minute), live)                    // a DM: no channel

	type row struct {
		n, posters int
		last       time.Time
		lastID     string
	}
	want := map[string]row{}
	err := pg.queryTenant(ctx, tid, channelCountsOracleSQL, []any{tid, now}, func(r pgx.Rows) error {
		var ch string
		var v row
		if err := r.Scan(&ch, &v.n, &v.last, &v.lastID, &v.posters); err != nil {
			return err
		}
		if !ChannelHidden(ch) { // the listing never shows a hidden one (SPL-68)
			want[ch] = v
		}
		return nil
	})
	if err != nil || len(want) != 3 {
		t.Fatalf("oracle %d channels %v", len(want), err)
	}
	stats, err := pg.ViewChannelStats(ctx, tid, now, nil)
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, st := range stats {
		w, ok := want[st.ChannelID]
		if !ok {
			if st.Count != 0 {
				t.Fatalf("%s: %d messages, the oracle has none", st.ChannelID, st.Count)
			}
			continue
		}
		seen++
		got := row{st.Count, st.Posters, st.LastAt, st.LastMsgID}
		if got.n != w.n || got.posters != w.posters || !got.last.Equal(w.last) || got.lastID != w.lastID {
			t.Fatalf("%s: got %+v, oracle %+v", st.ChannelID, got, w)
		}
	}
	if seen != len(want) {
		t.Fatalf("%d of %d oracle channels in the stats", seen, len(want))
	}
}
