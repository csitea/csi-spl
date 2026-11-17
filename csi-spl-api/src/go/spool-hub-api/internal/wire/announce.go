package wire

// TAnnounceError is the hub's refusal of a box's announce frame (SPL-5735).
// An announce is fire and forget: no request waits for its answer. Its
// refusals were error frames with no msg_id, and a box client takes an
// error frame with no msg_id as the answer of the request it has in flight,
// so a send in flight reported the roster's refusal although the hub stored
// the post. A frame type of its own is never the answer of a request: an
// older client ignores it, a current one logs it (hubclient readLoop).
// Error, Status and Detail are those of an error frame.
const TAnnounceError = "announce_error"

// The announce refusals: the token of a roster with an invalid or duplicate
// agent id, and the details the hub writes with each refusal.
const (
	TokenRosterDuplicate          = "roster_duplicate"
	DetailAnnounceNotBox          = "announce needs role=box"
	DetailAnnounceDuplicate       = "invalid or duplicate agent id in roster"
	DetailAnnounceSeatCap         = "bot seat cap reached: roster not updated"
	DetailAnnounceRosterNotStored = "roster not stored"
	DetailAnnounceSubsNotStored   = "subscriptions not stored"
)

// IsAnnounceRefusal reports whether f refuses an announce, not a request:
// a TAnnounceError frame, or an older hub's error frame with no msg_id that
// names a roster write (its token roster_duplicate, or one of the details
// above). An error frame with a msg_id is always some request's answer.
func IsAnnounceRefusal(f Frame) bool {
	if f.Type == TAnnounceError {
		return true
	}
	if f.Type != TError || f.MsgID != "" {
		return false
	}
	switch f.Detail {
	case DetailAnnounceNotBox, DetailAnnounceDuplicate, DetailAnnounceSeatCap,
		DetailAnnounceRosterNotStored, DetailAnnounceSubsNotStored:
		return true
	}
	return f.Error == TokenRosterDuplicate
}
