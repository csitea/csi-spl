package repodocs

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The worker's slower duties (spec 075 repo-edit §4.1, §5.1, §7, §11): the
// published sweep, the daily refresh of the history's authors and the
// 30-day overlay sweep.

// OverlayPrefix is where a save's text waits in the docs bucket until master
// and the publish hold it (spec §7).
const OverlayPrefix = ".edits/"

// treeIndex is the docs bucket's tree.json, as far as the worker reads it.
const treeIndex = "tree.json"

// sweepPublished marks pushed rows published once the env's tree.json sha
// contains their commit (GitHub compare: ahead or identical; spec §7 step 4).
// Each commit is compared at most once per tree.json sha, never per poll.
func (w *Worker) sweepPublished(ctx context.Context) error {
	tree, err := w.publishedSHA(ctx)
	if err != nil || tree == "" {
		return err
	}
	if tree != w.treeSHA {
		w.treeSHA, w.checked = tree, map[string]bool{}
	}
	rows, err := w.c.Queue.PushedRepoDocEdits(ctx)
	if err != nil {
		return err
	}
	w.unpublished = len(rows) > 0
	var done []string
	for _, e := range rows {
		if e.CommitSHA == "" || w.checked[e.CommitSHA] {
			continue
		}
		w.checked[e.CommitSHA] = true
		cmp, err := w.c.Repo.Compare(ctx, e.CommitSHA, tree)
		if err != nil {
			delete(w.checked, e.CommitSHA)
			return err
		}
		if cmp.Contains() {
			done = append(done, e.CommitSHA)
		}
	}
	if len(done) == 0 {
		return nil
	}
	n, err := w.c.Queue.PublishRepoDocEdits(ctx, done, w.c.Now())
	if err == nil {
		w.unpublished = len(rows) > len(done)
		w.c.Log.Info().Int64("n", n).Str("tree_sha", tree).Msg("repo-edit worker: edits published")
	}
	return err
}

// publishedSHA is the sha the env's tree.json was published from; "" when
// the bucket has no index yet.
func (w *Worker) publishedSHA(ctx context.Context) (string, error) {
	rc, err := w.c.Bucket.Get(ctx, treeIndex)
	if errors.Is(err, blob.ErrNotFound) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	defer rc.Close()
	var idx struct {
		SHA string `json:"sha"`
	}
	if err := json.NewDecoder(io.LimitReader(rc, 16<<20)).Decode(&idx); err != nil {
		return "", err
	}
	return idx.SHA, nil
}

// refreshAuthors reads the newest historyDepth commits of master and its
// .mailmap and replaces repo_doc_known_authors with the identities the
// history shows (spec §4.1 rule 2). Bot committers are left out.
func (w *Worker) refreshAuthors(ctx context.Context) error {
	cs, err := w.c.Repo.Commits(ctx, historyDepth)
	if err != nil {
		return err
	}
	mm, err := w.mailmap(ctx)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	var out []store.RepoDocKnownAuthor
	for _, c := range cs {
		id := mm.canonical(c.Author)
		key := strings.ToLower(id.Email)
		if id.Email == "" || strings.HasSuffix(id.Name, "[bot]") || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, store.RepoDocKnownAuthor{GitEmail: id.Email, GitName: id.Name})
	}
	return w.c.Queue.ReplaceRepoDocKnownAuthors(ctx, out, w.c.Now())
}

// mailmap reads .mailmap at master's head; none is an empty map.
func (w *Worker) mailmap(ctx context.Context) (mailmap, error) {
	head, err := w.c.Repo.HeadBlob(ctx, ".mailmap")
	if err != nil || head.Blob == "" {
		return nil, err
	}
	b, err := w.c.Repo.Blob(ctx, head.Blob)
	if err != nil {
		return nil, err
	}
	return parseMailmap(string(b)), nil
}

// mailmap maps a commit email (lower case) to its rules.
type mailmap map[string][]mailmapRule

type mailmapRule struct {
	commitName              string // "" matches any name
	properName, properEmail string // "" keeps the commit's
}

var mailmapPair = regexp.MustCompile(`\s*([^<#]*?)\s*<([^>]*)>`)

// parseMailmap reads git's four .mailmap forms:
//
//	Proper Name <commit@email>
//	<proper@email> <commit@email>
//	Proper Name <proper@email> <commit@email>
//	Proper Name <proper@email> Commit Name <commit@email>
func parseMailmap(text string) mailmap {
	mm := mailmap{}
	for _, ln := range strings.Split(text, "\n") {
		if i := strings.Index(ln, "#"); i >= 0 {
			ln = ln[:i]
		}
		ps := mailmapPair.FindAllStringSubmatch(ln, 2)
		switch len(ps) {
		case 1:
			k := strings.ToLower(ps[0][2])
			mm[k] = append(mm[k], mailmapRule{properName: ps[0][1]})
		case 2:
			k := strings.ToLower(ps[1][2])
			mm[k] = append(mm[k], mailmapRule{commitName: ps[1][1], properName: ps[0][1], properEmail: ps[0][2]})
		}
	}
	return mm
}

// canonical is id as the history shows it through .mailmap; a rule naming
// the commit name wins over one that does not.
func (mm mailmap) canonical(id github.Identity) github.Identity {
	var hit *mailmapRule
	for i, r := range mm[strings.ToLower(id.Email)] {
		if r.commitName == id.Name || (r.commitName == "" && hit == nil) {
			hit = &mm[strings.ToLower(id.Email)][i]
		}
	}
	if hit == nil {
		return id
	}
	if hit.properName != "" {
		id.Name = hit.properName
	}
	if hit.properEmail != "" {
		id.Email = hit.properEmail
	}
	return id
}

// sweepOverlays deletes the overlays saved more than OverlayKeep ago that no
// live row serves: no row at all (the row insert failed after the bucket
// write; spec §11) or a published or superseded row (§5.1 keeps an overlay
// 30 days for audit). A queued, pushing, pushed, conflict or failed row
// keeps its overlay: it is the text a push or a retry needs.
func (w *Worker) sweepOverlays(ctx context.Context) error {
	cutoff := w.c.Now().Add(-w.c.OverlayKeep)
	keys := map[string]string{} // edit_id -> key
	err := w.c.Bucket.List(ctx, OverlayPrefix, func(key string, uploaded time.Time) error {
		if uploaded.Before(cutoff) && strings.HasSuffix(key, ".md") {
			keys[strings.TrimSuffix(path.Base(key), ".md")] = key
		}
		return nil
	})
	if err != nil || len(keys) == 0 {
		return err
	}
	ids := make([]string, 0, len(keys))
	for id := range keys {
		ids = append(ids, id)
	}
	st, err := w.c.Queue.RepoDocEditStatuses(ctx, ids)
	if err != nil {
		return err
	}
	n := 0
	for id, key := range keys {
		s, ok := st[id]
		if ok && s != store.RepoDocPublished && s != store.RepoDocSuperseded {
			continue
		}
		if err := w.c.Bucket.Delete(ctx, key); err != nil && !errors.Is(err, blob.ErrNotFound) {
			return err
		}
		n++
	}
	w.c.Log.Info().Int("n", n).Msg("repo-edit worker: old overlays swept")
	return nil
}
