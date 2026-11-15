package hub

import "time"

// UnansweredAfter is how long a signed human post must go without an agent
// reply before the relay escalates it (Options.UnansweredGrace): the take /
// ack deferral (cnf env.box.desk_ack_defer_s, SPL-5514, reaching the hub as
// SPOOL_HUB_DESK_ACK_DEFER) plus the grace, the margin the deferred take line
// gets to land. Owner poll answer B on SPL-5514 (SPL-5594): the escalation
// waits for the deferral instead of firing inside it. A zero or negative
// deferral leaves the grace as it is; a zero grace stays off.
func UnansweredAfter(grace, deferral time.Duration) time.Duration {
	if grace <= 0 || deferral <= 0 {
		return grace
	}
	return deferral + grace
}
