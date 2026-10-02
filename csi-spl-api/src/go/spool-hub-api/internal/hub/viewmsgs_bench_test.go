package hub

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// viewMsgsOldDeliveries is the pre-perf viewMsgs (Deliveries started as an empty
// slice and grew by append), kept only so the benchmark shows the reallocations
// this change removes.
func viewMsgsOldDeliveries(rows []store.ViewMsg, react map[string][]store.StoredReaction) []viewMsg {
	out := make([]viewMsg, 0, len(rows))
	for _, m := range rows {
		v := viewMsg{Cursor: encCursor(m.ReceivedAt, m.MsgID), ReceivedAt: rfc(m.ReceivedAt),
			Env: json.RawMessage(m.Env), IsParent: m.IsParent,
			Reactions: groupReactions(react[m.MsgID]), TypedBy: m.TypedBy}
		ds := []viewDelivery{}
		for _, d := range m.Deliveries {
			ds = append(ds, viewDelivery{ToBox: d.ToBox, State: d.State})
		}
		v.Deliveries = &ds
		out = append(out, v)
	}
	return out
}

func benchViewMsgs() []store.ViewMsg {
	rows := make([]store.ViewMsg, 0, 20)
	for i := 0; i < 20; i++ {
		rows = append(rows, store.ViewMsg{
			MsgID: "m", ReceivedAt: time.Unix(1_800_000_000+int64(i), 0), Env: []byte(`{"v":1,"body":"hi"}`),
			Deliveries: []store.ViewDelivery{{ToBox: "box-a", State: "sent"}, {ToBox: "box-b", State: "queued"}, {ToBox: "box-c", State: "sent"}},
		})
	}
	return rows
}

func BenchmarkViewMsgsAppendDeliveries(b *testing.B) {
	rows := benchViewMsgs()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = viewMsgsOldDeliveries(rows, nil)
	}
}

func BenchmarkViewMsgsPresizedDeliveries(b *testing.B) {
	rows := benchViewMsgs()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = viewMsgs(rows, nil)
	}
}
