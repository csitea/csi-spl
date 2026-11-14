package config

import (
	"os"
	"slices"
	"testing"
)

// SPL-5524 R7 W3: SPOOL_HUB_OWNER_PRIO_WORDS set to "" turns the owner's
// prio word off; unset keeps the default words. RED CONTROL: drop the
// h.ownerPrioWordsOff() call in LoadHub -> "set empty" loads the 3 defaults.
func TestLoadHubOwnerPrioWords(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  bool
		val  string
		want []string
	}{
		{"unset", false, "", []string{"prio", "priority one", "urgent"}},
		{"set empty", true, "", nil},
		{"set blank", true, " , ", nil},
		{"set one", true, "asap", []string{"asap"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			setHubBase(t)
			if tc.set {
				t.Setenv("SPOOL_HUB_OWNER_PRIO_WORDS", tc.val)
			} else {
				t.Setenv("SPOOL_HUB_OWNER_PRIO_WORDS", "x")
				unsetEnv(t, "SPOOL_HUB_OWNER_PRIO_WORDS")
			}
			h, err := LoadHub()
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(h.OwnerPrioWords, tc.want) {
				t.Fatalf("OwnerPrioWords = %q, want %q", h.OwnerPrioWords, tc.want)
			}
		})
	}
}

// unsetEnv unsets key for the test; the t.Setenv before it restores it.
func unsetEnv(t *testing.T, key string) {
	t.Helper()
	if err := os.Unsetenv(key); err != nil {
		t.Fatal(err)
	}
}
