package main

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// repeatedKeys lists the top-level keys a JSON line holds more than once.
// zerolog appends a repeated key and Cloud Logging joins its values
// ("component":"hubauth", "env":"prddev"; SPL-6340).
func repeatedKeys(t *testing.T, line string) []string {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(line))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		t.Fatalf("not a JSON object: %q", line)
	}
	seen, rep := map[string]bool{}, []string{}
	for dec.More() {
		k, err := dec.Token()
		if err != nil {
			t.Fatalf("key of %q: %v", line, err)
		}
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			t.Fatalf("value of %q: %v", line, err)
		}
		if seen[k.(string)] {
			rep = append(rep, k.(string))
		}
		seen[k.(string)] = true
	}
	return rep
}

// TestHubLogKeysOnce writes lines through hubLogger the way the hub's sites
// do (a part logger, a deploy record, the operator invite mailer) and fails
// on any key a line carries twice; the control line has unique keys anyway.
func TestHubLogKeysOnce(t *testing.T) {
	base, _ := hubLogger(&config.Hub{Env: "prd", LogLevel: "info", LogFormat: "json"})
	var buf bytes.Buffer
	l := base.Output(&buf)
	cases := []struct {
		name string
		log  func()
	}{
		{"part-logger", func() { a := l.With().Str("component", "auth").Logger(); a.Info().Msg("auth.login_ok") }},
		{"deploy-record", func() {
			l.Info().Str("env", "dev").Str("component", "wui").Str("version", "v3.5.3").Msg("deploy.recorded")
		}},
		{"invite-mailer", func() {
			send := operatorMailer(&config.Hub{}, l, store.NewMemory(), &mail.Config{Transport: mail.TransportLog}, "https://example.com")
			if _, err := send(context.Background(), "t1", "invitee@example.com", "en"); err != nil {
				t.Fatalf("invite mailer: %v", err)
			}
		}},
		{"control", func() { l.Info().Str("tenant", "t1").Msg("ws hello accepted") }},
	}
	for _, c := range cases {
		buf.Reset()
		c.log()
		lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
		if len(lines) == 0 || lines[0] == "" {
			t.Fatalf("%s: wrote no line", c.name)
		}
		for _, line := range lines {
			if rep := repeatedKeys(t, line); len(rep) > 0 {
				t.Errorf("%s: repeated=%v in %s", c.name, rep, line)
			}
		}
	}
	buf.Reset()
	l.Info().Msg("probe")
	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["hub_env"] != "prd" || got["hub_version"] != version {
		t.Errorf("the hub's own facts moved: %s", buf.String())
	}
}
