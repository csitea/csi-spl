package spool

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Pins the legacy .md bridge's precedence before SPL-1032 split readLegacyMD:
// the file name sets from / sent / subject, the frontmatter overrides each one
// it names validly, and the defaults (legacy sender, mtime, seeded task id)
// fill what is left.
func TestLegacyMDPrecedence(t *testing.T) {
	const task = "11111111-2222-3333-4444-555555555555"
	mtime := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	cases := []struct {
		name, file, body           string
		from, ts, taskID, wantBody string
	}{
		{name: "name only", file: "20260903T084612Z--CLE-387--subj.md", body: "hello\n",
			from: "CLE-387", ts: "2026-09-03T08:46:12Z", taskID: uid.FromSeed("task:subj"), wantBody: "hello\n"},
		{name: "dash time format", file: "20260903-084612--CLE-01--s.md", body: "x",
			from: "CLE-01", ts: "2026-09-03T08:46:12Z", taskID: uid.FromSeed("task:s"), wantBody: "x"},
		{name: "frontmatter overrides the name", file: "20260903T084612Z--CLE-387--subj.md",
			body: "---\nFrom: \"CLE-03\"\nsent: 2026-09-04T01:02:03+02:00\ntask: " + task + "\nsubject: other\n---\n\nbody\n",
			from: "CLE-03", ts: "2026-09-03T23:02:03Z", taskID: task, wantBody: "body\n"},
		{name: "invalid frontmatter values are ignored", file: "20260903T084612Z--CLE-387--subj.md",
			body: "---\nfrom: ORC\nsent: yesterday\ntask_id:\nsubject:\n---\nb",
			from: "CLE-387", ts: "2026-09-03T08:46:12Z", taskID: uid.FromSeed("task:subj"), wantBody: "b"},
		{name: "frontmatter subject seeds the task", file: "odd.md", body: "---\nsubject: plan\nsent: 20260905T000000Z\n---\nb",
			from: msg.LegacySender, ts: "2026-09-05T00:00:00Z", taskID: uid.FromSeed("task:plan"), wantBody: "b"},
		{name: "crlf frontmatter", file: "odd.md", body: "---\r\nfrom: CLE-02\r\ntask_id: " + task + "\r\n---\r\n\r\nbody",
			from: "CLE-02", ts: "2026-09-01T10:00:00Z", taskID: task, wantBody: "body"},
		{name: "unterminated frontmatter is body", file: "odd.md", body: "---\nfrom: CLE-02\nno end",
			from: msg.LegacySender, ts: "2026-09-01T10:00:00Z", taskID: uid.FromSeed("task:odd.md"), wantBody: "---\nfrom: CLE-02\nno end"},
		{name: "lines without a colon are skipped", file: "odd.md", body: "---\njunk\nfrom: CLE-04\n---\nb",
			from: "CLE-04", ts: "2026-09-01T10:00:00Z", taskID: uid.FromSeed("task:odd.md"), wantBody: "b"},
	}
	st := New(newCfg(t))
	dir := t.TempDir()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := filepath.Join(dir, c.file)
			if err := os.WriteFile(p, []byte(c.body), 0o664); err != nil {
				t.Fatal(err)
			}
			if err := os.Chtimes(p, mtime, mtime); err != nil {
				t.Fatal(err)
			}
			m, err := st.readLegacyMD(p, "CLE-07")
			if err != nil {
				t.Fatal(err)
			}
			if m.From != c.from || m.TS != c.ts || m.TaskID != c.taskID || m.Body != c.wantBody {
				t.Fatalf("got from=%q ts=%q task=%q body=%q\nwant from=%q ts=%q task=%q body=%q",
					m.From, m.TS, m.TaskID, m.Body, c.from, c.ts, c.taskID, c.wantBody)
			}
			if m.To != "CLE-07" || m.Kind != "note" || m.MsgID != uid.FromSeed("msg:"+c.file+":"+c.body) {
				t.Fatalf("to=%q kind=%q msg_id=%q", m.To, m.Kind, m.MsgID)
			}
		})
	}
}

// Pins Tail before SPL-1033: one copy per msg id across inbox/outbox/archive,
// only .json and .md files, only the asked task, dirs and junk skipped.
func TestTailDedupeAndSkips(t *testing.T) {
	st := New(newCfg(t))
	m1, err := st.Send("GRK-03", "CLE-07", "", "task", "first", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Send("GRK-03", "CLE-07", "", "task", "other topic", nil); err != nil {
		t.Fatal(err)
	}
	inbox := st.dir("CLE-07", "inbox")
	if err := os.WriteFile(filepath.Join(inbox, "notes.txt"), []byte("x"), 0o664); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inbox, "broken.json"), []byte("{"), 0o664); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(inbox, "sub.json"), 0o775); err != nil {
		t.Fatal(err)
	}
	legacy := "---\ntask_id: " + m1.TaskID + "\n---\nlegacy line\n"
	if err := os.WriteFile(filepath.Join(inbox, "20260903T084612Z--CLE-01--x.md"), []byte(legacy), 0o664); err != nil {
		t.Fatal(err)
	}
	got, err := st.Tail(m1.TaskID)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 (the sent message once + the legacy line), got %d", len(got))
	}
	if got[0].Body != "legacy line\n" || got[1].MsgID != m1.MsgID {
		t.Fatalf("order/content: %q then %q", got[0].Body, got[1].MsgID)
	}
}
