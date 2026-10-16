package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Workspace documents, the Qto outline (spec 113): the doctree verbs over the
// hub's /v1/workspace/doctree routes (internal/hub/wsdoc_tree.go). The same
// door as doc-list / doc-write: the box's role=cli upload token, which the
// hub reads as an agent (rbac pure_agent: docs.read + docs.write).
//
//	doctree list [--topic id]                    the documents
//	doctree nodes [--parent id]                  one folder's children (none = the top)
//	doctree folder --name n [--parent id] [--title t] [--description d]
//	doctree create --title t [--folder id] [--description d]
//	doctree head <doc>                           rev, items, root, topic
//	doctree read <doc> [--item id]               the items as JSON (a subtree, or the whole doc)
//	doctree add <doc> --kind heading|para|code|table|picture ...
//	doctree edit <doc> <item> --field title|body|attrs.<key> [--value v | --file f] [--json]
//	doctree move <doc> <item> [--parent id] [--ord n] [--rev n]
//	doctree delete <doc> [<item>] [--rev n]      an item's subtree, or the whole document
//	doctree rename <doc> --title t [--rev n]
//	doctree export <doc> [--item id] [--out f] [--from read.json]
//	                                             Markdown, the WUI's export rules
//	doctree asset-put <doc> <path> --file f      a picture under its md-relative path (doctree_assets.go)
//	doctree asset-get <doc> <path>               it back, as JSON with the bytes in base64
//
// The item kinds of add (the WUI's model: an item is a heading; its body is
// the paragraph text; its attrs carry one code block and one image):
//
//	heading  --title t [--level n | --under item | --after item] [--text t] [--unnumbered] [--dotted] [--outline n] [--tight] [--tight-end]
//	         a new item; --level n appends it at depth n, under the last item at n-1;
//	         --unnumbered sets attrs.numbered false: no outline number (spec 137);
//	         --dotted sets attrs.outline_dot true: the export writes "1. x" (SPL-1900);
//	         --outline n sets attrs.outline_author n: the md author's number where it
//	         is not the derived one (0, a gap, a restart), the hub's outline (SPL-2024);
//	         --tight sets attrs.tight true: no blank line between the heading and its text;
//	         --tight-end sets attrs.tight_end true: no blank line after its text
//	para     --text t | --file f [--item id]     text appended to the item's body
//	table    --text t | --file f [--item id]     a Markdown table appended to the body
//	code     --text t | --file f [--lang l] [--item id] [--replace]
//	         the item's code block (attrs.src, attrs.lang), one per item
//	picture  --path f [--caption c] [--item id]  uploads the image, appends its token
//
// --item defaults to the last item of the document. A structural op sends
// --rev (0 = no precondition, the default); a text edit always sends the
// item rev it just read, so a concurrent edit is a 412, never lost.
//
// $SPOOL_DOCTREE_FS picks the tree every verb works on (the hub's ?fs=, spec
// 137 T022): workspace (unset, the default) or repo, the repository docs.
// The hub lets only the operator workspace's agents and admins write repo
// (the import, do_spl_doctree_import_md); everyone else reads it.

const (
	docTreeAPI      = "/v1/workspace/doctree"
	docTreeRespMax  = 64 << 20 // a whole document of up to 20,000 items
	docTreeImageMax = 5 << 20  // hub DocTreeImageMax
	docTreeUsage    = "usage: spool doctree list|nodes|folder|create|head|read|add|edit|move|delete|rename|export|asset-put|asset-get ..."
)

// dtItem is one item as the hub sends it.
type dtItem struct {
	ID      string         `json:"id"`
	Parent  string         `json:"parent"`
	Ord     int            `json:"ord"`
	Outline string         `json:"outline"`
	Depth   int            `json:"depth"`
	Title   string         `json:"title"`
	Body    string         `json:"body"`
	Attrs   map[string]any `json:"attrs"`
	Rev     int64          `json:"rev"`
}

func (it dtItem) attr(k string) string {
	s, _ := it.Attrs[k].(string)
	return s
}

// dtClient is one verb's hub session: the upload token is minted once. fs
// is the tree ($SPOOL_DOCTREE_FS), "" = the workspace.
type dtClient struct {
	cfg   *config.Config
	http  *http.Client
	token string
	fs    string
}

// dtFS is $SPOOL_DOCTREE_FS checked: "", workspace or repo.
func dtFS() (string, error) {
	switch v := os.Getenv("SPOOL_DOCTREE_FS"); v {
	case "", "workspace", "repo":
		return v, nil
	default:
		return "", fmt.Errorf("SPOOL_DOCTREE_FS is workspace or repo, not %q", v)
	}
}

// dtDial opens the role=cli session and mints the upload token.
func dtDial(ctx context.Context, cfg *config.Config) (*dtClient, func(), error) {
	if strings.TrimSpace(cfg.HubURL) == "" {
		return nil, nil, errors.New("workspace documents need hub mode ($SPOOL_HUB_URL is not set)")
	}
	if cfg.TenantID() == "" {
		return nil, nil, errors.New("workspace documents need a tenant ($SPOOL_TENANT, or a tenant host in $SPOOL_HUB_URL)")
	}
	fs, err := dtFS()
	if err != nil {
		return nil, nil, err
	}
	c := hubclient.New(cfg)
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, nil, err
	}
	tok, err := sess.UploadToken(ctx)
	if err != nil {
		sess.Close()
		return nil, nil, err
	}
	return &dtClient{cfg: cfg, http: c.HTTPClient(), token: tok, fs: fs}, func() { sess.Close() }, nil
}

// do sends one request; body is JSON unless ctype says otherwise. out, when
// not nil, receives the decoded answer.
func (c *dtClient) do(ctx context.Context, method, path, ctype string, body []byte, out any) ([]byte, error) {
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	if c.fs != "" {
		sep := "?"
		if strings.Contains(path, "?") {
			sep = "&"
		}
		path += sep + "fs=" + url.QueryEscape(c.fs)
	}
	req, err := http.NewRequestWithContext(ctx, method, docEndpoint(c.cfg.HubURL, path), rdr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set(hubclient.TenantHeader, c.cfg.TenantID())
	if body != nil {
		if ctype == "" {
			ctype = "application/json"
		}
		req.Header.Set("Content-Type", ctype)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %s %s: %w", hubclient.ErrUnreachable, method, path, err)
	}
	defer resp.Body.Close()
	limit := int64(docTreeRespMax)
	if resp.StatusCode >= 300 {
		limit = 8 << 10
	}
	b, err := readLimited(resp.Body, limit)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 {
		return nil, dtStatusError(resp.StatusCode, b)
	}
	if out != nil {
		if err := json.Unmarshal(b, out); err != nil {
			return nil, fmt.Errorf("%s %s: the hub's answer is not JSON: %w", method, path, err)
		}
	}
	return b, nil
}

func (c *dtClient) json(ctx context.Context, method, path string, in, out any) ([]byte, error) {
	var body []byte
	if in != nil {
		var err error
		if body, err = json.Marshal(in); err != nil {
			return nil, err
		}
	}
	return c.do(ctx, method, path, "", body, out)
}

// dtStatusError names the doctree outcomes (412, 409, 422) on top of docStatusError.
func dtStatusError(status int, body []byte) error {
	var eb struct {
		Error  string `json:"error"`
		Detail string `json:"detail"`
	}
	_ = json.Unmarshal(body, &eb) //nolint:errcheck // non-JSON falls through to docStatusError
	switch status {
	case http.StatusPreconditionFailed:
		return fmt.Errorf("412: stale rev, the document changed since it was read: read it again (%s)", eb.Detail)
	case http.StatusConflict:
		return fmt.Errorf("409: %s (%s)", eb.Error, eb.Detail)
	case http.StatusUnprocessableEntity:
		return fmt.Errorf("422: refused (%s)", eb.Detail)
	case http.StatusNotFound:
		if eb.Error == "workspace_doc_tree_off" {
			return fmt.Errorf("404: route off (%s)", eb.Detail)
		}
	}
	return docStatusError(status, body)
}

func dtDoc(doc string) string { return docTreeAPI + "/" + url.PathEscape(doc) }

// subtree reads item's subtree, "" = the whole document (without the hidden root).
func (c *dtClient) subtree(ctx context.Context, doc, item string) (int64, []dtItem, error) {
	p := dtDoc(doc) + "/subtree"
	if item != "" {
		p += "?item=" + url.QueryEscape(item)
	}
	var res struct {
		Rev   int64    `json:"rev"`
		Items []dtItem `json:"items"`
	}
	_, err := c.json(ctx, http.MethodGet, p, nil, &res)
	return res.Rev, res.Items, err
}

// item reads one item (its rev, body and attrs), the first of its subtree.
func (c *dtClient) item(ctx context.Context, doc, item string) (dtItem, error) {
	_, items, err := c.subtree(ctx, doc, item)
	if err != nil {
		return dtItem{}, err
	}
	if len(items) == 0 || items[0].ID != item {
		return dtItem{}, fmt.Errorf("404: no item %s in document %s", item, doc)
	}
	return items[0], nil
}

// edit writes one field under the item rev it read.
func (c *dtClient) edit(ctx context.Context, doc, item, field, value string, rev int64) ([]byte, error) {
	return c.json(ctx, http.MethodPatch, dtDoc(doc)+"/items/"+url.PathEscape(item),
		map[string]any{"field": field, "value": value, "rev": rev}, nil)
}

// dtFlags is a verb's flag set; flags may follow the positionals.
type dtFlags struct {
	*flag.FlagSet
	usage string
}

func newDTFlags(verb, usage string) *dtFlags {
	fs := flag.NewFlagSet("doctree "+verb, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() { fmt.Fprintln(fs.Output(), usage) }
	return &dtFlags{FlagSet: fs, usage: usage}
}

// parse takes flags anywhere and checks the positional count is in [lo, hi].
func (f *dtFlags) parse(args []string, lo, hi int) ([]string, error) {
	var pos []string
	for len(args) > 0 {
		if err := f.Parse(args); err != nil {
			return nil, errDocFlags
		}
		rest := f.Args()
		if len(rest) == 0 {
			break
		}
		if rest[0] == "--" {
			pos = append(pos, rest[1:]...)
			break
		}
		pos = append(pos, rest[0])
		args = rest[1:]
	}
	if len(pos) < lo || len(pos) > hi {
		return nil, errors.New(f.usage)
	}
	return pos, nil
}

func cmdDocTree(cfg *config.Config, args []string) int {
	if len(args) == 0 {
		return dtHelp(false)
	}
	switch args[0] {
	case "--help", "-h", "-help", "help":
		return dtHelp(true)
	}
	v, ok := dtVerbByName(args[0])
	if !ok {
		return fail(fmt.Errorf("unknown doctree verb %q; %s (spool doctree --help)", args[0], docTreeUsage))
	}
	ctx, stop := interruptible()
	defer stop()
	if err := v.run(ctx, cfg, args[1:]); err != nil {
		if errors.Is(err, errDocFlags) {
			return 1
		}
		return fail(err)
	}
	return 0
}

// dtRun dials the hub, calls f and prints its answer.
func dtRun(ctx context.Context, cfg *config.Config, f func(*dtClient) ([]byte, error)) error {
	c, done, err := dtDial(ctx, cfg)
	if err != nil {
		return err
	}
	defer done()
	out, err := f(c)
	if err != nil {
		return err
	}
	if writeStdout(out, true) != 0 {
		return errors.New("stdout")
	}
	return nil
}

func dtList(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("list", "usage: spool doctree list [--topic id]")
	topic := fs.String("topic", "", "only the documents linked to this topic")
	if _, err := fs.parse(args, 0, 0); err != nil {
		return err
	}
	p := docTreeAPI
	if *topic != "" {
		p += "?topic=" + url.QueryEscape(*topic)
	}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) { return c.json(ctx, http.MethodGet, p, nil, nil) })
}

func dtNodes(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("nodes", "usage: spool doctree nodes [--parent folder-id]")
	parent := fs.String("parent", "", "the folder (none = the top level)")
	if _, err := fs.parse(args, 0, 0); err != nil {
		return err
	}
	p := docTreeAPI + "/nodes"
	if *parent != "" {
		p += "?parent=" + url.QueryEscape(*parent)
	}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) { return c.json(ctx, http.MethodGet, p, nil, nil) })
}

func dtFolder(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("folder", "usage: spool doctree folder --name n [--parent folder-id] [--title t] [--description d]")
	name := fs.String("name", "", "the folder name")
	parent := fs.String("parent", "", "the parent folder (none = the top level)")
	title := fs.String("title", "", "the folder title")
	desc := fs.String("description", "", "the folder description")
	if _, err := fs.parse(args, 0, 0); err != nil {
		return err
	}
	if strings.TrimSpace(*name) == "" {
		return errors.New(fs.usage)
	}
	in := map[string]any{"parent": *parent, "name": *name, "title": *title, "description": *desc}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) {
		return c.json(ctx, http.MethodPost, docTreeAPI+"/folders", in, nil)
	})
}

// dtMoveNode moves a folder (with its subtree) or a document in the
// explorer tree (spec 120 section 7; gap topic t1 b67d5dc7). The node id is
// the one doctree nodes lists, not the document id.
func dtMoveNode(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("move-node", "usage: spool doctree move-node <node> [--parent folder-id]")
	parent := fs.String("parent", "", "the new parent folder (none = the top level)")
	pos, err := fs.parse(args, 1, 1)
	if err != nil {
		return err
	}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) {
		return c.json(ctx, http.MethodPost, docTreeAPI+"/nodes/"+url.PathEscape(pos[0])+"/move", map[string]any{"parent": *parent}, nil)
	})
}

func dtCreate(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("create", "usage: spool doctree create --title t [--folder id] [--description d]")
	title := fs.String("title", "", "the document title")
	folder := fs.String("folder", "", "the folder to create it in (none = the top level)")
	desc := fs.String("description", "", "the meta description")
	if _, err := fs.parse(args, 0, 0); err != nil {
		return err
	}
	in := map[string]any{"title": *title, "description": *desc, "parent": *folder}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) { return c.json(ctx, http.MethodPost, docTreeAPI, in, nil) })
}

func dtHead(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("head", "usage: spool doctree head <doc>")
	pos, err := fs.parse(args, 1, 1)
	if err != nil {
		return err
	}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) { return c.json(ctx, http.MethodGet, dtDoc(pos[0]), nil, nil) })
}

func dtRead(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("read", "usage: spool doctree read <doc> [--item id]")
	item := fs.String("item", "", "the subtree of this item (none = the whole document)")
	pos, err := fs.parse(args, 1, 1)
	if err != nil {
		return err
	}
	p := dtDoc(pos[0]) + "/subtree"
	if *item != "" {
		p += "?item=" + url.QueryEscape(*item)
	}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) { return c.json(ctx, http.MethodGet, p, nil, nil) })
}

func dtEdit(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("edit", "usage: spool doctree edit <doc> <item> --field title|body|attrs.<key> [--value v | --file f] [--json]")
	field := fs.String("field", "", "title, body, or attrs.<key>: one key of the item's attrs")
	value := fs.String("value", "", "the new text")
	file := fs.String("file", "", "read the new text from this file")
	asJSON := fs.Bool("json", false, "attrs.<key>: the value is JSON (true, 3, null drops the key), not a string")
	pos, err := fs.parse(args, 2, 2)
	if err != nil {
		return err
	}
	key, isAttr := strings.CutPrefix(*field, "attrs.")
	if isAttr {
		if err := dtAttrKeyOK(key); err != nil {
			return err
		}
	} else if *field != "title" && *field != "body" {
		return errors.New("--field is title, body or attrs.<key>; " + fs.usage)
	}
	text, err := dtText(*value, *file, *field == "title")
	if err != nil {
		return err
	}
	var v any = text
	if *asJSON {
		if !isAttr {
			return errors.New("--json is for --field attrs.<key>")
		}
		if err := json.Unmarshal([]byte(text), &v); err != nil {
			return fmt.Errorf("--json: the value is not JSON: %w", err)
		}
	}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) {
		it, err := c.item(ctx, pos[0], pos[1])
		if err != nil {
			return nil, err
		}
		if !isAttr {
			return c.edit(ctx, pos[0], pos[1], *field, text, it.Rev)
		}
		raw, err := json.Marshal(dtAttrsWith(it.Attrs, key, v))
		if err != nil {
			return nil, err
		}
		return c.edit(ctx, pos[0], pos[1], "attrs", string(raw), it.Rev)
	})
}

// dtAttrKeyRe is an attrs key edit may set: lower case, digits, underscore.
var dtAttrKeyRe = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)

// dtAttrKeyOK refuses a malformed key and the typed keys, which add --kind
// code / picture own (they set them together, the hub checks them together).
func dtAttrKeyOK(key string) error {
	switch {
	case !dtAttrKeyRe.MatchString(key):
		return fmt.Errorf("attrs.%s: a key is lower case letters, digits and _", key)
	case key == "kind" || key == "src" || key == "lang" || key == "img_http_path" || key == "img_name":
		return fmt.Errorf("attrs.%s is set by add --kind code or picture, not by edit", key)
	}
	return nil
}

// dtAttrsWith is attrs with key set to v (a copy; nil v drops the key).
func dtAttrsWith(attrs map[string]any, key string, v any) map[string]any {
	out := map[string]any{}
	for k, x := range attrs {
		out[k] = x
	}
	if v == nil {
		delete(out, key)
	} else {
		out[key] = v
	}
	return out
}

func dtMove(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("move", "usage: spool doctree move <doc> <item> [--parent id] [--ord n] [--rev n]")
	parent := fs.String("parent", "", "the new parent item (none = the top level)")
	ord := fs.Int("ord", 0, "the place among the new parent's children, 1-based (0 = last)")
	rev := fs.Int64("rev", 0, "the doc rev read (0 = no precondition)")
	pos, err := fs.parse(args, 2, 2)
	if err != nil {
		return err
	}
	in := map[string]any{"rev": *rev, "parent": *parent, "ord": *ord}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) {
		return c.json(ctx, http.MethodPost, dtDoc(pos[0])+"/items/"+url.PathEscape(pos[1])+"/move", in, nil)
	})
}

func dtDelete(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("delete", "usage: spool doctree delete <doc> [<item>] [--rev n]")
	rev := fs.Int64("rev", 0, "the doc rev read (0 = no precondition)")
	pos, err := fs.parse(args, 1, 2)
	if err != nil {
		return err
	}
	p := dtDoc(pos[0])
	if len(pos) == 2 {
		p += "/items/" + url.PathEscape(pos[1])
	}
	p += "?rev=" + strconv.FormatInt(*rev, 10)
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) { return c.json(ctx, http.MethodDelete, p, nil, nil) })
}

func dtRename(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("rename", "usage: spool doctree rename <doc> --title t [--rev n]")
	title := fs.String("title", "", "the new title")
	rev := fs.Int64("rev", 0, "the doc rev read (0 = no precondition)")
	pos, err := fs.parse(args, 1, 1)
	if err != nil {
		return err
	}
	in := map[string]any{"title": *title, "rev": *rev}
	return dtRun(ctx, cfg, func(c *dtClient) ([]byte, error) { return c.json(ctx, http.MethodPatch, dtDoc(pos[0]), in, nil) })
}

func dtExport(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("export", "usage: spool doctree export <doc> [--item id] [--out file] [--from read.json]")
	item := fs.String("item", "", "export this item's branch (none = the whole document)")
	out := fs.String("out", "", "write the Markdown to this file (none = stdout)")
	from := fs.String("from", "", "export a saved `spool doctree read <doc>` answer (a file) instead of reading the hub")
	pos, err := fs.parse(args, 1, 1)
	if err != nil {
		return err
	}
	items, err := dtExportItems(ctx, cfg, pos[0], *from)
	if err != nil {
		return err
	}
	md, err := docTreeMarkdown(items, pos[0], *item)
	if err != nil {
		return err
	}
	if *out != "" {
		return os.WriteFile(*out, []byte(md), 0o644)
	}
	if writeStdout([]byte(md), false) != 0 {
		return errors.New("stdout")
	}
	return nil
}

// dtExportItems is the whole document's items, the hidden root first (its
// body is the preamble): from the hub (head for the root, then the root's
// subtree), or from a saved read answer (--from: offline, no hub; a `read
// <doc> --item <root>` answer carries the root, a plain `read <doc>` none).
func dtExportItems(ctx context.Context, cfg *config.Config, doc, from string) ([]dtItem, error) {
	if from == "" {
		c, done, err := dtDial(ctx, cfg)
		if err != nil {
			return nil, err
		}
		defer done()
		var head struct {
			Root string `json:"root"`
		}
		if _, err := c.json(ctx, http.MethodGet, dtDoc(doc), nil, &head); err != nil {
			return nil, err
		}
		_, items, err := c.subtree(ctx, doc, head.Root)
		return items, err
	}
	b, err := os.ReadFile(from)
	if err != nil {
		return nil, err
	}
	var res struct {
		Items []dtItem `json:"items"`
	}
	if err := json.Unmarshal(b, &res); err != nil {
		return nil, fmt.Errorf("--from %s: not a doctree read answer: %w", from, err)
	}
	return res.Items, nil
}

// dtText is --value / --text, or --file, or stdin when neither is given.
func dtText(value, file string, oneLine bool) (string, error) {
	if value != "" && file != "" {
		return "", errors.New("pass the text or --file, not both")
	}
	if value != "" {
		return value, nil
	}
	b, err := readDocBody(file)
	if err != nil {
		return "", err
	}
	s := string(b)
	if oneLine {
		s = strings.TrimSpace(s)
	}
	return s, nil
}

// dtAddOpts are the add flags.
type dtAddOpts struct {
	kind, title, text, file, lang, path, caption string
	outline                                      string
	item, under, after                           string
	level                                        int
	rev                                          int64
	replace, unnumbered, dotted, tight, tightEnd bool
}

func dtAdd(ctx context.Context, cfg *config.Config, args []string) error {
	fs := newDTFlags("add", "usage: spool doctree add <doc> --kind heading|para|code|table|picture "+
		"[--title t] [--level n | --under id | --after id] [--unnumbered] [--dotted] [--outline n] [--tight] [--tight-end] [--text t | --file f] [--lang l] [--path img] [--caption c] [--item id]")
	var o dtAddOpts
	fs.StringVar(&o.kind, "kind", "", "heading, para, code, table or picture")
	fs.StringVar(&o.title, "title", "", "the heading's title")
	fs.IntVar(&o.level, "level", 0, "heading: its depth (1 = top level), appended at the end of the document")
	fs.StringVar(&o.under, "under", "", "heading: the last child of this item")
	fs.StringVar(&o.after, "after", "", "heading: right after this item, same parent")
	fs.StringVar(&o.text, "text", "", "the text (heading: its paragraph)")
	fs.StringVar(&o.file, "file", "", "read the text from this file")
	fs.StringVar(&o.lang, "lang", "", "code: its language")
	fs.StringVar(&o.path, "path", "", "picture: the local image file (png, jpeg, gif, webp)")
	fs.StringVar(&o.caption, "caption", "", "picture: what the picture shows")
	fs.StringVar(&o.item, "item", "", "para, table, code, picture: the item (none = the last item)")
	fs.Int64Var(&o.rev, "rev", 0, "heading: the doc rev read (0 = no precondition)")
	fs.BoolVar(&o.replace, "replace", false, "code: replace the item's code block")
	fs.BoolVar(&o.unnumbered, "unnumbered", false, "heading: no outline number (attrs.numbered false)")
	fs.BoolVar(&o.dotted, "dotted", false, `heading: the export writes its number "1." (attrs.outline_dot true)`)
	fs.StringVar(&o.outline, "outline", "", "heading: the author's number when it is not the derived one, e.g. 0 or 3.1 (attrs.outline_author)")
	fs.BoolVar(&o.tight, "tight", false, "heading: the export writes its text right under it, no blank line (attrs.tight true)")
	fs.BoolVar(&o.tightEnd, "tight-end", false, "heading: the export writes no blank line after its text (attrs.tight_end true)")
	pos, err := fs.parse(args, 1, 1)
	if err != nil {
		return err
	}
	doc := pos[0]
	var f func(*dtClient) ([]byte, error)
	switch o.kind {
	case "heading":
		f, err = dtAddHeading(ctx, doc, o)
	case "para", "table":
		f, err = dtAddText(ctx, doc, o)
	case "code":
		f, err = dtAddCode(ctx, doc, o)
	case "picture":
		f, err = dtAddPicture(ctx, doc, o)
	default:
		return errors.New("--kind is heading, para, code, table or picture; " + fs.usage)
	}
	if err != nil {
		return err
	}
	return dtRun(ctx, cfg, f)
}

func dtAddHeading(ctx context.Context, doc string, o dtAddOpts) (func(*dtClient) ([]byte, error), error) {
	n := 0
	for _, set := range []bool{o.level > 0, o.under != "", o.after != ""} {
		if set {
			n++
		}
	}
	if n > 1 {
		return nil, errors.New("heading: pass one of --level, --under, --after")
	}
	if strings.TrimSpace(o.title) == "" {
		return nil, errors.New("heading: --title is required")
	}
	if o.outline != "" && (o.unnumbered || !dtOutlineRe.MatchString(o.outline)) {
		return nil, errors.New("heading: --outline is a number such as 0, 3.1 or 4.2.0, on a numbered heading")
	}
	body := ""
	if o.text != "" || o.file != "" {
		var err error
		if body, err = dtText(o.text, o.file, false); err != nil {
			return nil, err
		}
	}
	return func(c *dtClient) ([]byte, error) {
		anchor, where := o.under, "child"
		switch {
		case o.after != "":
			anchor, where = o.after, "sibling"
		case o.level > 1:
			_, items, err := c.subtree(ctx, doc, "")
			if err != nil {
				return nil, err
			}
			p, err := docTreeLevelParent(items, o.level)
			if err != nil {
				return nil, err
			}
			anchor = p
		}
		in := map[string]any{"rev": o.rev, "anchor": anchor, "where": where, "ord": 0, "title": o.title, "body": body}
		attrs := map[string]any{}
		if o.unnumbered {
			attrs["numbered"] = false
		}
		if o.dotted {
			attrs["outline_dot"] = true
		}
		if o.outline != "" {
			attrs["outline_author"] = o.outline
		}
		if o.tight {
			attrs["tight"] = true
		}
		if o.tightEnd {
			attrs["tight_end"] = true
		}
		if len(attrs) > 0 {
			in["attrs"] = attrs
		}
		return c.json(ctx, http.MethodPost, dtDoc(doc)+"/items", in, nil)
	}, nil
}

// dtOutlineRe is an author's number (--outline), the hub's authorOutlineRe.
var dtOutlineRe = regexp.MustCompile(`^\d+(\.\d+)*$`)

// docTreeLevelParent is the parent of a new heading at depth level appended
// at the end of the document: the last item (document order) at level-1.
func docTreeLevelParent(items []dtItem, level int) (string, error) {
	for i := len(items) - 1; i >= 0; i-- {
		if items[i].Depth == level-1 {
			return items[i].ID, nil
		}
	}
	return "", fmt.Errorf("heading: no item at level %d to put a level %d heading under", level-1, level)
}

// dtTarget is --item, or the document's last item.
func dtTarget(ctx context.Context, c *dtClient, doc, item string) (dtItem, error) {
	if item != "" {
		return c.item(ctx, doc, item)
	}
	_, items, err := c.subtree(ctx, doc, "")
	if err != nil {
		return dtItem{}, err
	}
	if len(items) == 0 {
		return dtItem{}, errors.New("the document has no item yet: add a heading first")
	}
	return items[len(items)-1], nil
}

// appendPara is body with text appended as its own paragraph.
func appendPara(body, text string) string {
	body = strings.TrimRight(body, " \t\r\n")
	text = strings.Trim(text, "\r\n")
	if body == "" {
		return text
	}
	return body + "\n\n" + text
}

// mdTableOK checks text is one Markdown table: a header row, a separator row
// of dashes, then rows, each line a | row.
func mdTableOK(text string) error {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) < 2 {
		return errors.New("table: a Markdown table is a header row and a separator row (|---|), then the rows")
	}
	for i, l := range lines {
		l = strings.TrimSpace(l)
		if !strings.HasPrefix(l, "|") || !strings.HasSuffix(l, "|") {
			return fmt.Errorf("table: line %d is not a | row: %q", i+1, l)
		}
	}
	sep := strings.Trim(strings.TrimSpace(lines[1]), "|")
	for _, cellText := range strings.Split(sep, "|") {
		c := strings.Trim(strings.TrimSpace(cellText), ":")
		if c == "" || strings.Trim(c, "-") != "" {
			return errors.New("table: line 2 is the separator row, e.g. |---|---|")
		}
	}
	return nil
}

func dtAddText(ctx context.Context, doc string, o dtAddOpts) (func(*dtClient) ([]byte, error), error) {
	text, err := dtText(o.text, o.file, false)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(text) == "" {
		return nil, fmt.Errorf("%s: the text is empty", o.kind)
	}
	if o.kind == "table" {
		if err := mdTableOK(text); err != nil {
			return nil, err
		}
		text = strings.TrimSpace(text)
	}
	return func(c *dtClient) ([]byte, error) {
		it, err := dtTarget(ctx, c, doc, o.item)
		if err != nil {
			return nil, err
		}
		return c.edit(ctx, doc, it.ID, "body", appendPara(it.Body, text), it.Rev)
	}, nil
}

func dtAddCode(ctx context.Context, doc string, o dtAddOpts) (func(*dtClient) ([]byte, error), error) {
	src, err := dtText(o.text, o.file, false)
	if err != nil {
		return nil, err
	}
	src = strings.Trim(src, "\r\n")
	if strings.TrimSpace(src) == "" {
		return nil, errors.New("code: the source is empty")
	}
	return func(c *dtClient) ([]byte, error) {
		it, err := dtTarget(ctx, c, doc, o.item)
		if err != nil {
			return nil, err
		}
		if it.attr("src") != "" && !o.replace {
			return nil, fmt.Errorf("code: item %s (%s %s) already has a code block, one per item: "+
				"add a heading for the next one, or pass --replace", it.ID, it.Outline, it.Title)
		}
		attrs := map[string]any{}
		for k, v := range it.Attrs {
			attrs[k] = v
		}
		attrs["src"] = src
		if o.lang != "" {
			attrs["lang"] = o.lang
		} else {
			delete(attrs, "lang")
		}
		raw, err := json.Marshal(attrs)
		if err != nil {
			return nil, err
		}
		return c.edit(ctx, doc, it.ID, "attrs", string(raw), it.Rev)
	}, nil
}

// dtImageTypes are the image types the hub takes, by extension.
var dtImageTypes = map[string]string{".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
	".gif": "image/gif", ".webp": "image/webp"}

func dtAddPicture(ctx context.Context, doc string, o dtAddOpts) (func(*dtClient) ([]byte, error), error) {
	if o.path == "" {
		return nil, errors.New("picture: --path is required")
	}
	ctype := dtImageTypes[strings.ToLower(filepath.Ext(o.path))]
	if ctype == "" {
		return nil, errors.New("picture: the image is .png, .jpg, .gif or .webp")
	}
	data, err := os.ReadFile(o.path)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 || len(data) > docTreeImageMax {
		return nil, fmt.Errorf("picture: an image is 1..%d bytes", docTreeImageMax)
	}
	caption := o.caption
	if caption == "" {
		caption = strings.TrimSuffix(filepath.Base(o.path), filepath.Ext(o.path))
	}
	return func(c *dtClient) ([]byte, error) {
		it, err := dtTarget(ctx, c, doc, o.item)
		if err != nil {
			return nil, err
		}
		var up struct {
			Path string `json:"img_http_path"`
		}
		if _, err := c.do(ctx, http.MethodPost, dtDoc(doc)+"/images", ctype, data, &up); err != nil {
			return nil, err
		}
		if up.Path == "" {
			return nil, errors.New("picture: the hub's answer has no img_http_path")
		}
		if _, err := c.edit(ctx, doc, it.ID, "body", appendPara(it.Body, picToken(caption, up.Path)), it.Rev); err != nil {
			return nil, err
		}
		return json.Marshal(map[string]any{"item": it.ID, "img_http_path": up.Path, "caption": cleanCaption(caption)})
	}, nil
}
