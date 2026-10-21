package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// Activity categories (spec 143 section 4, rdb 0204, SPL-2790; owner HUM-10,
// token burn topic e8ae0aad: "not all tokens are equal", msg 1b2269f7, and
// the tree "has to be expandable in the future", msg 52fddc9d). The tree is
// data: a finer category is one row, its parent the path minus its last
// segment. Estate-wide like the token burn: every scope reads, the operator
// writes. A spawn request carries the work kind and category of its brief
// (fleet_asks.work_kind, .category_path); the token rollup credits each
// placed lane's minutes to its request's category, every other minute to
// 'uncategorised'.

// CategoryPathRe is rdb 0204's category_path CHECK.
var CategoryPathRe = regexp.MustCompile(`^[a-z0-9_]+(/[a-z0-9_]+)*$`)

// CategoryPathMax bounds a path (the table has no length CHECK; a URL path
// and a log line stay readable).
const CategoryPathMax = 200

// Uncategorised is the rollup's node for the minutes no categorised request
// claims (spec 143 4.4: never dropped, never guessed).
const Uncategorised = "uncategorised"

// WorkKinds are rdb 0204's fleet_asks.work_kind CHECK, "" (not given) aside:
// the lane kinds of do_spl_lane_mix.
var WorkKinds = []string{"specs_and_docs", "tests", "simple_coding", "complex_coding", "i18n", "secret", "review", "dispatch"}

// ErrUnknownCategory is a request's category_path that names no node (the
// fleet_asks FK), or a new node whose parent is not there.
var ErrUnknownCategory = errors.New("unknown category")

// Category is one row of activity_categories. ParentPath "" = a root.
type Category struct {
	Path        string         `json:"category_path"`
	ParentPath  string         `json:"parent_path"`
	Title       string         `json:"title"`
	Description string         `json:"description"`
	Dimensions  map[string]any `json:"dimensions"`
	IsActive    bool           `json:"is_active"`
	CreatedAt   time.Time      `json:"created_at"`
	UpdatedAt   time.Time      `json:"updated_at"`
}

// CategoryParent is path's parent: the path minus its last segment, "" for
// a root (rdb 0204's activity_categories_parent_check).
func CategoryParent(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[:i]
	}
	return ""
}

// CategoryDepth is path's depth: 1 for a root.
func CategoryDepth(path string) int { return strings.Count(path, "/") + 1 }

// CheckCategory names the first thing c may not carry ("" = fine): the Go
// side of rdb 0204's CHECKs.
func CheckCategory(c Category) string {
	switch {
	case len(c.Path) > CategoryPathMax || !CategoryPathRe.MatchString(c.Path):
		return "category_path must be lowercase segments [a-z0-9_] joined by '/', up to 200 characters"
	case c.Path == Uncategorised:
		return "category_path 'uncategorised' is the rollup's own node"
	case c.ParentPath != CategoryParent(c.Path):
		return "parent_path must be category_path minus its last segment"
	case strings.TrimSpace(c.Title) == "" || len(c.Title) > 100:
		return "title must be 1..100 characters"
	case len(c.Description) > 500:
		return "description must be at most 500 characters"
	}
	return ""
}

// CheckAskCategory names what a spawn request's work kind and category may
// not be ("" = fine); both may be empty (not given).
func CheckAskCategory(workKind, path string) string {
	switch {
	case workKind != "" && !slices.Contains(WorkKinds, workKind):
		return "work_kind must be one of " + strings.Join(WorkKinds, ", ")
	case path != "" && (len(path) > CategoryPathMax || !CategoryPathRe.MatchString(path)):
		return "category_path must be lowercase segments [a-z0-9_] joined by '/'"
	}
	return ""
}

// CategoryLaneTokens is the token burn of [from, to) credited to one leaf:
// Path is the request's category_path, "" for the minutes no categorised
// request claims. Tokens are input + output + cache write, CacheRead beside
// them, CostUSD the list cost of the rows priced in USD.
type CategoryLaneTokens struct {
	Path      string
	Tokens    int64
	CacheRead int64
	CostUSD   float64
}

// CategoryStore is the store half of rdb 0204. Optional: the routes answer
// unsupported on a store without it.
type CategoryStore interface {
	// ListCategories is every node, inactive ones too, in path order.
	ListCategories(ctx context.Context) ([]Category, error)
	// CreateCategory stores a checked node; ErrConflict when the path is
	// taken, ErrUnknownCategory when its parent is not there.
	CreateCategory(ctx context.Context, c Category) (Category, error)
	// UpdateCategory replaces node c.Path's title, description, dimensions
	// and is_active; ErrNotFound when there is none.
	UpdateCategory(ctx context.Context, c Category) (Category, error)
	// SetAskCategory records the work kind and category ("" = not given) of
	// a tenant's spawn request; ErrNotFound when there is no such ask,
	// ErrUnknownCategory when path names no node (the FK).
	SetAskCategory(ctx context.Context, tenant, fleet, askID, workKind, path string) error
	// CategoryTokens is the metered burn of the minutes [from, to) per
	// category leaf. A lane is a request of operator tenant op closed
	// "placed: <agent>@<box>"; its (agent, box) minutes from CategoryPlaceLead
	// before the placement until CategoryPlaceLead before the next placement
	// of that id are its request's.
	CategoryTokens(ctx context.Context, op string, from, to time.Time) ([]CategoryLaneTokens, error)
}

// CategoryPlaceLead is how long before its placement a lane's minutes are
// already its own: the request closes only after the launcher's start check
// (up to 45 s) and the hand-back.
const CategoryPlaceLead = 5 * time.Minute

// CategoryTokensRangeMax is the longest rollup, in days: the minute rows the
// rollup reads are kept 30 days (spec 140 3.6).
const CategoryTokensRangeMax = 30

// placedLaneRe is a placed request's reason, "placed: <agent>@<box>"
// (do_spl_spawn_placed).
var placedLaneRe = regexp.MustCompile(`^placed: ([A-Za-z0-9-]+)@([a-z0-9-]+)$`)

// CategoryNode is one node of the rollup: its own and every descendant's
// burn.
type CategoryNode struct {
	Path      string  `json:"category_path"`
	Title     string  `json:"title"`
	Depth     int     `json:"depth"`
	Tokens    int64   `json:"tokens"`
	CacheRead int64   `json:"cache_read"`
	CostUSD   float64 `json:"cost_usd"`
}

// CategoryTokensResponse is GET /v1/reporting/tokens/by-category. Depth 0 =
// every level down to the leaves. The depth-1 nodes plus Uncategorised sum
// to the totals: nothing is dropped.
type CategoryTokensResponse struct {
	From          string         `json:"from"`
	To            string         `json:"to"`
	Depth         int            `json:"depth"`
	Tokens        int64          `json:"tokens"`
	CacheRead     int64          `json:"cache_read"`
	CostUSD       float64        `json:"cost_usd"`
	Categories    []CategoryNode `json:"categories"`
	Uncategorised CategoryNode   `json:"uncategorised"`
}

// CategoryRollup sums the leaves' burn into every node of depth 1..depth
// (depth 0 = all) of the tree cats: a leaf's burn counts in each of its
// ancestors. A leaf "" or one no node of cats names is 'uncategorised'.
// Pure: both drivers' rows, one math.
func CategoryRollup(cats []Category, leaves []CategoryLaneTokens, from, to time.Time, depth int) CategoryTokensResponse {
	out := CategoryTokensResponse{From: from.UTC().Format(time.RFC3339), To: to.UTC().Format(time.RFC3339), Depth: depth,
		Categories: []CategoryNode{}, Uncategorised: CategoryNode{Path: Uncategorised, Title: "Uncategorised"}}
	nodes, known := map[string]*CategoryNode{}, map[string]bool{}
	for _, c := range cats {
		known[c.Path] = true
		if d := CategoryDepth(c.Path); depth == 0 || d <= depth {
			nodes[c.Path] = &CategoryNode{Path: c.Path, Title: c.Title, Depth: d}
		}
	}
	for _, l := range leaves {
		out.Tokens, out.CacheRead, out.CostUSD = out.Tokens+l.Tokens, out.CacheRead+l.CacheRead, out.CostUSD+l.CostUSD
		if !known[l.Path] {
			addCategoryBurn(&out.Uncategorised, l)
			continue
		}
		for p := l.Path; p != ""; p = CategoryParent(p) {
			if n := nodes[p]; n != nil {
				addCategoryBurn(n, l)
			}
		}
	}
	for _, n := range nodes {
		n.CostUSD = cents(n.CostUSD)
		out.Categories = append(out.Categories, *n)
	}
	sort.Slice(out.Categories, func(i, j int) bool { return out.Categories[i].Path < out.Categories[j].Path })
	out.CostUSD, out.Uncategorised.CostUSD = cents(out.CostUSD), cents(out.Uncategorised.CostUSD)
	return out
}

func addCategoryBurn(n *CategoryNode, l CategoryLaneTokens) {
	n.Tokens, n.CacheRead, n.CostUSD = n.Tokens+l.Tokens, n.CacheRead+l.CacheRead, n.CostUSD+l.CostUSD
}

// CategoryTokensWindow is the rollup's minutes: from and to (RFC 3339 or a
// UTC day YYYY-MM-DD, to excluded) as given, else the 7 days to now's minute
// (a missing from is 7 days before to). A non-empty third value says why the
// query is refused.
func CategoryTokensWindow(from, to string, now time.Time) (time.Time, time.Time, string) {
	parse := func(s string) (time.Time, bool) {
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			return t.UTC(), true
		}
		t, err := time.Parse(time.DateOnly, s)
		return t, err == nil
	}
	t, ok := now.UTC().Truncate(time.Minute), true
	if to != "" {
		if t, ok = parse(to); !ok {
			return t, t, "to must be RFC 3339 or a UTC day YYYY-MM-DD"
		}
	}
	f := t.Add(-7 * 24 * time.Hour)
	if from != "" {
		if f, ok = parse(from); !ok {
			return f, t, "from must be RFC 3339 or a UTC day YYYY-MM-DD"
		}
	}
	if !t.After(f) || t.Sub(f) > CategoryTokensRangeMax*24*time.Hour {
		return f, t, fmt.Sprintf("to must be after from, at most %d days (the minute rows' retention)", CategoryTokensRangeMax)
	}
	return f, t, ""
}

// CategorySeed is rdb 0204's seed (spec 143 4.2.1, owner poll 2 answer A):
// the Memory driver's tree, parents first.
var CategorySeed = []Category{
	{Path: "coding", Title: "Coding", Description: "Writing and changing code", Dimensions: map[string]any{}},
	{Path: "review", Title: "Review", Description: "Reviewing work and triaging gates", Dimensions: map[string]any{"kind": "review"}},
	{Path: "specs_and_docs", Title: "Specs and docs", Description: "Specs, plans and documentation", Dimensions: map[string]any{"kind": "specs_and_docs"}},
	{Path: "tests", Title: "Tests", Description: "Writing and running tests", Dimensions: map[string]any{"kind": "tests"}},
	{Path: "dispatch", Title: "Dispatch", Description: "Routing the owner's work to lanes", Dimensions: map[string]any{"kind": "dispatch"}},
	{Path: "coding/simple", ParentPath: "coding", Title: "Simple coding", Description: "Small bug fixes, routine edits, minor tweaks", Dimensions: map[string]any{"kind": "simple_coding"}},
	{Path: "coding/hard", ParentPath: "coding", Title: "Hard coding", Description: "Complex features, algorithmic work, large refactors", Dimensions: map[string]any{"kind": "complex_coding"}},
	{Path: "coding/i18n", ParentPath: "coding", Title: "Translations", Description: "Translations, locale sync, untranslated gates", Dimensions: map[string]any{"kind": "i18n"}},
	{Path: "review/r7", ParentPath: "review", Title: "Peer review", Description: "R7 peer review rounds", Dimensions: map[string]any{"kind": "review"}},
	{Path: "review/gate", ParentPath: "review", Title: "Gate triage", Description: "Pre-push verification, CI gate triage", Dimensions: map[string]any{"kind": "review"}},
	{Path: "specs_and_docs/spec", ParentPath: "specs_and_docs", Title: "Specs", Description: "System architecture specs, spec-kit plans", Dimensions: map[string]any{"kind": "specs_and_docs"}},
	{Path: "specs_and_docs/doc", ParentPath: "specs_and_docs", Title: "Docs", Description: "Developer guide, user manuals, release documentation", Dimensions: map[string]any{"kind": "specs_and_docs"}},
	{Path: "tests/unit", ParentPath: "tests", Title: "Unit tests", Description: "Go, JS and TS unit tests", Dimensions: map[string]any{"kind": "tests"}},
	{Path: "tests/e2e", ParentPath: "tests", Title: "End-to-end tests", Description: "Playwright e2e, integration verification", Dimensions: map[string]any{"kind": "tests"}},
	{Path: "dispatch/triage", ParentPath: "dispatch", Title: "Triage", Description: "Topic triage, issue filing, owner clarification", Dimensions: map[string]any{"kind": "dispatch"}},
	{Path: "dispatch/placement", ParentPath: "dispatch", Title: "Placement", Description: "Lane placement, queue scheduling", Dimensions: map[string]any{"kind": "dispatch"}},
}

// categorySpan is one placed lane's claim on its (agent, box) minutes;
// until zero = open.
type categorySpan struct {
	agent, box, path string
	from, until      time.Time
}

// categorySpans are the placed requests among asks as spans: each from its
// placement less CategoryPlaceLead to the next placement of the same
// (agent, box) less the same. path is a request's category. The Memory
// driver's rule; Postgres says it in categoryBurnSQL.
func categorySpans(asks []FleetAsk, path func(FleetAsk) string) []categorySpan {
	type placed struct {
		agent, box, path string
		at               time.Time
	}
	var ps []placed
	for _, a := range asks {
		if m := placedLaneRe.FindStringSubmatch(a.Reason); a.State == "done" && m != nil {
			ps = append(ps, placed{m[1], m[2], path(a), a.UpdatedAt})
		}
	}
	sort.Slice(ps, func(i, j int) bool { return ps[i].at.Before(ps[j].at) })
	out := make([]categorySpan, len(ps))
	for i, p := range ps {
		out[i] = categorySpan{agent: p.agent, box: p.box, path: p.path, from: p.at.Add(-CategoryPlaceLead)}
		for _, q := range ps[i+1:] {
			if q.agent == p.agent && q.box == p.box {
				out[i].until = q.at.Add(-CategoryPlaceLead)
				break
			}
		}
	}
	return out
}

// spanPath is the category of the span of spans that claims agent's minute
// m on box, "" for none.
func spanPath(spans []categorySpan, agent, box string, m time.Time) string {
	for _, sp := range spans {
		if sp.agent == agent && sp.box == box && !m.Before(sp.from) && (sp.until.IsZero() || m.Before(sp.until)) {
			return sp.path
		}
	}
	return ""
}

// The Memory driver keeps its tree and the requests' categories beside the
// store, like the token burn.
var (
	memCategoriesMu sync.Mutex
	memCategories   = map[*Memory]map[string]Category{}
	memAskCategory  = map[*Memory]map[[3]string][2]string{} // (tenant, fleet, ask) -> (work kind, path)
)

// memCategoryTree is s's tree, seeded on first use; memCategoriesMu held.
func (s *Memory) memCategoryTree() map[string]Category {
	if memCategories[s] == nil {
		now := time.Now().UTC().Truncate(time.Microsecond)
		m := map[string]Category{}
		for _, c := range CategorySeed {
			c.IsActive, c.CreatedAt, c.UpdatedAt = true, now, now
			m[c.Path] = c
		}
		memCategories[s] = m
	}
	return memCategories[s]
}

// ListCategories is CategoryStore on Memory.
func (s *Memory) ListCategories(_ context.Context) ([]Category, error) {
	memCategoriesMu.Lock()
	defer memCategoriesMu.Unlock()
	out := []Category{}
	for _, c := range s.memCategoryTree() {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, nil
}

// CreateCategory is CategoryStore on Memory.
func (s *Memory) CreateCategory(_ context.Context, c Category) (Category, error) {
	if why := CheckCategory(c); why != "" {
		return Category{}, fmt.Errorf("category: %s", why)
	}
	memCategoriesMu.Lock()
	defer memCategoriesMu.Unlock()
	tree := s.memCategoryTree()
	if _, ok := tree[c.Path]; ok {
		return Category{}, ErrConflict
	}
	if _, ok := tree[c.ParentPath]; c.ParentPath != "" && !ok {
		return Category{}, ErrUnknownCategory
	}
	if c.Dimensions == nil {
		c.Dimensions = map[string]any{}
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	c.CreatedAt, c.UpdatedAt = now, now
	tree[c.Path] = c
	return c, nil
}

// UpdateCategory is CategoryStore on Memory.
func (s *Memory) UpdateCategory(_ context.Context, c Category) (Category, error) {
	if why := CheckCategory(c); why != "" {
		return Category{}, fmt.Errorf("category: %s", why)
	}
	memCategoriesMu.Lock()
	defer memCategoriesMu.Unlock()
	tree := s.memCategoryTree()
	old, ok := tree[c.Path]
	if !ok {
		return Category{}, ErrNotFound
	}
	if c.Dimensions == nil {
		c.Dimensions = map[string]any{}
	}
	c.CreatedAt, c.UpdatedAt = old.CreatedAt, time.Now().UTC().Truncate(time.Microsecond)
	tree[c.Path] = c
	return c, nil
}

// SetAskCategory is CategoryStore on Memory.
func (s *Memory) SetAskCategory(_ context.Context, tenant, fleet, askID, workKind, path string) error {
	if why := CheckAskCategory(workKind, path); why != "" {
		return fmt.Errorf("ask category: %s", why)
	}
	k := [3]string{tenant, fleet, askID}
	s.mu.Lock()
	_, ok := s.asks[k]
	s.mu.Unlock()
	if !ok {
		return ErrNotFound
	}
	memCategoriesMu.Lock()
	defer memCategoriesMu.Unlock()
	if _, known := s.memCategoryTree()[path]; path != "" && !known {
		return ErrUnknownCategory
	}
	if memAskCategory[s] == nil {
		memAskCategory[s] = map[[3]string][2]string{}
	}
	memAskCategory[s][k] = [2]string{workKind, path}
	return nil
}

// AskCategory is the work kind and category recorded for an ask on Memory;
// ok false = none recorded.
func (s *Memory) AskCategory(tenant, fleet, askID string) (workKind, path string, ok bool) {
	memCategoriesMu.Lock()
	defer memCategoriesMu.Unlock()
	v, ok := memAskCategory[s][[3]string{tenant, fleet, askID}]
	return v[0], v[1], ok
}

// CategoryTokens is CategoryStore on Memory.
func (s *Memory) CategoryTokens(_ context.Context, op string, from, to time.Time) ([]CategoryLaneTokens, error) {
	s.mu.Lock()
	var asks []FleetAsk
	for k, a := range s.asks {
		if k[0] == op {
			a.Fleet = k[1]
			asks = append(asks, a)
		}
	}
	s.mu.Unlock()
	spans := categorySpans(asks, func(a FleetAsk) string { _, p, _ := s.AskCategory(op, a.Fleet, a.AskID); return p })
	acc := map[string]*CategoryLaneTokens{}
	memFleetTokensMu.Lock()
	defer memFleetTokensMu.Unlock()
	for _, b := range memFleetTokens[s] {
		if !b.IsMetered || b.Minute.Before(from) || !b.Minute.Before(to) {
			continue
		}
		path := spanPath(spans, b.AgentID, b.BoxTag, b.Minute)
		l := acc[path]
		if l == nil {
			l = &CategoryLaneTokens{Path: path}
			acc[path] = l
		}
		l.Tokens, l.CacheRead = l.Tokens+b.TokensIn+b.TokensOut+b.CacheWrite, l.CacheRead+b.CacheRead
		if b.Priced && b.Currency == "USD" {
			l.CostUSD += b.CostMicros / 1e6
		}
	}
	out := make([]CategoryLaneTokens, 0, len(acc))
	for _, l := range acc {
		out = append(out, *l)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, nil
}

var _ CategoryStore = (*Memory)(nil)
