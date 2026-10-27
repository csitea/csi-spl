package hubclient

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/keydesk"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// VendorKeyHub is the desk's hub half of a workspace key lease (spec 127
// 5.2 steps 2-3): POST /v1/vendor-keys/{kind}/lease, box-authenticated like
// every desk REST call, answers {"sealed":"<base64 age ciphertext>"} sealed
// to the desk's X25519 key (keydesk.Payload). The route is 127 H2's; until
// it is live a 404 reads as keydesk.TokNoLeaseRoute.
type VendorKeyHub struct{ C *Client }

// leaseAnswer is the hub's lease body. Only ciphertext crosses the wire.
type leaseAnswer struct {
	Sealed string `json:"sealed"`
}

// Lease asks the hub for kind's sealed key.
func (h VendorKeyHub) Lease(ctx context.Context, kind string) ([]byte, error) {
	var a leaseAnswer
	if err := h.post(ctx, "/v1/vendor-keys/"+kind+"/lease", &a); err != nil {
		return nil, err
	}
	b, err := base64.StdEncoding.DecodeString(a.Sealed)
	if err != nil || len(b) == 0 {
		return nil, &keydesk.Refused{Token: keydesk.TokBadSeal}
	}
	return b, nil
}

// Exhausted reports the vendor's refusal of kind (spec 159 9 point 1): the
// kind only, never the vendor's text.
func (h VendorKeyHub) Exhausted(ctx context.Context, kind string) error {
	return h.post(ctx, "/v1/vendor-keys/"+kind+"/exhausted", nil)
}

// post runs one box-authenticated POST; a hub refusal becomes
// keydesk.Refused with the hub's token, a 404 TokNoLeaseRoute.
func (h VendorKeyHub) post(ctx context.Context, path string, out any) error {
	sess, err := h.C.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return err
	}
	defer sess.Close()
	err = sess.rest(ctx, http.MethodPost, path, nil, out)
	var he *HubError
	if errors.As(err, &he) {
		if he.Status == http.StatusNotFound {
			return &keydesk.Refused{Token: keydesk.TokNoLeaseRoute}
		}
		return &keydesk.Refused{Token: he.Token}
	}
	return err
}

// redactKeys removes every vendor key this box root's desk handed out from
// an outbound body (spec 127 L9, the desk half), before any copy of it is
// written or sent. The terminal mirror posts through spool send, so it is
// covered too. A box root with no key desk passes the body as it is; a key
// socket that does not answer refuses the send (keydesk.RedactVia).
func (c *Client) redactKeys(ctx context.Context, m *msg.Message) error {
	body, err := keydesk.RedactVia(ctx, keydesk.SockPath(c.Cfg.HubDir()), m.Body)
	if err != nil {
		return err
	}
	m.Body = body
	return nil
}
