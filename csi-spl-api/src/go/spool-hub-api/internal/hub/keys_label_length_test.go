package hub_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

// SPL-5583: the key label limit (80) counts characters, as rdb 0018's
// length(label) CHECK does, not UTF-8 bytes: 80 Cyrillic letters (160
// bytes) are taken, 81 are refused.
func TestKeysLabelCountsCharacters(t *testing.T) {
	k := newKeysRig(t, 0)
	for _, c := range []struct {
		name, label string
		status      int
	}{
		{"cyrillic 80 chars", strings.Repeat("Я", 80), 201},
		{"cyrillic 81 chars", strings.Repeat("Я", 81), 400},
		{"ascii 80 chars", strings.Repeat("a", 80), 201},
		{"ascii 81 chars", strings.Repeat("a", 81), 400},
	} {
		pub, _ := newPub(t)
		b, _ := json.Marshal(map[string]string{"public_key": sign.PinForm(pub), "label": c.label})
		if code, body := k.do(t, k.alice, "POST", "", string(b)); code != c.status {
			t.Errorf("%s: %d %s (want %d)", c.name, code, body, c.status)
		}
	}
}
