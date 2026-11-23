package hub

import (
	"context"
	"slices"
	"time"
)

// BoxFeatures is a test hook (spec 071 7.8 "wire feature"): the hello
// features of the tenant's live role=box session of box, and false when the
// box has none.
func (s *Server) BoxFeatures(tenant, box string) ([]string, bool) {
	x := s.boxSession(tenant, box)
	if x == nil {
		return nil, false
	}
	return slices.Clone(x.features), true
}

// AskBoxSample is a test hook (spec 071 7.8 "two-instance delivery"):
// askBoxSample, the announce row T6's route makes per asked box.
func (s *Server) AskBoxSample(ctx context.Context, tenant, box string, deadline time.Time) (string, error) {
	return s.askBoxSample(ctx, tenant, box, deadline)
}

// PendingBoxSample is a test hook: whether this instance holds request req
// for (tenant, box).
func (s *Server) PendingBoxSample(tenant, box, req string) bool {
	s.samples.mu.Lock()
	defer s.samples.mu.Unlock()
	r := s.samples.m[req]
	return r != nil && r.tenant == tenant && r.box == box
}
