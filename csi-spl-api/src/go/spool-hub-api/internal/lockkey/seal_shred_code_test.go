package lockkey

import (
	"encoding/base64"
	"os"
	"testing"
)

// SPL-5137: a box whose clear key could not be removed IS sealed, and a second
// Seal refuses it, so this return is the only time its recovery code exists.
func TestSealKeepsTheRecoveryCodeWhenShredFails(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root opens a 0400 file for writing, so shred does not fail here")
	}
	clearKey := base64.StdEncoding.EncodeToString(srLockKey(t))
	keysDir, _ := srPlantClearBoxKey(t, clearKey, 0o400)
	res, err := Seal(keysDir, tTenant, tBox, []byte(tSecret), fast)
	srWantErr(t, err, "sealed, but the clear box key was not removed")
	if res.Meta.Box != tBox || res.Meta.LockPubkey == "" {
		t.Fatalf("meta not returned with the error: %+v", res.Meta)
	}
	rec, err := ParseRecoveryCode(res.RecoveryCode)
	if err != nil {
		t.Fatalf("recovery code %q: %v", res.RecoveryCode, err)
	}
	if _, lock, err := OpenLockByRecovery(keysDir, rec); err != nil {
		t.Fatalf("the returned code does not open the lock key: %v", err)
	} else {
		Wipe(lock)
	}
}
