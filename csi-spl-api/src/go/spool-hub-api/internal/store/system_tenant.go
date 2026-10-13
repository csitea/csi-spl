package store

// SystemTenant is the reserved tenant of the repository docs (spec 137
// T020, rdb 0191): one tree of folders and documents every workspace reads
// (a permissive FOR SELECT policy on the doctree tables) and only the
// operator scope writes. It is no workspace: it is suspended, has no host
// and no channels, and the operator workspace list and the all-tenant sweeps
// leave it out. The tenant id regexp admits it, so 0191 inserts the row and
// a later create of a workspace named "system" fails on the primary key.
const SystemTenant = "system"
