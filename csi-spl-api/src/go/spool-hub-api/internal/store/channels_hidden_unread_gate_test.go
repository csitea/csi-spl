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

	if open, same := hiddenGateCompare(t, pg, tid, now, reads, "HUM-1", lobby); open || !same {
		t.Fatalf("only issues + an archived channel unmarked: gate open=%v (want false), same list=%v", open, same)
	}
	archivedTopic("ops", 16*time.Minute) // HUM-1 is no member of ops
	if open, same := hiddenGateCompare(t, pg, tid, now, reads, "HUM-1", lobby); !open || !same {
		t.Fatalf("unjoined ops unmarked: gate open=%v (want true), same list=%v", open, same)
	}
	for _, reader := range []string{"", "HUM-2"} {
		if _, same := hiddenGateCompare(t, pg, tid, now, nil, reader, lobby); !same {
			t.Fatalf("reader %q, no marks: list differs from the ap-02 gate", reader)
		}
	}
}

// hiddenGateCompare reports whether the fixed gate is open, and whether the
// channel list is the same under the ap-02 gate and the fixed one.
func hiddenGateCompare(t *testing.T, pg *Postgres, tid string, now time.Time, reads map[string]ReadMark, reader, lobby string) (bool, bool) {
	t.Helper()
	ctx := context.Background()
	fixed := newChannelStats(tid).hiddenUnreadRead(reads, now, reader, lobby)
	if !strings.Contains(fixed.sql, gateSkip) {
		t.Fatal("the gate no longer carries the skip this test cuts out")
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
			h.sql, h.args = strings.Replace(h.sql, gateSkip, "", 1), h.args[:7]
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
