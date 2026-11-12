package hub

import "net/http"

// operatorWriteCaller is fleetLoadCaller for the writes of the operator's paid
// items and cost entries, minus a live act-as clone (SPL-5348): a clone of the
// operator admin may not write what operatorReadCaller does not let it read.
// fleetLoadCaller itself stays as it is for its other routes.
func (s *Server) operatorWriteCaller(w http.ResponseWriter, r *http.Request) (string, *opActor, string, bool) {
	tenant, a, who, ok := s.fleetLoadCaller(w, r)
	if ok && a != nil && s.readerIsActAsClone(r.Context(), tenant, a.hum) {
		writeForbidden(w, permOperatorAdmin, "an act-as clone does not write the operator's costs")
		return "", nil, "", false
	}
	return tenant, a, who, ok
}
