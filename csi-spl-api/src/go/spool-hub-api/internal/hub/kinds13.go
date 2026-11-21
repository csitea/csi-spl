package hub

import "github.com/csitea/csi-spl/spool-hub-api/internal/wire"

// kinds6 are the message kinds every box reader takes; a reader older than
// spec 033 K.4.3 (T023) refuses any other kind and never commits the frame.
var kinds6 = map[string]bool{"task": true, "result": true, "note": true, "reject": true, "blocker": true, "msg": true}

// acceptsKind reports whether this box's reader takes kind k: the first six
// always, any kind when the hello carried wire.FeatureKinds13. "" (an
// unreadable kind) is not this guard's call, as accepts(0) is not.
func (x *session) acceptsKind(k string) bool {
	return k == "" || kinds6[k] || x.has(wire.FeatureKinds13)
}

// acceptsEnv reports whether this box's reader takes the envelope raw: its
// inner version (accepts) and its inner kind (acceptsKind). A frame it would
// refuse stays queued until the box runs a binary that takes it.
func (x *session) acceptsEnv(raw []byte) bool {
	return x.accepts(wire.InnerVersion(raw)) && x.acceptsKind(wire.InnerKind(raw))
}
