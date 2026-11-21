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
	Scanned int // objects listed under t/, tmp/ and each workspace's qto-assets/, qto-media/ and .doctree/
	Deleted int // unreferenced blobs, stale tmp objects, unnamed pictures and doc media removed
}

// SweepFiles deletes every tenant blob (t/<tenant>/files/<sha256>) that no
// message in retention carries, that is no member's avatar and no doc's
// picture (attrs.assets, SPL-2201), and that was
// uploaded more than FileOrphanGrace ago; and every tmp/ object that old
// (an upload a crashed hub never promoted). Content-addressed: one sha256
// can sit on several messages, so it goes only when NONE carries it. The
// decision is re-checked right before each delete, so a re-upload (Touch)
// or a send landing while the listing runs keeps the blob. Then each
// workspace's own docs store (sweepOwnAssets, sweepOwnMedia).
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
	return r, errors.Join(s.sweepOwnAssets(ctx, now, &r), s.sweepOwnMedia(ctx, now, &r))
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

// docMediaSweepStore is the store side of the doc media sweep (rdb 0306).
type docMediaSweepStore interface {
	DocMediaSweep(ctx context.Context, tenant string, now time.Time, grace time.Duration) ([]store.DocMedia, error)
	DocGoneBefore(ctx context.Context, tenant string, cutoff time.Time, limit int) ([]string, error)
	DocGoneDrop(ctx context.Context, tenant, doc string) error
	DocMediaHold(ctx context.Context, tenant, doc, name string) (store.DocMediaHold, error)
}

var _ docMediaSweepStore = (*store.Postgres)(nil)

// docMediaSwept are the per-doc prefixes of a workspace's own docs store
// the media sweep walks: the media of spec 190 (qto-media/<doc>/) and the
// pictures of spec 113 (.doctree/<doc>/, gap G6).
var docMediaSwept = []string{DocMediaPrefix, ".doctree/"}

// docGoneBatch bounds the deleted docs one sweep clears per workspace.
const docGoneBatch = 500

// sweepOwnMedia applies the 7-day grace of spec 190 (Q6 A, C7, row H3) to
// each workspace's own docs store: a media file no section of its doc has
// named for DocMediaGrace, every file of a doc deleted DocMediaGrace ago,
// and, as a backstop, any object under docMediaSwept of a visible doc that
// nothing names and that was uploaded before the grace. A doc locked to a
// human is hidden from the sweep, and its files are kept. Errors as
// sweepOwnAssets: a missing bucket is skipped, any other does not stop the
// other workspaces.
func (s *Server) sweepOwnMedia(ctx context.Context, now time.Time, r *FileSweepResult) error {
	ms, ok := s.o.Store.(docMediaSweepStore)
	lt, listed := s.o.Store.(ownAssetTenants)
	if !ok || !listed || s.o.WorkspaceDocs == nil {
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
			err = s.sweepTenantMedia(ctx, mediaSweep{st: st, ms: ms, tenant: tenant, now: now, r: r})
		}
		if err != nil && !bucketMissing(err) {
			errs = append(errs, errors.Join(errors.New("workspace "+tenant+" doc media"), err))
		}
	}
	return errors.Join(errs...)
}

// mediaSweep is one workspace's pass of sweepOwnMedia.
type mediaSweep struct {
	st     blob.Store
	ms     docMediaSweepStore
	tenant string
	now    time.Time
	r      *FileSweepResult
}

// sweepTenantMedia: the rows past their grace, the docs deleted before it,
// then the backstop walk and the stale scratch uploads.
func (s *Server) sweepTenantMedia(ctx context.Context, m mediaSweep) error {
	defer s.fileUsage.forget(m.tenant)
	rows, err := m.ms.DocMediaSweep(ctx, m.tenant, m.now, DocMediaGrace)
	if err != nil {
		return err
	}
	for _, row := range rows {
		if err := m.delete(ctx, docMediaKey(row.Doc, row.FileName())); err != nil {
			return err
		}
	}
	docs, err := m.ms.DocGoneBefore(ctx, m.tenant, m.now.Add(-DocMediaGrace), docGoneBatch)
	if err != nil {
		return err
	}
	for _, doc := range docs {
		for _, p := range docMediaSwept {
			if err := m.st.List(ctx, p+doc+"/", func(key string, _ time.Time) error { m.r.Scanned++; return m.delete(ctx, key) }); err != nil {
				return err
			}
		}
		if err := m.ms.DocGoneDrop(ctx, m.tenant, doc); err != nil {
			return err
		}
	}
	for _, p := range docMediaSwept {
		if err := m.st.List(ctx, p, func(key string, up time.Time) error { return m.backstop(ctx, p, key, up) }); err != nil {
			return err
		}
	}
	return m.st.List(ctx, docMediaScratch, func(key string, up time.Time) error {
		m.r.Scanned++
		if m.now.Sub(up) < FileOrphanGrace {
			return nil
		}
		return m.delete(ctx, key)
	})
}

// backstop deletes key (<prefix><doc>/<name>) when its doc is visible,
// names it neither in the index nor in a section, and both the listing and
// a fresh read put its upload before the grace. A gone doc waits for its
// own pass above; a hidden one is kept.
func (m mediaSweep) backstop(ctx context.Context, prefix, key string, up time.Time) error {
	m.r.Scanned++
	doc, name, ok := strings.Cut(strings.TrimPrefix(key, prefix), "/")
	if !ok || strings.Contains(name, "/") || m.now.Sub(up) < DocMediaGrace {
		return nil
	}
	h, err := m.ms.DocMediaHold(ctx, m.tenant, doc, name)
	if err != nil || !h.Live || h.Index || h.Named {
		return err
	}
	if up, err = m.st.Uploaded(ctx, key); errors.Is(err, blob.ErrNotFound) || err == nil && m.now.Sub(up) < DocMediaGrace {
		return nil
	} else if err != nil {
		return err
	}
	return m.delete(ctx, key)
}

// delete removes key; gone already (another hub process, or a doc whose
// row and object went in one pass) is no error.
func (m mediaSweep) delete(ctx context.Context, key string) error {
	err := m.st.Delete(ctx, key)
	if errors.Is(err, blob.ErrNotFound) {
		return nil
	}
	if err == nil {
		m.r.Deleted++
	}
	return err
}
