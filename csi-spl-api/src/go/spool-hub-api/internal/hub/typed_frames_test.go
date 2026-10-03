package hub

import (
	"bytes"
	"encoding/json"
	"io"
	"strconv"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Perf round 4, G12: the presence, message_edited and message_deleted frames
// are typed structs. The legacy* builders below are the map frames they
// replaced, verbatim, kept as the byte-for-byte reference and the A side of
// the benchmarks.

func legacyPresenceFrame(peer, status string) map[string]string {
	return map[string]string{"type": "presence", "peer": peer, "status": status}
}

func legacyEditedFrame(m store.EditableMessage, canon []byte, e wire.Envelope, at time.Time, by string, rev int) map[string]any {
	frame := map[string]any{"type": editedFrame, "task_id": m.TaskID, "msg_id": m.MsgID,
		"cursor": encCursor(m.ReceivedAt, m.MsgID), "received_at": rfc(m.ReceivedAt),
		"envelope": e.Msg, "env": json.RawMessage(canon)}
	if m.Channel != "" {
		frame["channel"] = m.Channel
	}
	if e.ParentTaskID != "" {
		frame["parent_task_id"] = e.ParentTaskID
	}
	editedFields(frame, at, by, rev)
	kindFields(frame, m.Kind, m.KindSetAt, m.KindSetBy)
	return frame
}

func legacyDeletedFrame(m store.EditableMessage) map[string]any {
	frame := map[string]any{"type": deletedFrame, "task_id": m.TaskID, "msg_id": m.MsgID}
	if m.Channel != "" {
		frame["channel"] = m.Channel
	}
	return frame
}

func sameJSON(t *testing.T, name string, want, got any) {
	t.Helper()
	w, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	g, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(w, g) {
		t.Errorf("%s: typed frame differs from the map frame\nmap:   %s\ntyped: %s", name, w, g)
	}
}

func TestTypedPresenceFrameBytes(t *testing.T) {
	for _, c := range [][2]string{{"CLE-01@box-a", "online"}, {"c-036@sat", "offline"}, {"", ""}, {"a<b&c@x", "online"}} {
		f := presenceFrame(c[0], c[1])
		sameJSON(t, c[0]+"/"+c[1], legacyPresenceFrame(c[0], c[1]), &f)
	}
}

const typedCanon = `{"from_box":"box-a","msg":{"body":"a<b & c","from":"CLE-01","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","v":1},"parent_task_id":"33333333-3333-4333-8333-333333333333","to_box":"box-b"}`

func TestTypedEditedFrameBytes(t *testing.T) {
	recv := time.Date(2026, 10, 3, 2, 0, 0, 123456789, time.UTC)
	at := recv.Add(time.Minute)
	canons := map[string]string{
		"full":      typedCanon,
		"no parent": `{"msg":{"body":"x"}}`,
		"no msg":    `{}`,
	}
	for cn, canon := range canons {
		var e wire.Envelope
		if err := json.Unmarshal([]byte(canon), &e); err != nil {
			t.Fatal(err)
		}
		for _, ch := range []string{"", "general"} {
			for _, kindAt := range []time.Time{{}, at.Add(time.Second)} {
				for _, kind := range []string{"", "note"} {
					for _, edAt := range []time.Time{{}, at} {
						for _, by := range []string{"", "alice"} {
							for _, rev := range []int{-1, 0, 1, 7} {
								m := store.EditableMessage{MsgID: "11111111-1111-4111-8111-111111111111",
									TaskID: "22222222-2222-4222-8222-222222222222", Channel: ch, ReceivedAt: recv,
									Kind: kind, KindSetAt: kindAt, KindSetBy: by}
								name := cn + "/" + ch + "/" + kind + "/" + by + "/" + strconv.Itoa(rev)
								sameJSON(t, name, legacyEditedFrame(m, []byte(canon), e, edAt, by, rev), newEditedMsg(m, []byte(canon), e, edAt, by, rev))
							}
						}
					}
				}
			}
		}
	}
}

func TestTypedDeletedFrameBytes(t *testing.T) {
	for _, ch := range []string{"", "general"} {
		m := store.EditableMessage{MsgID: "11111111-1111-4111-8111-111111111111", TaskID: "22222222-2222-4222-8222-222222222222", Channel: ch}
		sameJSON(t, "channel="+ch, legacyDeletedFrame(m), newDeletedMsg(m))
	}
}

// The benchmarks are a proxy for the fan-outs: one encode per socket write,
// as wsjson.Write does, without the sockets. A = the map frames as they were
// built (presence: one map per agent x socket), B = the typed frames as
// presence / fanoutEdited / fanoutDeleted build them now.

const (
	benchAgents  = 10
	benchSockets = 5
	benchEditTo  = 10
)

func wsWrite(v any) { json.NewEncoder(io.Discard).Encode(v) } //nolint:errcheck

func benchAgentNames() []string {
	a := make([]string, benchAgents)
	for i := range a {
		a[i] = "CLE-" + strconv.Itoa(i)
	}
	return a
}

func BenchmarkPresenceFrameMap(b *testing.B) {
	agents := benchAgentNames()
	b.ReportAllocs()
	for range b.N {
		for range benchSockets {
			for _, a := range agents {
				wsWrite(legacyPresenceFrame(a+"@box-a", "online"))
			}
		}
	}
}

func BenchmarkPresenceFrameTyped(b *testing.B) {
	agents := benchAgentNames()
	b.ReportAllocs()
	for range b.N {
		frames := make([]presenceMsg, len(agents))
		for i, a := range agents {
			frames[i] = presenceFrame(a+"@box-a", "online")
		}
		for range benchSockets {
			for i := range frames {
				wsWrite(&frames[i])
			}
		}
	}
}

func benchEdit(b *testing.B) (store.EditableMessage, wire.Envelope, time.Time) {
	var e wire.Envelope
	if err := json.Unmarshal([]byte(typedCanon), &e); err != nil {
		b.Fatal(err)
	}
	at := time.Date(2026, 10, 3, 2, 1, 0, 0, time.UTC)
	m := store.EditableMessage{MsgID: "11111111-1111-4111-8111-111111111111", TaskID: "22222222-2222-4222-8222-222222222222",
		Channel: "general", ReceivedAt: at.Add(-time.Minute), Kind: "note", KindSetAt: at, KindSetBy: "alice"}
	return m, e, at
}

func BenchmarkEditedFrameMap(b *testing.B) {
	m, e, at := benchEdit(b)
	b.ReportAllocs()
	for range b.N {
		f := legacyEditedFrame(m, []byte(typedCanon), e, at, "alice", 2)
		for range benchEditTo {
			wsWrite(f)
		}
	}
}

func BenchmarkEditedFrameTyped(b *testing.B) {
	m, e, at := benchEdit(b)
	b.ReportAllocs()
	for range b.N {
		f := newEditedMsg(m, []byte(typedCanon), e, at, "alice", 2)
		for range benchEditTo {
			wsWrite(f)
		}
	}
}

func BenchmarkDeletedFrameMap(b *testing.B) {
	m, _, _ := benchEdit(b)
	b.ReportAllocs()
	for range b.N {
		f := legacyDeletedFrame(m)
		for range benchEditTo {
			wsWrite(f)
		}
	}
}

func BenchmarkDeletedFrameTyped(b *testing.B) {
	m, _, _ := benchEdit(b)
	b.ReportAllocs()
	for range b.N {
		f := newDeletedMsg(m)
		for range benchEditTo {
			wsWrite(f)
		}
	}
}
