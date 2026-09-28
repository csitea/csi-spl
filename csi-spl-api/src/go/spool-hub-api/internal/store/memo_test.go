package store

import (
	"context"
	"errors"
	"testing"
)

// the request memo answers a repeated membership read from the
// first one, and nothing outlives the request. CONTROLS: a fresh request reads
// again (a demotion bites on the next request), a transient error is never
// memoised, and a context without a memo always reads.
func TestMemberRoleMemo(t *testing.T) {
	loads := 0
	role := "developer"
	var fail error
	load := func() (string, error) {
		loads++
		if fail != nil {
			return "", fail
		}
		return role, nil
	}
	ask := func(ctx context.Context) (string, error) { return memberRole(ctx, "HUM-1", "t1", load) }

	req := WithMemo(context.Background())
	if WithMemo(req) != req {
		t.Fatal("WithMemo on a memo context must keep the one memo")
	}
	for i := 0; i < 3; i++ {
		if r, err := ask(req); r != "developer" || err != nil {
			t.Fatalf("ask %d: %q %v", i, r, err)
		}
	}
	if loads != 1 {
		t.Fatalf("one request, three asks: %d loads, want 1", loads)
	}
	if r, _ := memberRole(req, "HUM-2", "t1", load); r != "developer" || loads != 2 {
		t.Fatalf("another human is another key: loads %d", loads)
	}

	// CONTROL: the next request sees a demotion at once.
	role = "tester"
	if r, _ := ask(WithMemo(context.Background())); r != "tester" {
		t.Fatalf("next request read %q, want the demoted role", r)
	}

	// CONTROL: a transient error is not memoised; ErrNotFound is.
	req = WithMemo(context.Background())
	fail = errors.New("conn reset")
	if _, err := ask(req); err == nil {
		t.Fatal("error swallowed")
	}
	fail = nil
	if r, err := ask(req); r != "tester" || err != nil {
		t.Fatalf("after a transient error the same request must read again: %q %v", r, err)
	}
	req = WithMemo(context.Background())
	fail = ErrNotFound
	ask(req) //nolint:errcheck
	fail = nil
	if _, err := ask(req); !errors.Is(err, ErrNotFound) {
		t.Fatalf("not-a-member within one request: %v", err)
	}

	// CONTROL: no memo, no memoising.
	before := loads
	ask(context.Background()) //nolint:errcheck
	ask(context.Background()) //nolint:errcheck
	if loads != before+2 {
		t.Fatalf("without a memo every ask reads: %d loads, want %d", loads-before, 2)
	}
}
