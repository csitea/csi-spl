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
	"regexp"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Workspace docs (spec 075 T009). An agent reads and writes the workspace
// catalogue through the hub. A save is last write wins: the verb sends no
// If-Match, and the hub keeps .history/.
//
//	doc-list [prefix]
//	doc-read <path>
//	doc-write <path> [--file f | stdin]
//	doc-delete <path>
//
// Auth is the box's role=cli upload token, the same bearer the file door uses
// (Authorization: Bearer, plus X-Spool-Tenant).
//
// The hub (T007+T008) answers tree.json as {"files":[{"path","updated"}]},
// PUT and DELETE as {"path","history"}, and 404 workspace_docs_off when the
// store is not configured. A doc path is the hub's: segments of
// [A-Za-z0-9._-], none starting with a dot, ending in .md, at most 1 MiB.

const (
	docTreePath     = "/v1/workspace/docs/tree.json"
	docMarkdownType = "text/markdown; charset=utf-8"
	docMaxBytes     = 1 << 20 // hub MaxWorkspaceDoc
	docRESTTimeout  = 60 * time.Second
)

// workspaceDocRe is the hub's ValidWorkspaceDocPath (internal/hub docsPathRe):
// a relative .md path, no hidden segment, no "..".
var workspaceDocRe = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\.md$`)

var errDocFlags = errors.New("bad flags")

func cmdDocList(cfg *config.Config, args []string) int {
	const usage = "usage: spool doc-list [prefix]"
	fs, err := docFlagSet("doc-list", usage, args)
	if err != nil {
		return 1
	}
	if fs.NArg() > 1 {
		return fail(errors.New(usage))
	}
	prefix, err := cleanPrefix(fs.Arg(0))
	if err != nil {
		return fail(err)
	}
	ctx, stop := interruptible()
	defer stop()
	body, err := docCall(ctx, cfg, http.MethodGet, docTreePath, "", nil)
	if err != nil {
		return fail(err)
	}
	out, err := filterDocTree(body, prefix)
	if err != nil {
		return fail(err)
	}
	return writeStdout(out, true)
}

func cmdDocRead(cfg *config.Config, args []string) int {
	const usage = "usage: spool doc-read <path>"
	_, rel, rc, ok := oneDocPath("doc-read", usage, args)
	if !ok {
		return rc
	}
	ctx, stop := interruptible()
	defer stop()
	body, err := docCall(ctx, cfg, http.MethodGet, rel, "", nil)
	if err != nil {
		return fail(err)
	}
	if _, err := os.Stdout.Write(body); err != nil {
		return fail(err)
	}
	return 0
}

func cmdDocWrite(cfg *config.Config, args []string) int {
	const usage = "usage: spool doc-write <path> [--file f]"
	fs := flag.NewFlagSet("doc-write", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() { fmt.Fprintln(fs.Output(), usage) }
	file := fs.String("file", "", "read the document from this file instead of stdin")
	// The standard flag parser stops at the first non-flag, so
	// `doc-write <path> --file f` would leave --file unparsed. Move flags first.
	if err := fs.Parse(docWriteArgs(args)); err != nil {
		return 1
	}
	if fs.NArg() != 1 {
		return fail(errors.New(usage))
	}
	rel, err := workspaceDocPath(fs.Arg(0))
	if err != nil {
		return fail(err)
	}
	body, err := readDocBody(*file)
	if err != nil {
		return fail(err)
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := docCall(ctx, cfg, http.MethodPut, rel, docMarkdownType, body)
	if err != nil {
		return fail(err)
	}
	if len(bytes.TrimSpace(out)) == 0 {
		out, err = json.Marshal(map[string]any{"path": fs.Arg(0), "written": true})
		if err != nil {
			return fail(err)
		}
	}
	return writeStdout(out, true)
}

func cmdDocDelete(cfg *config.Config, args []string) int {
	const usage = "usage: spool doc-delete <path>"
	raw, rel, rc, ok := oneDocPath("doc-delete", usage, args)
	if !ok {
		return rc
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := docCall(ctx, cfg, http.MethodDelete, rel, "", nil)
	if err != nil {
		return fail(err)
	}
	if len(bytes.TrimSpace(out)) == 0 {
		out, err = json.Marshal(map[string]any{"path": raw, "deleted": true})
		if err != nil {
			return fail(err)
		}
	}
	return writeStdout(out, true)
}

// docWriteArgs moves --file ahead of the path so flag.FlagSet sees it.
// `spool doc-write <path> --file f` and `spool doc-write --file f <path>`
// both parse. A `--` keeps the rest positional.
func docWriteArgs(args []string) []string {
	var flags, pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			pos = append(pos, args[i+1:]...)
			break
		}
		if a == "--file" || a == "-file" {
			flags = append(flags, a)
			if i+1 < len(args) {
				i++
				flags = append(flags, args[i])
			}
			continue
		}
		if strings.HasPrefix(a, "--file=") || strings.HasPrefix(a, "-file=") {
			flags = append(flags, a)
			continue
		}
		pos = append(pos, a)
	}
	return append(flags, pos...)
}

func docFlagSet(verb, usage string, args []string) (*flag.FlagSet, error) {
	fs := flag.NewFlagSet(verb, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() { fmt.Fprintln(fs.Output(), usage) }
	if err := fs.Parse(args); err != nil {
		return nil, errDocFlags
	}
	return fs, nil
}

// oneDocPath parses a verb whose only argument is the document path.
// raw is the path the caller passed; rel is the hub URL path. ok is false
// when the process should exit with rc (flags already printed, or usage).
func oneDocPath(verb, usage string, args []string) (raw, rel string, rc int, ok bool) {
	fs, err := docFlagSet(verb, usage, args)
	if err != nil {
		return "", "", 1, false
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "spool: "+usage)
		return "", "", 1, false
	}
	raw = fs.Arg(0)
	rel, err = workspaceDocPath(raw)
	if err != nil {
		fmt.Fprintln(os.Stderr, "spool: "+err.Error())
		return "", "", 1, false
	}
	return raw, rel, 0, true
}

// readDocBody is --file, or stdin when --file is absent. A terminal on stdin
// is refused so the verb does not wait for a person who meant to pass --file.
func readDocBody(file string) ([]byte, error) {
	if file != "" {
		b, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		if int64(len(b)) > docMaxBytes {
			return nil, fmt.Errorf("document is larger than %d bytes", docMaxBytes)
		}
		return b, nil
	}
	st, err := os.Stdin.Stat()
	if err != nil {
		return nil, err
	}
	if st.Mode()&os.ModeCharDevice != 0 {
		return nil, errors.New("doc-write reads stdin, which is a terminal: pass --file or pipe the document")
	}
	return readLimited(os.Stdin, docMaxBytes)
}

// cleanPrefix checks an optional catalogue prefix. "notes" matches the path
// notes and anything under notes/. A trailing slash keeps only the children.
func cleanPrefix(p string) (string, error) {
	if p == "" {
		return "", nil
	}
	if strings.HasPrefix(p, "/") || strings.Contains(p, "\\") {
		return "", fmt.Errorf("prefix %q must be a relative path prefix", p)
	}
	for _, seg := range strings.Split(strings.TrimSuffix(p, "/"), "/") {
		if seg == "" || seg == "." || seg == ".." {
			return "", fmt.Errorf("prefix %q must be a relative path prefix", p)
		}
	}
	return p, nil
}

// workspaceDocPath is the hub URL path for one document. The path must be one
// the hub will store (ValidWorkspaceDocPath); each segment is percent-encoded.
func workspaceDocPath(rel string) (string, error) {
	rel = strings.TrimSpace(rel)
	if rel == "" {
		return "", errors.New("a document path is required")
	}
	if len(rel) > 512 || !workspaceDocRe.MatchString(rel) {
		return "", fmt.Errorf("document path %q is not a workspace doc path", rel)
	}
	var b strings.Builder
	b.WriteString("/v1/workspace/docs/")
	for i, seg := range strings.Split(rel, "/") {
		if i > 0 {
			b.WriteByte('/')
		}
		b.WriteString(url.PathEscape(seg))
	}
	return b.String(), nil
}

// filterDocTree keeps catalogue entries whose path equals prefix or lives
// under it. An empty prefix returns the hub's bytes unchanged, so a shape
// the hub has not documented yet is printed as the hub sent it. A prefix
// needs a JSON array, or an object with a files array
// ({"files":[{"path","updated"}]}).
func filterDocTree(body []byte, prefix string) ([]byte, error) {
	if prefix == "" {
		return body, nil
	}
	var v any
	if err := json.Unmarshal(body, &v); err != nil {
		return nil, fmt.Errorf("tree.json is not JSON: %w", err)
	}
	switch t := v.(type) {
	case []any:
		return marshalDoc(filterEntries(t, prefix))
	case map[string]any:
		files, ok := t["files"].([]any)
		if !ok {
			return nil, fmt.Errorf("tree.json has no files array to filter by %q", prefix)
		}
		t["files"] = filterEntries(files, prefix)
		return marshalDoc(t)
	default:
		return nil, errors.New("tree.json is not a catalogue")
	}
}

func filterEntries(in []any, prefix string) []any {
	out := make([]any, 0)
	for _, e := range in {
		p := entryPath(e)
		if p != "" && docPrefixMatch(p, prefix) {
			out = append(out, e)
		}
	}
	return out
}

func entryPath(e any) string {
	switch v := e.(type) {
	case string:
		return v
	case map[string]any:
		s, _ := v["path"].(string)
		return s
	default:
		return ""
	}
}

// docPrefixMatch: "notes" keeps notes and notes/...; "notes/" keeps only
// the children. "notes" does not keep notes-old.md.
func docPrefixMatch(path, prefix string) bool {
	if strings.HasSuffix(prefix, "/") {
		return strings.HasPrefix(path, prefix)
	}
	return path == prefix || strings.HasPrefix(path, prefix+"/")
}

func marshalDoc(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// docCall performs one workspace-docs request and returns the hub's body.
// A 4xx/5xx is an error that names 401, 403 (no docs.write) or 404 (route
// off, or no doc).
func docCall(ctx context.Context, cfg *config.Config, method, urlPath, contentType string, body []byte) ([]byte, error) {
	if strings.TrimSpace(cfg.HubURL) == "" {
		return nil, errors.New("workspace docs need hub mode ($SPOOL_HUB_URL is not set)")
	}
	if cfg.TenantID() == "" {
		return nil, errors.New("workspace docs need a tenant ($SPOOL_TENANT, or a tenant host in $SPOOL_HUB_URL)")
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, docRESTTimeout)
		defer cancel()
	}
	c := hubclient.New(cfg)
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	tok, err := sess.UploadToken(ctx)
	if err != nil {
		return nil, err
	}
	var rdr io.Reader
	if method == http.MethodPut {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, docEndpoint(cfg.HubURL, urlPath), rdr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set(hubclient.TenantHeader, cfg.TenantID())
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := c.HTTPClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %s %s: %w", hubclient.ErrUnreachable, method, urlPath, err)
	}
	defer resp.Body.Close()
	limit := int64(docMaxBytes)
	if resp.StatusCode >= 300 {
		limit = 8 << 10
	}
	b, err := readLimited(resp.Body, limit)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 {
		return nil, docStatusError(resp.StatusCode, b)
	}
	return b, nil
}

func docEndpoint(hub, urlPath string) string {
	return strings.TrimRight(hub, "/") + urlPath
}

func docStatusError(status int, body []byte) error {
	var eb struct {
		Error      string `json:"error"`
		Detail     string `json:"detail"`
		Permission string `json:"permission"`
	}
	_ = json.Unmarshal(body, &eb)
	detail := strings.TrimSpace(eb.Detail)
	if detail == "" {
		detail = strings.TrimSpace(eb.Error)
	}
	if detail == "" {
		detail = strings.TrimSpace(string(body))
	}
	switch status {
	case http.StatusUnauthorized:
		if detail == "" {
			detail = "a valid upload token is required"
		}
		return fmt.Errorf("401: not signed in (%s)", detail)
	case http.StatusForbidden:
		perm := eb.Permission
		if perm == "" {
			perm = "docs.write"
		}
		if detail == "" {
			return fmt.Errorf("403: no %s", perm)
		}
		return fmt.Errorf("403: no %s (%s)", perm, detail)
	case http.StatusRequestEntityTooLarge:
		if detail == "" {
			detail = fmt.Sprintf("a doc is at most %d bytes", docMaxBytes)
		}
		return fmt.Errorf("413: too large (%s)", detail)
	case http.StatusNotFound:
		why := "route off or no doc"
		switch eb.Error {
		case "docs_off", "workspace_docs_off":
			why = "route off"
		case "not_found":
			why = "no doc"
		}
		if detail == "" {
			return fmt.Errorf("404: %s", why)
		}
		return fmt.Errorf("404: %s (%s)", why, detail)
	default:
		if detail == "" {
			return fmt.Errorf("hub answered %d", status)
		}
		return fmt.Errorf("hub answered %d: %s", status, detail)
	}
}

func readLimited(r io.Reader, n int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, n+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > n {
		return nil, fmt.Errorf("document is larger than %d bytes", n)
	}
	return b, nil
}

func writeStdout(b []byte, ensureNL bool) int {
	if ensureNL && (len(b) == 0 || b[len(b)-1] != '\n') {
		b = append(b, '\n')
	}
	if _, err := os.Stdout.Write(b); err != nil {
		return fail(err)
	}
	return 0
}
