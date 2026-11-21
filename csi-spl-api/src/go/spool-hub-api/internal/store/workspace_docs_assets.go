package store

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
)

// A document's pictures (gap G6, SPL-2201; spec 137 unified-fs.md section
// 7): the hidden root's attrs.assets maps each picture's md-relative path,
// `<doc>.assets/NN-name.ext`, to the sha256 of its bytes, which the hub keeps
// in its object store at t/<tenant>/files/<sha256>. docAttrsCheck refuses any
// other shape, so a path the hub serves is always one of this form.

// DocAssetsMax caps the pictures of one document.
const DocAssetsMax = 500

var (
	docAssetPathRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.assets/[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*\.(png|jpg|jpeg|gif|webp)$`)
	docAssetSHARe  = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// DocAssetPath reports whether p is a picture path of the layout:
// <doc>.assets/NN-name.ext, lower-case name, png, jpg, jpeg, gif or webp.
func DocAssetPath(p string) bool { return len(p) <= 260 && docAssetPathRe.MatchString(p) }

// DocAssetOf is the sha256 the root attrs map path to, "" = none.
func DocAssetOf(rootAttrs json.RawMessage, path string) string {
	var m struct {
		Assets map[string]any `json:"assets"`
	}
	if json.Unmarshal(rootAttrs, &m) != nil {
		return ""
	}
	id, _ := m.Assets[path].(string)
	if !docAssetSHARe.MatchString(id) {
		return ""
	}
	return id
}

// docAssetsCheck refuses an attrs.assets that is not an object of picture
// paths to sha256 digests, or holds more than DocAssetsMax.
func docAssetsCheck(m map[string]any) error {
	v, ok := m["assets"]
	if !ok {
		return nil
	}
	assets, ok := v.(map[string]any)
	if !ok || len(assets) > DocAssetsMax {
		return fmt.Errorf("%w: attrs.assets is an object of at most %d pictures", ErrDocRefused, DocAssetsMax)
	}
	for p, id := range assets {
		s, _ := id.(string)
		if !DocAssetPath(p) || !docAssetSHARe.MatchString(s) {
			return fmt.Errorf("%w: attrs.assets maps a <doc>.assets/NN-name.ext path to a sha256, not %q", ErrDocRefused, p)
		}
	}
	return nil
}

// DocAssetHeld reports whether some document of tenant names fileID in its
// root's attrs.assets: the blob is a picture of that doc, and retention must
// keep it although no message carries it. Every document counts, also one
// locked to a human the reading context is not (spec 125 B8): the orphan
// sweep reads with no human, and rdb 0256's human_lock would hide such a
// doc's root item, so the read goes through rdb 0307's door
// spool_doc_asset_held, which sees every root item of the session's tenant
// and returns only the boolean. No title, item or attrs of a locked doc
// leaves the store (spec 125 C7-C9).
func (s *Postgres) DocAssetHeld(ctx context.Context, tenant, fileID string) (bool, error) {
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT spool_doc_asset_held($1)`, []any{fileID}, &ok)
	return ok, err
}
