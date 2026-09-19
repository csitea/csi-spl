package auth

import (
	"errors"
	"strings"
	"testing"
)

var testArgon = Argon2Params{MemoryKiB: 64, Iterations: 1}

func TestPasswordHashRoundTrip(t *testing.T) {
	h, err := HashPassword("correct horse battery", testArgon)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$argon2id$v=19$m=64,t=1,p=1$") {
		t.Fatalf("not a PHC argon2id string: %s", h)
	}
	if err := VerifyPassword(h, "correct horse battery"); err != nil {
		t.Fatalf("right password: %v", err)
	}
	if err := VerifyPassword(h, "correct horse batterY"); !errors.Is(err, ErrPasswordMismatch) {
		t.Fatalf("wrong password: want mismatch, got %v", err)
	}
	h2, _ := HashPassword("correct horse battery", testArgon)
	if h == h2 {
		t.Fatal("two hashes of one password are equal: salt not random")
	}
}

// A hash made with other params still verifies (params travel in the hash).
func TestPasswordVerifyUsesStoredParams(t *testing.T) {
	h, _ := HashPassword("pw-with-old-cost-1", Argon2Params{MemoryKiB: 32, Iterations: 2})
	if err := VerifyPassword(h, "pw-with-old-cost-1"); err != nil {
		t.Fatal(err)
	}
}

func TestPasswordRejectsBadInput(t *testing.T) {
	if _, err := HashPassword("", testArgon); err == nil {
		t.Fatal("empty password hashed")
	}
	if _, err := HashPassword("x", Argon2Params{}); err == nil {
		t.Fatal("zero params accepted")
	}
	for _, bad := range []string{"", "plain", "$argon2i$v=19$m=64,t=1,p=1$AAAA$AAAA",
		"$argon2id$v=19$m=99999999,t=1,p=1$AAAA$AAAA", "$argon2id$v=19$m=64,t=1,p=1$AAAA$"} {
		if err := VerifyPassword(bad, "x"); err == nil || errors.Is(err, ErrPasswordMismatch) {
			t.Fatalf("%q: want an encoding error, got %v", bad, err)
		}
	}
}
