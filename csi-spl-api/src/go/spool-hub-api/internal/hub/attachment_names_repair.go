package hub

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// POST /v1/operator/attachment-names/repair (SPL-1808): the hub names the
// attachments still named by their own sha256 on the messages of a box whose
// pin is REVOKED. Owner HUM-10, t1 b1af5f5c msg 8d4cf989 (poll a575a57a,
// option A): "Rename them on the hub; their old signature no longer matches".
//
// A live box repairs its own rows and re-signs them (`spool attach-rename`,
// box_edit.go); the hub never touches those, it counts them in live_box. A
// revoked box can sign nothing any more, so for its rows the hub rewrites the
// names in place and KEEPS the stored sig, which then no longer verifies
// against that box's old key: the owner's accepted cost. Names only, as the
// box path: the type comes from the blob's magic bytes, the name becomes
// file-<12 hex>.<ext>, an unknown type keeps its name; bytes, file_id, body,
// revision and edit stamps stay. Browsers get the row as message_edited.
//
// Body {tenant, dry_run?}; at most attachmentRepairMax messages per call.

const attachmentRepairMax = 2000

type attachmentRepairResult struct {
	Tenant   string           `json:"tenant"`
	DryRun   bool             `json:"dry_run"`
	Found    int              `json:"found"`    // messages with a sha-named file
	LiveBox  int              `json:"live_box"` // of those, a live box's: left to it
	Messages int              `json:"messages"` // repaired (dry: would be)
	Renamed  int              `json:"renamed"`  // files named (dry: would be)
	Unknown  int              `json:"unknown"`  // files of no known type, kept
	ByType   map[string]int   `json:"by_type"`
	Samples  []map[string]any `json:"samples"`
	Failed   []map[string]any `json:"failed"`
	More     bool             `json:"more"` // the cap was hit: call again
}

func (s *Server) handleOperatorAttachmentNamesRepair(w http.ResponseWriter, r *http.Request) {
	by, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	var body struct {
		Tenant string `json:"tenant"`
		DryRun bool   `json:"dry_run"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {tenant, dry_run?}")
		return
	}
	if !msg.ValidTenantID(body.Tenant) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "tenant must be a valid slug")
		return
	}
	hn, ok := s.o.Store.(store.HashNamedFiles)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store cannot list sha-named files")
		return
	}
	ctx := r.Context()
	ids, err := hn.HashNamedCarriers(ctx, body.Tenant, s.o.Now(), attachmentRepairMax)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", body.Tenant).Msg("attachment names repair: list")
		writeErr(w, http.StatusInternalServerError, "internal", "sha-named files not listed")
		return
	}
	out := attachmentRepairResult{Tenant: body.Tenant, DryRun: body.DryRun, Found: len(ids),
		ByType: map[string]int{}, Samples: []map[string]any{}, Failed: []map[string]any{}, More: len(ids) == attachmentRepairMax}
	for _, id := range ids {
		if err := s.repairNames(ctx, body.Tenant, id, body.DryRun, &out); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", body.Tenant).Str("msg_id", id).Msg("attachment names repair")
			out.Failed = append(out.Failed, map[string]any{"msg_id": id, "error": err.Error()})
		}
	}
	s.o.Log.Info().Str("tenant", body.Tenant).Str("by", by).Bool("dry_run", body.DryRun).Int("found", out.Found).
		Int("live_box", out.LiveBox).Int("messages", out.Messages).Int("renamed", out.Renamed).
		Int("unknown", out.Unknown).Int("failed", len(out.Failed)).Msg("operator.attachment_names_repair")
	writeJSON(w, http.StatusOK, out)
}

// repairNames names one message's sha-named files when its box's pin is
// revoked, and adds what it did (or would do) to out.
func (s *Server) repairNames(ctx context.Context, tenant, id string, dry bool, out *attachmentRepairResult) error {
	m, err := s.o.Store.GetEditable(ctx, tenant, id, s.o.Now())
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if m.FromBox == WUIBox || m.EnvSig == "" {
		out.LiveBox++ // the hub's own rows: never this path
		return nil
	}
	switch _, err := s.o.Store.GetPin(ctx, tenant, m.FromBox); {
	case err == nil:
		out.LiveBox++
		return nil
	case !errors.Is(err, store.ErrNotFound):
		return err
	}
	env, err := wire.ParseEnvelope(m.Env)
	if err != nil {
		return err
	}
	inner, err := msg.Parse(env.Msg)
	if err != nil {
		return err
	}
	n := 0
	for i, a := range inner.Files {
		if a.Mode != "blob" || a.Kind != "file" || !files.IsHashName(a.Name, a.FileID, a.SHA256) {
			continue
		}
		ext, err := s.sniffBlob(ctx, tenant, a.FileID)
		if err != nil {
			return err
		}
		if ext == "" {
			out.Unknown++
			continue
		}
		to := files.RepairedName(a.FileID, ext)
		if len(out.Samples) < 5 {
			out.Samples = append(out.Samples, map[string]any{"msg_id": id, "before": a.Name, "after": to})
		}
		inner.Files[i].Name = to
		out.ByType[ext]++
		out.Renamed++
		n++
	}
	if n == 0 {
		return nil
	}
	out.Messages++
	if dry {
		return nil
	}
	if env.Msg, err = msg.Canonical(inner); err != nil {
		return err
	}
	canon, err := env.Marshal() // the stored sig stays (owner option A)
	if err != nil {
		return err
	}
	fj, err := json.Marshal(inner.Files)
	if err != nil {
		return err
	}
	if err := s.o.Store.DetachFile(ctx, tenant, id, store.FileDetach{Msg: env.Msg, Env: canon, Files: fj}); err != nil {
		return err
	}
	m.Msg, m.Env = env.Msg, canon
	s.fanoutEdited(ctx, tenant, m, canon, m.EditedAt, m.EditedBy, m.Revision)
	return nil
}

// sniffBlob: the extension the stored bytes of fileID are, "" when unknown.
func (s *Server) sniffBlob(ctx context.Context, tenant, fileID string) (string, error) {
	key, err := blob.Key(tenant, fileID)
	if err != nil {
		return "", err
	}
	rc, err := s.o.Blob.Get(ctx, key)
	if err != nil {
		return "", err
	}
	defer rc.Close()
	b := make([]byte, 8192)
	k, err := io.ReadFull(rc, b)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return "", err
	}
	return files.SniffBytes(b[:k], k < len(b)), nil
}
