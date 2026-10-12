package hub

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// DELETE /v1/attachments/{file_id} — the X on an attachment (SPL-1560, owner
// HUM-10 t1 d74ecae5: "remove attached images from the system, from message
// cards, from issues, from comments, everywhere where there are attachments").
//
// "From the system" is literal: the file comes off EVERY message the caller
// may change that carries it (a message card, an issue comment, the note an
// issue description's file rides on), each row re-signed as an edit would be,
// and the stored blob is deleted once no message carries it any more.
//
// Who may: the uploader and workspace admins. The hub keeps no uploader
// column; a file is uploaded by the member who sends it, so the uploader of
// an attachment is the author of the message that carries it. That is the
// edit rule (mayChangeTopic: the author, the tenant owner or an admin), never
// wider. A row the caller may read but not change keeps the file, and so
// does a box-signed row (the hub cannot re-sign an agent's envelope); either
// keeps the blob alive, and the answer counts them in `kept`.
//
// Refusals: no message the caller may read carries the file = 404 (the same
// answer as a file that does not exist, as DELETE /v1/files); readable but
// none changeable = 403 not_author, or 409 not_editable when every one is
// box-signed.
//
// Audit: the hub has no audit table for deletes (a message delete is a log
// line, edit.go); this logs one line per removal with the rows it changed.
func (s *Server) handleRemoveAttachment(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	from, ok := s.editorID(r, t.ID)
	if !ok {
		writeForbidden(w, rbac.NotesSend, "removing an attachment needs a signed-in member session")
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	if !s.permit(w, r, t.ID, hum, rbac.NotesSend) {
		return
	}
	fileID := r.PathValue("file_id")
	if _, err := blob.Key(t.ID, fileID); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
		return
	}
	reader, ok := s.readerID(r, t.ID)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "remove failed")
		return
	}
	res, err := s.detachEverywhere(r.Context(), t.ID, hum, from, reader, fileID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("file_id", fileID).Msg("attachment remove")
		writeErr(w, http.StatusInternalServerError, "internal", "remove failed")
		return
	}
	switch {
	case res.readable == 0:
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
		return
	case len(res.removed) == 0 && res.boxSigned == res.readable:
		writeErr(w, http.StatusConflict, "not_editable", "a box-signed message can only be changed by its box")
		return
	case len(res.removed) == 0:
		writeErr(w, http.StatusForbidden, "not_author", "only the uploader, the tenant owner or an admin may remove this attachment")
		return
	}
	blobGone, err := s.dropBlobIfFree(r.Context(), t.ID, fileID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("file_id", fileID).Msg("attachment blob delete")
	}
	ids := make([]string, 0, len(res.removed))
	rows := make([]map[string]any, 0, len(res.removed))
	for _, d := range res.removed {
		ids = append(ids, d.m.MsgID)
		rows = append(rows, editedPayload(d.m, d.canon, d.m.EditedAt, d.m.EditedBy, d.m.Revision))
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("file_id", fileID).Str("by", from).Strs("msg_ids", ids).
		Int("kept", res.readable-len(res.removed)).Bool("blob_deleted", blobGone).Msg("attachment removed")
	writeJSON(w, http.StatusOK, map[string]any{
		"file_id": fileID, "removed": ids, "messages": rows,
		"kept": res.readable - len(res.removed), "blob_deleted": blobGone,
	})
}

// detached is one row taken off: the row as read and its new canonical env.
type detached struct {
	m     store.EditableMessage
	canon []byte
}

type detachResult struct {
	removed   []detached
	readable  int // carriers the caller may read
	boxSigned int // of those, rows the hub cannot re-sign
}

// detachEverywhere takes fileID off every carrier the caller may change, and
// pushes each changed row to its viewers as a message_edited frame (the
// frame replaces a held row, so the card loses the file live).
func (s *Server) detachEverywhere(ctx context.Context, tenant, hum, from, reader, fileID string) (detachResult, error) {
	var res detachResult
	now := s.o.Now()
	ids, err := s.o.Store.FileCarriers(ctx, tenant, fileID, now)
	if err != nil {
		return res, err
	}
	for _, id := range ids {
		m, err := s.o.Store.GetEditable(ctx, tenant, id, now)
		if errors.Is(err, store.ErrNotFound) {
			continue
		}
		if err != nil {
			return res, err
		}
		may, err := s.canReadMessage(ctx, tenant, m, reader)
		if err != nil {
			return res, err
		}
		if !may {
			continue
		}
		res.readable++
		pub := s.wuiPub()
		if m.FromBox != WUIBox || (m.EnvSig != "" && pub == nil) {
			res.boxSigned++
			continue
		}
		if !s.mayChangeTopic(ctx, tenant, hum, from, m.FromID) {
			continue
		}
		if m.EnvSig == "" {
			pub = nil
		}
		d, canon, err := s.withoutFile(m, fileID, pub)
		if err != nil {
			return res, fmt.Errorf("msg %s: %w", id, err)
		}
		if err := s.o.Store.DetachFile(ctx, tenant, id, d); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				continue
			}
			return res, err
		}
		m.Msg, m.Env = d.Msg, d.Env
		res.removed = append(res.removed, detached{m: m, canon: canon})
		s.fanoutEdited(ctx, tenant, m, canon, m.EditedAt, m.EditedBy, m.Revision)
	}
	return res, nil
}

// withoutFile is m's envelope with fileID off its files[], re-signed with
// pub when it was signed (edit.go editedEnvelope's rule 7).
func (s *Server) withoutFile(m store.EditableMessage, fileID string, pub ed25519.PublicKey) (store.FileDetach, []byte, error) {
	env, err := wire.ParseEnvelope(m.Env)
	if err != nil {
		return store.FileDetach{}, nil, err
	}
	inner, err := msg.Parse(env.Msg)
	if err != nil {
		return store.FileDetach{}, nil, err
	}
	kept := []msg.Attachment{}
	for _, f := range inner.Files {
		if f.FileID != fileID && f.SHA256 != fileID {
			kept = append(kept, f)
		}
	}
	inner.Files = kept
	if env.Msg, err = msg.Canonical(inner); err != nil {
		return store.FileDetach{}, nil, err
	}
	if pub != nil {
		if env, err = s.dispatchEnvelope(env.ToBox, env.Channel, env.ParentTaskID, pub, inner); err != nil {
			return store.FileDetach{}, nil, fmt.Errorf("re-sign: %w", err)
		}
	}
	canon, err := env.Marshal()
	if err != nil {
		return store.FileDetach{}, nil, err
	}
	files, err := json.Marshal(kept)
	if err != nil {
		return store.FileDetach{}, nil, err
	}
	return store.FileDetach{Msg: env.Msg, Env: canon, EnvSig: env.Sig, Files: files}, canon, nil
}

// dropBlobIfFree deletes the stored bytes once no message in retention
// carries the file (the same test as the read door's FileAttached). true =
// the blob is gone (or was already).
func (s *Server) dropBlobIfFree(ctx context.Context, tenant, fileID string) (bool, error) {
	still, err := s.o.Store.FileAttached(ctx, tenant, fileID, s.o.Now())
	if err != nil || still {
		return false, err
	}
	key, err := blob.Key(tenant, fileID)
	if err != nil {
		return false, err
	}
	switch err := s.o.Blob.Delete(ctx, key); {
	case errors.Is(err, blob.ErrNotFound):
	case err != nil:
		return false, err
	}
	s.fileUsage.forget(tenant)
	return true, nil
}

// attachmentPreflight answers CORS preflight for DELETE
// /v1/attachments/{file_id}; no new request header (edit.go editPreflight).
func (s *Server) attachmentPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
