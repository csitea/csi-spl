package main

import (
	"fmt"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 160 row B2 (SPL-3888): `spool file-streams push --json -`, the box
// follower's push. Red on origin/master before SPL-3888: no cmdFileStreams,
// the package does not compile.

func fsFrame(n, textLen int) string {
	parts := make([]string, n)
	for i := range parts {
		parts[i] = fmt.Sprintf(`{"seq":%d,"at":"2026-10-27T10:00:00Z","text":%q,"marker":false}`, i+1, strings.Repeat("x", textLen))
	}
	return `{"type":"lane","lane_op":"file_streams_push","stream_key":"app","lines":[` + strings.Join(parts, ",") +
		`],"dropped":3,"redactions":{"github-token":1}}`
}

// TestFileStreamsVerb: the follower's announce and push frames go to the
// hub as their lane payload only (the hub refuses unknown fields); the ack
// is printed as one JSON line of type ack.
func TestFileStreamsVerb(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{
		wire.FileStreamsAnnounceOp: `{"type":"ack","lane_op":"file_streams_announce","streams":[{"stream_key":"app","state":"following"}],"inserted":0,"at":"x"}`,
		wire.FileStreamsPushOp:     `{"type":"ack","lane_op":"file_streams_push","stream_key":"app","inserted":2,"acked_seq":2,"at":"x"}`,
	}), nil)
	cfg := hubCfg(t, h.URL)
	ann := `{"type":"lane","lane_op":"file_streams_announce","streams":[{"stream_key":"app","path":"/var/log/app.log","state":"following"}]}`
	if rc, out, errOut := capture(t, ann, func() int { return cmdFileStreams(cfg, []string{"push", "--json", "-"}) }); rc != 0 || !strings.Contains(out, `"type":"ack"`) {
		t.Fatalf("announce: rc %d out %q err %q", rc, out, errOut)
	}
	if rc, out, errOut := capture(t, fsFrame(2, 5), func() int { return cmdFileStreams(cfg, []string{"push", "--json", "-"}) }); rc != 0 || !strings.Contains(out, `"inserted":2`) {
		t.Fatalf("push: rc %d out %q err %q", rc, out, errOut)
	}
	fr := h.Frames()
	if len(fr) != 2 || fr[0].LaneOp != wire.FileStreamsAnnounceOp || fr[1].LaneOp != wire.FileStreamsPushOp {
		t.Fatalf("frames = %+v", fr)
	}
	if _, err := wire.DecodeFileStreamsAnnounce(fr[0].Lane); err != nil {
		t.Errorf("sent announce %s: %v", fr[0].Lane, err)
	}
	if p, err := wire.DecodeFileStreamsPush(fr[1].Lane); err != nil || p.Dropped != 3 {
		t.Errorf("sent push %s: %+v %v", fr[1].Lane, p, err)
	}
}

// TestFileStreamsVerbSplits: a follower frame over the hub's socket limit
// (here 400 lines of 2048 bytes, ~0.8 MiB) goes as parts of at most
// wire.FileStreamPushMaxBytes, in seq order, dropped and redactions on the
// first part only. CONTROL: one part of 0.8 MiB is past the hub's 512 KiB
// read limit and would close the socket.
func TestFileStreamsVerbSplits(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{
		wire.FileStreamsPushOp: `{"type":"ack","lane_op":"file_streams_push","stream_key":"app","inserted":1,"at":"x"}`,
	}), nil)
	cfg := hubCfg(t, h.URL)
	rc, out, errOut := capture(t, fsFrame(400, 2048), func() int { return cmdFileStreams(cfg, []string{"push", "--json", "-"}) })
	if rc != 0 {
		t.Fatalf("rc %d out %q err %q", rc, out, errOut)
	}
	fr := h.Frames()
	if len(fr) < 2 {
		t.Fatalf("%d parts, want >= 2", len(fr))
	}
	var next int64 = 1
	for i, f := range fr {
		p, err := wire.DecodeFileStreamsPush(f.Lane)
		if err != nil || len(f.Lane) > wire.FileStreamPushMaxBytes {
			t.Fatalf("part %d (%d bytes): %v", i, len(f.Lane), err)
		}
		if p.Lines[0].Seq != next || (i == 0) != (p.Dropped == 3) {
			t.Fatalf("part %d starts at seq %d (want %d), dropped %d", i, p.Lines[0].Seq, next, p.Dropped)
		}
		next = p.Lines[len(p.Lines)-1].Seq + 1
	}
	if next != 401 || !strings.Contains(out, fmt.Sprintf(`"inserted":%d`, len(fr))) {
		t.Fatalf("parts end at %d, ack %q", next, out)
	}
}

// TestFileStreamsVerbRefusals: usage errors and bad frames exit 1 before
// the hub.
func TestFileStreamsVerbRefusals(t *testing.T) {
	h := newScriptHub(t, refuseAll, nil)
	cfg := hubCfg(t, h.URL)
	runVerbCases(t, func(a []string) int { return cmdFileStreams(cfg, a) }, []verbCase{
		{"no op", nil, 1, "usage: spool file-streams"},
		{"no --json", []string{"push", "-"}, 1, "usage: spool file-streams"},
	})
	for name, in := range map[string]string{
		"not json":   `nope`,
		"no op":      `{"type":"lane"}`,
		"bad key":    `{"lane_op":"file_streams_push","stream_key":"A B","lines":[{"seq":1,"at":"2026-10-27T10:00:00Z","text":"x"}]}`,
		"bad stream": `{"lane_op":"file_streams_announce","streams":[{"stream_key":"a","path":"/p","state":"gone"}]}`,
	} {
		rc, _, errOut := capture(t, in, func() int { return cmdFileStreams(cfg, []string{"push", "--json", "-"}) })
		if rc != 1 || !strings.Contains(errOut, "file-streams push") {
			t.Errorf("%s: rc %d err %q", name, rc, errOut)
		}
	}
	if fr := h.Frames(); len(fr) != 0 {
		t.Fatalf("bad input reached the hub: %+v", fr)
	}
}
