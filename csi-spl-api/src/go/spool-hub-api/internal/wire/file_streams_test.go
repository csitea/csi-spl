package wire

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// Spec 160 row B2 (SPL-3888): the file streams frames. Red on origin/master
// before SPL-3888: no DecodeFileStreamsPush, the package does not compile.

func fsPush(lines string) json.RawMessage {
	return json.RawMessage(`{"stream_key":"app","lines":[` + lines + `],"dropped":0,"redactions":{"github-token":1}}`)
}

func fsLine(seq int, text string) string {
	t, _ := json.Marshal(text)
	return fmt.Sprintf(`{"seq":%d,"at":"2026-10-27T10:00:00Z","text":%s,"marker":false}`, seq, t)
}

// TestDecodeFileStreamsPush: a good push decodes; each malformed one is
// refused as bad_file_stream, an oversize one as too_large (case C23's wire
// half: refused before anything is stored).
func TestDecodeFileStreamsPush(t *testing.T) {
	p, err := DecodeFileStreamsPush(fsPush(fsLine(1, "a") + "," + fsLine(2, "b")))
	if err != nil || len(p.Lines) != 2 || p.Lines[1].Text != "b" || p.Redactions["github-token"] != 1 {
		t.Fatalf("good push = %+v %v", p, err)
	}
	many := make([]string, FileStreamLinesPerPush+1)
	for i := range many {
		many[i] = fsLine(i+1, "x")
	}
	for name, c := range map[string]struct {
		raw  json.RawMessage
		want error
	}{
		"unknown field (a box)": {json.RawMessage(`{"stream_key":"app","box":"b","lines":[` + fsLine(1, "a") + `]}`), ErrBadFileStream},
		"bad key":               {json.RawMessage(`{"stream_key":"App","lines":[` + fsLine(1, "a") + `]}`), ErrBadFileStream},
		"no lines":              {fsPush(""), ErrBadFileStream},
		"seq not increasing":    {fsPush(fsLine(2, "a") + "," + fsLine(2, "b")), ErrBadFileStream},
		"seq 0":                 {fsPush(fsLine(0, "a")), ErrBadFileStream},
		"newline in text":       {fsPush(fsLine(1, "a\nb")), ErrBadFileStream},
		"line too long":         {fsPush(fsLine(1, strings.Repeat("x", FileStreamLineMax+1))), ErrBadFileStream},
		"no at":                 {fsPush(`{"seq":1,"text":"a","marker":false}`), ErrBadFileStream},
		"negative dropped":      {json.RawMessage(`{"stream_key":"app","lines":[` + fsLine(1, "a") + `],"dropped":-1}`), ErrBadFileStream},
		"1001 lines":            {fsPush(strings.Join(many, ",")), ErrFileStreamTooLarge},
		"over the byte cap":     {json.RawMessage(strings.Repeat(" ", FileStreamPushMaxBytes) + string(fsPush(fsLine(1, "a")))), ErrFileStreamTooLarge},
	} {
		if _, err := DecodeFileStreamsPush(c.raw); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", name, err, c.want)
		}
	}
}

// TestDecodeFileStreamsAnnounce: the follower's announce decodes; a twice
// named key, an unknown state or a frame that names a box is refused.
func TestDecodeFileStreamsAnnounce(t *testing.T) {
	a, err := DecodeFileStreamsAnnounce(json.RawMessage(`{"streams":[{"stream_key":"token-burn-cron","path":"/var/csi/csi-spl/token-burn/cron.log","state":"following"},
		{"stream_key":"x","path":"$HOME/x.log","state":"refused"}]}`))
	if err != nil || len(a.Streams) != 2 || a.Streams[1].State != FileStreamRefused {
		t.Fatalf("good announce = %+v %v", a, err)
	}
	for name, raw := range map[string]string{
		"twice":      `{"streams":[{"stream_key":"a","path":"/p","state":"following"},{"stream_key":"a","path":"/q","state":"missing"}]}`,
		"state gone": `{"streams":[{"stream_key":"a","path":"/p","state":"gone"}]}`,
		"no path":    `{"streams":[{"stream_key":"a","path":"","state":"following"}]}`,
		"a box":      `{"streams":[],"box":"b"}`,
		"no streams": `{}`,
	} {
		if _, err := DecodeFileStreamsAnnounce(json.RawMessage(raw)); !errors.Is(err, ErrBadFileStream) {
			t.Errorf("%s: %v, want ErrBadFileStream", name, err)
		}
	}
}
