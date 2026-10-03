/**
 * Tenant settings (SPL-1037, specs/046), the section pages' helpers: the
 * body readers, the responder id rule, the error words. The entry gate and
 * the section list are tenant-settings-nav.mjs (the sidebar and the avatar
 * menu load it eagerly; this file only rides with the lazy pages). Node
 * tests import this file.
 */

import { isWritableAgentId } from './agent-id.mjs'

const str = (v) => (typeof v === 'string' ? v : '')

/** A GET/PATCH /v1/tenant/settings body with safe types. */
export function normalizeTenantSettings(body) {
  const b = body && typeof body === 'object' ? body : {}
  return {
    tenantId: str(b.tenant_id),
    displayName: str(b.display_name),
    defaultLocale: str(b.default_locale),
    responders: (Array.isArray(b.responders) ? b.responders : []).filter((r) => typeof r === 'string' && r),
    maxResponders: Number.isInteger(b.max_responders) && b.max_responders > 0 ? b.max_responders : 20,
    /* W16 (spec 047): '' when the hub keeps no issues (the field hides) */
    issuePrefix: str(b.issue_prefix),
    /* CLE-77819: "Who can archive topics"; an absent / unknown value is the default */
    topicArchivePolicy: TOPIC_ARCHIVE_POLICY_OPTIONS.includes(b.topic_archive_policy) ? b.topic_archive_policy : 'everyone',
    /* rdb 0109: a guideline. Absent, junk or a sum other than 100 is the default. */
    agentSplit: agentSplitOf(b.agent_split),
  }
}

/** CLE-77819: the "Who can archive topics" choices, in the order General lists them. */
export const TOPIC_ARCHIVE_POLICY_OPTIONS = Object.freeze(['everyone', 'admins', 'starter'])

/** Vendor kinds, in the order the settings page lists them. */
export const AGENT_SPLIT_KINDS = Object.freeze(['claude', 'grok', 'agy', 'qwen'])

/** Owner's current split. qwen is 0 so the four sum to 100. */
export const DEFAULT_AGENT_SPLIT = Object.freeze({ claude: 40, grok: 50, agy: 10, qwen: 0 })

/**
 * Four whole-number shares that sum to 100. Anything else (absent, a
 * fraction, a share outside 0..100, a sum other than 100) is the default.
 */
export function agentSplitOf(raw) {
  const src = raw && typeof raw === 'object' ? raw : null
  if (!src) return { ...DEFAULT_AGENT_SPLIT }
  const out = {}
  for (const k of AGENT_SPLIT_KINDS) {
    const n = src[k]
    if (!Number.isInteger(n) || n < 0 || n > 100) return { ...DEFAULT_AGENT_SPLIT }
    out[k] = n
  }
  const sum = AGENT_SPLIT_KINDS.reduce((total, k) => total + out[k], 0)
  return sum === 100 ? out : { ...DEFAULT_AGENT_SPLIT }
}

/** The issue key prefix as the hub stores it (upper-cased), or '' when the hub would refuse it. */
export function issuePrefixOf(s) {
  const v = String(s || '').trim().toUpperCase()
  return /^[A-Z][A-Z0-9]{0,9}$/.test(v) ? v : ''
}

/** A GET /v1/tenant/channels body → rows with safe types, default channels first, then by name. */
export function normalizeTenantChannels(body) {
  const b = body && typeof body === 'object' ? body : {}
  const rows = (Array.isArray(b.channels) ? b.channels : []).filter((c) => c && str(c.channel)).map((c) => ({
    channel: c.channel,
    name: str(c.name) || c.channel,
    description: str(c.description),
    visibility: c.visibility === 'default' ? 'default' : 'members',
    members: Number(c.members) || 0,
    agents: Number(c.agents) || 0,
    messages: Number(c.messages) || 0,
    noFallback: c.no_fallback === true,
    createdBy: str(c.created_by),
    lastTs: str(c.last_ts),
    archivable: c.archivable === true,
  }))
  rows.sort((a, b) => (a.visibility === b.visibility ? a.name.localeCompare(b.name) : a.visibility === 'default' ? -1 : 1))
  return rows
}

/** An agent id the hub accepts as a responder (c-004; CLE-01 until LEGACY_ID_UNTIL); never a HUM-*. */
export function validResponderId(s) {
  return isWritableAgentId(String(s || '').trim())
}

/** Move item i of list by delta (-1 up, +1 down); a new array, unchanged when out of range. */
export function moveItem(list, i, delta) {
  const out = list.slice()
  const j = i + delta
  if (i < 0 || i >= out.length || j < 0 || j >= out.length) return out
  ;[out[i], out[j]] = [out[j], out[i]]
  return out
}

/** The i18n key for a failed tenant-settings call's hub token. */
export function tenantSettingsErrorKey(err) {
  const token = err && typeof err.token === 'string' ? err.token : ''
  const known = ['forbidden', 'bad_setting', 'bad_split', 'bad_responder', 'channel_public', 'unknown_channel', 'shared_account', 'bad_name', 'bad_locale', 'last_admin', 'last_owner', 'self']
  return 'tenant_settings.error.' + (known.includes(token) ? token : 'generic')
}
