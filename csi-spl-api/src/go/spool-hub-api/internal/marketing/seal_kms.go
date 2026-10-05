package marketing

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"hash/crc32"

	cloudkms "google.golang.org/api/cloudkms/v1"
	"google.golang.org/api/option"
)

// castagnoli is the CRC32C table KMS uses for its integrity fields.
var castagnoli = crc32.MakeTable(crc32.Castagnoli)

// CloudKMS is the KMS adapter over the Cloud KMS REST API. It runs as the
// hub's runtime service account (Application Default Credentials).
type CloudKMS struct {
	keys *cloudkms.ProjectsLocationsKeyRingsCryptoKeysService
}

// NewCloudKMS builds the Cloud KMS client.
func NewCloudKMS(ctx context.Context, opts ...option.ClientOption) (*CloudKMS, error) {
	svc, err := cloudkms.NewService(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("marketing: cloud kms client: %w", err)
	}
	return &CloudKMS{keys: svc.Projects.Locations.KeyRings.CryptoKeys}, nil
}

// Encrypt wraps plaintext under keyName, checking KMS's CRC32C round trip.
func (c *CloudKMS) Encrypt(ctx context.Context, keyName string, plaintext []byte) ([]byte, string, error) {
	req := &cloudkms.EncryptRequest{
		Plaintext:       base64.StdEncoding.EncodeToString(plaintext),
		PlaintextCrc32c: int64(crc32.Checksum(plaintext, castagnoli)),
	}
	resp, err := c.keys.Encrypt(keyName, req).Context(ctx).Do()
	if err != nil {
		return nil, "", err
	}
	if !resp.VerifiedPlaintextCrc32c {
		return nil, "", errors.New("kms encrypt: plaintext crc32c not verified")
	}
	wrapped, err := base64.StdEncoding.DecodeString(resp.Ciphertext)
	if err != nil {
		return nil, "", fmt.Errorf("kms encrypt: %w", err)
	}
	if int64(crc32.Checksum(wrapped, castagnoli)) != resp.CiphertextCrc32c {
		return nil, "", errors.New("kms encrypt: ciphertext crc32c mismatch")
	}
	return wrapped, resp.Name, nil
}

// Decrypt unwraps wrapped under keyName (any version of that key).
func (c *CloudKMS) Decrypt(ctx context.Context, keyName string, wrapped []byte) ([]byte, error) {
	req := &cloudkms.DecryptRequest{
		Ciphertext:       base64.StdEncoding.EncodeToString(wrapped),
		CiphertextCrc32c: int64(crc32.Checksum(wrapped, castagnoli)),
	}
	resp, err := c.keys.Decrypt(keyName, req).Context(ctx).Do()
	if err != nil {
		return nil, err
	}
	plain, err := base64.StdEncoding.DecodeString(resp.Plaintext)
	if err != nil {
		return nil, fmt.Errorf("kms decrypt: %w", err)
	}
	if int64(crc32.Checksum(plain, castagnoli)) != resp.PlaintextCrc32c {
		return nil, errors.New("kms decrypt: plaintext crc32c mismatch")
	}
	return plain, nil
}
