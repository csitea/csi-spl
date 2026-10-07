package github

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Identity is a git author or committer.
type Identity struct {
	Name  string `json:"name"`
	Email string `json:"email"`
}

// Head is the branch tip and the blob of one path in it. Blob is "" when
// the path does not exist at Commit.
type Head struct {
	Commit string
	Blob   string
}

// Comparison is GitHub's compare of base...head. Status is ahead, behind,
// identical or diverged.
type Comparison struct {
	Status   string `json:"status"`
	AheadBy  int    `json:"ahead_by"`
	BehindBy int    `json:"behind_by"`
}

// Contains reports whether head holds base (spec §6.3 step 4: the published
// tree.json sha contains the pushed commit).
func (c Comparison) Contains() bool {
	return c.Status == "ahead" || c.Status == "identical"
}

func (c *Client) repoPath(rest string) string {
	return "/repos/" + url.PathEscape(c.owner) + "/" + url.PathEscape(c.repo) + rest
}

func escapePath(p string) string {
	segs := strings.Split(strings.Trim(p, "/"), "/")
	for i, s := range segs {
		segs[i] = url.PathEscape(s)
	}
	return strings.Join(segs, "/")
}

// HeadBlob reads the branch tip, then the blob sha of path at that commit.
func (c *Client) HeadBlob(ctx context.Context, path string) (Head, error) {
	tip, err := c.headCommit(ctx)
	if err != nil {
		return Head{}, err
	}
	// A directory answers an ARRAY of entries, a file an object: read raw
	// first so a directory is reported as one, not as an undecodable answer.
	var raw json.RawMessage
	p := c.repoPath("/contents/" + escapePath(path) + "?ref=" + url.QueryEscape(tip))
	err = c.call(ctx, "contents", http.MethodGet, p, nil, &raw)
	var ae *APIError
	if errors.As(err, &ae) && ae.Status == http.StatusNotFound {
		return Head{Commit: tip}, nil
	}
	if err != nil {
		return Head{}, err
	}
	if t := bytes.TrimSpace(raw); len(t) > 0 && t[0] == '[' {
		return Head{}, &APIError{Op: "contents", Status: http.StatusUnprocessableEntity, Message: path + " is a dir"}
	}
	var file struct {
		SHA  string `json:"sha"`
		Type string `json:"type"`
	}
	if json.Unmarshal(raw, &file) != nil {
		return Head{}, &APIError{Op: "contents", Status: http.StatusOK, Message: "undecodable answer"}
	}
	if file.Type != "" && file.Type != "file" {
		return Head{}, &APIError{Op: "contents", Status: http.StatusUnprocessableEntity, Message: path + " is a " + file.Type}
	}
	return Head{Commit: tip, Blob: file.SHA}, nil
}

func (c *Client) headCommit(ctx context.Context) (string, error) {
	var ref struct {
		Object struct {
			SHA string `json:"sha"`
		} `json:"object"`
	}
	err := c.call(ctx, "ref", http.MethodGet, c.repoPath("/git/ref/heads/"+escapePath(c.branch)), nil, &ref)
	return ref.Object.SHA, err
}

// Blob returns the bytes of one blob (the base or the head text of a merge).
func (c *Client) Blob(ctx context.Context, sha string) ([]byte, error) {
	var b struct {
		Content  string `json:"content"`
		Encoding string `json:"encoding"`
	}
	if err := c.call(ctx, "blob", http.MethodGet, c.repoPath("/git/blobs/"+url.PathEscape(sha)), nil, &b); err != nil {
		return nil, err
	}
	if b.Encoding != "base64" {
		return []byte(b.Content), nil
	}
	return base64.StdEncoding.DecodeString(strings.ReplaceAll(b.Content, "\n", ""))
}

// Commit writes content to path on top of parent and moves the branch to
// the new commit, fast-forward only: blob -> tree -> commit -> PATCH ref
// force:false. The committer is the App (GitHub sets it for an installation
// token); author is the editor. A branch that moved past parent answers 422,
// returned as ErrRefMoved and leaving the branch untouched.
//
// Each call decodes into its own answer type: a commit's "tree" is an
// object, the POST /git/trees answer's "tree" is an array of entries, so
// one shared type fails every real push at the tree step (spec 075).
func (c *Client) Commit(ctx context.Context, path string, content []byte, author Identity, message, parent string) (string, error) {
	var blob, tree, commit shaAnswer
	var parentCommit commitAnswer
	in := map[string]string{"content": base64.StdEncoding.EncodeToString(content), "encoding": "base64"}
	if err := c.call(ctx, "blob", http.MethodPost, c.repoPath("/git/blobs"), in, &blob); err != nil {
		return "", err
	}
	if err := c.call(ctx, "commit", http.MethodGet, c.repoPath("/git/commits/"+url.PathEscape(parent)), nil, &parentCommit); err != nil {
		return "", err
	}
	treeIn := map[string]any{"base_tree": parentCommit.Tree.SHA, "tree": []map[string]string{
		{"path": strings.Trim(path, "/"), "mode": "100644", "type": "blob", "sha": blob.SHA},
	}}
	if err := c.call(ctx, "tree", http.MethodPost, c.repoPath("/git/trees"), treeIn, &tree); err != nil {
		return "", err
	}
	commitIn := map[string]any{"message": message, "tree": tree.SHA, "parents": []string{parent}, "author": map[string]string{
		"name": author.Name, "email": author.Email, "date": c.now().UTC().Format(time.RFC3339),
	}}
	if err := c.call(ctx, "commit", http.MethodPost, c.repoPath("/git/commits"), commitIn, &commit); err != nil {
		return "", err
	}
	if err := c.moveRef(ctx, commit.SHA); err != nil {
		return "", err
	}
	return commit.SHA, nil
}

// shaAnswer is the part of the blob, tree and commit create answers the
// client reads.
type shaAnswer struct {
	SHA string `json:"sha"`
}

// commitAnswer is the part of GET /git/commits/{sha} the client reads.
type commitAnswer struct {
	SHA  string    `json:"sha"`
	Tree shaAnswer `json:"tree"`
}

func (c *Client) moveRef(ctx context.Context, sha string) error {
	in := map[string]any{"sha": sha, "force": false}
	err := c.call(ctx, "ref", http.MethodPatch, c.repoPath("/git/refs/heads/"+escapePath(c.branch)), in, nil)
	var ae *APIError
	if errors.As(err, &ae) && ae.Status == http.StatusUnprocessableEntity {
		ae.refMove = true
	}
	return err
}

// Compare is GitHub's compare base...head.
func (c *Client) Compare(ctx context.Context, base, head string) (Comparison, error) {
	var out Comparison
	p := c.repoPath("/compare/" + url.PathEscape(base) + "..." + url.PathEscape(head))
	err := c.call(ctx, "compare", http.MethodGet, p, nil, &out)
	return out, err
}
