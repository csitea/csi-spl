package wire

// Fleet seating (spec 158 section 4.2 items 3 and 4, build row T7): a fleet
// desk box proves itself with the key it holds in the operator workspace.
//
//	GET  /v1/fleet/workspaces  headers FleetBoxHeader, FleetTSHeader, FleetSigHeader:
//	                           the operator-workspace box key's signature over
//	                           FleetWorkspacesPayload
//	POST /v1/fleet/enrol       FleetEnrolRequest: SigOp by the operator-workspace
//	                           box key and SigNew by the new key, both over
//	                           FleetEnrolPayload

// The headers of a signed GET /v1/fleet/workspaces.
const (
	FleetBoxHeader = "X-Spool-Fleet-Box"
	FleetTSHeader  = "X-Spool-Fleet-Ts"
	FleetSigHeader = "X-Spool-Fleet-Sig"
)

// FleetWorkspacesPayload is what the box signs to list the fleet workspaces:
// jq -cS '{box_id,op:"fleet_workspaces",ts}'.
func FleetWorkspacesPayload(boxID, ts string) ([]byte, error) {
	return Canonical(map[string]string{"box_id": boxID, "op": "fleet_workspaces", "ts": ts})
}

// FleetEnrolPayload is what both keys sign to enrol pubkey into tenant as
// boxID: jq -cS '{box_id,op:"fleet_enrol",pubkey,tenant,ts}'. The workspace
// is signed, so a signature for one workspace never enrols into another.
func FleetEnrolPayload(tenant, boxID, pubkey, ts string) ([]byte, error) {
	return Canonical(map[string]string{"box_id": boxID, "op": "fleet_enrol", "pubkey": pubkey,
		"tenant": tenant, "ts": ts})
}

// FleetEnrolRequest is the body of POST /v1/fleet/enrol.
type FleetEnrolRequest struct {
	Tenant string `json:"tenant"`
	BoxID  string `json:"box_id"`
	PubKey string `json:"pubkey"`
	TS     string `json:"ts"`
	SigOp  string `json:"sig_op"`
	SigNew string `json:"sig_new"`
}
