package wire

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// Spec 160 row B9 (SPL-4294): the web glob syntax, the pull frame and the
// announce's new fields. Red on origin/master before SPL-4294: no
// CheckFileStreamGlob, the package does not compile.

// TestFileStreamGlobSyntax (case C43, the syntax of 3.8.3): each bad glob is
// bad_glob, each good one passes. CONTROL: the good list passes, so the
// refusals are the checks', not a check that refuses every string.
func TestFileStreamGlobSyntax(t *testing.T) {
	for _, g := range []string{"/var/log/*.log", "/var/log/syslog", "$HOME/logs/app-?.log", "/var/csi/csi-spl/token-burn/cron.log", "/srv/a b/x*"} {
		if err := CheckFileStreamGlob(g); err != nil {
			t.Errorf("CONTROL: %q refused: %v", g, err)
		}
	}
	for name, g := range map[string]string{
		"relative":          "var/log/*.log",
		"empty":             "",
		"**":                "/var/log/**.log",
		"* in a directory":  "/var/*/syslog",
		"? in a directory":  "/var/lo?/syslog",
		"[":                 "/var/log/[ab].log",
		"{":                 "/var/log/{a,b}.log",
		".. segment":        "/var/log/../shadow",
		". segment":         "/var/./log/x",
		"empty segment":     "/var//log/x",
		"trailing slash":    "/var/log/",
		"control character": "/var/log/a\tb",
		"newline":           "/var/log/a\nb",
		"513 bytes":         "/" + strings.Repeat("a", 512),
		"bad UTF-8":         "/var/log/\xff",
		"$HOMEX":            "$HOMEX/y",
		"root":              "/",
	} {
		if err := CheckFileStreamGlob(g); !errors.Is(err, ErrBadGlob) {
			t.Errorf("%s %q: %v, want bad_glob", name, g, err)
		}
	}
	if err := CheckFileStreamGlob("/" + strings.Repeat("a", 511)); err != nil {
		t.Errorf("512 bytes refused: %v", err)
	}
}

// TestFileStreamGlobUnder: the glob's literal directory against a folder,
// as strings, $HOME/ unexpanded on both sides.
func TestFileStreamGlobUnder(t *testing.T) {
	for _, c := range []struct {
		glob, folder string
		want         bool
	}{
		{"/var/log/*.log", "/var/log", true},
		{"/var/log/nginx/*.log", "/var/log/", true},
		{"/var/logs/*.log", "/var/log", false},
		{"/var/*.log", "/var/log", false},
		{"$HOME/logs/x", "$HOME/logs", true},
		{"$HOME/logs/x", "/srv/u/logs", false},
		{"/var/log/x", "", false},
	} {
		if got := FileStreamGlobUnder(c.glob, c.folder); got != c.want {
			t.Errorf("under(%q, %q) = %v, want %v", c.glob, c.folder, got, c.want)
		}
	}
}

// TestFileStreamGlobPullFrame (case C46, wire half): the pull's payload is
// {}; a frame naming a box or a tenant is bad_file_stream. CONTROL: {} decodes.
func TestFileStreamGlobPullFrame(t *testing.T) {
	if err := DecodeFileStreamsGlobsPull(json.RawMessage(`{}`)); err != nil {
		t.Fatalf("CONTROL: {} refused: %v", err)
	}
	for _, raw := range []string{`{"box":"box-b"}`, `{"tenant":"t2"}`, `{"box_id":"x"}`, `[]`, `null x`} {
		if err := DecodeFileStreamsGlobsPull(json.RawMessage(raw)); !errors.Is(err, ErrBadFileStream) {
			t.Errorf("pull %s: %v, want bad_file_stream", raw, err)
		}
	}
	ack, _ := json.Marshal(FileStreamsAckFrame{Type: "ack", LaneOp: FileStreamsGlobsOp, Globs: &[]FileStreamGlobLive{}})
	if !strings.Contains(string(ack), `"globs":[]`) {
		t.Errorf("an empty pull ack = %s, want globs: [] (the box tells none from not answered)", ack)
	}
}

// TestFileStreamGlobAnnounceFields (3.8.5): an announce with folders, glob
// reports and a stream's glob_id decodes; an old announce without them
// still does (row B9 deploys before B10 sends them); each bad field is
// bad_file_stream.
func TestFileStreamGlobAnnounceFields(t *testing.T) {
	const id = "0b1e2f3a-4b5c-4d6e-8f70-112233445566"
	good := `{"streams":[{"stream_key":"app-1a2b3c","path":"/var/log/app.log","state":"following","glob_id":"` + id + `"}],
		"folders":[{"path":"/var/log","state":"allowed"},{"path":"/etc","state":"refused","reason":"too short"}],
		"globs":[{"id":"` + id + `","state":"partial","matched":12,"followed":6,"over_cap":6}]}`
	a, err := DecodeFileStreamsAnnounce(json.RawMessage(good))
	if err != nil || len(a.Folders) != 2 || a.Globs[0].OverCap != 6 || a.Streams[0].GlobID != id {
		t.Fatalf("good announce = %+v %v", a, err)
	}
	old, err := DecodeFileStreamsAnnounce(json.RawMessage(`{"streams":[{"stream_key":"app","path":"/var/log/app.log","state":"following"}]}`))
	if err != nil || old.Folders != nil || old.Globs != nil {
		t.Fatalf("an announce before B10 = %+v %v", old, err)
	}
	for name, raw := range map[string]string{
		"glob_id not a uuid":    `{"streams":[{"stream_key":"a","path":"/x","state":"following","glob_id":"x"}]}`,
		"folder relative":       `{"streams":[],"folders":[{"path":"var/log","state":"allowed"}]}`,
		"folder state":          `{"streams":[],"folders":[{"path":"/var/log","state":"following"}]}`,
		"folder twice":          `{"streams":[],"folders":[{"path":"/var/log","state":"allowed"},{"path":"/var/log","state":"allowed"}]}`,
		"glob state":            `{"streams":[],"globs":[{"id":"` + id + `","state":"pending","matched":0,"followed":0,"over_cap":0}]}`,
		"glob counts":           `{"streams":[],"globs":[{"id":"` + id + `","state":"partial","matched":2,"followed":2,"over_cap":1}]}`,
		"glob negative":         `{"streams":[],"globs":[{"id":"` + id + `","state":"none","matched":-1,"followed":0,"over_cap":0}]}`,
		"glob id twice":         `{"streams":[],"globs":[{"id":"` + id + `","state":"none"},{"id":"` + id + `","state":"none"}]}`,
		"glob names a box":      `{"streams":[],"globs":[{"id":"` + id + `","state":"none","box":"b"}]}`,
		"folder reason 2 lines": `{"streams":[],"folders":[{"path":"/var/log","state":"refused","reason":"a\nb"}]}`,
	} {
		if _, err := DecodeFileStreamsAnnounce(json.RawMessage(raw)); !errors.Is(err, ErrBadFileStream) {
			t.Errorf("%s: %v, want bad_file_stream", name, err)
		}
	}
}
