/**
 * The mock hub's Tenant settings (NUXT_PUBLIC_USE_MOCK=1, specs/046). Its own
 * module so spool-client loads it only in a mock build (dynamic import): the
 * initial chunk stays inside the 027 budget.
 */
import { AGENT_SPLIT_KINDS, DEFAULT_SPLIT_KINDS, issuePrefixOf, SPLIT_TASK_KINDS, splitKindRule, splitMainOf, TOPIC_ARCHIVE_POLICY_OPTIONS, validResponderId } from './tenant-settings.mjs'
import { marketingShareLinks } from './marketing-share-links.mjs'
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
 * (T033 routes; DELETE /v1/marketing/channels/{id} is SPL-4496's).
 * One Page with its Instagram account is connected; Connect adds a second
 * Page. localStorage spool.mock.marketing.meta=not_configured plays a hub
 * without the Meta app (every Meta route 503), =no_admin a Page whose
 * connecting member holds no posting task (Meta's Page roles),
 * =disconnect_refused a hub that refuses the DELETE (403).
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
      if (flag() === 'disconnect_refused') throw mockErr(403, 'forbidden')
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
    // spec 090 T036: posted by hand; it leaves that channel's list like a publish
    handOver(id, channel) {
      if (!find(channel) || !unshared.some((x) => x.id === id)) throw mockErr(404, 'not_found')
      if ((done[channel] || []).includes(id)) throw mockErr(409, 'already_recorded')
      done[channel] = [...(done[channel] || []), id]
      return { post: id, channel, status: 'published', platform_post_id: 'manual', published_at: new Date().toISOString() }
    },
  }
}

/**
 * spec 090 X row (SPL-5194): one X account, @mock_studio; Connect adds
 * @mock_shop. spool.mock.marketing.x=not_configured plays a hub without the
 * X app (503), =too_long a post that does not fit 280 even shortened (422).
 */
function mockMarketingX(unshared) {
  const flag = () => {
    try { return globalThis.localStorage?.getItem('spool.mock.marketing.x') || '' } catch { return '' }
  }
  const accounts = [{ channel_id: 'mch-x-1', user_id: '42', username: 'mock_studio', name: 'Mock Studio', status: 'active' }]
  const done = {}
  const has = (id) => accounts.some((a) => a.channel_id === id)
  return {
    configured() {
      if (flag() === 'not_configured') throw mockErr(503, 'not_configured')
    },
    has,
    accounts: () => ({ accounts: accounts.map((a) => ({ ...a })) }),
    connect() {
      if (!has('mch-x-2')) accounts.push({ channel_id: 'mch-x-2', user_id: '43', username: 'mock_shop', name: 'Mock Shop', status: 'active' })
      return { authorize_url: '' }
    },
    disconnect(id) {
      const i = accounts.findIndex((a) => a.channel_id === id)
      if (i < 0) throw mockErr(404, 'not_found')
      accounts.splice(i, 1)
      return null
    },
    posts(channel) {
      const sent = done[channel] || []
      return { posts: unshared.filter((p) => !sent.includes(p.id)).map((p) => ({ ...p })) }
    },
    publish(id, channel) {
      if (!unshared.some((x) => x.id === id) || (done[channel] || []).includes(id)) throw mockErr(409, 'already_recorded')
      if (flag() === 'too_long') throw mockErr(422, 'too_long')
      done[channel] = [...(done[channel] || []), id]
      return { post: id, scheduled: 1, published: 1, retried: 0, failed: 0, deferred: 0 }
    },
  }
}

/** spec 090 X row: GET /v1/marketing/x/accounts and POST .../x/connect, 404 while marketing is off. */
function mockMarketingXRoutes(xm, on) {
  const gate = () => {
    if (!on()) throw mockErr(404, 'not_found')
    xm.configured()
  }
  return {
    xAccounts() {
      gate()
      return xm.accounts()
    },
    connectX() {
      gate()
      return xm.connect()
    },
  }
}

/**
 * spec 090 T041 (SPL-5258): one LinkedIn company page, Mock Company; Connect
 * adds Mock Labs. spool.mock.marketing.li_page=not_configured plays a hub
 * without the Company Page app (503). Publish as the page answers 403 to a
 * member without tenant.settings (spool.mock.marketing.publish=forbidden).
 */
function mockMarketingLiPage(unshared) {
  const flag = () => {
    try { return globalThis.localStorage?.getItem('spool.mock.marketing.li_page') || '' } catch { return '' }
  }
  const pages = [{ channel_id: 'mch-lp-1', organization_id: '1001', organization_urn: 'urn:li:organization:1001', name: 'Mock Company',
    vanity_name: 'mock-company', role: 'ADMINISTRATOR', status: 'active', expires_at: '2027-11-11T09:00:00Z' }]
  const done = {}
  const has = (id) => pages.some((p) => p.channel_id === id)
  return {
    configured() {
      if (flag() === 'not_configured') throw mockErr(503, 'not_configured')
    },
    has,
    pages: () => ({ pages: pages.map((p) => ({ ...p })) }),
    connect() {
      if (!has('mch-lp-2')) {
        pages.push({ channel_id: 'mch-lp-2', organization_id: '1002', organization_urn: 'urn:li:organization:1002', name: 'Mock Labs',
          vanity_name: '', role: 'CONTENT_ADMIN', status: 'active', expires_at: '2027-11-11T09:00:00Z' })
      }
      return { authorize_url: '' }
    },
    disconnect(id) {
      const i = pages.findIndex((p) => p.channel_id === id)
      if (i < 0) throw mockErr(404, 'not_found')
      pages.splice(i, 1)
      return null
    },
    posts(channel) {
      const sent = done[channel] || []
      return { posts: unshared.filter((p) => !sent.includes(p.id)).map((p) => ({ ...p })) }
    },
    publish(id, channel) {
      if (flag() === 'not_configured') throw mockErr(503, 'not_configured')
      if (!unshared.some((x) => x.id === id) || (done[channel] || []).includes(id)) throw mockErr(409, 'already_recorded')
      done[channel] = [...(done[channel] || []), id]
      return { post: id, scheduled: 1, published: 1, retried: 0, failed: 0, deferred: 0 }
    },
  }
}

/** spec 090 T041: GET /v1/marketing/linkedin-org/pages and POST .../connect, 404 while marketing is off. */
function mockMarketingLiPageRoutes(lp, on) {
  const gate = () => {
    if (!on()) throw mockErr(404, 'not_found')
    lp.configured()
  }
  return {
    linkedInPages() {
      gate()
      return lp.pages()
    },
    connectLinkedInPage() {
      gate()
      return lp.connect()
    },
  }
}

/**
 * The X accounts (SPL-5194) and the LinkedIn company pages (SPL-5258): own(id)
 * names the one a channel id belongs to (undefined: a Meta channel), routes
 * are their list and connect calls.
 */
function mockMarketingOwnChannels(unshared, on) {
  const xm = mockMarketingX(unshared)
  const lp = mockMarketingLiPage(unshared)
  const own = (id) => (id ? [xm, lp].find((m) => m.has(id)) : undefined)
  return { xm, own, routes: { ...mockMarketingXRoutes(xm, on), ...mockMarketingLiPageRoutes(lp, on) } }
}

/**
 * spec 090 T036/T037: the share links (built by the hub's twin module, with
 * three same-origin pictures so the hand-over's photo picker has a choice,
 * and a fourth on another origin under /blog/img/ as the hub builds it on
 * the apex: the card shows it on this host's own path) and the hand-over of
 * a post posted by hand.
 */
function mockMarketingHandOver(unshared, meta, on, publishFlag) {
  return {
    marketingShareLinks(id) {
      const p = on() && unshared.find((x) => x.id === id)
      if (!p) throw mockErr(404, 'not_found')
      const origin = globalThis.location?.origin || 'https://app.example.com'
      const url = `${origin}/blog/${p.id}`
      const images = [p.image, '/login-wallpaper.webp', '/spool-hub-emblem-560.webp'].map((x) => new URL(x, origin).href)
      images.push('https://other.example/blog/img/mock-foreign.webp')
      return { post_id: p.id, url, ...marketingShareLinks({ url, title: p.title, summary: p.summary, images }) }
    },
    manualPublishMarketingPost(id, channel) {
      if (!on()) throw mockErr(404, 'not_found')
      if (publishFlag() === 'forbidden') throw mockErr(403, 'forbidden')
      return meta.handOver(id, channel)
    },
  }
}

/**
 * spec 090 section 22 (SPL-5240): the workspace's own posts, with the hub's
 * rules: only the author edits, deletes and publishes; a published draft is
 * kept (409); once per channel; Instagram needs a JPEG picture, X 280
 * characters. One draft by another admin is seeded (mine false).
 */
function mockMarketingDrafts(on, publishFlag, chans) {
  const now = () => new Date().toISOString()
  const drafts = [{ id: 'mdr-other-1', author_id: 'HUM-other', body: 'A post another admin wrote.', image_url: '', published_at: null,
    created_at: '2026-11-09T10:00:00Z', updated_at: '2026-11-09T10:00:00Z', mine: false, posts: [] }]
  let n = 0
  const gate = () => {
    if (!on()) throw mockErr(404, 'not_found')
    if (publishFlag() === 'forbidden') throw mockErr(403, 'forbidden')
  }
  const own = (id) => {
    const d = drafts.find((x) => x.id === id)
    if (!d) throw mockErr(404, 'not_found')
    if (!d.mine) throw mockErr(403, 'forbidden')
    return d
  }
  const check = (b) => {
    const body = String(b?.body ?? '')
    if (!body.trim() || [...body].length > 3000) throw mockErr(400, 'bad_body')
    const img = String(b?.image_url ?? '').trim()
    if (img && !/^https:\/\/[^/@]+\//.test(img)) throw mockErr(400, 'bad_image_url')
    return { body, image_url: img }
  }
  const unfit = (ch, d) => {
    if (ch.platform === 'instagram_business' && !/\.jpe?g$/i.test(d.image_url)) return 'instagram_needs_jpeg'
    if (ch.platform === 'x' && [...d.body].length > 280) return 'x_too_long'
    return ''
  }
  const copy = (d) => ({ ...d, posts: d.posts.map((p) => ({ ...p })) })
  return {
    marketingDrafts() {
      gate()
      return { drafts: drafts.map(copy), channels: chans() }
    },
    createMarketingDraft(b) {
      gate()
      const d = { id: `mdr-${++n}`, author_id: 'HUM-mock', ...check(b), published_at: null, created_at: now(), updated_at: now(), mine: true, posts: [] }
      drafts.unshift(d)
      return copy(d)
    },
    updateMarketingDraft(id, b) {
      gate()
      const d = own(id)
      if (d.published_at) throw mockErr(409, 'published')
      Object.assign(d, check(b), { updated_at: now() })
      return copy(d)
    },
    deleteMarketingDraft(id) {
      gate()
      const d = own(id)
      if (d.published_at) throw mockErr(409, 'published')
      drafts.splice(drafts.indexOf(d), 1)
      return null
    },
    publishMarketingDraft(id, ids) {
      gate()
      const d = own(id)
      if (!ids.length) throw mockErr(400, 'bad_channels')
      const results = ids.map((cid) => {
        const ch = chans().find((c) => c.channel_id === cid)
        const why = !ch ? 'not_found' : d.posts.some((p) => p.channel_id === cid) ? 'already_recorded' : unfit(ch, d)
        if (why) return { channel_id: cid, platform: ch?.platform, outcome: 'refused', error: why }
        d.posts.push({ channel_id: cid, status: 'published' })
        return { channel_id: cid, platform: ch.platform, outcome: 'published' }
      })
      if (results.some((r) => r.outcome !== 'refused')) d.published_at = d.published_at || now()
      return { draft: copy(d), results }
    },
  }
}

/** spec 090 section 22: every connected channel a draft can go to. */
function mockDraftChannels(meta, xm) {
  return [
    { channel_id: 'mch-li-1', platform: 'linkedin', name: 'FirstName LastName' },
    ...meta.channels().channels.map((c) => ({ channel_id: c.channel_id, platform: c.platform, name: c.account_name })),
    ...xm.accounts().accounts.map((a) => ({ channel_id: a.channel_id, platform: 'x', name: '@' + a.username })),
  ]
}

/** The mock's marketing routes: the switch (spec 090 §15) and the owner's publish (SPL-1698). */
function mockMarketing() {
  // spec 090 §15: the mock workspace is allow-listed and starts OFF, like a
  // real one; localStorage spool.mock.marketing=unlisted plays a workspace
  // outside the cnf allow-list (every marketing route 404).
  const mkt = { enabled: false }
  // SPL-1698: the mock signed-in member is the workspace owner holding the
  // LinkedIn channel, with two live posts not shared yet. localStorage
  // spool.mock.marketing.publish=forbidden plays a member who may not
  // publish (403), =recorded a post already published elsewhere (409),
  // =other an admin whose LinkedIn channel another member connected (SPL-5196).
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
  const { xm, own, routes } = mockMarketingOwnChannels(unshared, () => mktListed() && mkt.enabled)
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
      if (own(id)) return own(id).disconnect(id)
      return meta.disconnect(id)
    },
    ...routes,
    ...mockMarketingDrafts(() => mktListed() && mkt.enabled, mktPublish, () => mockDraftChannels(meta, xm)),
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
      if (own(channel)) return own(channel).posts(channel)
      if (channel) return meta.posts(channel)
      return { posts: unshared.map((p) => ({ ...p })), profiles: [{ channel_id: 'mch-li-1', name: 'FirstName LastName', mine: mktPublish() !== 'other' }] }
    },
    ...mockMarketingHandOver(unshared, meta, () => mktListed() && mkt.enabled, mktPublish),
    publishMarketingPost(id, channel) {
      if (!mktListed() || !mkt.enabled) throw mockErr(404, 'not_found')
      if (mktPublish() === 'forbidden') throw mockErr(403, 'forbidden')
      if (own(channel)) return own(channel).publish(id, channel)
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
