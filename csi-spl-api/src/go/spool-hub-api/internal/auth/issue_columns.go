package auth

import (
	"context"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
)

// The Issues sheet's column widths (SPL-1132, rdb 0076 humans.issues_columns).
// Owner, prd t1 topic beb4024f: "the columns of the issues grid should be
// resizable". A person's widths are kept on the account like the other
// layout choices: one JSON object of column -> px, null when never sized
// (the WUI then lays the sheet out as it always did).

// IssueColumns are the sheet columns a width may be kept for, in sheet order
// (the WUI's SHEET_COLUMNS; tests/unit pins the two lists equal).
var IssueColumns = []string{"key", "title", "status", "priority", "level", "assignee", "label", "deadline", "updated"}

// IssueColumnMin and IssueColumnMax bound one stored width, in CSS px. The
// WUI applies its own per-column floor (Key and Title stay usable) on top.
const (
	IssueColumnMin = 24
	IssueColumnMax = 2000
)

// IsIssueColumns reports whether cols holds only IssueColumns keys, each with
// a width inside [IssueColumnMin, IssueColumnMax]. An empty map is valid.
func IsIssueColumns(cols map[string]int) bool {
	for k, w := range cols {
		if !slices.Contains(IssueColumns, k) || w < IssueColumnMin || w > IssueColumnMax {
			return false
		}
	}
	return true
}

// parseIssueColumns reads PUT preferences' issues_columns: present = has, a
// null or an empty object clears (nil). A refusal is (code, detail).
func parseIssueColumns(raw json.RawMessage) (cols map[string]int, has bool, code, detail string) {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return nil, false, "", ""
	}
	if s == "null" {
		return nil, true, "", ""
	}
	if json.Unmarshal(raw, &cols) != nil || cols == nil || !IsIssueColumns(cols) {
		return nil, true, "unsupported_issues_columns", "issues_columns must be an object of " + strings.Join(IssueColumns, ",") +
			" -> a whole px width " + strconv.Itoa(IssueColumnMin) + ".." + strconv.Itoa(IssueColumnMax) + ", or null"
	}
	if len(cols) == 0 {
		cols = nil
	}
	return cols, true, "", ""
}

// issueColumns is the session human's stored column widths, nil when unset,
// with no human or store, or when the read fails. It rides GET /session and
// the native POST /login answer, like railOrder.
func (h *Handler) issueColumns(ctx context.Context, s Session) map[string]int {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	cols, err := h.settings(ctx, s.HumanID).IssueColumns(ctx, s.HumanID)
	if err != nil {
		h.log.Warn().Err(err).Msg("auth issues_columns lookup")
		return nil
	}
	if len(cols) == 0 {
		return nil
	}
	return cols
}
