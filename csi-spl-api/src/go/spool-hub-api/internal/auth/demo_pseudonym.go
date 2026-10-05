package auth

import (
	"errors"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// ErrPseudonymFixed from Preferences.SetDisplayName refuses a demo visitor's
// rename: a demo_user is shown only under its generated pseudonym (specs/077
// FR-007, T011), so PUT preferences display_name answers 403 pseudonym.
var ErrPseudonymFixed = errors.New("auth: a demo visitor keeps its pseudonym")

// demoSession reports whether the session's human holds a demo_user seat
// (specs/077 T011). The open rule seats only a human with no membership
// elsewhere, so such a session is a demo visitor's: GET session then carries
// no email and never the IdP name.
func demoSession(roles []TenantRole) bool {
	for _, r := range roles {
		if r.Role == rbac.DemoUser {
			return true
		}
	}
	return false
}
