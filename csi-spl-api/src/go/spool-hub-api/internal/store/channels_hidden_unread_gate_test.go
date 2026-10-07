package store

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// gateSkip is what the ap-02 gate fix added to um; cutting it out is the
// gate as ap-02 shipped it (0576d2cd).
var gateSkip = "\n\t\t\tAND cl.ch <> ALL($8::text[]) AND " + notArchived("cl.ch")

// narrowSkip is what ap-02 explore added to um after gateSkip; cutting it out
// is the gate as f2e86af25ab6 shipped it.
var narrowSkip = "\n\t\t\tAND (SELECT true FROM messages a WHERE a.tenant_id = $1 AND a.archived_at IS NOT NULL LIMIT 1)" +
	"\n\t\t\tAND (SELECT true FROM messages u WHERE u.tenant_id = $1 AND u.channel = cl.ch AND u.expires_at > $2" +
	"\n\t\t\t\tAND ($6::text IS NULL OR u.from_id IS DISTINCT FROM $6) AND " + hiddenLineSQL + " LIMIT 1)"

// TestHiddenUnreadGateSkipsUnlistedChannels (Postgres): a reader whose only
// unmarked channels are issues and an archived channel gets the ap-02 gate
// closed, and the same channel list as the ap-02 gate. An unmarked live
// channel the reader has not joined still opens it, with the same list.
func TestHiddenUnreadGateSkipsUnlistedChannels(t *testing.T) {
	ds := drivers(t)
	s, ok := ds["postgres"]
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	pg := s.(*Postgres)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	tid := newTenant(t, pg)
	lobby := "00000000-0000-4000-8000-0000000000aa"
	line := func(ago time.Duration, task, ch, from string) Message {
		m := msgFor(tid, task, "box-wui", now, now.Add(-ago), "e")
		m.Channel, m.FromID, m.ReceivedAt = ch, from, now.Add(-ago)
		return m
	}
	// archivedTopic posts a card and a reply in ch and archives the card.
	archivedTopic := func(ch string, ago time.Duration) {
		t.Helper()
		task := uuid4()
		card := line(ago, task, ch, "CLE-07")
		for _, m := range []Message{card, line(ago-time.Minute, task, ch, "CLE-07")} {
			if _, err := pg.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := pg.SetArchived(ctx, tid, card.MsgID, "HUM-1", now.Add(-time.Minute), true); err != nil {
			t.Fatal(err)
		}
	}
	for _, ch := range []string{"old", "ops"} {
		if err := pg.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: "HUM-2"}); err != nil {
			t.Fatal(err)
		}
	}
	archivedTopic("devel", 20*time.Minute)
	archivedTopic(ChannelLobby, 19*time.Minute)
	archivedTopic(ChannelIssues, 18*time.Minute)
	archivedTopic("old", 17*time.Minute)
	if err := pg.ArchiveChannel(ctx, tid, "old", "HUM-2", now.Add(-30*time.Second)); err != nil {
		t.Fatal(err)
	}
	early := now.Add(-time.Hour)
	reads := map[string]ReadMark{"devel": {At: early}, ChannelLobby: {At: early}}

	if open, same := hiddenGateCompare(t, pg, tid, now, reads, "HUM-1", lobby, gateSkip, narrowSkip); open || !same {
		t.Fatalf("only issues + an archived channel unmarked: gate open=%v (want false), same list=%v", open, same)
	}
	archivedTopic("ops", 16*time.Minute) // HUM-1 is no member of ops
	if open, same := hiddenGateCompare(t, pg, tid, now, reads, "HUM-1", lobby, gateSkip, narrowSkip); !open || !same {
		t.Fatalf("unjoined ops unmarked: gate open=%v (want true), same list=%v", open, same)
	}
	for _, reader := range []string{"", "HUM-2"} {
		if _, same := hiddenGateCompare(t, pg, tid, now, nil, reader, lobby, gateSkip, narrowSkip); !same {
			t.Fatalf("reader %q, no marks: list differs from the ap-02 gate", reader)
		}
	}
}

// TestHiddenUnreadGateSkipsChannelsWithNoHiddenLine (Postgres, ap-02
// explore): an unmarked channel whose lines are none hidden, or hidden but
// only the reader's own or expired, keeps the gate closed, with the same list
// as the f2e86af25ab6 gate. A hidden live line of another opens it - also a
// reply moved into the unmarked channel from a marked one's archived card.
func TestHiddenUnreadGateSkipsChannelsWithNoHiddenLine(t *testing.T) {
	ds := drivers(t)
	s, ok := ds["postgres"]
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	pg := s.(*Postgres)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	tid := newTenant(t, pg)
	lobby := "00000000-0000-4000-8000-0000000000aa"
	insert := func(m Message) {
		t.Helper()
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	line := func(ago time.Duration, task, ch, from string) Message {
		m := msgFor(tid, task, "box-wui", now, now.Add(-ago), "e")
		m.Channel, m.FromID, m.ReceivedAt = ch, from, now.Add(-ago)
		return m
	}
	// archivedTopic posts a card in ch and a reply in replyCh, both by from
	// (expired when gone), and archives the card.
	archivedTopic := func(ch, replyCh, from string, ago time.Duration, gone bool) {
		t.Helper()
		task := uuid4()
		card, reply := line(ago, task, ch, from), line(ago-time.Minute, task, replyCh, from)
		if gone {
			card.ExpiresAt, reply.ExpiresAt = now.Add(-time.Second), now.Add(-time.Second)
		}
		insert(card)
		insert(reply)
		if _, err := pg.SetArchived(ctx, tid, card.MsgID, "HUM-1", now.Add(-time.Minute), true); err != nil {
			t.Fatal(err)
		}
	}
	insert(line(30*time.Minute, uuid4(), "fina", "CLE-07")) // live, not hidden
	archivedTopic("devel", "devel", "CLE-07", 20*time.Minute, false)
	archivedTopic("own", "own", "HUM-1", 19*time.Minute, false)
	archivedTopic("gone", "gone", "CLE-07", 18*time.Minute, true)
	early := now.Add(-time.Hour)
	reads := map[string]ReadMark{"devel": {At: early}}

	if open, same := hiddenGateCompare(t, pg, tid, now, reads, "HUM-1", lobby, narrowSkip); open || !same {
		t.Fatalf("no hidden live line of another unmarked: gate open=%v (want false), same list=%v", open, same)
	}
	if open, same := hiddenGateCompare(t, pg, tid, now, reads, "HUM-2", lobby, narrowSkip); !open || !same {
		t.Fatalf("HUM-2 reads HUM-1's hidden lines in own: gate open=%v (want true), same list=%v", open, same)
	}
	archivedTopic("devel", "fina", "CLE-07", 10*time.Minute, false) // a reply moved into fina
	if open, same := hiddenGateCompare(t, pg, tid, now, reads, "HUM-1", lobby, narrowSkip); !open || !same {
		t.Fatalf("hidden moved reply in fina: gate open=%v (want true), same list=%v", open, same)
	}
	for _, reader := range []string{"", "HUM-2"} {
		if _, same := hiddenGateCompare(t, pg, tid, now, nil, reader, lobby, narrowSkip); !same {
			t.Fatalf("reader %q, no marks: list differs from the f2e86af25ab6 gate", reader)
		}
	}
}

// hiddenGateCompare reports whether the gate is open, and whether the
// channel list is the same under the gate and the gate with cuts cut out.
func hiddenGateCompare(t *testing.T, pg *Postgres, tid string, now time.Time, reads map[string]ReadMark, reader, lobby string, cuts ...string) (bool, bool) {
	t.Helper()
	ctx := context.Background()
	fixed := newChannelStats(tid).hiddenUnreadRead(reads, now, reader, lobby)
	for _, c := range cuts {
		if !strings.Contains(fixed.sql, c) {
			t.Fatalf("the gate no longer carries the skip this test cuts out: %q", c)
		}
	}
	var open int
	cut := strings.Index(fixed.sql, ",\n\t\tz AS (")
	if err := pg.queryTenant(ctx, tid, fixed.sql[:cut]+` SELECT count(*)::int FROM um WHERE $2::timestamptz IS NOT NULL AND $7::text IS NOT NULL`,
		fixed.args, func(r pgx.Rows) error { return r.Scan(&open) }); err != nil {
		t.Fatal(err)
	}
	list := func(old bool) string {
		cs := newChannelStats(tid)
		h := cs.hiddenUnreadRead(reads, now, reader, lobby)
		if old {
			for _, c := range cuts {
				h.sql = strings.Replace(h.sql, c, "", 1)
			}
			if !strings.Contains(h.sql, "$8") {
				h.args = h.args[:7]
			}
		}
		if err := pg.queryTenantBatch(ctx, tid, cs.channelsRead(), cs.countsRead(now, reader),
			cs.markedUnreadRead(reads, now, reader, lobby), h, cs.membersRead()); err != nil {
			t.Fatal(err)
		}
		out := cs.result()
		sort.Slice(out, func(i, j int) bool { return out[i].ChannelID < out[j].ChannelID })
		raw, err := json.Marshal(out)
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}
	a, b := list(true), list(false)
	if a != b {
		t.Logf("ap-02 gate %s\nfixed gate %s", a, b)
	}
	return open > 0, a == b
}
