// Test-only helpers moved from production code.

package cicdlogs

import "encoding/json"

// DumpJSON is a test helper (compact).
func DumpJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
