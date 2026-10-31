/**
 * The mock hub's Tenant settings (NUXT_PUBLIC_USE_MOCK=1, specs/046). Its own
 * module so spool-client loads it only in a mock build (dynamic import): the
 * initial chunk stays inside the 027 budget.
 */
import { AGENT_SPLIT_KINDS, DEFAULT_SPLIT_KINDS, issuePrefixOf, SPLIT_TASK_KINDS, splitKindRule, splitMainOf, TOPIC_ARCHIVE_POLICY_OPTIONS, validResponderId } from './tenant-settings.mjs'
import { HOURS_DEFAULTS, HOURS_KEY_GRACE, HOURS_KEY_IDLE, HOURS_KEY_PERIOD, HOURS_KEY_TZ, hoursSettingValid } from './hours-settings.mjs'


function mockErr(status, token) {
  const e = new Error(`spool ${status} ${token}`)
  e.status = status
  e.token = token
  return e
}

// spec 098: the registered generic keys the mock keeps, at the hub defaults:
// the four hours keys (spec 107 section 4.2) and blocker -> issue minutes.
// The blocker key, default and range are written out here, not imported from
// blocker-settings.mjs: that import put a chunk of its own in the home
// preload of the mock bundle (+0.1 KB on ci_home_gzip_kb);
// tests/unit/blocker-issue.test.mjs pins them to blocker-settings.mjs.
const BLOCKER_KEY_MINUTES = 'blocker.issue_after_minutes'
const BLOCKER_MINUTES_DEFAULT = 3
const KV_DEFAULTS = Object.freeze({ [HOURS_KEY_PERIOD]: HOURS_DEFAULTS.period, [HOURS_KEY_GRACE]: HOURS_DEFAULTS.graceDays, [HOURS_KEY_IDLE]: HOURS_DEFAULTS.idleMinutes, [HOURS_KEY_TZ]: HOURS_DEFAULTS.tz, [BLOCKER_KEY_MINUTES]: BLOCKER_MINUTES_DEFAULT })
const kvValid = (k, v) => (k === BLOCKER_KEY_MINUTES ? Number.isInteger(v) && v >= 0 && v <= 1440 : hoursSettingValid(k, v))

/** PATCH {settings}: every key and value checked before any is written (098 section 4); null resets. */
function patchKv(kv, raw) {
  const s = raw && typeof raw === 'object' ? raw : {}
  for (const [k, v] of Object.entries(s)) {
    if (!(k in KV_DEFAULTS) || (v !== null && !kvValid(k, v))) throw mockErr(400, 'bad_setting')
  }
  for (const [k, v] of Object.entries(s)) {
    if (v === null) delete kv[k]
    else kv[k] = v
  }
}

/** The canned channel rows; each mock copies them (archive and the flag mutate). */
const MOCK_CHANNELS = Object.freeze([
  { channel: 'lobby', name: 'lobby', visibility: 'default', members: 0, agents: 2, messages: 40, no_fallback: false, archivable: false },
  { channel: 'alerts', name: 'alerts', visibility: 'default', members: 0, agents: 1, messages: 3, no_fallback: false, archivable: false },
  { channel: 'design', name: 'Design', visibility: 'members', members: 3, agents: 1, messages: 12, no_fallback: false, archivable: true, created_by: 'HUM-3' },
  { channel: 'secret', name: 'Secret', visibility: 'members', members: 1, agents: 0, messages: 2, no_fallback: true, archivable: true, created_by: 'HUM-12' },
])

/** spec 115 HUB-1 (rdb 0163): GET / PATCH /v1/agent-split on the mock. */
function mockSplitKinds() {
  // the kinds this workspace set; the rest read as the spec 115 section 2 default
  const kinds = {}
  const splitKinds = () => ({
    tenant_id: 'mock',
    vendors: [...AGENT_SPLIT_KINDS],
    kinds: SPLIT_TASK_KINDS.map((kind) => {
      const k = kinds[kind] || DEFAULT_SPLIT_KINDS[kind]
      return { kind, weights: { ...k.weights }, backup: k.backup, main: splitMainOf(k.weights), set: Boolean(kinds[kind]) }
    }),
  })
  return {
    splitKinds,
    /** PATCH /v1/agent-split: every kind is checked before any is written, like the hub. */
    patchSplitKinds(p) {
      const asked = p && typeof p === 'object' && p.kinds && typeof p.kinds === 'object' ? p.kinds : {}
      const next = {}
      for (const [kind, row] of Object.entries(asked)) {
        if (!SPLIT_TASK_KINDS.includes(kind)) throw mockErr(400, 'bad_split')
        if (row === null) { next[kind] = null; continue }
        const weights = {}
        for (const v of AGENT_SPLIT_KINDS) weights[v] = row.weights?.[v] ?? 0
        if (Object.keys(row.weights || {}).some((v) => !AGENT_SPLIT_KINDS.includes(v))) throw mockErr(400, 'bad_split')
        if (splitKindRule(kind, weights, row.backup)) throw mockErr(400, 'bad_split')
        next[kind] = { weights, backup: row.backup }
      }
      if (!Object.keys(next).length) throw mockErr(400, 'bad_split')
      for (const [kind, row] of Object.entries(next)) {
        if (row) kinds[kind] = row
        else delete kinds[kind]
      }
      return splitKinds()
    },
  }
}

/**
 * spec 090 T035: the mock's connected Facebook Pages and Instagram accounts
 * (T033 routes; DELETE /v1/marketing/channels/{id} is lane SPL-4496's).
 * One Page with its Instagram account is connected; Connect adds a second
 * Page. localStorage spool.mock.marketing.meta=not_configured plays a hub
 * without the Meta app (every Meta route 503), =no_admin a Page whose
 * connecting member holds no posting task (Meta's Page roles).
 */
function mockMarketingMeta(unshared) {
  const flag = () => {
    try { return globalThis.localStorage?.getItem('spool.mock.marketing.meta') || '' } catch { return '' }
  }
  const POST_TASKS = ['ANALYZE', 'ADVERTISE', 'MODERATE', 'CREATE_CONTENT', 'MANAGE']
  const pages = [{ channel_id: 'mch-fb-1', page_id: '1001', name: 'Mock Studio', status: 'active', tasks: POST_TASKS,
    instagram: { channel_id: 'mch-ig-1', ig_user_id: '17841', username: 'mock.studio', status: 'active' } }]
  // per channel: the post ids already published there
  const done = {}
  const find = (id) => pages.find((p) => p.channel_id === id || p.instagram?.channel_id === id)
  const platformOf = (id) => (pages.some((p) => p.channel_id === id) ? 'facebook_page' : 'instagram_business')
  return {
    configured() {
      if (flag() === 'not_configured') throw mockErr(503, 'not_configured')
    },
    pages: () => ({ pages: pages.map(({ tasks, ...p }) => ({ ...p, auto_publish: false, instagram: p.instagram ? { ...p.instagram } : null })) }),
    channels: () => ({ channels: pages.flatMap((p) => [
      { channel_id: p.channel_id, platform: 'facebook_page', account_name: p.name, status: p.status, metadata: { page_id: p.page_id, tasks: [...p.tasks] } },
      ...(p.instagram ? [{ channel_id: p.instagram.channel_id, platform: 'instagram_business', account_name: p.instagram.username, status: p.instagram.status,
        metadata: { ig_user_id: p.instagram.ig_user_id, username: p.instagram.username, page_id: p.page_id } }] : []),
    ]) }),
    connect() {
      // the mock skips Meta's consent page: the callback's effect at once
      const n = pages.length + 1
      if (!pages.some((p) => p.channel_id === `mch-fb-${n}`)) {
        pages.push({ channel_id: `mch-fb-${n}`, page_id: String(1000 + n), name: 'Mock Shop', status: 'active',
          tasks: flag() === 'no_admin' ? ['ANALYZE'] : POST_TASKS, instagram: null })
      }
      return { authorize_url: '' }
    },
    disconnect(id) {
      const i = pages.findIndex((p) => p.channel_id === id)
      if (i >= 0) pages.splice(i, 1)
      else if (find(id)) find(id).instagram = null
      else throw mockErr(404, 'not_found')
      return null
    },
    posts(channel) {
      if (!find(channel)) throw mockErr(404, 'not_found')
      const sent = done[channel] || []
      return { posts: unshared.filter((p) => !sent.includes(p.id)).map((p) => ({ ...p })) }
    },
    publish(id, channel) {
      if (!find(channel)) throw mockErr(404, 'not_found')
      const p = unshared.find((x) => x.id === id)
      if (!p || (done[channel] || []).includes(id)) throw mockErr(409, 'already_recorded')
      if (platformOf(channel) === 'instagram_business' && !/\.jpe?g$/i.test(p.image || '')) throw mockErr(422, 'instagram_needs_jpeg')
      done[channel] = [...(done[channel] || []), id]
      return { post: id, scheduled: 1, published: 1, retried: 0, failed: 0, deferred: 0 }
    },
  }
}

/** The mock's marketing routes: the switch (spec 090 §15) and the owner's publish (SPL-1698). */
function mockMarketing() {
  // spec 090 §15: the mock workspace is allow-listed and starts OFF, like a
  // real one; localStorage spool.mock.marketing=unlisted plays a workspace
  // outside the cnf allow-list (every marketing route 404).
  const mkt = { enabled: false }
  // SPL-1698: the mock signed-in member is the workspace owner holding the
  // LinkedIn channel, with two live posts not shared yet. localStorage
  // spool.mock.marketing.publish=forbidden plays a non-owner (403),
  // =recorded a post already published elsewhere (409).
  const unshared = [
    { id: '2026-10-13-mock-second', title: 'Mock post two', summary: 'The newer mock post.', image: '/logo.webp' },
    { id: '2026-10-12-mock-first', title: 'Mock post one', summary: 'The older mock post.', image: '/mock-first.jpg' },
  ]
  const mktPublish = () => {
    try { return globalThis.localStorage?.getItem('spool.mock.marketing.publish') || '' } catch { return '' }
  }
  const mktListed = () => {
    try { return globalThis.localStorage?.getItem('spool.mock.marketing') !== 'unlisted' } catch { return true }
  }
  const meta = mockMarketingMeta(unshared)
  const metaOn = () => {
    if (!mktListed() || !mkt.enabled) throw mockErr(404, 'not_found')
    meta.configured()
  }
  return {
    metaPages() {
      metaOn()
      return meta.pages()
    },
    marketingChannels() {
      if (!mktListed() || !mkt.enabled) throw mockErr(404, 'not_found')
      return meta.channels()
    },
    connectFacebook() {
      metaOn()
      return meta.connect()
    },
    disconnectMarketingChannel(id) {
      if (!mktListed() || !mkt.enabled) throw mockErr(404, 'not_found')
      return meta.disconnect(id)
    },
    marketing() {
      if (!mktListed()) throw mockErr(404, 'not_found')
      return { tenant_id: 'mock', enabled: mkt.enabled }
    },
    setMarketing(on) {
      if (!mktListed()) throw mockErr(404, 'not_found')
      mkt.enabled = Boolean(on)
      return { tenant_id: 'mock', enabled: mkt.enabled }
    },
    marketingPosts(channel) {
      if (!mktListed() || !mkt.enabled) throw mockErr(404, 'not_found')
      if (mktPublish() === 'forbidden') throw mockErr(403, 'forbidden')
      if (channel) return meta.posts(channel)
      return { posts: unshared.map((p) => ({ ...p })) }
    },
    publishMarketingPost(id, channel) {
      if (!mktListed() || !mkt.enabled) throw mockErr(404, 'not_found')
      if (mktPublish() === 'forbidden') throw mockErr(403, 'forbidden')
      if (channel) return meta.publish(id, channel)
      const i = unshared.findIndex((p) => p.id === id)
      if (mktPublish() === 'recorded' || i < 0) throw mockErr(409, 'already_recorded')
      unshared.splice(i, 1)
      return { post: id, scheduled: 1, published: 1, retried: 0, failed: 0 }
    },
  }
}

export function createMockTenant() {
  const cfg = { display_name: 'Mock tenant', default_locale: '', responders: ['CLE-01'], issue_prefix: 'SPL', topic_archive_policy: 'everyone', agent_split: { claude: 40, grok: 50, agy: 10, qwen: 0, mistral: 0 } }
  const channels = MOCK_CHANNELS.map((c) => ({ ...c }))
  const kv = {}
  const settings = () => ({ tenant_id: 'mock', ...cfg, responders: cfg.responders.slice(), agent_split: { ...cfg.agent_split }, max_responders: 20, settings: { ...KV_DEFAULTS, ...kv } })
  return {
    settings,
    ...mockSplitKinds(),
    patch(p) {
      if (p.display_name !== undefined) {
        const n = String(p.display_name).trim()
        if (n.length > 200 || /[\r\n]/.test(n)) throw mockErr(400, 'bad_setting')
        cfg.display_name = n
      }
      if (p.default_locale !== undefined) cfg.default_locale = String(p.default_locale)
      if (p.topic_archive_policy !== undefined) {
        if (!TOPIC_ARCHIVE_POLICY_OPTIONS.includes(p.topic_archive_policy)) throw mockErr(400, 'bad_setting')
        cfg.topic_archive_policy = p.topic_archive_policy
      }
      if (p.issue_prefix !== undefined) {
        const v = issuePrefixOf(p.issue_prefix)
        if (!v) throw mockErr(400, 'bad_setting')
        cfg.issue_prefix = v
      }
      if (p.agent_split !== undefined) {
        const s = p.agent_split
        const keys = ['claude', 'grok', 'agy', 'qwen', 'mistral']
        if (!s || typeof s !== 'object' || Object.keys(s).length !== keys.length || keys.some((k) => !Object.prototype.hasOwnProperty.call(s, k))) {
          throw mockErr(400, 'bad_split')
        }
        let sum = 0
        for (const k of keys) {
          const n = s[k]
          if (!Number.isInteger(n) || n < 0 || n > 100) throw mockErr(400, 'bad_split')
          sum += n
        }
        if (sum !== 100) throw mockErr(400, 'bad_split')
        cfg.agent_split = { claude: s.claude, grok: s.grok, agy: s.agy, qwen: s.qwen, mistral: s.mistral }
      }
      if (p.responders !== undefined) {
        if (!p.responders.every(validResponderId)) throw mockErr(400, 'bad_responder')
        cfg.responders = [...new Set(p.responders)]
      }
      if (p.settings !== undefined) patchKv(kv, p.settings)
      return settings()
    },
    ...mockMarketing(),
    channels: () => ({ tenant_id: 'mock', channels: channels.map((c) => ({ ...c })) }),
    setNoFallback(id, off) {
      const c = channels.find((x) => x.channel === id)
      if (!c) throw mockErr(404, 'unknown_channel')
      c.no_fallback = Boolean(off)
      return { channel: id, no_fallback: c.no_fallback }
    },
    archive(id) {
      const i = channels.findIndex((x) => x.channel === id)
      if (i < 0) throw mockErr(404, 'unknown_channel')
      if (!channels[i].archivable) throw mockErr(409, 'channel_public')
      channels.splice(i, 1)
      return null
    },
  }
}
