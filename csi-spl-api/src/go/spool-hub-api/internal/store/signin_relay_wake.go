package store

import (
	"context"
	"errors"
)

// Spec 181 row B11: the sign-in relay's NOTIFY channel. A web-UI request
// may land on one hub instance while the VM's role=box socket is held by
// another, so every relay event is announced to every instance, this one
// too, on the listen connection RunWake already holds; the instance that
// holds the VM's socket writes its frame. Memory fans it out in process,
// as for the box sample.
//
// The payload is opaque here (the hub's JSON event). It is never stored:
// no table, no row. An input event carries only ciphertext sealed to the
// VM's desk recipient, never the person's input in the clear.

// SigninRelayChannel is the Postgres NOTIFY channel of the sign-in relay.
const SigninRelayChannel = "spool_signin_relay"

// SigninRelayMaxPayload is the largest payload announced: Postgres refuses
// a NOTIFY payload of 8000 bytes or more.
const SigninRelayMaxPayload = 7000

// ErrSigninRelayPayload is an empty or oversized payload.
var ErrSigninRelayPayload = errors.New("sign-in relay event: empty or over SigninRelayMaxPayload bytes")

// SigninRelayWaker is implemented by stores that carry the relay's events.
// Its listener is WakeHandlers.SigninRelay, on ListenAll's connection.
type SigninRelayWaker interface {
	// AnnounceSigninRelay tells every listener, this process's too, about
	// one relay event.
	AnnounceSigninRelay(ctx context.Context, payload string) error
}

var (
	_ SigninRelayWaker = (*Memory)(nil)
	_ SigninRelayWaker = (*Postgres)(nil)
)

func checkSigninRelayPayload(p string) error {
	if p == "" || len(p) > SigninRelayMaxPayload {
		return ErrSigninRelayPayload
	}
	return nil
}

// notifySigninRelay fans p out to the in-process listeners.
func (w *memWake) notifySigninRelay(p string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, sub := range w.subs {
		if sub.relay != nil {
			go sub.relay(p)
		}
	}
}

// AnnounceSigninRelay fans p out to every in-process listener.
func (s *Memory) AnnounceSigninRelay(_ context.Context, p string) error {
	if err := checkSigninRelayPayload(p); err != nil {
		return err
	}
	s.wake.notifySigninRelay(p)
	return nil
}

// AnnounceSigninRelay sends the NOTIFY on a pooled connection: it reads no
// tenant table, so it needs no tenant scope.
func (s *Postgres) AnnounceSigninRelay(ctx context.Context, p string) error {
	if err := checkSigninRelayPayload(p); err != nil {
		return err
	}
	_, err := s.pool.Exec(ctx, `SELECT pg_notify('`+SigninRelayChannel+`', $1)`, p)
	return err
}
