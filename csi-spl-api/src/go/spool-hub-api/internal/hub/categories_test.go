package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
)

const (
	categoriesPath   = "/v1/reporting/categories"
	opCategoriesPath = "/v1/operator/categories"
	byCategoryPath   = "/v1/reporting/tokens/by-category"
)

// treeNode finds path in a GET /v1/reporting/categories answer's nesting.
func treeNode(nodes []any, path string) map[string]any {
	for _, n := range nodes {
		m := n.(map[string]any)
		if m["category_path"] == path {
			return m
		}
		if kids, _ := m["children"].([]any); kids != nil {
			if got := treeNode(kids, path); got != nil {
				return got
			}
		}
	}
	return nil
}

// spec 143 T041: every member reads the tree; the operator admin adds a
// child under a seeded node and reads it back nested under its parent,
// changes it, and a turned-off node leaves the tree. RED CONTROL: a
// developer of the operator workspace, another workspace's admin and an
// anonymous caller are refused (403 operator.workspaces) on every operator
// route and on the token rollup; a node whose parent is missing and a taken
// path are refused.
func TestCategoryRoutes(t *testing.T) {
	r := newFleetTokensRig(t)
	leaf := "coding/hard/go_" + strings.ToLower(newTenantID(""))
	node := map[string]any{"category_path": leaf, "title": "Go", "dimensions": map[string]any{"kind": "complex_coding"}}
	for name, who := range map[string][2]string{"operator developer": {r.op, r.dev}, "other workspace admin": {r.other, r.otherA}, "anonymous": {r.op, ""}} {
		for _, rt := range [][2]string{{http.MethodPost, opCategoriesPath}, {http.MethodPut, opCategoriesPath + "/coding/hard"}, {http.MethodGet, byCategoryPath}} {
			var body any
			if rt[0] != http.MethodGet {
				body = node
			}
			if code, got := call(t, r.e, who[0], rt[0], rt[1], who[1], body); code != http.StatusForbidden || got["permission"] != "operator.workspaces" {
				t.Errorf("RED CONTROL %s %s %s: %d %v, want 403 operator.workspaces", name, rt[0], rt[1], code, got)
			}
		}
	}
	if code, _ := call(t, r.e, r.op, http.MethodGet, categoriesPath, "", nil); code == http.StatusOK {
		t.Errorf("anonymous tree read: %d, want a refusal", code)
	}
	for _, who := range [][2]string{{r.op, r.dev}, {r.other, r.otherA}} {
		code, got := call(t, r.e, who[0], http.MethodGet, categoriesPath, who[1], nil)
		roots, _ := got["categories"].([]any)
		if code != http.StatusOK || treeNode(roots, "coding") == nil || treeNode(roots, "dispatch/placement") == nil {
			t.Fatalf("member tree read (%s): %d %v", who[1], code, got)
		}
	}
	code, got := call(t, r.e, r.op, http.MethodPost, opCategoriesPath, r.admin, node)
	if code != http.StatusCreated || got["parent_path"] != "coding/hard" || got["is_active"] != true {
		t.Fatalf("operator create: %d %v", code, got)
	}
	_, got = call(t, r.e, r.op, http.MethodGet, categoriesPath, r.dev, nil)
	roots, _ := got["categories"].([]any)
	hard := treeNode(roots, "coding/hard")
	if hard == nil || treeNode(hard["children"].([]any), leaf) == nil || treeNode(roots, leaf)["title"] != "Go" {
		t.Fatalf("the new child is not nested under coding/hard: %v", hard)
	}
	if code, got := call(t, r.e, r.op, http.MethodPut, opCategoriesPath+"/"+leaf, r.admin, map[string]any{"title": "Go services"}); code != http.StatusOK ||
		got["title"] != "Go services" || got["is_active"] != true || got["dimensions"].(map[string]any)["kind"] != "complex_coding" {
		t.Fatalf("update: %d %v", code, got)
	}
	if code, _ := call(t, r.e, r.op, http.MethodPut, opCategoriesPath+"/"+leaf, r.admin, map[string]any{"is_active": false}); code != http.StatusOK {
		t.Fatalf("turn off: %d", code)
	}
	if _, got = call(t, r.e, r.op, http.MethodGet, categoriesPath, r.dev, nil); treeNode(got["categories"].([]any), leaf) != nil {
		t.Errorf("a turned-off node is still in the tree")
	}
	for name, bad := range map[string]map[string]any{
		"missing parent": {"category_path": "nosuch_" + strings.ToLower(newTenantID("")) + "/x", "title": "x"},
		"bad path":       {"category_path": "Coding/X", "title": "x"},
		"no title":       {"category_path": "coding/untitled"},
		"unknown field":  {"category_path": "coding/x", "title": "x", "colour": "red"},
	} {
		if code, got := call(t, r.e, r.op, http.MethodPost, opCategoriesPath, r.admin, bad); code != http.StatusBadRequest {
			t.Errorf("RED CONTROL %s: %d %v, want 400", name, code, got)
		}
	}
	if code, got := call(t, r.e, r.op, http.MethodPost, opCategoriesPath, r.admin, map[string]any{"category_path": "coding", "title": "again"}); code != http.StatusConflict {
		t.Errorf("RED CONTROL a taken path: %d %v, want 409", code, got)
	}
	if code, _ := call(t, r.e, r.op, http.MethodPut, opCategoriesPath+"/coding/no_such_node", r.admin, map[string]any{"title": "x"}); code != http.StatusNotFound {
		t.Errorf("update of a missing node: %d, want 404", code)
	}
	if code, _ := call(t, r.e, r.op, http.MethodPut, opCategoriesPath+"/coding/hard", r.admin, map[string]any{"category_path": "coding/moved"}); code != http.StatusBadRequest {
		t.Errorf("a move: %d, want 400", code)
	}
}

// spec 143 T042 (hub) + T043 (route): a box of the operator workspace
// records its spawn request's category (ask_op category), the request is
// placed ("placed: c-1@<box>") and the lane's minutes roll up into coding
// (depth 1) and coding/hard (leaf). RED CONTROLS: a category naming no node
// is refused (unknown_category) and a bad depth answers 400; another lane's
// minutes are 'uncategorised', counted in the total.
func TestCategoryTokensRoute(t *testing.T) {
	r := newFleetTokensRig(t)
	ctx := context.Background()
	const ask = "cacacaca-0000-4000-8000-000000000001"
	by := "c-001@" + r.opBox.id
	askCall(t, r.opBox, action.AskArgs{Fleet: "main", Op: "put", AskID: ask, Kind: "task", From: "c-002@" + r.opBox.id, Summary: "SPAWN REQUEST"})
	if _, err := action.Ask(ctx, r.opBox.cfg, action.AskArgs{Fleet: "main", Op: "category", AskID: ask, By: by, WorkKind: "complex_coding",
		CategoryPath: "coding/no_such_node", Hub: r.opBox.c}); err == nil || !strings.Contains(err.Error(), "unknown_category") {
		t.Fatalf("RED CONTROL a category naming no node: %v, want unknown_category", err)
	}
	got := askCall(t, r.opBox, action.AskArgs{Fleet: "main", Op: "category", AskID: ask, By: by, WorkKind: "complex_coding", CategoryPath: "coding/hard"})
	if got.Fleet != "main" {
		t.Fatalf("category op: %+v", got)
	}
	if _, err := action.Ask(ctx, r.opBox.cfg, action.AskArgs{Fleet: "main", Op: "category", AskID: ask, By: by, WorkKind: "astrology", Hub: r.opBox.c}); err == nil {
		t.Fatal("RED CONTROL a bad work kind was sent")
	}
	askCall(t, r.opBox, action.AskArgs{Fleet: "main", Op: "done", AskID: ask, By: by, Reason: "placed: c-1@" + r.opBox.id})
	m := time.Now().UTC().Truncate(time.Minute).Add(-2 * time.Minute)
	if _, err := r.push(t, r.opBox, tokSample{agent: "c-1", vendor: "claude", minute: m, in: 1000, out: 200, cw: 30},
		tokSample{agent: "c-9", vendor: "claude", minute: m, in: 50000}); err != nil {
		t.Fatal(err)
	}
	code, out := call(t, r.e, r.op, http.MethodGet, byCategoryPath+"?depth=1", r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("rollup: %d %v", code, out)
	}
	nodes := map[string]map[string]any{}
	for _, n := range out["categories"].([]any) {
		nodes[n.(map[string]any)["category_path"].(string)] = n.(map[string]any)
	}
	if len(nodes) < 5 || nodes["coding"]["tokens"] != float64(1230) || nodes["coding/hard"] != nil {
		t.Fatalf("depth 1: coding %v, %d nodes (want the roots only)", nodes["coding"], len(nodes))
	}
	if u := out["uncategorised"].(map[string]any); u["tokens"].(float64) < 50000 || out["tokens"].(float64) < 51230 {
		t.Fatalf("RED CONTROL uncategorised %v of total %v: c-9's minute was dropped", u, out["tokens"])
	}
	_, leafOut := call(t, r.e, r.op, http.MethodGet, byCategoryPath, r.admin, nil)
	found := false
	for _, n := range leafOut["categories"].([]any) {
		if n := n.(map[string]any); n["category_path"] == "coding/hard" {
			found = n["tokens"] == float64(1230)
		}
	}
	if !found {
		t.Fatalf("leaf read: coding/hard is not 1230 tokens: %v", leafOut["categories"])
	}
	for _, q := range []string{"?depth=0", "?depth=x", "?from=2020-01-01&to=2020-06-01", "?to=nope"} {
		if code, _ := call(t, r.e, r.op, http.MethodGet, byCategoryPath+q, r.admin, nil); code != http.StatusBadRequest {
			t.Errorf("RED CONTROL %s: %d, want 400", q, code)
		}
	}
}
