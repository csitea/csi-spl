package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"path"
	"strings"
	"time"
	"unicode"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A box edits, or deletes, a message it sent itself (specs/032 FR-ED-012..016,
// contracts/message-edit-v1.md §10). The owner asked every agent to re-edit its
// own earlier posts, keeping a revision; the browser's PATCH cannot do it,
// because a box-signed envelope carries that box's signature and the hub holds
// no key to re-sign it (rule 7). So the box re-signs it: over its own socket,
// whose hello proved the box, it fetches the stored envelope, replaces the
// body, signs the result with the SAME box key and sends it back. The hub
// verifies it against the box's pin and writes it through the one edit path
// the browser uses (ApplyEdit, the register, message_edited).
//
// The unit of trust is the box, not the agent: the box key signs every
// envelope a box sends, whichever of its agents wrote it, so the box that sent
// a message is the one principal that can sign its next revision. An agent the
// box no longer announces does not change that.

// onEdit answers an edit frame: no env = fetch the stored envelope, env = apply.
func (s *Server) onEdit(ctx context.Context, x *session, f wire.Frame) {
	id, m, ok := s.boxOwnMessage(ctx, x, f, len(f.Env) > 0)
	if !ok {
		return
	}
	if len(f.Env) == 0 { // the fetch: what the box re-signs
		x.write(ctx, wire.Frame{Type: wire.TEdit, MsgID: id, TaskID: m.TaskID, Env: m.Env, Revision: m.Revision}) //nolint:errcheck
		return
	}
	env, inner, rename, ok := s.verifyBoxEdit(ctx, x, id, m, f.Env)
	if !ok {
		return // verifyBoxEdit answered
	}
	canon, err := env.Marshal()
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "edit not stored")
		return
	}
	if rename {
		s.onRenameFiles(ctx, x, id, m, env, inner, canon)
		return
	}
	now := s.o.Now().UTC().Truncate(time.Second)
	rev, err := s.o.Store.ApplyEdit(ctx, x.tenant, id, store.Edit{
		Body: inner.Body, Msg: env.Msg, Env: canon, EditedBy: inner.From, EditedAt: now, EnvSig: env.Sig})
	switch {
	case errors.Is(err, store.ErrNotFound):
		x.fail(ctx, id, "not_found", http.StatusNotFound, "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("box edit store")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "edit not stored")
		return
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("msg_id", id).Str("by", inner.From).Int("revision", rev).Msg("message edited by its box")
	s.fanoutEdited(ctx, x.tenant, m, canon, now, inner.From, rev)
	x.write(ctx, wire.Frame{Type: wire.TEdit, MsgID: id, TaskID: m.TaskID, Revision: rev}) //nolint:errcheck
}

// onRenameFiles stores a names-only edit (SPL-1808): the attachments whose
// name was their own sha get a real one. It is a repair of how the file was
// attached, not a new revision of what was said, so it writes no revision
// and keeps the edit stamps; it rides the store's row rewrite that removing
// an attachment uses (msg, env, env_sig, files), and browsers get the row
// back as a message_edited frame, as for that removal.
func (s *Server) onRenameFiles(ctx context.Context, x *session, id string, m store.EditableMessage, env *wire.Envelope, inner *msg.Message, canon []byte) {
	fj, err := json.Marshal(inner.Files)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "rename not stored")
		return
	}
	err = s.o.Store.DetachFile(ctx, x.tenant, id, store.FileDetach{Msg: env.Msg, Env: canon, EnvSig: env.Sig, Files: fj})
	switch {
	case errors.Is(err, store.ErrNotFound):
		x.fail(ctx, id, "not_found", http.StatusNotFound, "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("box file rename store")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "rename not stored")
		return
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("msg_id", id).Msg("attachment names repaired by the message's box")
	m.Msg, m.Env = env.Msg, canon
	s.fanoutEdited(ctx, x.tenant, m, canon, m.EditedAt, m.EditedBy, m.Revision)
	x.write(ctx, wire.Frame{Type: wire.TEdit, MsgID: id, TaskID: m.TaskID, Revision: m.Revision}) //nolint:errcheck
}

// onDelete removes a message this box sent: the box-side twin of the
// browser's DELETE, with the same cascade and message_deleted frame.
func (s *Server) onDelete(ctx context.Context, x *session, f wire.Frame) {
	id, m, ok := s.boxOwnMessage(ctx, x, f, true)
	if !ok {
		return
	}
	if err := s.o.Store.DeleteMessage(ctx, x.tenant, id); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			x.fail(ctx, id, "not_found", http.StatusNotFound, "no such message")
			return
		}
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("box delete store")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "delete not stored")
		return
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("msg_id", id).Msg("message deleted by its box")
	s.fanoutDeleted(ctx, x.tenant, m)
	x.write(ctx, wire.Frame{Type: wire.TDelete, MsgID: id, TaskID: m.TaskID}) //nolint:errcheck
}

// boxOwnMessage is §10 rules 1-4, shared by fetch, edit and delete: a UUID,
// a paid tenant (writes only), a message in this tenant within retention, and
// one THIS box sent. It answers every refusal itself.
func (s *Server) boxOwnMessage(ctx context.Context, x *session, f wire.Frame, write bool) (string, store.EditableMessage, bool) {
	id := f.MsgID
	if !uuidRe.MatchString(id) || id != strings.ToLower(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "an "+f.Type+" frame needs msg_id, the message's lowercase UUID")
		return "", store.EditableMessage{}, false
	}
	if write {
		t, err := s.o.Store.GetTenant(ctx, x.tenant)
		if err != nil {
			x.fail(ctx, id, "internal", http.StatusInternalServerError, "tenant unavailable")
			return "", store.EditableMessage{}, false
		}
		if !billing.AllowsWrite(t.BillingStatus) {
			x.fail(ctx, id, billing.TokenUnpaid, billing.HTTPUnpaid, "tenant billing is unpaid")
			return "", store.EditableMessage{}, false
		}
	}
	m, err := s.o.Store.GetEditable(ctx, x.tenant, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		x.fail(ctx, id, "not_found", http.StatusNotFound, "no such message")
		return "", store.EditableMessage{}, false
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("box edit lookup")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "message unavailable")
		return "", store.EditableMessage{}, false
	}
	if m.FromBox != x.box {
		x.fail(ctx, id, "not_author", http.StatusForbidden, "only the box that sent a message may "+f.Type+" it")
		return "", store.EditableMessage{}, false
	}
	return id, m, true
}

// verifyBoxEdit is §10 rules 5-8 on the new envelope: signed by this box and
// verified against its pin, the same msg_id, a body that is not empty and
// fits, and nothing else changed - not an inner field, not a hub-envelope tag -
// so the message keeps its position, its addressee and its topic. It answers
// every refusal itself.
//
// One more edit is a rename (SPL-1808): the body stays the stored one and
// only the names of attachments still named by their own sha256 change.
// rename = true says that is what this envelope is.
func (s *Server) verifyBoxEdit(ctx context.Context, x *session, id string, m store.EditableMessage, raw []byte) (*wire.Envelope, *msg.Message, bool, bool) {
	refuse := func(token string, status int, detail string) (*wire.Envelope, *msg.Message, bool, bool) {
		x.fail(ctx, id, token, status, detail)
		return nil, nil, false, false
	}
	env, err := wire.ParseEnvelope(raw)
	if err != nil {
		return refuse("bad_json", http.StatusBadRequest, "envelope does not parse")
	}
	if env.FromBox != x.box {
		return refuse("bad_sig", http.StatusBadRequest, "from_box is not the hello box")
	}
	pub, err := s.o.Store.GetPin(ctx, x.tenant, x.box)
	if err != nil {
		return refuse("unpinned_box", http.StatusBadRequest, "from_box is no longer pinned")
	}
	if err := env.Verify(pub); err != nil {
		return refuse("bad_sig", http.StatusBadRequest, "envelope sig does not verify against the from_box pin")
	}
	inner, err := env.Inner()
	if err != nil {
		return refuse("bad_json", http.StatusBadRequest, err.Error())
	}
	if inner.MsgID != id {
		return refuse("bad_json", http.StatusBadRequest, "the envelope's msg_id is not the edited message")
	}
	if strings.TrimSpace(inner.Body) == "" {
		return refuse("empty_body", http.StatusBadRequest, "body must not be empty")
	}
	if len(inner.Body) > bodyMax {
		return refuse("too_large", http.StatusRequestEntityTooLarge, "body must be at most 65536 bytes")
	}
	if rf := vendorTokenRefusal(inner.Body); rf != nil { // spec 159 L23
		return refuse(rf.token, rf.status, rf.detail)
	}
	old, err := wire.ParseEnvelope(m.Env)
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("box edit: stored envelope")
		return refuse("internal", http.StatusInternalServerError, "message unavailable")
	}
	if env.ToBox != old.ToBox || env.Channel != old.Channel || env.ParentTaskID != old.ParentTaskID {
		return refuse("bad_edit", http.StatusBadRequest, "an edit changes the body only: to_box, channel and parent_task_id must be the stored ones")
	}
	// The stored inner object with the new body must be byte-for-byte the
	// signed one: ts, from, to, task_id, kind, files and v stay as they were.
	want, err := msg.Parse(old.Msg)
	if err != nil {
		return refuse("internal", http.StatusInternalServerError, "message unavailable")
	}
	rename := renamesHashNames(want.Files, inner.Files)
	if rename && inner.Body != want.Body {
		return refuse("bad_edit", http.StatusBadRequest, "a file rename changes file names only: the body must be the stored one")
	}
	want.Body = inner.Body
	a, errA := msg.Canonical(want)
	b, errB := msg.Canonical(inner)
	if errA != nil || errB != nil || !bytes.Equal(a, b) {
		return refuse("bad_edit", http.StatusBadRequest, "an edit changes the body only (or the names of files named by their sha): every other msg field must be the stored one")
	}
	return env, inner, rename, true
}

// renamesHashNames reports whether next renames at least one of stored's
// attachments, and only in the one way SPL-1808 allows: a blob whose name is
// its own sha256 gets a plain file name. When it does, stored's names are
// set to next's, so the byte-for-byte check that follows sees every other
// field. Any other difference leaves stored as it was, and that check
// refuses it.
func renamesHashNames(stored, next []msg.Attachment) bool {
	if len(stored) != len(next) {
		return false
	}
	n := 0
	for i, a := range stored {
		if a.Name == next[i].Name {
			continue
		}
		if a.Mode != "blob" || !files.IsHashName(a.Name, a.FileID, a.SHA256) || !plainFileName(next[i].Name) {
			return false
		}
		n++
	}
	for i := range stored {
		stored[i].Name = next[i].Name
	}
	return n > 0
}

// plainFileName: a base name with no path, control character or leading dot,
// at most 255 bytes, and not itself a sha (a rename must name the file).
func plainFileName(n string) bool {
	if n == "" || len(n) > 255 || n[0] == '.' || path.Base(n) != n || strings.ContainsAny(n, `/\`) || files.IsHashName(n, n, n) {
		return false
	}
	return strings.IndexFunc(n, unicode.IsControl) < 0
}
