package hubclient

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-1808: RenameHashNamedFiles names the sha-named blobs of a message this
// box sent from their sniffed type, re-signs it and sends a names-only edit.
// The hub side (box_edit.go) has its own tests in internal/hub.

// renameMsg: a stored note with a png and an unknown blob, both named by
// their own sha, the blobs already in c's local store.
func renameMsg(t *testing.T, c *Client) (*msg.Message, string, string) {
	t.Helper()
	dir := t.TempDir()
	put := func(name, data string) msg.Attachment {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
		a, err := files.PutFile(c.Cfg.FilesDir(), p)
		if err != nil {
			t.Fatal(err)
		}
		a.Name = a.FileID
		return a
	}
	png := put("shot", "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01")
	bin := put("blob", "\x00\x01\x02\x03\xfe\xff")
	m := note("c-007", "c-008", "note", "see the screenshot")
	m.Files = []msg.Attachment{png, bin}
	return m, png.FileID, bin.FileID
}

func TestRenameHashNamedFiles(t *testing.T) {
	p := newPeer(t, "box-b")

	t.Run("dry run sends nothing", func(t *testing.T) {
		h := editHub(nil)
		c := opsClient(t, h)
		m, png, bin := renameMsg(t, c)
		h = editHub(envRaw(t, p, "box-b", "ops", m))
		c.Cfg.HubURL = h.start(t)
		r, err := c.RenameHashNamedFiles(context.Background(), strings.ToUpper(m.MsgID), "", true)
		if err != nil {
			t.Fatal(err)
		}
		if r.MsgID != m.MsgID || r.Renamed != 1 || r.Unknown != 1 || r.Applied || len(r.Files) != 2 {
			t.Fatalf("result %+v", r)
		}
		if r.Files[0].FileID != png || r.Files[0].To != files.RepairedName(png, "png") || r.Files[1].FileID != bin || r.Files[1].To != "" {
			t.Errorf("files %+v", r.Files)
		}
		if n := len(h.frames(wire.TEdit)); n != 1 {
			t.Errorf("%d edit frames, want the fetch only", n)
		}
	})

	t.Run("names the png, keeps the unknown, re-signs", func(t *testing.T) {
		h := editHub(nil)
		c := opsClient(t, h)
		m, png, bin := renameMsg(t, c)
		h = editHub(envRaw(t, p, "box-b", "ops", m))
		c.Cfg.HubURL = h.start(t)
		r, err := c.RenameHashNamedFiles(context.Background(), m.MsgID, "c-007", false)
		if err != nil {
			t.Fatal(err)
		}
		if !r.Applied || r.Renamed != 1 {
			t.Fatalf("result %+v", r)
		}
		edits := h.frames(wire.TEdit)
		if len(edits) != 2 {
			t.Fatalf("edit frames %+v", edits)
		}
		e, err := wire.ParseEnvelope(edits[1].Env)
		if err != nil {
			t.Fatal(err)
		}
		in, err := e.Inner()
		if err != nil {
			t.Fatal(err)
		}
		if e.FromBox != "box-a" || in.Body != m.Body || len(in.Files) != 2 ||
			in.Files[0].FileID != png || in.Files[0].Name != files.RepairedName(png, "png") ||
			in.Files[1].FileID != bin || in.Files[1].Name != bin {
			t.Errorf("applied envelope from %s body %q files %+v", e.FromBox, in.Body, in.Files)
		}
	})

	t.Run("another author", func(t *testing.T) {
		h := editHub(nil)
		c := opsClient(t, h)
		m, _, _ := renameMsg(t, c)
		h = editHub(envRaw(t, p, "box-b", "", m))
		c.Cfg.HubURL = h.start(t)
		if _, err := c.RenameHashNamedFiles(context.Background(), m.MsgID, "c-008", false); err == nil ||
			!strings.Contains(err.Error(), "written by c-007, not c-008") {
			t.Fatalf("got %v", err)
		}
	})

	t.Run("nothing sha-named: no edit", func(t *testing.T) {
		m := note("c-007", "c-008", "note", "plain")
		h := editHub(envRaw(t, p, "box-b", "", m))
		c := opsClient(t, h)
		r, err := c.RenameHashNamedFiles(context.Background(), m.MsgID, "", false)
		if err != nil || r.Applied || len(r.Files) != 0 {
			t.Fatalf("result %+v err %v", r, err)
		}
	})
}
