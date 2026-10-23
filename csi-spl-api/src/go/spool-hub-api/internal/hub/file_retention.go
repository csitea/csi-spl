package hub

import (
	"context"
	"errors"
	"strings"
	"time"

	"cloud.google.com/go/storage"

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
	Scanned int // objects listed under t/, tmp/ and each workspace's qto-assets/
	Deleted int // unreferenced blobs, stale tmp objects and unnamed pictures removed
}

// SweepFiles deletes every tenant blob (t/<tenant>/files/<sha256>) that no
// message in retention carries, that is no member's avatar and no doc's
// picture (attrs.assets, SPL-2201), and that was
// uploaded more than FileOrphanGrace ago; and every tmp/ object that old
// (an upload a crashed hub never promoted). Content-addressed: one sha256
// can sit on several messages, so it goes only when NONE carries it. The
// decision is re-checked right before each delete, so a re-upload (Touch)
// or a send landing while the listing runs keeps the blob. Then each
// workspace's own docs store (sweepOwnAssets).
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
	if err != nil {
		return r, err
	}
	return r, s.sweepOwnAssets(ctx, now, &r)
}

// ownAssetTenants lists the live workspaces (store.BlockerIssues has the
// one such read): the ones whose own docs store the sweep walks.
type ownAssetTenants interface {
	BlockerTenants(ctx context.Context) ([]string, error)
}

// sweepOwnAssets deletes every picture in a workspace's own docs store
// (qto-assets/<sha256>, spec 114 R3) that no doc of THAT workspace names and
// that was uploaded more than FileOrphanGrace ago, re-checked right before
// the delete (SPL-2963). Tenant "system" keeps the shared store, swept
// above. A bucket that does not exist yet (dev before step 052's apply) is
// skipped; any other store error does not stop the other workspaces and is
// returned at the end. A store that cannot tell which pictures a doc names
// deletes nothing.
func (s *Server) sweepOwnAssets(ctx context.Context, now time.Time, r *FileSweepResult) error {
	lt, ok := s.o.Store.(ownAssetTenants)
	if _, held := s.o.Store.(docAssetStore); !ok || !held || s.o.WorkspaceDocs == nil {
		return nil
	}
	tenants, err := lt.BlockerTenants(ctx)
	if err != nil {
		return err
	}
	var errs []error
	for _, tenant := range tenants {
		st, own, err := s.docAssetBucket(ctx, tenant)
		if !own {
			continue
		}
		if err == nil {
			err = st.List(ctx, DocAssetPrefix, func(key string, up time.Time) error {
				r.Scanned++
				id := strings.TrimPrefix(key, DocAssetPrefix)
				if now.Sub(up) < FileOrphanGrace || !docAssetSHA(id) {
					return nil
				}
				gone, err := s.ownAssetDelete(ctx, st, tenant, id, now)
				if gone {
					r.Deleted++
				}
				return err
			})
		}
		if err != nil && !bucketMissing(err) {
			errs = append(errs, errors.Join(errors.New("workspace "+tenant+" qto-assets"), err))
		}
	}
	return errors.Join(errs...)
}

// ownAssetDelete removes picture id from tenant's own store when no doc of
// tenant names it and its upload is still older than the grace, both read
// now rather than from the listing.
func (s *Server) ownAssetDelete(ctx context.Context, st blob.Store, tenant, id string, now time.Time) (bool, error) {
	if kept, err := s.fileKept(ctx, tenant, id); err != nil || kept {
		return false, err
	}
	key := DocAssetPrefix + id
	up, err := st.Uploaded(ctx, key)
	if errors.Is(err, blob.ErrNotFound) {
		return false, nil
	}
	if err != nil || now.Sub(up) < FileOrphanGrace {
		return false, err
	}
	if err := st.Delete(ctx, key); err != nil {
		if errors.Is(err, blob.ErrNotFound) { // another hub process got it first
			return false, nil
		}
		return false, err
	}
	s.fileUsage.forget(tenant)
	return true, nil
}

// docAssetSHA: id is a lower-case hex sha256, the only name a picture has.
func docAssetSHA(id string) bool {
	if len(id) != 64 {
		return false
	}
	for _, c := range id {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// bucketMissing: the store's bucket does not exist (GCS, or an S3 API's
// NoSuchBucket); a directory store that does not exist lists nothing.
func bucketMissing(err error) bool {
	var api interface{ ErrorCode() string }
	return errors.Is(err, storage.ErrBucketNotExist) || errors.As(err, &api) && api.ErrorCode() == "NoSuchBucket"
}

// orphanDelete removes key when no message in retention carries fileID and
// its upload is still older than the grace, both read now rather than from
// the listing.
func (s *Server) orphanDelete(ctx context.Context, tenant, fileID, key string, now time.Time) (bool, error) {
	attached, err := s.o.Store.FileAttached(ctx, tenant, fileID, now)
	if err != nil || attached {
		return false, err
	}
	if kept, err := s.fileKept(ctx, tenant, fileID); err != nil || kept {
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
