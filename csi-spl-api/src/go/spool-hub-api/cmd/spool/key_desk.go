package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/keydesk"
)

// keyDeskTick is how often the desk expires leases and sweeps seat dirs.
const keyDeskTick = 30 * time.Second

// startKeyDesk runs the desk key socket of spec 127 X1 inside the hub-run
// sidecar when SPOOL_KEY_DESK=1 (a workspace desk on a fleet box, spec 159
// 5.2). Its socket is keydesk.SockPath(<hub dir>), the path a seat's
// launcher passes as $SPOOL_KEY_SOCK. Off (the default) it does nothing,
// so no fleet desk changes. A desk that cannot start is logged and the
// sidecar goes on: with no socket no seat gets a key, which is closed.
func startKeyDesk(ctx context.Context, cfg *config.Config, c *hubclient.Client) {
	if os.Getenv("SPOOL_KEY_DESK") != "1" {
		return
	}
	s, err := keyDeskServer(cfg, c)
	if err != nil {
		c.Log.Error().Err(err).Msg("key desk not started")
		return
	}
	go func() {
		if err := s.Run(ctx, keyDeskTick); err != nil {
			c.Log.Error().Err(err).Msg("key desk stopped")
		}
	}()
}

// keyDeskServer builds the desk from the environment: SPOOL_SEAT_ROOT
// (default /run/user/<uid>/spool-seat, 127 5.4), SPOOL_KEY_LEASE_TTL (a Go
// duration, default 15m) and the desk's X25519 identity in its hub dir.
func keyDeskServer(cfg *config.Config, c *hubclient.Client) (*keydesk.Server, error) {
	seats := os.Getenv("SPOOL_SEAT_ROOT")
	if seats == "" {
		seats = filepath.Join("/run/user", strconv.Itoa(os.Getuid()), "spool-seat")
	}
	ttl := 15 * time.Minute
	if v := os.Getenv("SPOOL_KEY_LEASE_TTL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			return nil, fmt.Errorf("SPOOL_KEY_LEASE_TTL %q is not a positive duration", v)
		}
		ttl = d
	}
	if err := os.MkdirAll(cfg.HubDir(), 0o700); err != nil {
		return nil, err
	}
	id, err := keydesk.LoadOrCreateIdentity(filepath.Join(cfg.HubDir(), "desk-x25519.key"))
	if err != nil {
		return nil, err
	}
	c.Log.Info().Str("recipient", id.Recipient().String()).Str("seat_root", seats).Msg("key desk up")
	return &keydesk.Server{
		Path: keydesk.SockPath(cfg.HubDir()), SeatRoot: seats, Box: cfg.BoxID,
		Hub: hubclient.VendorKeyHub{C: c}, Identity: id, TTL: ttl,
		Log: func(l string) { c.Log.Warn().Msg(l) },
	}, nil
}
