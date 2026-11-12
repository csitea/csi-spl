package hub

import "net/http"

// operatorWriteCaller is fleetLoadCaller for the writes of the operator's paid
// items and cost entries (SPL-5348). A live act-as clone is refused there by
// operatorActor, which since SPL-5369 refuses it every operator write; the
// Bearer path is the operator service account, never a clone.
func (s *Server) operatorWriteCaller(w http.ResponseWriter, r *http.Request) (string, *opActor, string, bool) {
	return s.fleetLoadCaller(w, r)
}
