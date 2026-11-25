package action

import (
	"context"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 058 section 7 (SPL-6513): `spool send --record-of <msg_id>` keeps the
// msg_id and goes on a record_only frame; the flags that route or attach are
// refused before any dial.

func TestSendRecordOfHub(t *testing.T) {
	h := newVerbHub(t)
	cfg := hubCfg(t, h)
	res, err := SendCtx(context.Background(), cfg, SendArgs{From: "CLE-1", To: "CLE-2", Kind: "note", Body: "same box", RecordOf: askID})
	if err != nil {
		t.Fatal(err)
	}
	f := h.last(t)
	if !f.RecordOnly || wire.InnerMsgID(f.Env) != askID || res.MsgID != askID {
		t.Fatalf("frame record_only %v msg %s, result %+v; want a record of %s", f.RecordOnly, wire.InnerMsgID(f.Env), res, askID)
	}
}

func TestSendRecordOfRefused(t *testing.T) {
	hub := testkit.NewConfig(t)
	hub.HubURL = "http://127.0.0.1:1"
	local := testkit.NewConfig(t)
	base := SendArgs{From: "CLE-1", To: "CLE-2", Kind: "note", Body: "b", RecordOf: askID}
	with := func(f func(*SendArgs)) SendArgs { a := base; f(&a); return a }
	for _, c := range []struct {
		name string
		hub  bool
		in   SendArgs
		want string
	}{
		{"local mode", false, base, "needs hub mode"},
		{"not a uuid", true, with(func(a *SendArgs) { a.RecordOf = "nope" }), "must be the msg_id"},
		{"to-box", true, with(func(a *SendArgs) { a.ToBox = "box-b" }), "no --to-box"},
		{"channel", true, with(func(a *SendArgs) { a.Channel = "ops" }), "no --to-box"},
		{"attachment", true, with(func(a *SendArgs) { a.FileRefs = []string{"/x"} }), "no attachments"},
	} {
		cfg := local
		if c.hub {
			cfg = hub
		}
		_, err := SendCtx(context.Background(), cfg, c.in)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err %v, want %q", c.name, err, c.want)
		}
	}
}
