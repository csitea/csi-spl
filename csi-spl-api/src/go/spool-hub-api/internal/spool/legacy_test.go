package spool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// TestFR015_LegacyFallbackIsValid: a legacy .md whose sender is not an agent
// id (the orchestrator writes `--ORC--`) and whose frontmatter `to` is free
// text must come back as a VALID v:1 object: from = the documented sentinel
// msg.LegacySender, to = the inbox owner (message-schema.md legacy bridge).
// Before the fix it came back as from:"LEGACY" (fails the id regex) and
// to:"CLE-00 ORC" (unvalidated frontmatter), exit 0.
func TestFR015_LegacyFallbackIsValid(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if err := st.ensureAgent("CLE-07"); err != nil {
		t.Fatal(err)
	}
	inbox := st.dir("CLE-07", "inbox")
	legacy := map[string]string{
		"20260919T134653Z--ORC--brief.md":   "---\nfrom: ORC\nto: CLE-00 ORC\n---\nbrief body\n",
		"20260919T134654Z--CLE-00--ok.md":   "plain body, no frontmatter\n",
		"20260919T134655Z-no-separators.md": "odd name\n",
	}
	for name, body := range legacy {
		if err := os.WriteFile(filepath.Join(inbox, name), []byte(body), 0o664); err != nil {
			t.Fatal(err)
		}
	}
	res, err := st.Recv("CLE-07", false)
	if err != nil || len(res.Messages) != 3 || res.Failed != 0 {
		t.Fatalf("recv: err=%v msgs=%d failed=%d, want nil/3/0", err, len(res.Messages), res.Failed)
	}
	for _, m := range res.Messages {
		if err := m.Validate(); err != nil {
			t.Errorf("synthesized legacy message does not validate: %v (%+v)", err, m)
		}
		if m.To != "CLE-07" {
			t.Errorf("to = %q, want the inbox owner CLE-07", m.To)
		}
		switch {
		case strings.Contains(m.Body, "brief body"), strings.Contains(m.Body, "odd name"):
			if m.From != msg.LegacySender {
				t.Errorf("from = %q, want sentinel %q", m.From, msg.LegacySender)
			}
		default:
			if m.From != "CLE-00" {
				t.Errorf("from = %q, want CLE-00 from the filename", m.From)
			}
		}
	}
	if !msg.ValidID(msg.LegacySender) {
		t.Fatalf("sentinel %q is not a valid agent id", msg.LegacySender)
	}
}

// TestFR015_LegacyOverLimitIsMalformed: the synthesized object is validated
// like any other, so a legacy body over the 64 KiB schema limit is surfaced as
// malformed (left in inbox, exit 1), not delivered.
func TestFR015_LegacyOverLimitIsMalformed(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if err := st.ensureAgent("CLE-07"); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(st.dir("CLE-07", "inbox"), "20260919T134653Z--CLE-00--big.md")
	if err := os.WriteFile(p, []byte(strings.Repeat("x", msg.MaxBodyBytes+1)), 0o664); err != nil {
		t.Fatal(err)
	}
	res, err := st.Recv("CLE-07", true)
	if err == nil || res.Failed != 1 || len(res.Messages) != 0 {
		t.Fatalf("want malformed: err=%v failed=%d msgs=%d", err, res.Failed, len(res.Messages))
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("malformed legacy file must stay in inbox: %v", err)
	}
}
