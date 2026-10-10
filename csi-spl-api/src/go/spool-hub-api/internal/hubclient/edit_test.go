package hubclient

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// editHub stores one envelope: an edit frame with no env fetches it, one with
// an env applies it (revision 2), a delete answers the topic.
func editHub(stored []byte) *opsHub {
	return &opsHub{reply: func(f wire.Frame) []wire.Frame {
		switch {
		case f.Type == wire.TEdit && len(f.Env) == 0:
			return []wire.Frame{{Type: wire.TEdit, MsgID: f.MsgID, Env: stored}}
		case f.Type == wire.TEdit:
			return []wire.Frame{{Type: wire.TEdit, MsgID: f.MsgID, TaskID: "task-e", Revision: 2}}
		case f.Type == wire.TDelete:
			return []wire.Frame{{Type: wire.TDelete, MsgID: f.MsgID, TaskID: "task-d"}}
		}
		return nil
	}}
}

func TestEditMessage(t *testing.T) {
	p := newPeer(t, "box-b")
	m := note("c-007", "c-008", "note", "old body")
	h := editHub(envRaw(t, p, "box-b", "ops", m))
	c := opsClient(t, h)

	// the id is lower-cased before it reaches the hub
	r, err := c.EditMessage(context.Background(), strings.ToUpper(m.MsgID), "new body", "c-007")
	if err != nil {
		t.Fatal(err)
	}
	if r.MsgID != m.MsgID || r.TaskID != "task-e" || r.From != "c-007" || r.Revision != 2 {
		t.Errorf("result %+v", r)
	}
	edits := h.frames(wire.TEdit)
	if len(edits) != 2 || edits[0].MsgID != m.MsgID || len(edits[0].Env) != 0 {
		t.Fatalf("edit frames %+v", edits)
	}
	// the new envelope is re-signed by THIS box, keeps to_box and channel,
	// and carries the new body under the same msg_id
	e, err := wire.ParseEnvelope(edits[1].Env)
	if err != nil {
		t.Fatal(err)
	}
	in, err := e.Inner()
	if err != nil {
		t.Fatal(err)
	}
	if e.FromBox != "box-a" || e.ToBox != "box-b" || e.Channel != "ops" || in.Body != "new body" || in.MsgID != m.MsgID {
		t.Errorf("applied envelope from %s to %s #%s body %q id %s", e.FromBox, e.ToBox, e.Channel, in.Body, in.MsgID)
	}
}

func TestEditMessageRefusals(t *testing.T) {
	p := newPeer(t, "box-b")
	m := note("c-007", "c-008", "note", "old")
	stored := envRaw(t, p, "box-b", "", m)

	t.Run("another author", func(t *testing.T) {
		h := editHub(stored)
		c := opsClient(t, h)
		_, err := c.EditMessage(context.Background(), m.MsgID, "x", "c-008")
		if err == nil || !strings.Contains(err.Error(), "written by c-007, not c-008") {
			t.Fatalf("got %v", err)
		}
		if n := len(h.frames(wire.TEdit)); n != 1 {
			t.Errorf("%d edit frames, want the fetch only", n)
		}
	})
	t.Run("stored envelope unreadable", func(t *testing.T) {
		c := opsClient(t, editHub([]byte(`{"nope":1}`)))
		if _, err := c.EditMessage(context.Background(), m.MsgID, "x", ""); err == nil || !strings.Contains(err.Error(), "stored envelope") {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("hub refuses the fetch", func(t *testing.T) {
		h := &opsHub{reply: func(f wire.Frame) []wire.Frame {
			return []wire.Frame{{Type: wire.TError, MsgID: f.MsgID, Error: "not_found", Status: 404}}
		}}
		c := opsClient(t, h)
		_, err := c.EditMessage(context.Background(), m.MsgID, "x", "")
		var he *HubError
		if !errors.As(err, &he) || he.Token != "not_found" {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("no box key", func(t *testing.T) {
		c := opsClient(t, editHub(stored))
		c.Cfg.BoxID = ""
		if _, err := c.EditMessage(context.Background(), m.MsgID, "x", ""); err == nil {
			t.Fatal("an edit without a box id went through")
		}
	})
}

func TestDeleteMessage(t *testing.T) {
	p := newPeer(t, "box-b")
	m := note("c-007", "c-008", "note", "gone soon")
	stored := envRaw(t, p, "box-b", "", m)

	h := editHub(stored)
	c := opsClient(t, h)
	task, err := c.DeleteMessage(context.Background(), strings.ToUpper(m.MsgID), "c-007")
	if err != nil || task != "task-d" {
		t.Fatalf("task %q err %v", task, err)
	}
	if d := h.frames(wire.TDelete); len(d) != 1 || d[0].MsgID != m.MsgID {
		t.Errorf("delete frames %+v", d)
	}

	// no --as: no author check, straight to the delete
	h = editHub(stored)
	c = opsClient(t, h)
	if _, err := c.DeleteMessage(context.Background(), m.MsgID, ""); err != nil {
		t.Fatal(err)
	}
	if n := len(h.frames(wire.TEdit)); n != 0 {
		t.Errorf("%d edit fetches without --as", n)
	}

	// --as another agent: refused before the delete frame
	h = editHub(stored)
	c = opsClient(t, h)
	if _, err := c.DeleteMessage(context.Background(), m.MsgID, "c-008"); err == nil || !strings.Contains(err.Error(), "not written by c-008") {
		t.Fatalf("got %v", err)
	}
	if n := len(h.frames(wire.TDelete)); n != 0 {
		t.Errorf("%d delete frames for a foreign message", n)
	}
}
