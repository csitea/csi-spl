package hub

import "slices"

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
