package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// A document's pictures under their md-relative path (gap G6, SPL-2201;
// spec 137 unified-fs.md section 7): `foo.md` -> `foo.assets/01-flow-map.png`,
// the hub's /{doc}/assets/{path} route. The md import uploads each picture
// a page links (asset-put); the md export writes each back to its path
// (asset-get). asset-get answers JSON with the bytes in base64: the desk
// action that runs it prints text, and a picture's bytes are not text.
//
//	doctree asset-put <doc> <path> --file f   upload f as the doc's picture at path
//	doctree asset-get <doc> <path>            {"path", "sha256", "bytes", "base64"}

// dtAssetPathRe is the hub's picture path (store.DocAssetPath): checked here
// first, so a bad path fails before any hub call.
var dtAssetPathRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.assets/[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*\.(png|jpg|jpeg|gif|webp)$`)

func dtAssetPath(p string) error {
	if !dtAssetPathRe.MatchString(p) {
		return fmt.Errorf("%q is not a picture path: <doc>.assets/NN-name.ext, two digits, a dash, a lower-case name, png, jpg, jpeg, gif or webp", p)
	}
	return nil
}

func dtAssetRoute(doc, path string) string { return dtDoc(doc) + "/assets/" + path }

func dtAssetPut(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("asset-put", "usage: spool doctree asset-put <doc> <path> --file f")
	file := fs.String("file", "", "the picture's bytes")
	pos, err := fs.parse(args, 2, 2)
	if err != nil {
		return err
	}
	if err := dtAssetPath(pos[1]); err != nil {
		return err
	}
	if *file == "" {
		return errors.New("asset-put: --file is required")
	}
	ctype := dtImageTypes["."+pos[1][strings.LastIndexByte(pos[1], '.')+1:]]
	data, err := os.ReadFile(*file)
	if err != nil {
		return err
	}
	if len(data) == 0 || len(data) > docTreeImageMax {
		return fmt.Errorf("asset-put: a picture is 1..%d bytes", docTreeImageMax)
	}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) {
		return c.do(ctx, http.MethodPut, dtAssetRoute(pos[0], pos[1]), ctype, data, nil)
	})
}

func dtAssetGet(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("asset-get", "usage: spool doctree asset-get <doc> <path>")
	pos, err := fs.parse(args, 2, 2)
	if err != nil {
		return err
	}
	if err := dtAssetPath(pos[1]); err != nil {
		return err
	}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) {
		b, err := c.do(ctx, http.MethodGet, dtAssetRoute(pos[0], pos[1]), "", nil, nil)
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(b)
		return json.Marshal(map[string]any{"path": pos[1], "sha256": hex.EncodeToString(sum[:]), "bytes": len(b),
			"base64": base64.StdEncoding.EncodeToString(b)})
	})
}
