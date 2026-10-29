// csi-spl-wui/src/utils/reporting-marketing.mjs
//
// Spec 163 G5, build row B1 (SPL-4250): the Reporting Marketing tab's read
// and its cards. Owner HUM-10 (csitea topic b13f7763, poll 337fb605, msg
// 449350b3): Q7 "A — Last touch, 28 days", Q8 "B — Workspace admins and the
// owner only". GET /v1/reporting/marketing answers { as_of, attribution:
// { rule, window_days }, stages, samples, definitions }, or 403 to anyone
// but the workspace's owner or an admin. B1 draws one empty card per stage;
// the connector rows (B3..B16) fill them.

import { mockMeGet } from './act-as-mock.mjs'
import { HUB_READ_TIMEOUT_MS } from './fetch-timeouts.mjs'
import { withSessionRetry } from './live-follow.mjs'

const MARKETING_REPORT_PATH = '/v1/reporting/marketing'

/** Spec 163 section 2.1..2.7, the overview's order: one card each. */
export const MARKETING_STAGE_IDS = Object.freeze(['reach', 'engagement', 'acquisition', 'conversion', 'revenue', 'retention', 'content_seo'])

/** The roles the hub admits (its TenantOwner || Has(rbac.Admin)); the mock plays them. */
const MOCK_STAFF_ROLES = Object.freeze(['admin', 'biz_owner'])

/**
 * The mock hub's answer: empty, as the live one until a connector writes;
 * 403 for a mock role that is neither the owner nor an admin (spool.mock.me;
 * none set plays the owner).
 * @param {number} now
 * @param {Storage | null} [store]
 */
export function mockMarketingReport(now, store) {
  const me = mockMeGet(store)
  if (me && !MOCK_STAFF_ROLES.includes(me.role)) {
    throw Object.assign(new Error('only the workspace owner or an admin sees the marketing numbers'), { status: 403 })
  }
  return {
    as_of: new Date(now).toISOString().slice(0, 19) + 'Z',
    attribution: { rule: 'last_touch', window_days: 28 },
    stages: [...MARKETING_STAGE_IDS],
    samples: [],
    definitions: [],
  }
}

/**
 * One GET of the report as the reader, behind the view door like the
 * Releases tab. Throws { status } on a non-2xx answer.
 * @param {{ mock?: boolean, base?: string, token?: string, credentials?: RequestCredentials }} api
 */
export function marketingReportRead(api, now = Date.now()) {
  if (api.mock) return Promise.resolve().then(() => mockMarketingReport(now))
  return withSessionRetry(api, async () => {
    const headers = { accept: 'application/json' }
    if (api.token) headers.authorization = `Bearer ${api.token}`
    const r = await fetch(`${api.base}${MARKETING_REPORT_PATH}`, { credentials: api.credentials, headers, signal: AbortSignal.timeout(HUB_READ_TIMEOUT_MS) })
    if (!r.ok) throw Object.assign(new Error(`marketing report ${r.status}`), { status: r.status })
    return r.json()
  })
}

/**
 * The cards in the hub's stage order (a stage the WUI has no label for is
 * left out, never drawn as a raw id), each with its samples: none in B1,
 * so every card is empty. A sample names no stage yet; the row that maps
 * metrics to stages fills `samples`.
 * @param {{ stages?: unknown, attribution?: { rule?: unknown, window_days?: unknown } }} [report] the hub's answer
 * @returns {{ id: string, labelKey: string, samples: unknown[] }[]}
 */
export function marketingStageCards(report) {
  const stages = Array.isArray(report?.stages) ? report.stages : MARKETING_STAGE_IDS
  return stages
    .filter((id) => MARKETING_STAGE_IDS.includes(id))
    .map((id) => ({ id, labelKey: 'reporting.marketing.stage.' + id, samples: [] }))
}

/**
 * The attribution line: Q7's rule and window, the hub's or Q7's default
 * when it names none; a rule the WUI has no words for is null (the line is
 * not drawn), never a raw id.
 * @param {{ stages?: unknown, attribution?: { rule?: unknown, window_days?: unknown } }} [report] the hub's answer
 * @returns {{ ruleKey: string, days: number } | null}
 */
export function marketingAttribution(report) {
  const a = report?.attribution || {}
  if (a.rule !== undefined && a.rule !== 'last_touch') return null
  const days = Number.isInteger(a.window_days) && a.window_days > 0 ? a.window_days : 28
  return { ruleKey: 'reporting.marketing.rule_last_touch', days }
}
