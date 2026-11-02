package hubclient

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 169 T7b, Q2: for 30 days a post to a moved topic is re-routed. A box key
// is live in one workspace only (rdb 0154), so the hub only refuses and names
// the workspace (T7); this client sends the post once through the agent's desk
// there, the same inner msg (task id and msg id, F4, F10) under that desk's key.
//
// Nothing is remembered: every post asks <SRC> first, so nothing outlives the
// redirect. Once it expires <SRC> answers 404 with no destination, and the post
// is refused and reported like any other that has nowhere to go.
//
// A retry is safe: the same inner msg under the same key and to_box is the same
// envelope, and the hub stores it once per (tenant, msg_id).

// movedRefused acts on a post's topic_moved refusal: the one re-route, or the
// refusal reported. The error names the token and, when there is one, the
// destination (the hub's detail).
func (c *Client) movedRefused(ctx context.Context, env *wire.Envelope, m *msg.Message, pending string, cl Claims, he *HubError) (string, error) {
	dc, e2, err := c.movedTarget(env, m, he, cl.Rerouted)
	if err != nil {
		return "", c.refuseMoved(pending, m, err)
	}
	cl.Rerouted = c.Cfg.TenantID()
	if cl.Rerouted == "" { // a legacy tenant host names none: the claim must still be set
		cl.Rerouted = "this box's workspace"
	}
	p2, err := dc.writePending(m, e2, cl)
	if err != nil {
		return "", fmt.Errorf("re-route to %s: %w", dc.Cfg.TenantID(), err) // still pending here: the next flush retries
	}
	removePending(pending)
	dc.deskOutbox(m)
	c.Log.Info().Str("msg_id", m.MsgID).Str("task_id", m.TaskID).Str("tenant", dc.Cfg.TenantID()).
		Msg("re-routed a post to a moved topic through its desk")
	d, err := dc.sendNow(ctx, e2, m, p2, cl)
	var dhe *HubError
	if errors.As(err, &dhe) && dhe.clientError() { // the desk rejected and told its own seat
		c.tellMoved(m, err)
	}
	return d, err
}

// answerMoved is movedRefused for an answer: never queued (SendAnswerMessage),
// so the desk's hub guard decides now and a refusal goes back to the caller.
func (c *Client) answerMoved(ctx context.Context, env *wire.Envelope, m *msg.Message, he *HubError, answers string, gen int64) (wire.Frame, error) {
	dc, e2, err := c.movedTarget(env, m, he, "")
	if err != nil {
		return wire.Frame{}, c.refuseMoved("", m, err)
	}
	sess, err := dc.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return wire.Frame{}, err
	}
	defer sess.Close()
	for _, a := range m.Files {
		if a.Mode == "blob" {
			if err := sess.UploadFile(ctx, a.FileID); err != nil {
				return wire.Frame{}, err
			}
		}
	}
	f, err := sess.SendAnswer(ctx, e2, answers, gen)
	if err != nil {
		return f, c.refuseMoved("", m, fmt.Errorf("the answer was refused in %s too: %w", dc.Cfg.TenantID(), err))
	}
	dc.deskOutbox(m)
	return f, nil
}

// movedTarget is the desk and the envelope of the one re-route; an error wrapping
// he says why there is none.
func (c *Client) movedTarget(env *wire.Envelope, m *msg.Message, he *HubError, rerouted string) (*Client, *wire.Envelope, error) {
	tenant, _, ok := wire.ParseMovedDetail(he.Detail)
	switch {
	case rerouted != "":
		return nil, nil, fmt.Errorf("a second topic_moved, one hop only (first refused in %s): %w", rerouted, he)
	case he.Status != http.StatusConflict || !ok:
		return nil, nil, fmt.Errorf("the refusal names no destination: %w", he)
	}
	dc, err := c.movedDesk(tenant, m)
	if err != nil {
		return nil, nil, fmt.Errorf("%w: %w", err, he)
	}
	e2, err := dc.deskEnvelope(env, m)
	if err != nil {
		return nil, nil, fmt.Errorf("desk %s in %s: %w: %w", dc.Cfg.BoxID, tenant, err, he)
	}
	if err := c.copyBlobs(dc, m); err != nil {
		return nil, nil, fmt.Errorf("desk %s in %s: %w: %w", dc.Cfg.BoxID, tenant, err, he)
	}
	return dc, e2, nil
}

// movedDesk is the client of m.From's desk in tenant. Only that tenant's desk and
// only with a seat for that agent: there is no fallback to another key or tenant.
func (c *Client) movedDesk(tenant string, m *msg.Message) (*Client, error) {
	if c.MovedDesk == nil {
		return nil, fmt.Errorf("no desk of %s in %s on this box: this client resolves no desks", m.From, tenant)
	}
	cfg, err := c.MovedDesk(tenant)
	if err != nil {
		return nil, fmt.Errorf("no desk of %s in %s on this box: %w", m.From, tenant, err)
	}
	if got := cfg.TenantID(); got != tenant {
		return nil, fmt.Errorf("no desk of %s in %s on this box: the desk found is in %q", m.From, tenant, got)
	}
	if !spool.New(cfg).KnownLocal(m.From) {
		return nil, fmt.Errorf("no desk of %s in %s on this box: desk %s has no seat for it", m.From, tenant, cfg.BoxID)
	}
	dc := New(cfg) // resolves no desks: a second refusal stops at it, as the claim says
	dc.ReadyTimeout, dc.KeepAlive = c.ReadyTimeout, c.KeepAlive
	return dc, nil
}

// deskEnvelope signs the same inner msg and tags with the desk's key.
func (c *Client) deskEnvelope(env *wire.Envelope, m *msg.Message) (*wire.Envelope, error) {
	own, priv, err := c.box()
	if err != nil {
		c.Log.Error().Err(err).Str("box", c.Cfg.BoxID).Msg("the desk key of a re-route does not load")
		return nil, errors.New("its key does not load")
	}
	toBox, err := c.deskToBox(env, m)
	if err != nil {
		return nil, fmt.Errorf("cannot place %s there: %w", m.To, err)
	}
	e2 := &wire.Envelope{FromBox: own, ToBox: toBox, Channel: env.Channel, ParentTaskID: env.ParentTaskID, Msg: env.Msg}
	p, err := e2.SigningPayload()
	if err != nil {
		return nil, err
	}
	e2.Sig = sign.Sign(priv, p)
	return e2, nil
}

// deskToBox is the to_box in the desk's workspace: box-wui and the peers' box mean
// the same everywhere, any other box id only if that workspace's roster says so.
func (c *Client) deskToBox(env *wire.Envelope, m *msg.Message) (string, error) {
	if env.ToBox == wuiBox || env.ToBox == msg.PeersToBox {
		return env.ToBox, nil
	}
	for _, a := range c.loadRoster()[env.ToBox] {
		if a == m.To {
			return env.ToBox, nil
		}
	}
	return c.ResolveToBox(m.To, "")
}

// copyBlobs puts m's blobs in the desk's store: it uploads from there.
func (c *Client) copyBlobs(dc *Client, m *msg.Message) error {
	for _, a := range m.Files {
		if a.Mode != "blob" {
			continue
		}
		dst := filepath.Join(dc.Cfg.FilesDir(), a.FileID)
		if _, err := os.Stat(dst); err == nil {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(c.Cfg.FilesDir(), a.FileID))
		if err != nil {
			return fmt.Errorf("blob %s is not in the local store: %w", a.FileID, err)
		}
		if err := writeAtomic(dst, raw); err != nil {
			return fmt.Errorf("blob %s not copied: %w", a.FileID, err)
		}
	}
	return nil
}

// deskOutbox records the re-routed post in the seat's outbox on the desk. The post
// is already on its way: a failure is logged only.
func (c *Client) deskOutbox(m *msg.Message) {
	if err := spool.New(c.Cfg).WriteOutbox(m); err != nil {
		c.Log.Warn().Err(err).Str("msg_id", m.MsgID).Msg("re-route: no outbox copy on the desk")
	}
}

// refuseMoved ends a post refused as moved: out of pending/ with its reason, and
// the agent told. The returned error tells the caller, when there is one.
func (c *Client) refuseMoved(pending string, m *msg.Message, why error) error {
	err := fmt.Errorf("post to a moved topic NOT sent: %w", why)
	c.reject(pending, err)
	c.tellMoved(m, err)
	return err
}

// tellMoved puts a reject in the sending agent's inbox here and rings its pane: a
// queued post has no caller left, so this is how the agent learns.
func (c *Client) tellMoved(m *msg.Message, why error) {
	from, _, _ := strings.Cut(m.From, "@")
	st := spool.New(c.Cfg)
	body := fmt.Sprintf("Your %s (msg %s) on task %s: %v", m.Kind, m.MsgID, m.TaskID, why)
	rej, err := st.Compose(from, from, m.TaskID, "reject", body, nil)
	if err == nil {
		_, err = st.Deliver(rej)
	}
	if err != nil {
		c.Log.Error().Err(err).Str("msg_id", m.MsgID).Str("agent", from).
			Msg("a post to a moved topic was refused and its agent could not be told")
	}
}
