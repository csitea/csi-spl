package action

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// SPL t1 1457bb6f: the topic list is hub-only and needs the acting agent and
// a channel; the rest goes to the hub (internal/hub topics_agent_test.go
// drives it end to end).
func TestTopicsArgs(t *testing.T) {
	ctx := context.Background()
	if _, err := Topics(ctx, &config.Config{}, TopicsArgs{As: "c-007", Channel: "x"}); err == nil || !strings.Contains(err.Error(), "hub mode") {
		t.Fatalf("folder mode: %v", err)
	}
	cfg := &config.Config{HubURL: "http://127.0.0.1:1", BoxID: "box-a", KeysDir: t.TempDir(), SpoolRoot: t.TempDir()}
	if _, err := Topics(ctx, cfg, TopicsArgs{Channel: "x"}); err == nil || !strings.Contains(err.Error(), "--as") {
		t.Fatalf("no --as: %v", err)
	}
	if _, err := Topics(ctx, cfg, TopicsArgs{As: "c-007", Channel: "#"}); err == nil || !strings.Contains(err.Error(), "--channel") {
		t.Fatalf("a bare '#' channel: %v", err)
	}
	// A hub that does not answer: the request is built and the dial fails.
	hc := hubclient.New(cfg)
	hc.ReadyTimeout = time.Second
	if _, err := Topics(ctx, cfg, TopicsArgs{As: "c-007", Channel: "#refactoring", Limit: 5, Before: "cur", Hub: hc}); err == nil {
		t.Fatal("an unreachable hub answered")
	}
}
