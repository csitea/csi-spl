package auth

import (
	"context"
	"encoding/json"
	"strings"
)

// The Issues list default sort (CLE-35099, spec 023 addendum). Owner, prd t1
// topic 3a589b54: "There should be a setting for the default sort order of the
// issues listing, and the global default for new users should be sorted by
// prio: 1, 2, 3 ... from top to bottom". Kept PER TENANT in the membership
// override (rdb 0078): {col, dir}. Null / never picked = the product default
// (priority ascending, tie-broken by updated newest-first, the hub's stable
// secondary order). Clicking a column header still re-sorts the current view
// (SPL-972/1027); this is only the default the Issues list opens with.

// IssuesSortColumns are the columns a default sort may name: the hub's own
// sorts (priority, level, deadline, updated, created) and the sheet columns the
// WUI sorts client-side (key, title, status, assignee, label).
var IssuesSortColumns = []string{
	"priority", "level", "deadline", "updated", "created",
	"key", "title", "status", "assignee", "label",
}

// IssuesSortDirs are the two directions. asc = 1, 2, 3 from the top.
var IssuesSortDirs = []string{"asc", "desc"}

// IsIssuesSort reports whether v names a known column and direction.
func IsIssuesSort(v IssuesSort) bool {
	return inList(v.Col, IssuesSortColumns) && inList(v.Dir, IssuesSortDirs)
}

func inList(s string, list []string) bool {
	for _, x := range list {
		if s == x {
			return true
		}
	}
	return false
}

// parseIssuesSort reads PUT preferences' issues_sort: present = has, a null
// clears (nil). A refusal is (code, detail). DisallowUnknownFields keeps the
// stored shape to {col, dir}.
func parseIssuesSort(raw json.RawMessage) (v *IssuesSort, has bool, code, detail string) {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return nil, false, "", ""
	}
	if s == "null" {
		return nil, true, "", ""
	}
	dec := json.NewDecoder(strings.NewReader(s))
	dec.DisallowUnknownFields()
	var got IssuesSort
	if err := dec.Decode(&got); err != nil || !IsIssuesSort(got) {
		return nil, true, "unsupported_issues_sort", "issues_sort must be {col: one of " +
			strings.Join(IssuesSortColumns, ",") + ", dir: asc|desc}, or null"
	}
	return &got, true, "", ""
}

// issuesSort is the session human's stored default sort for the active tenant,
// nil when unset, with no human or store. It reads the request's overlaid
// snapshot (withSettings), so it already carries the per-tenant value.
func (h *Handler) issuesSort(ctx context.Context, s Session) *IssuesSort {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	if snap, ok := h.settingsSnap(ctx, s.HumanID); ok {
		return snap.IssuesSort
	}
	return nil
}
