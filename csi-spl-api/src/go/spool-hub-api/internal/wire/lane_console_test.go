package wire

import (
	"errors"
	"strings"
	"testing"
)

// Spec 153 3.18 (SPL-4810): the console push's decoder takes a masked screen
// and refuses anything else, with the reason as its error.
func TestDecodeLaneConsolePush(t *testing.T) {
	good := `{"agent_id":"c-128","screen":"$ make\nok","lines":2,"redactions":{"github-token":1}}`
	p, err := DecodeLaneConsolePush([]byte(good))
	if err != nil || p.AgentID != "c-128" || p.Lines != 2 || p.Redactions["github-token"] != 1 {
		t.Fatalf("good push: %+v %v", p, err)
	}
	for name, raw := range map[string]string{
		"a box in the frame": `{"agent_id":"c-1","screen":"","lines":0,"redactions":{},"box":"x"}`,
		"a path as agent":    `{"agent_id":"../etc","screen":"","lines":0,"redactions":{}}`,
		"a tmux target":      `{"agent_id":"c-1:0.1","screen":"","lines":0,"redactions":{}}`,
		"negative lines":     `{"agent_id":"c-1","screen":"","lines":-1,"redactions":{}}`,
		"a NUL":              `{"agent_id":"c-1","screen":"a\u0000b","lines":1,"redactions":{}}`,
		"an empty kind":      `{"agent_id":"c-1","screen":"","lines":0,"redactions":{"":1}}`,
	} {
		if _, err := DecodeLaneConsolePush([]byte(raw)); !errors.Is(err, ErrBadFileStream) {
			t.Errorf("%s: %v, want bad_file_stream", name, err)
		}
	}
	big := `{"agent_id":"c-1","screen":"` + strings.Repeat("x", LaneConsoleScreenMax+1) + `","lines":1,"redactions":{}}`
	if _, err := DecodeLaneConsolePush([]byte(big)); !errors.Is(err, ErrFileStreamTooLarge) {
		t.Errorf("oversized screen: %v, want too_large", err)
	}
}
