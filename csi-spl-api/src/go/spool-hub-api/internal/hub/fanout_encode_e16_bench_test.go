package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The fan-outs perf round 4 (G8) left encoding once per socket: reactions,
// topic archive / delete, move, merge, edit and delete (perf edition
// 20261004, E16). fanoutRig is fanout_encode_bench_test.go's.

const e16Canon = `{"channel":"` + LobbyChannel + `","from_box":"box-wui","to_box":"box-wui","sig":"",` +
	`"msg":{"v":1,"msg_id":"m-1","task_id":"t-1","ts":"2026-10-03T00:00:00Z","from":"h1","to":"ALL-0",` +
	`"kind":"msg","body":"an edited fan-out line <b>&</b> an edited fan-out line","files":[]}}`

func e16Msg() store.EditableMessage {
	return store.EditableMessage{MsgID: "m-1", TaskID: "t-1", Channel: LobbyChannel, FromID: "h1",
		ToID: BroadcastID, Kind: "msg", ReceivedAt: time.Unix(1_790_000_000, 0), Env: []byte(e16Canon)}
}

func e16Reactions() []viewReaction {
	return []viewReaction{{Emoji: "+1", Actors: []string{"h1", "h2", "c-001"}}, {Emoji: "eyes", Actors: []string{"h3"}}}
}

// e16TopicFrame is a topic_archived frame as withType builds it.
func e16TopicFrame() map[string]any {
	return withType(topicArchivedFrame, e16Msg(), map[string]any{"msg_id": "m-1", "task_id": "t-1",
		"archived": true, "archived_at": "2026-10-04T00:00:00Z", "archived_by": "h1", "children": 12})
}

// e16MoveFrame is a message_moved frame as moveFrame builds it.
func e16MoveFrame() map[string]any {
	return moveFrame(messageMovedFrame, map[string]any{"msg_id": "m-1", "task_id": "t-2", "from_task_id": "t-1",
		"channel": LobbyChannel, "from_channel": LobbyChannel, "cursor": "c-1", "undo": "u", "moved_by": "h1"})
}

var e16At = time.Unix(1_790_000_600, 0)

var e16Names = []string{"Reaction", "Topic", "Move", "Merged", "Edited", "Deleted"}

// e16Site is one E16 fan-out, one call.
func e16Site(name string) func(*Server, context.Context) {
	m := e16Msg()
	switch name {
	case "Reaction":
		return func(s *Server, ctx context.Context) { s.fanoutReaction(ctx, "t1", m, e16Reactions()) }
	case "Topic":
		return func(s *Server, ctx context.Context) { s.fanoutTopic(ctx, "t1", m, e16TopicFrame()) }
	case "Move":
		return func(s *Server, ctx context.Context) { s.fanoutMove(ctx, "t1", m, m, e16MoveFrame()) }
	case "Merged":
		return func(s *Server, ctx context.Context) {
			s.fanoutMerged(ctx, "t1", m, m, []byte(e16Canon), e16At, "h1", 2)
		}
	case "Edited":
		return func(s *Server, ctx context.Context) { s.fanoutEdited(ctx, "t1", m, []byte(e16Canon), e16At, "h1", 2) }
	}
	return func(s *Server, ctx context.Context) { s.fanoutDeleted(ctx, "t1", m) }
}

// BenchmarkFanoutE16: each site, one frame to 10 sockets.
//
//	go test ./internal/hub -run '^$' -bench 'BenchmarkFanoutE16' -benchmem -count 6
func BenchmarkFanoutE16(b *testing.B) {
	for _, name := range e16Names {
		site := e16Site(name)
		b.Run(name, func(b *testing.B) {
			s, done := fanoutRig(b, 10, nil)
			defer done()
			ctx := context.Background()
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				site(s, ctx)
			}
		})
	}
}

// e16Want is what each site put on the wire before E16: its frame as
// wsjson.Write encodes it (the JSON plus the Encoder's newline).
func e16Want(t *testing.T, name string) []byte {
	t.Helper()
	m := e16Msg()
	var e wire.Envelope
	if err := json.Unmarshal([]byte(e16Canon), &e); err != nil {
		t.Fatal(err)
	}
	var v any
	switch name {
	case "Reaction":
		v = map[string]any{"type": reactionFrame, "task_id": m.TaskID, "msg_id": m.MsgID,
			"reactions": e16Reactions(), "channel": m.Channel}
	case "Topic":
		v = e16TopicFrame()
	case "Move":
		v = e16MoveFrame()
	case "Merged":
		f := map[string]any{"type": mergedFrame, "task_id": m.TaskID, "msg_id": m.MsgID,
			"merged_from": m.MsgID, "cursor": encCursor(m.ReceivedAt, m.MsgID),
			"received_at": rfc(m.ReceivedAt), "envelope": e.Msg, "env": json.RawMessage(e16Canon), "channel": m.Channel}
		editedFields(f, e16At, "h1", 2)
		kindFields(f, m.Kind, m.KindSetAt, m.KindSetBy)
		v = f
	case "Edited":
		v = newEditedMsg(m, []byte(e16Canon), e, e16At, "h1", 2)
	case "Deleted":
		v = newDeletedMsg(m)
	}
	var b bytes.Buffer
	if err := json.NewEncoder(&b).Encode(v); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// Every socket of every E16 site receives the bytes the site sent before.
func TestFanoutE16SitesSendTheSameBytes(t *testing.T) {
	for _, name := range e16Names {
		t.Run(name, func(t *testing.T) {
			got := make(chan []byte, 3)
			s, done := fanoutRig(t, 3, got)
			defer done()
			e16Site(name)(s, context.Background())
			want := e16Want(t, name)
			for i := 0; i < 3; i++ {
				select {
				case p := <-got:
					if !bytes.Equal(p, want) {
						t.Fatalf("socket %d got %q, want %q", i, p, want)
					}
				case <-time.After(5 * time.Second):
					t.Fatalf("socket %d: no frame", i)
				}
			}
		})
	}
}

// countingJSON counts how often the encoder marshals it.
type countingJSON struct{ n *atomic.Int32 }

func (c countingJSON) MarshalJSON() ([]byte, error) {
	c.n.Add(1)
	return []byte(`"x"`), nil
}

// The frame a caller hands fanoutTopic / fanoutMove is encoded once for
// all its sockets, not once per socket.
func TestFanoutTopicAndMoveEncodeOnce(t *testing.T) {
	m := e16Msg()
	for name, send := range map[string]func(*Server, map[string]any){
		"Topic": func(s *Server, f map[string]any) { s.fanoutTopic(context.Background(), "t1", m, f) },
		"Move":  func(s *Server, f map[string]any) { s.fanoutMove(context.Background(), "t1", m, m, f) },
	} {
		t.Run(name, func(t *testing.T) {
			got := make(chan []byte, 4)
			s, done := fanoutRig(t, 4, got)
			defer done()
			var n atomic.Int32
			send(s, map[string]any{"type": "t", "probe": countingJSON{&n}})
			for i := 0; i < 4; i++ {
				select {
				case p := <-got:
					if !strings.Contains(string(p), `"probe":"x"`) {
						t.Fatalf("socket %d got %q", i, p)
					}
				case <-time.After(5 * time.Second):
					t.Fatalf("socket %d: no frame", i)
				}
			}
			if got := n.Load(); got != 1 {
				t.Fatalf("frame encoded %d times for 4 sockets, want 1", got)
			}
		})
	}
}
