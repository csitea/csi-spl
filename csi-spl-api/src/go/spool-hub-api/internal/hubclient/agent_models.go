package hubclient

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// AgentModelReading is one live reading of a vendor CLI's models (spec 184
// contract 7.1.6), as the box reports it with ReportAgentModels.
type AgentModelReading struct {
	Vendor     string    `json:"-"`
	CLIVersion string    `json:"cli_version"`
	Models     []string  `json:"models"`
	ReadAt     time.Time `json:"read_at"`
}

// ReportAgentModels sends r to the hub (spec 184 row H2, contract 7.1.5):
// PUT /v1/boxes/{box}/agent-models/{vendor} on this box's own upload token,
// {box} = Cfg.BoxID. stored is the hub's answer: false when it already holds
// a reading of that box and vendor that is as new or newer. A hub refusal is
// a *HubError with the hub's token (door, box_mismatch, bad_reading, ...).
func (c *Client) ReportAgentModels(ctx context.Context, r AgentModelReading) (stored bool, err error) {
	if r.Models == nil {
		r.Models = []string{}
	}
	body, err := json.Marshal(r)
	if err != nil {
		return false, err
	}
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return false, err
	}
	defer sess.Close()
	var a struct {
		Stored bool `json:"stored"`
	}
	path := "/v1/boxes/" + url.PathEscape(c.Cfg.BoxID) + "/agent-models/" + url.PathEscape(r.Vendor)
	if err := sess.rest(ctx, http.MethodPut, path, bytes.NewReader(body), &a); err != nil {
		return false, err
	}
	return a.Stored, nil
}
