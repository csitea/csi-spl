package main

import (
	"context"
	"strings"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
)

// gcalConnect builds the Google Calendar connect wiring (spec 149 B5,
// SPL-3208). nil while cnf gcal.workspaces is empty: no route is mounted.
// Listed but missing the Google client, an endpoint, the scopes or the KMS
// key: the routes answer and connect says 503 gcal_not_configured. The
// client is the sign-in one (P2); its redirect URI is the WUI origin's
// callback, which the owner registers on it (S3).
func gcalConnect(ctx context.Context, hc *config.Hub, ac *auth.Config, log zerolog.Logger) *hub.GcalConnect {
	if len(hc.GcalWorkspaces) == 0 {
		log.Info().Msg("gcal: off, no workspace listed")
		return nil
	}
	appURL := strings.TrimRight(strings.TrimSpace(ac.AppURL), "/")
	apex := ""
	if hc.WUITenantHosts {
		apex = hc.WUIApexTenant
	}
	g := &hub.GcalConnect{
		Workspaces: hc.GcalWorkspaces,
		CookieName: ac.StateCookieName, CookieDomain: ac.CookieDomain, CookieSecure: ac.CookieSecure,
		WorkspaceURL:  hub.GcalWorkspaceURL(hc.TenantHostPattern, apex, appURL),
		ReadCalendars: hub.GcalReadsCalendars(hc.GcalScopes),
	}
	google, err := gcal.New(gcal.Config{
		ClientID: strings.TrimSpace(ac.GoogleClientID), ClientSecret: marketing.NewPlaintext(strings.TrimSpace(ac.GoogleClientSecret)),
		RedirectURI: appURL + hub.GcalCallbackPath, Scopes: strings.TrimSpace(hc.GcalScopes),
		AuthURL: hc.GcalAuthURL, TokenURL: hc.GcalTokenURL, RevokeURL: hc.GcalRevokeURL,
		UserinfoURL: hc.GcalUserinfoURL, CalendarBase: hc.GcalCalendarBase,
	})
	if err != nil || appURL == "" {
		log.Warn().Bool("app_url", appURL != "").Str("err", errText(err)).Msg("gcal: not configured, connect answers 503")
		return g
	}
	key := strings.TrimSpace(hc.MarketingKMSKey)
	if key == "" {
		log.Warn().Msg("gcal: not configured, no KMS key, connect answers 503")
		return g
	}
	kms, err := marketing.NewCloudKMS(ctx)
	if err != nil {
		log.Error().Err(err).Msg("gcal: not configured, no KMS client, connect answers 503")
		return g
	}
	if g.Sealer, err = marketing.NewSealer(kms, key, marketing.WithPurpose(hub.GcalPurpose)); err != nil {
		log.Error().Err(err).Msg("gcal: not configured, connect answers 503")
		return g
	}
	g.Google = google
	log.Info().Int("workspaces", len(g.Workspaces)).Str("redirect_uri", appURL+hub.GcalCallbackPath).Msg("gcal: on")
	return g
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
