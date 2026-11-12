package keyd

import "testing"

// SetTestScryptWorkFactor lowers the scrypt cost keyd seals with, for the
// test binary of another package (cmd/spool) and the helpers and keyd
// children it re-execs from itself. A production binary keeps age's
// default: outside a go test binary (testing.Testing), and for a logN
// outside 10..18, it refuses and changes nothing. It reports whether the
// cost changed (SPL-5352).
func SetTestScryptWorkFactor(logN int) bool {
	if !testing.Testing() || logN < 10 || logN > 18 {
		return false
	}
	scryptLogN = logN
	return true
}
