package hubclient

// SPL-5735: an announce refusal is answered by nobody's request, and the hub
// sent it as an error frame with no msg_id. sendFrame takes such a frame as
// its own answer, so a send in flight while the box re-announced reported
// the roster's refusal although the hub stored the post (the desk reply
// cross-talk of SPL-5642 / SPL-5644). Each case below has the hub answer the
// send with the announce refusal first and the send's own sent frame after.

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// arSend has a role=box session send one message to a hub that writes first
// before the send's own sent frame; it returns the send's frame and error
// and the session's announce refusals.
func arSend(t *testing.T, first wire.Frame) (wire.Frame, []error, error) {
	t.Helper()
	h := &opsHub{reply: func(f wire.Frame) []wire.Frame {
		if f.Type != wire.TSend {
			return opsReply(f)
		}
		return []wire.Frame{first, {Type: wire.TSent, MsgID: wire.InnerMsgID(f.Env), Delivery: wire.DeliverySent}}
	}}
	c := opsClient(t, h)
	_, priv, err := c.box()
	if err != nil {
		t.Fatal(err)
	}
	env, err := wire.NewEnvelope(priv, "box-a", "box-b", compose(t, c, "posted while the roster was refused"))
	if err != nil {
		t.Fatal(err)
	}
	s := srSession(t, c, wire.RoleBox)
	f, err := s.Send(context.Background(), env)
	return f, s.AnnounceRefusals(), err
}

func TestAnnounceRefusalDoesNotAnswerASend(t *testing.T) {
	cases := []struct {
		name  string
		first wire.Frame
	}{
		// an older hub: the refusals onAnnounce wrote as a msg_id-less error
		{"old hub, bot seat cap", wire.Frame{Type: wire.TError, Error: billing.TokenQuota, Status: billing.HTTPSeatQuota, Detail: wire.DetailAnnounceSeatCap}},
		{"old hub, roster_duplicate", wire.Frame{Type: wire.TError, Error: wire.TokenRosterDuplicate, Status: http.StatusConflict, Detail: wire.DetailAnnounceDuplicate}},
		{"old hub, roster not stored", wire.Frame{Type: wire.TError, Error: "internal", Status: http.StatusInternalServerError, Detail: wire.DetailAnnounceRosterNotStored}},
		{"old hub, subscriptions not stored", wire.Frame{Type: wire.TError, Error: "internal", Status: http.StatusInternalServerError, Detail: wire.DetailAnnounceSubsNotStored}},
		// this hub: its own frame type, which an older client never matches
		{"announce_error frame", wire.Frame{Type: wire.TAnnounceError, Error: billing.TokenQuota, Status: billing.HTTPSeatQuota, Detail: wire.DetailAnnounceSeatCap}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, refused, err := arSend(t, tc.first)
			if err != nil {
				t.Fatalf("the send reported the announce refusal as its own: %v", err)
			}
			if f.Type != wire.TSent || f.Delivery != wire.DeliverySent {
				t.Fatalf("send answer %+v, want its sent frame", f)
			}
			if len(refused) != 1 || !strings.Contains(refused[0].Error(), tc.first.Error) {
				t.Fatalf("announce refusals %v, want the one the hub wrote (%s)", refused, tc.first.Error)
			}
		})
	}
}

// CONTROL: a send's own refusal with no msg_id (the hub's bad_json before
// the envelope parses, and the scripted hubs of this package) still answers
// the send, and is no announce refusal.
func TestUnkeyedSendRefusalStillAnswersTheSend(t *testing.T) {
	forbidden := wire.Frame{Type: wire.TError, Error: "forbidden", Status: http.StatusForbidden, Detail: "not yours"}
	_, refused, err := arSend(t, forbidden)
	var he *HubError
	if !errors.As(err, &he) || he.Token != "forbidden" {
		t.Fatalf("send error %v, want the hub's forbidden", err)
	}
	if len(refused) != 0 {
		t.Fatalf("a send refusal was taken as an announce refusal: %v", refused)
	}
}
