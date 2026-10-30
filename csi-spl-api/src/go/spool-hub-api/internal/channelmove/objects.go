package channelmove

// The objects of a channel move outside the database (spec 169 T6, section
// 5.3, steps P3 and P6):
//
//   - M4, attachments: the files bucket blob t/<tenant>/files/<sha256> of
//     every mode "blob" item in the set's messages.files.
//   - M8, Qto pictures: the sha256 ids the moved docs' attrs.assets name, at
//     qto-assets/<sha256> in the workspace's own docs store (step 052), or,
//     for a picture stored before it (or a hub with no workspace docs
//     stores), at the files bucket key above. A Qto doc's text is a database
//     row and moves in P4, not here.
//
// P3 (Copy) runs before the database step and is idempotent: a key is
// content-addressed, so a <DST> object of the same name holds the same bytes.
// P6 (Delete) runs after the P4 commit and removes a <SRC> object only when
// no <SRC> row still lists it (the shared-file rule, section 5.5) and its
// <DST> copy exists, so it never deletes the only copy. A re-run of either
// resumes: what is already done counts as Present or Gone.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

// docAssetPrefix is hub.DocAssetPrefix (wsdoc_assets.go), repeated here
// because the hub imports this package, not the other way round.
const docAssetPrefix = "qto-assets/"

// Holder answers, from the database, whether a row of tenant still lists a
// blob. *store.Postgres has both (the file read door and the doc asset keep).
type Holder interface {
	FileAttached(ctx context.Context, tenant, fileID string, now time.Time) (bool, error)
	DocAssetHeld(ctx context.Context, tenant, fileID string) (bool, error)
}

// Objects is where a move's objects live.
type Objects struct {
	Files blob.Store // the hub's files bucket
	// Docs is a workspace's own docs store; nil, or a nil store, = none: its
	// Qto pictures live in Files (tenant "system", or no stores configured).
	Docs func(ctx context.Context, tenant string) (blob.Store, error)
	Held Holder
	Now  func() time.Time // nil = time.Now
}

// ObjectSet is the frozen object lists of the journal.
type ObjectSet struct {
	Files     []string // M4: file ids (sha256) of the set's blob attachments
	DocAssets []string // M8: sha256 ids the moved docs' attrs.assets name
}

// ObjectReport counts what one step did.
type ObjectReport struct {
	Copied  int      // P3: written to <DST>
	Present int      // P3: <DST> already held it
	Deleted int      // P6: removed from <SRC>
	Gone    int      // P6: <SRC> no longer held it
	Kept    []string // P6: <SRC> keys a staying row still lists (shared, 5.5)
}

// loc is one object: its store and key.
type loc struct {
	st  blob.Store
	key string
}

func (o Objects) now() time.Time {
	if o.Now != nil {
		return o.Now()
	}
	return time.Now()
}

func (o Objects) fileLoc(tenant, id string) (loc, error) {
	k, err := blob.Key(tenant, id)
	return loc{o.Files, k}, err
}

// assetLocs are the places a Qto picture of tenant may sit, preferred first:
// its own docs store, then the files bucket.
func (o Objects) assetLocs(ctx context.Context, tenant, id string) ([]loc, error) {
	f, err := o.fileLoc(tenant, id)
	if err != nil {
		return nil, err
	}
	if o.Docs == nil {
		return []loc{f}, nil
	}
	st, err := o.Docs(ctx, tenant)
	if err != nil {
		return nil, fmt.Errorf("docs store of %s: %w", tenant, err)
	}
	if st == nil {
		return []loc{f}, nil
	}
	return []loc{{st, docAssetPrefix + id}, f}, nil
}

// pairs walks set: fn gets each object's src places and its one dst place.
func (o Objects) pairs(ctx context.Context, src, dst string, set ObjectSet, fn func(id string, from []loc, to loc) error) error {
	for _, id := range set.Files {
		from, err := o.fileLoc(src, id)
		if err != nil {
			return err
		}
		to, _ := o.fileLoc(dst, id)
		if err := fn(id, []loc{from}, to); err != nil {
			return err
		}
	}
	for _, id := range set.DocAssets {
		from, err := o.assetLocs(ctx, src, id)
		if err != nil {
			return err
		}
		to, err := o.assetLocs(ctx, dst, id)
		if err != nil {
			return err
		}
		if err := fn(id, from, to[0]); err != nil {
			return err
		}
	}
	return nil
}

// Copy is P3: every object of set in src is written to dst.
func (o Objects) Copy(ctx context.Context, src, dst string, set ObjectSet) (ObjectReport, error) {
	var rep ObjectReport
	err := o.pairs(ctx, src, dst, set, func(id string, from []loc, to loc) error {
		return copyOne(ctx, from, to, id, &rep)
	})
	return rep, err
}

// copyOne writes id to `to` from the first of `from` that holds it. The bytes
// must hash to id: a content address that does not match is never spread.
func copyOne(ctx context.Context, from []loc, to loc, id string, rep *ObjectReport) error {
	switch ok, err := to.st.Exists(ctx, to.key); {
	case err != nil:
		return fmt.Errorf("check %s: %w", to.key, err)
	case ok:
		rep.Present++
		return nil
	}
	for _, f := range from {
		b, err := readAll(ctx, f)
		if errors.Is(err, blob.ErrNotFound) {
			continue
		}
		if err != nil {
			return fmt.Errorf("read %s: %w", f.key, err)
		}
		if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) != id {
			return fmt.Errorf("read %s: bytes do not hash to %s", f.key, id)
		}
		if err := to.st.Put(ctx, to.key, b); err != nil {
			return fmt.Errorf("write %s: %w", to.key, err)
		}
		rep.Copied++
		return nil
	}
	return fmt.Errorf("copy %s: no source object (%w)", id, blob.ErrNotFound)
}

func readAll(ctx context.Context, l loc) ([]byte, error) {
	rc, err := l.st.Get(ctx, l.key)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

// Delete is P6, a move only, after the P4 commit: every object of set that no
// src row still lists is removed from src, once its dst copy exists.
func (o Objects) Delete(ctx context.Context, src, dst string, set ObjectSet) (ObjectReport, error) {
	var rep ObjectReport
	err := o.pairs(ctx, src, dst, set, func(id string, from []loc, to loc) error {
		return o.deleteOne(ctx, src, id, from, to, &rep)
	})
	return rep, err
}

func (o Objects) deleteOne(ctx context.Context, src, id string, from []loc, to loc, rep *ObjectReport) error {
	held, err := o.held(ctx, src, id)
	if err != nil {
		return err
	}
	if held {
		for _, f := range from {
			rep.Kept = append(rep.Kept, f.key)
		}
		return nil
	}
	switch ok, err := to.st.Exists(ctx, to.key); {
	case err != nil:
		return fmt.Errorf("check %s: %w", to.key, err)
	case !ok:
		return fmt.Errorf("refuse to delete %s: no copy at %s (run P3 first)", id, to.key)
	}
	for _, f := range from {
		switch err := f.st.Delete(ctx, f.key); {
		case errors.Is(err, blob.ErrNotFound):
			rep.Gone++
		case err != nil:
			return fmt.Errorf("delete %s: %w", f.key, err)
		default:
			rep.Deleted++
		}
	}
	return nil
}

// held is the hub's keep rule for a blob of tenant (hub fileKept): a message
// carries it, or a doc names it.
func (o Objects) held(ctx context.Context, tenant, id string) (bool, error) {
	ok, err := o.Held.FileAttached(ctx, tenant, id, o.now())
	if err != nil || ok {
		return ok, err
	}
	return o.Held.DocAssetHeld(ctx, tenant, id)
}

// Open is the read of an attachment after a move (case C10): the database is
// asked first, so a blob that left tenant is ErrNotFound even while a hub
// instance's in-memory cache (blob.Cached) still holds its bytes.
func (o Objects) Open(ctx context.Context, tenant, id string) (io.ReadCloser, error) {
	f, err := o.fileLoc(tenant, id)
	if err != nil {
		return nil, blob.ErrNotFound
	}
	switch ok, err := o.held(ctx, tenant, id); {
	case err != nil:
		return nil, err
	case !ok:
		return nil, blob.ErrNotFound
	}
	return f.st.Get(ctx, f.key)
}
