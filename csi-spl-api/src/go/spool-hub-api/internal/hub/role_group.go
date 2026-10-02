package hub

import (
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// The role consumer group (spec 059 §11.1 S5, with CLE-77911's fleet lease).
// A channel post fans out per member box (spec 058 H7), so a role seated on
// two machines - c-002@box-desk and c-002@sat - would handle one post twice.
// For a role agent the hub instead routes to the box of that role's current
// fleet lease holder (fleet_leases, rdb 0094): Kafka's consumer group with
// one active member. Every other member keeps its normal delivery.
//
// Who is a role agent: the reserved ids of the role (spec 058 §3.0: 001 the
// orchestrator, 002 / 003 the master and failover dispatchers), in either id
// grammar, on every box. A role the hub does not know groups only the
// holder's own number.
//
// Handover (the lease moves by CAS on gen, spec 058 §3.5; a spec 060 rotation
// keeps <ID>@<box>, so it moves nothing here):
//   - the route is decided when the post commits, from the lease read then;
//     the next post after a move goes to the new holder;
//   - a row already queued stays with its box (at-least-once). Its recv frame
//     re-reads the lease, so a non-holder's role agent is left out of it -
//     unless that leaves the frame empty, when the row's box gets it anyway:
//     the post was routed there, and dropping it would lose it. The old
//     holder's agent is told STANDBY and does not act; the new one is told
//     ACTIVE and sweeps what the old one left unanswered
//     (do_spl_unanswered_sweep);
//   - a stalled holder: a lease not renewed for RoleLeaseStale (the loops'
//     LEASE_STALE, 180 s) is ignored and the post fans out to every member
//     box as before, so a dead holder never swallows a post. So does a lease
//     whose holder box seats none of the role's agents in that channel, and a
//     lease the store cannot read.

// roleNumbers is the reserved agent numbers of each fleet lease role.
var roleNumbers = map[string][]string{"orch": {"001"}, "dispatch": {"002", "003"}}

// DefaultRoleLeaseStale is RoleLeaseStale's zero value: LEASE_STALE's default.
const DefaultRoleLeaseStale = 180 * time.Second

// roleSeats maps a role agent number to the box(es) holding its role. A
// number not in it is no role agent; nil routes like before S5.
type roleSeats map[string]map[string]bool

// roleSeats reads the tenant's live fleet leases.
func (s *Server) roleSeats(ctx context.Context, tenant string) roleSeats {
	leases, err := s.o.Store.FleetLeases(ctx, tenant, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("fleet leases: channel posts fan out to every member box")
		return nil
	}
	stale := s.o.RoleLeaseStale
	if stale <= 0 {
		stale = DefaultRoleLeaseStale
	}
	var out roleSeats
	for _, l := range leases {
		id, box := agentid.SplitAtBox(l.Holder)
		if l.Gen == 0 || l.Age > stale || box == "" || !agentid.IsAgent(id) {
			continue
		}
		nums := roleNumbers[l.Role]
		if nums == nil {
			nums = []string{agentid.Number(id)}
		}
		for _, n := range nums {
			if out == nil {
				out = roleSeats{}
			}
			if out[n] == nil {
				out[n] = map[string]bool{}
			}
			out[n][box] = true
		}
	}
	return out
}

// seated keeps the roles whose holder box seats one of the role's agents in
// this channel (members: box -> agents); the others fan out as before.
func (r roleSeats) seated(members map[string][]string) roleSeats {
	var out roleSeats
	for n, boxes := range r {
		for box := range boxes {
			if hostsNumber(members[box], n) {
				if out == nil {
					out = roleSeats{}
				}
				out[n] = boxes
				break
			}
		}
	}
	return out
}

// filter is agents on box minus the role agents whose role is held elsewhere.
func (r roleSeats) filter(box string, agents []string) []string {
	if len(r) == 0 {
		return agents
	}
	var out []string
	for _, a := range agents {
		if boxes, ok := r[roleNumber(a)]; !ok || boxes[box] {
			out = append(out, a)
		}
	}
	return out
}

// roleNumber is an agent id's number ("" for a non-agent participant).
func roleNumber(id string) string {
	if !agentid.IsAgent(id) {
		return ""
	}
	return agentid.Number(id)
}

func hostsNumber(agents []string, n string) bool {
	for _, a := range agents {
		if roleNumber(a) == n {
			return true
		}
	}
	return false
}
