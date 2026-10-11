package action

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// Spec 130 section 5: the Flow is hub-only and needs the acting agent; the
// rest goes to the hub (internal/hub TestAgentFlowRead drives it end to end).
func TestFlowArgs(t *testing.T) {
	ctx := context.Background()
	if _, err := Flow(ctx, &config.Config{}, FlowArgs{As: "c-007"}); err == nil || !strings.Contains(err.Error(), "hub mode") {
		t.Fatalf("folder mode: %v", err)
	}
	cfg := &config.Config{HubURL: "http://127.0.0.1:1", BoxID: "box-a", KeysDir: t.TempDir(), SpoolRoot: t.TempDir()}
	if _, err := Flow(ctx, cfg, FlowArgs{}); err == nil || !strings.Contains(err.Error(), "--as") {
		t.Fatalf("no --as: %v", err)
	}
	// A hub that does not answer: the request is built and the dial fails.
	hc := hubclient.New(cfg)
	hc.ReadyTimeout = time.Second
	if _, err := Flow(ctx, cfg, FlowArgs{As: "c-007", Kind: "blocked", Limit: 5, Before: "cur", Hub: hc}); err == nil {
		t.Fatal("an unreachable hub answered")
	}
}
