package cicdlogs

import (
	"reflect"
	"testing"
)

// TestParseTenantTokens pins SPOOL_HUB_CICD_TENANT_TOKENS parsing: blanks
// and spaces are dropped, a later tenant wins, a token may hold ':', and any
// half-empty entry refuses the whole value.
func TestParseTenantTokens(t *testing.T) {
	const refusal = "SPOOL_HUB_CICD_TENANT_TOKENS entries look like tenant:token"
	for _, tc := range []struct {
		name string
		in   string
		want map[string]string
		err  string
	}{
		{"empty", "", map[string]string{}, ""},
		{"blank entries", " , ,", map[string]string{}, ""},
		{"two tenants", "t1:a, t2 : b ", map[string]string{"t1": "a", "t2": "b"}, ""},
		{"later wins", "t1:a,t1:b", map[string]string{"t1": "b"}, ""},
		{"colon in token", "t1:a:b", map[string]string{"t1": "a:b"}, ""},
		{"no colon", "t1", nil, refusal},
		{"empty tenant", ":tok", nil, refusal},
		{"empty token", "t1: ", nil, refusal},
		{"one bad of two", "t1:a,t2", nil, refusal},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseTenantTokens(tc.in)
			if tc.err != "" {
				if err == nil || err.Error() != tc.err {
					t.Fatalf("err = %v, want %q", err, tc.err)
				}
				return
			}
			if err != nil || !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got %v, %v; want %v", got, err, tc.want)
			}
		})
	}
}
