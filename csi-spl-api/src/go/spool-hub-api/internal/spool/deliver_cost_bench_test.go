package spool

// (specs/030 FR-001): what the BOX-SIDE MAILBOX costs per message.
//
// The owner asked whether the file-based mailbox is what makes the WUI chat
// slow, and whether it should become "web sockets + streaming client to server
// and back". Both legs are already WebSockets; the file is only the box-side
// mailbox (002: durable, replayable, readable by any CLI agent). This
// benchmark exists so that question is answered with a number instead of an
// opinion - in either direction.
//
//	go test ./internal/spool -run '^$' -bench BenchmarkDeliver -benchmem -count 5
//
// Read against the measured box<->hub RTT (~61.5 ms p50, live dev hub,
// 2026-09-21, n=20). A hop that costs microseconds is not the latency.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

func benchCfg(b *testing.B) *config.Config {
	b.Helper()
	root := b.TempDir()
	return &config.Config{
		SpoolRoot: filepath.Join(root, "msgs"),
		KeysDir:   filepath.Join(root, "keys"),
		PinsDir:   filepath.Join(root, "msgs", "pins"),
		LogLevel:  "error",
		LogFormat: "console",
	}
}

func benchDeliverMsg(i, n int) *msg.Message {
	return &msg.Message{
		V: msg.V1, MsgID: uuidLike(i), TaskID: "66666666-7777-4888-8999-aaaaaaaaaaaa",
		TS: "2026-09-21T12:00:00Z", From: "HUM-1", To: "CLE-00",
		Kind: "note", Body: strings.Repeat("x", n), Files: []msg.Attachment{},
	}
}

// uuidLike makes each iteration a DISTINCT msg_id, so the benchmark measures a
// real write and not DeliverTo's already-delivered short circuit.
//
// It varies the LEADING hex on purpose: msg.Filename tie-breaks a same-second
// collision with msg_id[:8], so a msg_id that differs only in its tail yields
// the SAME filename, DeliverTo short-circuits on the stat, and the benchmark
// silently measures two stat calls instead of a write. Measured while writing
// this file: tail-varying ids read 6.6 us/op with the notifier apparently free,
// which is what a benchmark of nothing looks like.
func uuidLike(i int) string {
	const hexd = "0123456789abcdef"
	b := []byte("11111111-2222-4333-8444-555555555555")
	for p := 7; p >= 0 && i > 0; p-- {
		b[p] = hexd[i&0xf]
		i >>= 4
	}
	return string(b)
}

// BenchmarkDeliverFileHop is the mailbox write alone, notifier off: marshal the
// v:1 object, ensure the agent dirs, write the inbox file atomically (temp +
// rename + the already-delivered stat checks). This is the hop the owner's
// question is about.
func BenchmarkDeliverFileHop(b *testing.B) {
	for _, bs := range []struct {
		name string
		n    int
	}{{"chat_80B", 80}, {"para_1KB", 1 << 10}, {"paste_16KB", 16 << 10}} {
		b.Run(bs.name, func(b *testing.B) {
			st := New(benchCfg(b))
			b.ReportAllocs()
			i := 0
			for b.Loop() {
				i++
				if _, err := st.DeliverTo(benchDeliverMsg(i, bs.n), "CLE-00"); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// BenchmarkDeliverWithNotifier is the same write plus the TERMINAL LEG: one
// $SPOOL_NOTIFY_CMD process per delivered message (specs/028), here the
// cheapest possible notifier - /bin/true with no tmux work at all. The gap
// between this and BenchmarkDeliverFileHop is therefore the FLOOR of "spawn one
// process per message", not its real cost: the production notifier is a bash
// script that also runs tmux.
//
// It matters because notify.Run is called synchronously inside writeBox, which
// runs inside the sidecar's socket read loop: whatever this costs, the box
// cannot read its next recv frame while it is being paid.
func BenchmarkDeliverWithNotifier(b *testing.B) {
	cfg := benchCfg(b)
	cfg.NotifyCmd = "/bin/true"
	cfg.NotifyTimeout = 5 * time.Second
	if _, err := os.Stat("/bin/true"); err != nil {
		b.Skipf("no /bin/true: %v", err)
	}
	st := New(cfg)
	b.ReportAllocs()
	i := 0
	for b.Loop() {
		i++
		if _, err := st.DeliverTo(benchDeliverMsg(i, 80), "CLE-00"); err != nil {
			b.Fatal(err)
		}
	}
}
