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
export const AGENT_SPLIT_KINDS = Object.freeze(['claude', 'grok', 'agy', 'qwen', 'mistral'])

/** Owner's current split. qwen and mistral (spec 110) are 0 so the five sum to 100. */
export const DEFAULT_AGENT_SPLIT = Object.freeze({ claude: 40, grok: 50, agy: 10, qwen: 0, mistral: 0 })

/**
 * Five whole-number shares that sum to 100 (the hub refuses four, spec 110). Anything else (absent, a
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

/** spec 115 (rdb 0163): the task kinds, in the order the Vendor split table lists them. */
export const SPLIT_TASK_KINDS = Object.freeze(['specs_and_docs', 'tests', 'simple_coding', 'complex_coding', 'i18n', 'secret'])

/** The kinds agy never serves (spec 115 G2): 0 and never the backup. */
const SPLIT_CODING_KINDS = Object.freeze(['tests', 'simple_coding', 'complex_coding'])

/** spec 115 section 2: the row of a kind the workspace has not set. */
export const DEFAULT_SPLIT_KINDS = Object.freeze({
  specs_and_docs: { weights: { claude: 10, grok: 0, agy: 70, qwen: 0, mistral: 20 }, backup: 'claude' },
  tests: { weights: { claude: 70, grok: 0, agy: 0, qwen: 0, mistral: 30 }, backup: 'mistral' },
  simple_coding: { weights: { claude: 20, grok: 0, agy: 0, qwen: 0, mistral: 80 }, backup: 'claude' },
  complex_coding: { weights: { claude: 80, grok: 0, agy: 0, qwen: 0, mistral: 20 }, backup: 'mistral' },
  i18n: { weights: { claude: 0, grok: 0, agy: 100, qwen: 0, mistral: 0 }, backup: 'claude' },
  secret: { weights: { claude: 100, grok: 0, agy: 0, qwen: 0, mistral: 0 }, backup: 'mistral' },
})

/** The vendor with the strict highest weight, '' on a tie. */
export function splitMainOf(weights) {
  let main = ''
  let top = -1
  let tie = false
  for (const v of AGENT_SPLIT_KINDS) {
    const w = weights[v]
    if (w > top) { main = v; top = w; tie = false } else if (w === top) tie = true
  }
  return tie ? '' : main
}

/**
 * The first spec 115 section 2 rule a row breaks, as its i18n key suffix
 * (split_rule_<x>), or '' when the hub would take it: whole numbers 0..100
 * summing to 100 ('sum'), one strict main ('tie'), a backup other than the
 * main ('backup'), agy 0 and never the backup in a coding kind ('agy'),
 * only claude or mistral in secret ('secret'). The hub checks the same.
 */
export function splitKindRule(kind, weights, backup) {
  let sum = 0
  for (const v of AGENT_SPLIT_KINDS) {
    const n = weights[v]
    if (!Number.isInteger(n) || n < 0 || n > 100) return 'sum'
    sum += n
  }
  if (sum !== 100) return 'sum'
  const main = splitMainOf(weights)
  if (!main) return 'tie'
  if (!AGENT_SPLIT_KINDS.includes(backup) || backup === main) return 'backup'
  if (SPLIT_CODING_KINDS.includes(kind) && (weights.agy > 0 || backup === 'agy')) return 'agy'
  if (kind === 'secret' && (AGENT_SPLIT_KINDS.some((v) => v !== 'claude' && v !== 'mistral' && weights[v] > 0) || !['claude', 'mistral'].includes(backup))) return 'secret'
  return ''
}

/**
 * A GET/PATCH /v1/agent-split body → one row per kind of SPLIT_TASK_KINDS,
 * in order. A kind absent or broken in the body reads as its default, unset.
 */
export function normalizeAgentSplitKinds(body) {
  const b = body && typeof body === 'object' ? body : {}
  const got = {}
  for (const k of Array.isArray(b.kinds) ? b.kinds : []) {
    if (k && typeof k === 'object' && SPLIT_TASK_KINDS.includes(k.kind)) got[k.kind] = k
  }
  return SPLIT_TASK_KINDS.map((kind) => {
    const src = got[kind]
    const weights = {}
    for (const v of AGENT_SPLIT_KINDS) weights[v] = src && src.weights && typeof src.weights === 'object' ? src.weights[v] ?? 0 : 0
    const backup = src ? str(src.backup) : ''
    if (!src || splitKindRule(kind, weights, backup)) {
      const d = DEFAULT_SPLIT_KINDS[kind]
      return { kind, weights: { ...d.weights }, backup: d.backup, main: splitMainOf(d.weights), set: false, updatedBy: '', updatedAt: '' }
    }
    return { kind, weights, backup, main: splitMainOf(weights), set: src.set === true, updatedBy: str(src.updated_by), updatedAt: str(src.updated_at) }
  })
}
