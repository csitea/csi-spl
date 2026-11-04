package wire

import (
	"encoding/json"
	"strings"
	"testing"
)

// imEnvelope wraps raw as the inner message of an envelope.
func imEnvelope(raw string) *Envelope {
	return &Envelope{FromBox: "box-a", ToBox: "box-b", Msg: json.RawMessage(raw)}
}

// imMsgJSON is fixedMsg as JSON, with edit applied to its map first.
func imMsgJSON(t *testing.T, edit func(map[string]any)) string {
	t.Helper()
	raw, err := json.Marshal(fixedMsg())
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	edit(m)
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

// ModelName is "" for a null model and the model's name otherwise.
func TestFleetTokenSampleModelName(t *testing.T) {
	if got := (FleetTokenSample{}).ModelName(); got != "" {
		t.Fatalf("nil model: got %q, want empty", got)
	}
	name := "claude-opus-4-7"
	if got := (FleetTokenSample{Model: &name}).ModelName(); got != name {
		t.Fatalf("set model: got %q, want %q", got, name)
	}
}

// skipWS steps over spaces, tabs, newlines and carriage returns, and stops at
// the first other byte or the end of the slice.
func TestSkipWS(t *testing.T) {
	cases := []struct {
		in   string
		from int
		want int
	}{
		{"", 0, 0},
		{"x", 0, 0},
		{"  x", 0, 2},
		{"\tx", 0, 1},
		{"\nx", 0, 1},
		{"\rx", 0, 1},
		{" \t\r\n{", 0, 4},
		{"a  b", 1, 3},
		{" \t\n\r", 0, 4},
		{"x   ", 1, 4},
		{"x", 1, 1},
	}
	for _, c := range cases {
		if got := skipWS([]byte(c.in), c.from); got != c.want {
			t.Errorf("skipWS(%q, %d) = %d, want %d", c.in, c.from, got, c.want)
		}
	}
}

// Inner refuses malformed JSON and a message that fails Validate, and returns
// a valid one.
func TestEnvelopeInner(t *testing.T) {
	if _, err := imEnvelope(`{"v":1,`).Inner(); err == nil || !strings.Contains(err.Error(), "decode message") {
		t.Fatalf("malformed msg: got %v, want a decode error", err)
	}

	noTask := imMsgJSON(t, func(m map[string]any) { delete(m, "task_id") })
	if _, err := imEnvelope(noTask).Inner(); err == nil || !strings.Contains(err.Error(), "task_id") {
		t.Fatalf("msg without task_id: got %v, want a validation error", err)
	}

	m, err := imEnvelope(imMsgJSON(t, func(map[string]any) {})).Inner()
	if err != nil {
		t.Fatalf("valid msg: %v", err)
	}
	if want := fixedMsg(); m.MsgID != want.MsgID || m.TaskID != want.TaskID || m.Body != want.Body {
		t.Fatalf("valid msg: got %+v, want %+v", m, want)
	}
}
