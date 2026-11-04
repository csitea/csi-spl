// SPDX-License-Identifier: AGPL-3.0-only

package hub

import (
	"context"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// issueMoveJSON is one moved issue key of the session's workspace (spec 169
// W4, row T7g). Live is the hub's clock against the row's expiry, the same
// rule as a moved task's redirect (Q2 = A: 30 days, then nothing).
type issueMoveJSON struct {
	OldKey    string `json:"old_key"`
	Dst       string `json:"dst"`
	NewKey    string `json:"new_key"`
	ExpiresAt string `json:"expires_at"`
	Live      bool   `json:"live"`
}

// agentIssueMoves is the agent issue op moved: every kind issue row of
// channel_move_redirects whose <SRC> is the session's workspace, live and
// expired. A store with no map answers 503, never an empty list: the closer
// would read an empty one as "nothing moved" and close on that guess.
func (s *Server) agentIssueMoves(ctx context.Context, tenant string) (any, *issueErr) {
	ms, ok := s.o.Store.(store.IssueMoves)
	if !ok {
		return nil, &issueErr{http.StatusServiceUnavailable, "unavailable", "this hub keeps no moved issue keys"}
	}
	rows, err := ms.IssueMoves(ctx, tenant)
	if err != nil {
		return nil, &issueErr{http.StatusServiceUnavailable, "unavailable", "the moved issue keys could not be read; try again"}
	}
	now := s.o.Now()
	out := make([]issueMoveJSON, 0, len(rows))
	for _, m := range rows {
		out = append(out, issueMoveJSON{OldKey: m.OldKey, Dst: m.Dst, NewKey: m.NewKey,
			ExpiresAt: m.ExpiresAt.UTC().Format(time.RFC3339), Live: m.Live(now)})
	}
	return map[string]any{"moved": out}, nil
}
