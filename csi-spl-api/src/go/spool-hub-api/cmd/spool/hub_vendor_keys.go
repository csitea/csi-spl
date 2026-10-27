package main

import (
	"context"
	"strings"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/vendorkey"
)

// vendorKeySealer is the seal of a workspace's own vendor keys (spec 127 H1,
// spec 159 T1): Cloud KMS on SPOOL_HUB_VENDOR_KEYS_KMS_KEY plus the pepper
// SPOOL_HUB_VENDOR_KEYS_PEPPER. nil (logged, never the pepper) while either
// is unset or the KMS client does not start: every /v1/vendor-keys route
// then answers 503 vendor_keys_off, never an unsealed write.
func vendorKeySealer(ctx context.Context, hc *config.Hub, log zerolog.Logger) *vendorkey.Sealer {
	key, pepper := strings.TrimSpace(hc.VendorKeysKMSKey), hc.VendorKeysPepper
	if key == "" || pepper == "" {
		log.Warn().Bool("kms_key", key != "").Bool("pepper", pepper != "").Msg("vendor keys: not configured, routes answer 503")
		return nil
	}
	kms, err := marketing.NewCloudKMS(ctx)
	if err != nil {
		log.Error().Err(err).Msg("vendor keys: no KMS client, routes answer 503")
		return nil
	}
	s, err := vendorkey.NewSealer(kms, key, []byte(pepper))
	if err != nil {
		log.Error().Err(err).Msg("vendor keys: not configured, routes answer 503")
		return nil
	}
	log.Info().Msg("vendor keys: on")
	return s
}
