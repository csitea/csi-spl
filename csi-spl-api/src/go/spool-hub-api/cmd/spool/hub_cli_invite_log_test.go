package main

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// TestCLIInviteMailLogKeysOnce calls the logger pair inviteMailOpts.send
// builds (cliInviteMailLoggers) with the log transport: the mail.log_sink
// line carries component=mail once, the CLI's own line component=cli once
// (bug round 44 row 02; before it, the sink line read
// "component":"cli","component":"mail").
func TestCLIInviteMailLogKeysOnce(t *testing.T) {
	var buf bytes.Buffer
	sender, log := cliInviteMailLoggers(&mail.Config{Transport: mail.TransportLog}, zerolog.New(&buf))
	cases := []struct {
		name, component string
		write           func()
	}{
		{"mail.log_sink", "mail", func() {
			if err := sender.Send(context.Background(), mail.Message{Template: "invite", To: "invitee@example.com"}); err != nil {
				t.Fatalf("send: %v", err)
			}
		}},
		{"cli", "cli", func() { log.Info().Msg("invite.cli_probe") }},
	}
	for _, c := range cases {
		buf.Reset()
		c.write()
		line := strings.TrimSpace(buf.String())
		if rep := repeatedKeys(t, line); len(rep) > 0 {
			t.Fatalf("%s: repeated=%v in %s", c.name, rep, line)
		}
		var got map[string]any
		if err := json.Unmarshal([]byte(line), &got); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got["component"] != c.component {
			t.Errorf("%s: component=%v, want %s in %s", c.name, got["component"], c.component, line)
		}
	}
}
