package store

import "context"

// Test hooks: write shapes no production path writes today (an unverified
// identity, a disabled human). They live in a _test.go file so they never
// ship in the hub binary.

// unverifyIdentity is a test hook: it leaves the address on the identity but
// clears human_identities.email_verified, the one shape no production path
// writes today and the one CLE-3451's linking must refuse to merge on.
func (s *Memory) unverifyIdentity(provider, subject string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if row, ok := s.hum.identities[[2]string{provider, subject}]; ok {
		row.verified = false
	}
}

// disableHuman is a test hook (humans.disabled_at); no production caller yet.
func (s *Memory) disableHuman(humanID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if hm, ok := s.hum.humans[humanID]; ok {
		hm.disabled = true
	}
}

// unverifyIdentity is a test hook: see Memory.unverifyIdentity.
func (s *Postgres) unverifyIdentity(provider, subject string) {
	s.pool.Exec(context.Background(), //nolint:errcheck
		`UPDATE human_identities SET email_verified = false WHERE provider = $1 AND subject = $2`, provider, subject)
}

// disableHuman is a test hook (humans.disabled_at); no production caller yet.
func (s *Postgres) disableHuman(humanID string) {
	s.pool.Exec(context.Background(), `UPDATE humans SET disabled_at = now() WHERE human_id = $1`, humanID) //nolint:errcheck
}
