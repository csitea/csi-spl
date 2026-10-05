package marketing

import (
	"context"
	"crypto/rand"
	"fmt"
	"sync"
)

// FakeKMS is an in-memory KMS for tests: one random AES-256 key per key name,
// generated on first use, living only in this process. It holds no real key.
type FakeKMS struct {
	mu   sync.Mutex
	keys map[string][]byte
}

// NewFakeKMS returns an empty FakeKMS.
func NewFakeKMS() *FakeKMS { return &FakeKMS{keys: map[string][]byte{}} }

func (f *FakeKMS) key(keyName string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	k, ok := f.keys[keyName]
	if !ok {
		k = make([]byte, 32)
		if _, err := rand.Read(k); err != nil {
			return nil, err
		}
		f.keys[keyName] = k
	}
	return k, nil
}

// Encrypt wraps plaintext with keyName's in-memory key.
func (f *FakeKMS) Encrypt(_ context.Context, keyName string, plaintext []byte) ([]byte, string, error) {
	k, err := f.key(keyName)
	if err != nil {
		return nil, "", err
	}
	gcm, err := newGCM(k)
	if err != nil {
		return nil, "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, "", err
	}
	return gcm.Seal(nonce, nonce, plaintext, []byte(keyName)), keyName + "/cryptoKeyVersions/1", nil
}

// Decrypt unwraps what Encrypt wrapped under the same keyName.
func (f *FakeKMS) Decrypt(_ context.Context, keyName string, wrapped []byte) ([]byte, error) {
	k, err := f.key(keyName)
	if err != nil {
		return nil, err
	}
	gcm, err := newGCM(k)
	if err != nil {
		return nil, err
	}
	n := gcm.NonceSize()
	if len(wrapped) < n {
		return nil, fmt.Errorf("fake kms: short ciphertext")
	}
	return gcm.Open(nil, wrapped[:n], wrapped[n:], []byte(keyName))
}
