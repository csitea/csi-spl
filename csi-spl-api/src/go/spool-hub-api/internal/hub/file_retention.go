package hub

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// File retention. A stored blob is exactly as private as the
// messages carrying it (mayReadFile), so once the last of them expires the
// blob has no reader left: the read door stops serving it after the upload
// grace, and this sweep deletes it after the orphan grace. Before this the
// sweep deleted messages and never their blobs, and the door read "no message
// carries it" as "an upload not sent yet" - an expired private attachment
// became readable by the whole tenant, for ever.
const (
	// FileUploadGrace is how long after its upload a blob that no message
	// in retention carries stays readable (the upload-then-send window: a
	// box or browser fetches back what it just uploaded).
	FileUploadGrace = time.Hour
	// FileOrphanGrace is how old such a blob must be before retention
	// deletes it. Longer than FileUploadGrace: a send may reference an
	// upload made a while ago, and must still find its bytes.
	FileOrphanGrace = 24 * time.Hour
	// fileSweepEvery: the orphan sweep lists the whole bucket, so it runs
	// far less often than the message sweep.
	fileSweepEvery = time.Hour
)

// FileSweepResult counts what one orphan sweep did.
type FileSweepResult struct {
	Scanned int // objects listed under t/ and tmp/
	Deleted int // unreferenced blobs and stale tmp objects removed
}

// SweepFiles deletes every tenant blob (t/<tenant>/files/<sha256>) that no
// message in retention carries, that is no member's avatar, and that was
// uploaded more than FileOrphanGrace ago; and every tmp/ object that old
// (an upload a crashed hub never promoted). Content-addressed: one sha256
// can sit on several messages, so it goes only when NONE carries it. The
// decision is re-checked right before each delete, so a re-upload (Touch)
// or a send landing while the listing runs keeps the blob.
func (s *Server) SweepFiles(ctx context.Context, now time.Time) (FileSweepResult, error) {
	var r FileSweepResult
	avatars := map[string]map[string]bool{}
	err := s.o.Blob.List(ctx, "t/", func(key string, up time.Time) error {
		r.Scanned++
		tenant, fileID, ok := parseFileKey(key)
		if !ok || now.Sub(up) < FileOrphanGrace {
			return nil
		}
		av, ok := avatars[tenant]
		if !ok {
			var err error
			if av, err = s.tenantAvatarSet(ctx, tenant); err != nil {
				return err
			}
			avatars[tenant] = av
		}
		if av[fileID] {
			return nil
		}
		gone, err := s.orphanDelete(ctx, tenant, fileID, key, now)
		if gone {
			r.Deleted++
		}
		return err
	})
	if err != nil {
		return r, err
	}
	err = s.o.Blob.List(ctx, "tmp/", func(key string, up time.Time) error {
		r.Scanned++
		if now.Sub(up) < FileOrphanGrace {
			return nil
		}
		if err := s.o.Blob.Delete(ctx, key); err != nil && !errors.Is(err, blob.ErrNotFound) {
			return err
		}
		r.Deleted++
		return nil
	})
	return r, err
}

// orphanDelete removes key when no message in retention carries fileID and
// its upload is still older than the grace, both read now rather than from
// the listing.
func (s *Server) orphanDelete(ctx context.Context, tenant, fileID, key string, now time.Time) (bool, error) {
	attached, err := s.o.Store.FileAttached(ctx, tenant, fileID, now)
	if err != nil || attached {
		return false, err
	}
	up, err := s.o.Blob.Uploaded(ctx, key)
	if errors.Is(err, blob.ErrNotFound) {
		return false, nil
	}
	if err != nil || now.Sub(up) < FileOrphanGrace {
		return false, err
	}
	if err := s.o.Blob.Delete(ctx, key); err != nil {
		if errors.Is(err, blob.ErrNotFound) { // another hub process got it first
			return false, nil
		}
		return false, err
	}
	s.fileUsage.forget(tenant)
	return true, nil
}

// tenantAvatarSet is the file_ids of tenant's member avatars: their tenant
// copy lives at t/<tenant>/files/ too and no message carries it.
func (s *Server) tenantAvatarSet(ctx context.Context, tenant string) (map[string]bool, error) {
	out := map[string]bool{}
	h, ok := s.o.Store.(store.Humans)
	if !ok {
		return out, nil
	}
	m, err := h.TenantAvatars(ctx, tenant)
	for _, fid := range m {
		if fid != "" {
			out[fid] = true
		}
	}
	return out, err
}

// parseFileKey splits t/<tenant>/files/<sha256>; ok=false for anything else.
func parseFileKey(key string) (tenant, fileID string, ok bool) {
	p := strings.Split(key, "/")
	if len(p) != 4 || p[0] != "t" || p[2] != "files" || p[1] == "" {
		return "", "", false
	}
	if k, err := blob.Key(p[1], p[3]); err != nil || k != key {
		return "", "", false
	}
	return p[1], p[3], true
}
