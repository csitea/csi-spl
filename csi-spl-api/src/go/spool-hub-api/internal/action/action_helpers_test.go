// Test-only helpers moved from production code.

package action

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// Send builds the attachments and writes the message: locally (no hub), or in
// hub mode ($SPOOL_HUB_URL set) through the box-signed envelope. It is the
// test/legacy entry (no non-test caller); SendCtx is the API.
//
// Deprecated: use SendCtx instead.
func Send(cfg *config.Config, in SendArgs) (SendResult, error) {
	return SendCtx(context.Background(), cfg, in)
}
