package main

import (
	"strings"
	"testing"
)

// SPL-2405: fleet-tokens-reprice refuses a missing --db, --models or --from,
// a bad --from and a stray argument before it opens any DB. The DB path
// itself: store TestFleetTokenRepriceUnpriced and csi-spl-orc
// spl-token-burn-reprice.tst.sh part B.
func TestFleetTokensRepriceRefusals(t *testing.T) {
	t.Setenv("SPOOL_HUB_DB_DSN", "")
	db := "postgres://u:p@127.0.0.1:1/none?sslmode=disable&connect_timeout=1"
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--models", "m", "--from", "2026-10-16"}, "are required"},
		{[]string{"--db", db, "--from", "2026-10-16"}, "are required"},
		{[]string{"--db", db, "--models", "m"}, "are required"},
		{[]string{"--db", db, "--models", "m", "--from", "2026-10-16", "x"}, "are required"},
		{[]string{"--db", db, "--models", "m", "--from", "16.10.2026"}, "neither RFC3339"},
	} {
		if rc, _, errOut := runCap(t, "", append([]string{"fleet-tokens-reprice"}, c.args...)...); rc != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("%v: rc %d %q, want 1 and %q", c.args, rc, errOut, c.want)
		}
	}
	// CONTROL: good arguments get past the checks to the DB (none listens).
	if rc, _, errOut := runCap(t, "", "fleet-tokens-reprice", "--db", db, "--models", "m", "--from", "2026-10-16T00:00:00Z"); rc != 1 || strings.Contains(errOut, "required") || strings.Contains(errOut, "neither") {
		t.Errorf("good arguments: rc %d %q, want a DB error", rc, errOut)
	}
}
