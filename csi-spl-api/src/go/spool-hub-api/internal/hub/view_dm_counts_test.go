package hub

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The DM counts the hub sends (dm_counts=true) and the counts the WUI made
// from the inline page (utils/channel-feed.mjs) are one set of rules: both
// sides pass the same fixture, csi-spl-wui/tests/unit/dm-counts-parity.json
// (the WUI half is tests/unit/dm-counts-parity.test.mjs).
func TestDMCountsMatchWUIFixture(t *testing.T) {
	path := filepath.Join("..", "..", "..", "..", "..", "..", "csi-spl-wui", "tests", "unit", "dm-counts-parity.json")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the shared fixture %s: %v", path, err)
	}
	var fx struct {
		Cases []struct {
			Name    string
			Self    string
			Cursors map[string]struct{ TS, ID string }
			Topics  []struct {
				Count        int
				Participants []string
				Messages     []struct {
					MsgID      string `json:"msg_id"`
					From       string
					FromBox    string `json:"from_box"`
					To         string
					ToBox      string `json:"to_box"`
					TypedBy    string `json:"typed_by"`
					Channel    string
					ReceivedAt string `json:"received_at"`
				}
			}
			Expect struct{ Unread, Total map[string]int }
		}
	}
	if err := json.Unmarshal(src, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) < 5 {
		t.Fatalf("fixture has %d cases", len(fx.Cases))
	}
	for _, c := range fx.Cases {
		t.Run(c.Name, func(t *testing.T) {
			// the cursors as the WUI sends them (dmReadParams): dm: keys with a time
			reads := map[string]dmCursor{}
			for k, v := range c.Cursors {
				if len(k) > 3 && k[:3] == "dm:" && v.TS != "" {
					reads[k[3:]] = dmCursor{ts: v.TS, id: v.ID}
				}
			}
			unread, total := map[string]int{}, map[string]int{}
			for _, tp := range c.Topics {
				var msgs []store.TopicMsgMeta
				for _, m := range tp.Messages {
					at, err := time.Parse(time.RFC3339Nano, m.ReceivedAt)
					if err != nil || rfc(at) != m.ReceivedAt {
						t.Fatalf("received_at %q is not the hub's own format (%v)", m.ReceivedAt, err)
					}
					msgs = append(msgs, store.TopicMsgMeta{MsgID: m.MsgID, ReceivedAt: at, FromID: m.From, FromBox: m.FromBox,
						ToID: m.To, ToBox: m.ToBox, TypedBy: m.TypedBy, Channel: m.Channel})
				}
				got := dmCounts(viewTopic{Count: tp.Count, Participants: tp.Participants}, msgs, c.Self, reads)
				for p, n := range got.Unread {
					unread["dm:"+p] += n
				}
				for p, n := range got.Total {
					total["dm:"+p] += n
				}
			}
			if !reflect.DeepEqual(unread, c.Expect.Unread) {
				t.Errorf("unread %v, want %v", unread, c.Expect.Unread)
			}
			if !reflect.DeepEqual(total, c.Expect.Total) {
				t.Errorf("total %v, want %v", total, c.Expect.Total)
			}
		})
	}
}

func TestParseDMReads(t *testing.T) {
	got, ok := parseDMReads([]string{"CLE-1@box-desk~2026-10-01T10:00:00.5Z~m1", "HUM-2@box-wui~2026-10-01T11:00:00Z~"})
	if !ok || got["CLE-1@box-desk"] != (dmCursor{"2026-10-01T10:00:00.5Z", "m1"}) || got["HUM-2@box-wui"] != (dmCursor{"2026-10-01T11:00:00Z", ""}) {
		t.Fatalf("%v %v", got, ok)
	}
	for _, bad := range []string{"no-tilde", "~2026-10-01T10:00:00Z"} {
		if _, ok := parseDMReads([]string{bad}); ok {
			t.Errorf("%q accepted", bad)
		}
	}
}
