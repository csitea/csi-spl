package hub

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// An event's discussion is topic_id (rdb 0125). SPL-4043 adds the issue
// list and the one responsible owner (a member or an agent), distinct from
// the creator. The store checks shape; this file checks the workspace.

const calendarMaxIssueKeys = 20

// takeLinks trims owner_id and issue_keys. An absent list stays nil, so a
// PATCH that omits it leaves the stored list. Safe to call once per request.
func takeLinks(q *calendarRequest) *issueErr {
	if q.OwnerID != nil {
		*q.OwnerID = strings.TrimSpace(*q.OwnerID)
	}
	if q.IssueKeys == nil {
		return nil
	}
	keys, ie := trimIssueKeys(*q.IssueKeys)
	if ie != nil {
		return ie
	}
	q.IssueKeys = &keys
	return nil
}

// trimIssueKeys drops blanks and repeats. A key is "SPL-12" or a number.
func trimIssueKeys(in []string) ([]string, *issueErr) {
	out := make([]string, 0, len(in))
	for _, k := range in {
		k = strings.TrimSpace(k)
		if k == "" || slices.Contains(out, k) {
			continue
		}
		if utf8.RuneCountInString(k) > 32 {
			return nil, badCalendar("an issue key is at most 32 characters")
		}
		if _, ok := store.ParseIssueRef(k); !ok {
			return nil, badCalendar("issue key " + k + " is not a key of this workspace")
		}
		out = append(out, k)
	}
	if len(out) > calendarMaxIssueKeys {
		return nil, badCalendar("an event links at most 20 issues")
	}
	return out, nil
}

// canonicalIssueKeys resolves each key to the workspace's own key (SPL-12).
// An empty list does not touch the issues store. A prefix that is not this
// workspace's (HUM-10 parses as a number) is refused.
func (s *Server) canonicalIssueKeys(ctx context.Context, tenant string, keys []string) ([]string, *issueErr, error) {
	if len(keys) == 0 {
		return []string{}, nil, nil
	}
	is, ie := s.issueStore()
	if ie != nil {
		return nil, ie, nil
	}
	prefix, err := is.IssuePrefix(ctx, tenant)
	if err != nil {
		return nil, nil, err
	}
	out := make([]string, 0, len(keys))
	for _, k := range keys {
		if i := strings.LastIndexByte(k, '-'); i >= 0 && !strings.EqualFold(k[:i], prefix) {
			return nil, badCalendar("issue key " + k + " is not in this workspace"), nil
		}
		n, ok := store.ParseIssueRef(k)
		if !ok {
			return nil, badCalendar("issue key " + k + " is not a key of this workspace"), nil
		}
		iss, err := is.GetIssue(ctx, tenant, n)
		if errors.Is(err, store.ErrNotFound) {
			return nil, badCalendar("issue key " + k + " is not in this workspace"), nil
		}
		if err != nil {
			return nil, nil, err
		}
		if key := iss.Key(); !slices.Contains(out, key) {
			out = append(out, key)
		}
	}
	return out, nil, nil
}

// calendarOwnerKnown: owner is the creator, a member (HUM-n) or an agent of
// the roster (id or id@box). The creator is always allowed, including the
// door-off rig and a sync writer.
func (s *Server) calendarOwnerKnown(ctx context.Context, tenant, owner, creator string) (*issueErr, error) {
	if owner == "" || owner == creator {
		return nil, nil
	}
	known := map[string]bool{}
	if md, ok := s.o.Store.(store.MemberDirectory); ok {
		ms, err := md.ListMembers(ctx, tenant)
		if err != nil {
			return nil, err
		}
		for _, m := range ms {
			known["human:"+m.HumanID] = true
		}
	}
	roster, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		return nil, err
	}
	for box, agents := range roster {
		for _, a := range agents {
			known["agent:"+a], known["agent:"+a+"@"+box] = true, true
		}
	}
	key := "agent:" + owner
	if humanIDRe.MatchString(owner) {
		key = "human:" + owner
	}
	if !known[key] {
		return badCalendar("owner " + owner + " is not a member or an agent of this workspace"), nil
	}
	return nil, nil
}

// bindEventLinks checks a create's issue keys and owner and writes the
// refusal. Call it after newEvent, so the owner already defaults to the creator.
func (s *Server) bindEventLinks(w http.ResponseWriter, r *http.Request, tenant, creator string, e *store.CalendarEvent) bool {
	keys, ie, err := s.canonicalIssueKeys(r.Context(), tenant, e.IssueKeys)
	if err != nil {
		s.writeCalendarErr(w, tenant, "issue links", err)
		return false
	}
	if ie != nil {
		writeIssueErr(w, ie)
		return false
	}
	e.IssueKeys = keys
	ie, err = s.calendarOwnerKnown(r.Context(), tenant, e.OwnerID, creator)
	if err != nil {
		s.writeCalendarErr(w, tenant, "owner", err)
		return false
	}
	if ie != nil {
		writeIssueErr(w, ie)
		return false
	}
	return true
}

// canonPatchLinks resolves a PATCH's issue list and owner. An empty owner
// is left for the store, which resets it to the creator. An empty list clears.
func (s *Server) canonPatchLinks(ctx context.Context, tenant, creator string, p *store.CalendarPatch) (*issueErr, error) {
	if p.IssueKeys != nil {
		keys, ie, err := s.canonicalIssueKeys(ctx, tenant, *p.IssueKeys)
		if ie != nil || err != nil {
			return ie, err
		}
		p.IssueKeys = &keys
	}
	if p.OwnerID != nil && *p.OwnerID != "" {
		return s.calendarOwnerKnown(ctx, tenant, *p.OwnerID, creator)
	}
	return nil, nil
}
