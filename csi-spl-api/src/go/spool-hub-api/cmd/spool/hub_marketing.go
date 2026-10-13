package main

import (
	"context"
	"os"
	"strings"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
)

// marketingLinkedIn builds the LinkedIn connect + share wiring (spec 090,
// SPL-1634), or nil while the app's id, its secret or the KMS key is not
// set: then connect answers 503 and the share sweep idles. The hub's public
// origin is the operator audience (cnf hub env SPOOL_HUB_OPERATOR_AUDIENCE),
// where the member's session cookie reaches the hub.
func marketingLinkedIn(ctx context.Context, hc *config.Hub, log zerolog.Logger, pmc *mail.Config, appURL string) *hub.MarketingLinkedIn {
	id, secret, key := strings.TrimSpace(hc.MarketingLinkedInClientID), strings.TrimSpace(hc.MarketingLinkedInClientSecret), strings.TrimSpace(hc.MarketingKMSKey)
	apiURL := strings.TrimRight(strings.TrimSpace(os.Getenv("SPOOL_HUB_OPERATOR_AUDIENCE")), "/")
	appURL = strings.TrimRight(appURL, "/")
	if id == "" || secret == "" || key == "" || appURL == "" || apiURL == "" {
		log.Info().Bool("client_id", id != "").Bool("client_secret", secret != "").Bool("kms_key", key != "").
			Bool("app_url", appURL != "").Bool("api_url", apiURL != "").Msg("marketing: linkedin off")
		return nil
	}
	kms, err := marketing.NewCloudKMS(ctx)
	if err != nil {
		log.Error().Err(err).Msg("marketing: linkedin off, no KMS client")
		return nil
	}
	sealer, err := marketing.NewSealer(kms, key)
	if err != nil {
		log.Error().Err(err).Msg("marketing: linkedin off")
		return nil
	}
	m := &hub.MarketingLinkedIn{
		LinkedIn: &marketing.LinkedIn{ClientID: id, ClientSecret: marketing.NewPlaintext(secret),
			RedirectURI: appURL + hub.LinkedInCallbackPath, Version: hc.MarketingLinkedInVersion},
		Sealer: sealer, AppURL: appURL, APIURL: apiURL,
	}
	if pmc != nil && pmc.Transport != mail.TransportNone {
		sender := pmc.Sender(log)
		m.Mail = func(ctx context.Context, to, subject, body string) error {
			return sender.Send(ctx, mail.Message{To: to, Subject: subject, TextBody: body, Template: "marketing_reconnect", Locale: "en"})
		}
	}
	log.Info().Str("redirect_uri", m.LinkedIn.RedirectURI).Bool("mail", m.Mail != nil).Msg("marketing: linkedin on")
	return m
}
