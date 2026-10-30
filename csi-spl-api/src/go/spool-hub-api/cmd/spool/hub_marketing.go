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

// marketingMeta builds the Facebook Page + Instagram connect (spec 090 T033,
// SPL-4254), or nil while the Meta app's id, its secret, the KMS key or the
// WUI origin is not set (cnf marketing.facebook.inject "false"): then every
// /v1/marketing/facebook route answers 503 not_configured. The redirect URI
// is the WUI origin's callback, registered in the Meta app (meta-app-setup.md
// step 3). The dispatcher (T034) mails a failure or a refused token through
// the mail relay, with the re-connect link on the hub's public origin.
func marketingMeta(ctx context.Context, hc *config.Hub, log zerolog.Logger, pmc *mail.Config, appURL string) *hub.MarketingMeta {
	id, secret, key := strings.TrimSpace(hc.MarketingFacebookAppID), strings.TrimSpace(hc.MarketingFacebookClientSecret), strings.TrimSpace(hc.MarketingKMSKey)
	appURL = strings.TrimRight(strings.TrimSpace(appURL), "/")
	if id == "" || secret == "" || key == "" || appURL == "" {
		log.Info().Bool("app_id", id != "").Bool("client_secret", secret != "").Bool("kms_key", key != "").
			Bool("app_url", appURL != "").Msg("marketing: meta off, connect answers 503")
		return nil
	}
	meta := &marketing.Meta{AppID: id, AppSecret: marketing.NewPlaintext(secret), RedirectURI: appURL + hub.MetaCallbackPath,
		Version: strings.TrimSpace(hc.MarketingFacebookAPIVersion), Scopes: strings.TrimSpace(hc.MarketingFacebookScopes)}
	if _, err := meta.AuthorizeURL(""); err != nil {
		log.Error().Err(err).Msg("marketing: meta off, connect answers 503")
		return nil
	}
	kms, err := marketing.NewCloudKMS(ctx)
	if err != nil {
		log.Error().Err(err).Msg("marketing: meta off, no KMS client, connect answers 503")
		return nil
	}
	sealer, err := marketing.NewSealer(kms, key)
	if err != nil {
		log.Error().Err(err).Msg("marketing: meta off, connect answers 503")
		return nil
	}
	m := &hub.MarketingMeta{Meta: meta, Sealer: sealer, AppURL: appURL,
		APIURL: strings.TrimRight(strings.TrimSpace(os.Getenv("SPOOL_HUB_OPERATOR_AUDIENCE")), "/")}
	if pmc != nil && pmc.Transport != mail.TransportNone {
		sender := pmc.Sender(log)
		m.Mail = func(ctx context.Context, to, subject, body string) error {
			return sender.Send(ctx, mail.Message{To: to, Subject: subject, TextBody: body, Template: "marketing_reconnect", Locale: "en"})
		}
	}
	log.Info().Str("redirect_uri", meta.RedirectURI).Bool("mail", m.Mail != nil).Msg("marketing: meta on")
	return m
}
