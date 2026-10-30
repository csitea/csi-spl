package hub

import (
	"context"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The member match of spec 154 B6 (section 2.4, cases C13-C13e): every
// contact the list and card routes answer carries member_id, the human id
// of the member of the SESSION's workspace whose verified identity is the
// contact's email, else null. The match never looks outside that
// workspace, so read from another workspace a member of W1 only and an
// address of no human answer the same null (C13c). It runs on each
// request and is never stored. The contacts were read under the person
// scope; this is a second read, in the workspace scope (1.2 row 26).

// contactsMatch fills member_id on out with one store call for the whole
// page (C13e); a page with no email makes none. A store without the match
// leaves every member_id null.
func (s *Server) contactsMatch(ctx context.Context, tenant string, out []contactOut) error {
	cm, ok := s.o.Store.(store.ContactMembers)
	if !ok {
		return nil
	}
	emails := make([]string, 0, len(out))
	for _, c := range out {
		if c.Email != nil {
			emails = append(emails, *c.Email)
		}
	}
	if len(emails) == 0 {
		return nil
	}
	members, err := cm.MembersByVerifiedEmail(ctx, tenant, emails)
	if err != nil {
		return err
	}
	for i := range out {
		if out[i].Email == nil {
			continue
		}
		if hum, ok := members[strings.ToLower(*out[i].Email)]; ok {
			out[i].MemberID = &hum
		}
	}
	return nil
}
