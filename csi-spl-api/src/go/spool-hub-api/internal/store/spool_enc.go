package store

// Spec 136 (spool messages encrypted at rest) section 8.1: the workspace
// flag spool_enc. On, the workspace's box seats seal its messages at rest
// (spec 136 sections 2-6); off, the default, the workspace is plain and
// behaves byte for byte as before. A seat learns it at pin time and from the
// roster (hub: the POST /v1/pins answer, the welcome and roster frames).
//
// No migration: the flag is a registered tenants.settings key (spec 098,
// rdb 0136), set with PATCH /v1/tenant/settings {"settings":{"spool_enc":
// true}} and rolled back by setting it false or null (spec 136 8.4). Nothing
// here names a workspace: the flag is per row, looked up (rule 8).

// SpoolEncKey is the workspace setting "messages encrypted at rest".
const SpoolEncKey = "spool_enc"

func init() {
	RegisterTenantSetting(TenantSettingDef{Key: SpoolEncKey, Kind: SettingBool, Default: false})
}

// SpoolEnc is the workspace's spool_enc flag in force (false when unset).
func (t Tenant) SpoolEnc() bool { return t.Settings.Bool(SpoolEncKey) }
