package hub_test

import (
	"context"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestQuotaPeriodBoundaryAndResend (027 T040 CONTROLS): the month quota read
// from the period counters refuses exactly as the row count did. At quota 1:
// a resend of the stored msg_id gets the same sent reply as the first send; a
// new message is refused 429 until the clock crosses billing.PeriodStart of
// the next month, then one more is admitted and the next refused again.
func TestQuotaPeriodBoundaryAndResend(t *testing.T) {
	next := billing.PeriodStart(time.Now()).AddDate(0, 1, 0)
	var clock atomic.Int64
	clock.Store(next.Add(-time.Minute).UnixNano())
	e := newEnv(t, func(o *hub.Options) {
		o.QuotaMessagesPerMonth = 1
		o.HelloSkew = 62 * 24 * time.Hour // the box signs hellos with the real clock
		o.Now = func() time.Time { return time.Unix(0, clock.Load()).UTC() }
	})
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	sess, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	envelope := func(body string) *wire.Envelope {
		t.Helper()
		m, err := spool.New(a.cfg).Compose("GRK-03", "CLE-07", "", "note", body, nil)
		if err != nil {
			t.Fatal(err)
		}
		env, err := wire.NewEnvelope(priv, "box-a", "box-b", m)
		if err != nil {
			t.Fatal(err)
		}
		return env
	}
	refused := func(what string, env *wire.Envelope) {
		t.Helper()
		var he *hubclient.HubError
		if _, err := sess.Send(ctx, env); !errors.As(err, &he) || he.Token != billing.TokenQuota || he.Status != http.StatusTooManyRequests {
			t.Fatalf("%s: want 429 quota, got %v", what, err)
		}
	}

	first := envelope("one")
	r1, err := sess.Send(ctx, first)
	if err != nil {
		t.Fatalf("first send: %v", err)
	}
	r2, err := sess.Send(ctx, first)
	if err != nil {
		t.Fatalf("resend at the quota: %v", err)
	}
	if r1.Type != r2.Type || r1.MsgID != r2.MsgID || r1.TaskID != r2.TaskID || r1.ToBox != r2.ToBox || r1.Delivery != r2.Delivery {
		t.Fatalf("resend reply %+v differs from the first %+v", r2, r1)
	}
	refused("second message, last minute of the period", envelope("two"))

	clock.Store(next.UnixNano())
	if _, err := sess.Send(ctx, envelope("three")); err != nil {
		t.Fatalf("first message of the next period: %v", err)
	}
	refused("second message of the next period", envelope("four"))
}
