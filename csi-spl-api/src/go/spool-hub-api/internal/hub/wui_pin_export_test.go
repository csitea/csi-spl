package hub

import "context"

// EnsureWUIPin is a test hook (spec 158 row P1): ensureWUIPin with the audit
// row naming actorHum of actorTenant.
func (s *Server) EnsureWUIPin(ctx context.Context, tenant, actorTenant, actorHum string) string {
	return s.ensureWUIPin(ctx, tenant, wuiPinActor{actorTenant, actorHum})
}
