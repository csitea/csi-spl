package store

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// demoSeat reports whether hum holds a demo_user seat in tenant, the open
// demo workspace (specs/077 T011): its name is the pseudonym and it keeps no
// IdP picture. Any other tenant, the demo off, or a failed read is false: the
// seat itself was pseudonymised in the admission transaction already.
func (a AuthHooks) demoSeat(ctx context.Context, hum, tenant string) bool {
	if a.Policy.OpenWorkspace == "" || tenant != a.Policy.OpenWorkspace {
		return false
	}
	role, err := a.H.MemberRole(ctx, hum, tenant)
	return err == nil && role == rbac.DemoUser
}
