package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/vendorkey"
)

// vendorKeySealer is the seal of a workspace's own vendor keys (spec 127 H1,
// spec 159 T1): Cloud KMS on SPOOL_HUB_VENDOR_KEYS_KMS_KEY plus the pepper
// in the file SPOOL_HUB_VENDOR_KEYS_PEPPER_FILE. nil (logged, never the pepper)
// while either is unset, the file is not exactly the pepper's size or the KMS
// client does not start: every /v1/vendor-keys route then answers 503
// vendor_keys_off, never an unsealed write.
func vendorKeySealer(ctx context.Context, hc *config.Hub, log zerolog.Logger) *vendorkey.Sealer {
	key, file := strings.TrimSpace(hc.VendorKeysKMSKey), strings.TrimSpace(hc.VendorKeysPepperFile)
	if key == "" || file == "" {
		log.Warn().Bool("kms_key", key != "").Bool("pepper_file", file != "").Msg("vendor keys: not configured, routes answer 503")
		return nil
	}
	pepper, err := readVendorKeyPepper(file)
	if err != nil {
		log.Error().Err(err).Msg("vendor keys: no pepper, routes answer 503")
		return nil
	}
	kms, err := marketing.NewCloudKMS(ctx)
	if err != nil {
		log.Error().Err(err).Msg("vendor keys: no KMS client, routes answer 503")
		return nil
	}
	s, err := vendorkey.NewSealer(kms, key, pepper)
	if err != nil {
		log.Error().Err(err).Msg("vendor keys: not configured, routes answer 503")
		return nil
	}
	log.Info().Msg("vendor keys: on")
	return s
}

// readVendorKeyPepper reads the raw pepper file. A short read would make
// fingerprints the real pepper cannot verify, so any length but
// vendorkey.PepperBytes is an error that names the length, never the bytes.
func readVendorKeyPepper(file string) ([]byte, error) {
	b, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	if len(b) != vendorkey.PepperBytes {
		return nil, fmt.Errorf("vendor key pepper file holds %d bytes, want %d", len(b), vendorkey.PepperBytes)
	}
	return b, nil
}

// vendorKeyMailer sends the vendor key notice (spec 159 section 3,
// mail.TemplateVendorKeyChanged) through the platform relay; nil with no
// relay (the hub then logs vendor_key.mail_off and mails nobody).
func vendorKeyMailer(log zerolog.Logger, pmc *mail.Config) hub.VendorKeyMailer {
	if pmc.Transport == mail.TransportNone {
		return nil
	}
	sender := pmc.Sender(log)
	return func(ctx context.Context, to, locale string, n hub.VendorKeyNotice) error {
		build := mail.VendorKeyChanged
		if n.Action == store.VendorKeyExhausted { // spec 159 9 point 5 (T5)
			build = mail.VendorKeyExhausted
		}
		msg, err := build(to, locale, mail.VendorKeyNotice{TenantID: n.Tenant, Kind: n.Kind,
			Action: n.Action, Last4: n.Last4, ChangedBy: n.By, ChangedAt: n.At})
		if err != nil {
			return err
		}
		return sender.Send(ctx, msg)
	}
}
