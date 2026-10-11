package hub

import (
	"encoding/base64"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Owner bug (t1 d5d00918, msg c74e95d4): the Issues list read every issue of
// the tenant at once (prd t1 has 1400+). The list is now a keyset page:
// ?limit= (the Issues tab asks issuePageDefault; no limit is still the whole
// list, which the agent list, the hours picker and the parent lookup read)
// and ?cursor= the next_cursor of the page before, a key in
// the current sort rather than an offset, so a row created or moved meanwhile
// shifts nothing. counts and epics stay over the whole filtered list.

const (
	issuePageDefault = 30  // the Issues tab's page (WUI ISSUE_PAGE): the first and every Load more
	issuePageMax     = 500 // the largest page one call may ask for
)

// issueSortDir is the direction a sort runs when ?dir= is not given: the
// order the list always had (priority urgent first, deadline soonest, the
// times newest first, the number newest first, text A..Z).
var issueSortDir = map[string]string{
	"priority": "asc", "level": "asc", "deadline": "asc", "updated": "desc", "created": "desc",
	"number": "desc", "title": "asc", "status": "asc", "assignee": "asc", "label": "asc", "default": "asc",
}

// issueCursor is the last row of a page, as much of it as the order reads.
type issueCursor struct {
	Sort     string     `json:"s"`
	Dir      string     `json:"d"`
	Number   int        `json:"n"`
	Priority int        `json:"p,omitempty"`
	Level    int        `json:"l,omitempty"`
	Deadline *time.Time `json:"dl,omitempty"`
	Updated  time.Time  `json:"u"`
	Created  time.Time  `json:"c"`
	Title    string     `json:"t,omitempty"`
	Status   string     `json:"st,omitempty"`
	Assignee string     `json:"a,omitempty"`
	Label    string     `json:"lb,omitempty"`
}

func encodeIssueCursor(by, dir string, i store.Issue) string {
	raw, _ := json.Marshal(issueCursor{Sort: by, Dir: dir, Number: i.Number, Priority: i.Priority, Level: i.Level,
		Deadline: i.Deadline, Updated: i.UpdatedAt, Created: i.CreatedAt, Title: i.Title, Status: i.Status,
		Assignee: i.Assignee, Label: firstLabel(i)})
	return base64.RawURLEncoding.EncodeToString(raw)
}

func decodeIssueCursor(v string) (store.Issue, string, string, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(v)
	var c issueCursor
	if err != nil || json.Unmarshal(raw, &c) != nil || c.Number <= 0 {
		return store.Issue{}, "", "", false
	}
	i := store.Issue{Number: c.Number, Priority: c.Priority, Level: c.Level, Deadline: c.Deadline, UpdatedAt: c.Updated,
		CreatedAt: c.Created, Title: c.Title, Status: c.Status, Assignee: c.Assignee}
	if c.Label != "" {
		i.Labels = []string{c.Label}
	}
	return i, c.Sort, c.Dir, true
}

// parseIssuePage reads ?sort= ?dir= ?limit= ?cursor= into f.
func parseIssuePage(get func(string) string, f *issueFilter) *issueErr {
	f.sort = get("sort")
	if f.sort == "" {
		f.sort = "priority"
	}
	if _, ok := issueSortDir[f.sort]; !ok {
		return badIssue("sort must be priority, level, deadline, updated, created, number, title, status, assignee, label or default")
	}
	switch f.dir = get("dir"); f.dir {
	case "":
		f.dir = issueSortDir[f.sort]
	case "asc", "desc":
	default:
		return badIssue("dir must be asc or desc")
	}
	if v := get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > issuePageMax {
			return badIssue("limit must be 1.." + strconv.Itoa(issuePageMax))
		}
		f.limit = n
	}
	if v := get("cursor"); v != "" {
		c, by, dir, ok := decodeIssueCursor(v)
		if !ok {
			return badIssue("cursor is not a next_cursor of this list")
		}
		if by != f.sort || dir != f.dir {
			return badIssue("cursor belongs to another sort; start the list again")
		}
		f.cursor = &c
	}
	return nil
}

func firstLabel(i store.Issue) string {
	if len(i.Labels) == 0 {
		return ""
	}
	l := append([]string(nil), i.Labels...)
	sort.Strings(l)
	return l[0]
}

// issueCell is one row's value in a sort column; empty sorts last either way.
type issueCell struct {
	empty bool
	n     int64
	s     string
}

func cellOf(i store.Issue, by string) issueCell {
	switch by {
	case "priority", "default":
		return issueCell{empty: i.Priority == 0, n: int64(i.Priority)}
	case "level":
		return issueCell{empty: i.Level == 0, n: int64(i.Level)}
	case "deadline":
		if i.Deadline == nil {
			return issueCell{empty: true}
		}
		return issueCell{n: i.Deadline.UnixNano()}
	case "updated":
		return issueCell{n: i.UpdatedAt.UnixNano()}
	case "created":
		return issueCell{n: i.CreatedAt.UnixNano()}
	case "number":
		return issueCell{n: int64(i.Number)}
	case "title":
		return issueCell{s: strings.ToLower(i.Title)}
	case "status":
		return issueCell{n: int64(statusRank(i.Status))}
	case "assignee":
		return issueCell{empty: i.Assignee == "", s: i.Assignee}
	case "label":
		l := firstLabel(i)
		return issueCell{empty: l == "", s: l}
	}
	return issueCell{}
}

func statusRank(st string) int {
	for k, s := range store.IssueStatuses {
		if s == st {
			return k
		}
	}
	return len(store.IssueStatuses)
}

// cmpCell: -1, 0 or 1 in ascending order, empty last whatever the direction.
func cmpCell(a, b issueCell, sign int) int {
	switch {
	case a.empty && b.empty:
		return 0
	case a.empty:
		return 1
	case b.empty:
		return -1
	case a.n != b.n:
		if a.n < b.n {
			return -sign
		}
		return sign
	}
	return strings.Compare(a.s, b.s) * sign
}

// issueLess is the list order: the column in its direction, then (for
// "default", the WUI's product order, SPL-1181) updated newest first, then
// the newest number first, so no two rows tie and a cursor is exact.
func issueLess(by, dir string) func(x, y store.Issue) bool {
	sign := 1
	if dir == "desc" {
		sign = -1
	}
	return func(x, y store.Issue) bool {
		if c := cmpCell(cellOf(x, by), cellOf(y, by), sign); c != 0 {
			return c < 0
		}
		if by == "default" && !x.UpdatedAt.Equal(y.UpdatedAt) {
			return x.UpdatedAt.After(y.UpdatedAt)
		}
		return x.Number > y.Number
	}
}

// pageIssues orders kept, then cuts the page after f.cursor; limit 0 is the
// whole list. next is the cursor of the page after, "" on the last one.
func pageIssues(kept []store.Issue, f issueFilter, limit int) (page []store.Issue, next string) {
	less := issueLess(f.sort, f.dir)
	sort.SliceStable(kept, func(a, b int) bool { return less(kept[a], kept[b]) })
	from := 0
	if f.cursor != nil {
		from = sort.Search(len(kept), func(k int) bool { return less(*f.cursor, kept[k]) })
	}
	page = kept[from:]
	if limit > 0 && len(page) > limit {
		page = page[:limit]
		next = encodeIssueCursor(f.sort, f.dir, page[limit-1])
	}
	return page, next
}
