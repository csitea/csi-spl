package cicdlogs

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// dnBus is a Bus whose Deliver counts its calls and returns err.
type dnBus struct {
	calls int
	err   error
}

func (b *dnBus) PutFile(context.Context, string, string, []byte) (msg.Attachment, error) {
	return msg.Attachment{}, nil
}

func (b *dnBus) Deliver(context.Context, string, *wire.Envelope) (string, error) {
	b.calls++
	if b.err != nil {
		return "", b.err
	}
	return wire.DeliveryQueued, nil
}

func dnService(t *testing.T, bus Bus) *Service {
	t.Helper()
	return &Service{Settings: enabled(t, "tok", "t1:acme/app"), Bus: bus, Signer: signer(t)}
}

// TestDeliverNoteWrongSizeSigner: a signer that is not an ed25519 private key
// is refused with ErrNoHubSigner before anything reaches the bus.
func TestDeliverNoteWrongSizeSigner(t *testing.T) {
	bus := &dnBus{}
	svc := dnService(t, bus)
	svc.Signer = svc.Signer[:16]
	res, err := svc.deliverNote(context.Background(), "t1", baseReq(), "body", nil, false, true)
	if !errors.Is(err, ErrNoHubSigner) {
		t.Fatalf("err = %v, want ErrNoHubSigner", err)
	}
	if res.Message != nil || bus.calls != 0 {
		t.Fatalf("res %+v, Deliver calls %d; want none", res, bus.calls)
	}
}

// TestDeliverNoteInvalidMessage: a request the message refuses (no valid
// recipient) returns that validation error and never delivers.
func TestDeliverNoteInvalidMessage(t *testing.T) {
	bus := &dnBus{}
	req := baseReq()
	req.To = ""
	res, err := dnService(t, bus).deliverNote(context.Background(), "t1", req, "body", nil, false, true)
	if err == nil || !strings.Contains(err.Error(), "not a valid agent id") {
		t.Fatalf("err = %v, want the to-validation error", err)
	}
	if res.Message != nil || bus.calls != 0 {
		t.Fatalf("res %+v, Deliver calls %d; want none", res, bus.calls)
	}
}

// TestDeliverNoteDeliverRefused: a refused Bus.Deliver is returned as is,
// with no Result.
func TestDeliverNoteDeliverRefused(t *testing.T) {
	refused := errors.New("bus refused")
	bus := &dnBus{err: refused}
	res, err := dnService(t, bus).deliverNote(context.Background(), "t1", baseReq(), "body", nil, false, true)
	if !errors.Is(err, refused) {
		t.Fatalf("err = %v, want %v", err, refused)
	}
	if bus.calls != 1 {
		t.Fatalf("Deliver calls %d, want 1", bus.calls)
	}
	if res.Message != nil || res.Delivery != "" || res.Configured {
		t.Fatalf("res %+v, want the zero Result", res)
	}
}
