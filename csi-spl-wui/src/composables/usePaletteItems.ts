// 081 T003 (FR-002): the command palette's go-to rows, built from the stores
// the app already holds: the rail tabs, Help, Docs and Workspace settings;
// the channels and the people (a person opens their DM); the viewer's
// recent topics; the docs (075's trees, repo and workspace); the Settings
// pages. No second index: every row reads the list its own section shows,
// behind the same gates (the DM tab while acting as a member, specs/054;
// Workspace settings for its admins only). The ranking is
// utils/palette.mjs's; the dialog (T004) shows the rows and calls go().
import type { LocationQuery, RouteLocationRaw } from 'vue-router'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSidePane, type SidePaneId } from '~/composables/useSidePane'
import { useHumanNames } from '~/composables/useHumanNames'
import { useWorkspaceDocs } from '~/composables/useWorkspaceDocs'
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useViewerStore } from '~/stores/viewer'
import { useAccessStore } from '~/stores/access'
import { RAIL_TABS } from '~/utils/rail-order.mjs'
import { routeForTab } from '~/utils/sidebar-tabs.mjs'
import { SETTINGS_QUERY, SETTINGS_SECTIONS } from '~/utils/settings-nav.mjs'
import { tenantSettingsVisible } from '~/utils/tenant-settings-nav.mjs'
import { docsRoute, validDocsPath } from '~/utils/docs.mjs'
import { wsDocsRoute } from '~/utils/ws-docs.mjs'
import { pushRecent, type PaletteItem } from '~/utils/palette.mjs'
import type { UiIconName } from '~/utils/uiIcons'
import type { TopicRow } from '~/types/spool'

/** The palette's groups, in the order the dialog draws them (spec 3.1). */
export const PALETTE_GROUPS = ['sections', 'channels', 'people', 'topics', 'docs', 'settings'] as const
export type PaletteGroup = typeof PALETTE_GROUPS[number]

/** One go-to row: a route (no locale yet) or a sidebar list to show. */
export type PaletteGoItem = PaletteItem & {
  group: PaletteGroup
  icon?: UiIconName
  to?: RouteLocationRaw
  pane?: SidePaneId
}

type TreeFile = { path: string, title: string }

/* the repo docs tree, read once per page life (pages/docs.vue reads the same
   tree.json for its explorer) */
const repoDocs = shallowRef<TreeFile[]>([])
let repoLoad: Promise<void> | null = null

const PANE_TABS = new Set<string>(['dm', 'channels', 'flow'])

type Translate = (key: string) => string
type SpoolApi = ReturnType<typeof useSpoolApi>

/** The rail tabs, then Help, Docs and (for its admins) Workspace settings. */
function sectionRows(t: Translate, opts: { acting: boolean, tenantSettings: boolean }): PaletteGoItem[] {
  const rows: PaletteGoItem[] = []
  for (const tab of RAIL_TABS) {
    /* specs/054: no DM tab while acting as a member */
    if (tab.id === 'dm' && opts.acting) continue
    const to = routeForTab(tab.id)
    const row: PaletteGoItem = { id: 'tab:' + tab.id, group: 'sections', label: t(tab.labelKey), icon: tab.icon }
    if (to !== null) row.to = to
    else if (PANE_TABS.has(tab.id)) row.pane = tab.id as SidePaneId
    else continue
    rows.push(row)
  }
  rows.push({ id: 'page:help', group: 'sections', label: t('help.title'), icon: 'help', to: '/help' })
  rows.push({ id: 'page:docs', group: 'sections', label: t('docs.title'), icon: 'book-open', to: '/docs' })
  if (opts.tenantSettings) {
    rows.push({ id: 'page:tenant-settings', group: 'sections', label: t('tenant_settings.title'), icon: 'settings', to: '/tenant-settings' })
  }
  return rows
}

function channelRows(list: readonly { channel_id: string, name: string }[]): PaletteGoItem[] {
  return list.map((c) => ({ id: 'channel:' + c.channel_id, group: 'channels', label: c.name || c.channel_id, keywords: [c.channel_id], icon: 'hash', to: '/channel/' + c.channel_id }))
}

/** A person opens their DM (spec 3.1), named as the DM list names them. */
function personRows(peers: readonly { id: string, box: string, label: string }[], name: (id: string, box?: string) => string): PaletteGoItem[] {
  return peers.map((p) => ({ id: 'dm:' + p.label, group: 'people', label: name(p.id, p.box), keywords: [p.id, p.label], icon: 'user', to: '/dm/' + encodeURIComponent(p.label) }))
}

function topicRows(list: readonly TopicRow[]): PaletteGoItem[] {
  return list.map((row) => ({ id: 'topic:' + row.task_id, group: 'topics', label: row.subject || row.task_id, keywords: [row.task_id], icon: 'list', to: '/t/' + row.task_id }))
}

/** The workspace docs, then the repo's (075: /docs/ws/<path>, /docs/<path>). */
function docRows(ws: readonly TreeFile[], repo: readonly TreeFile[]): PaletteGoItem[] {
  const doc = (id: string, f: TreeFile, to: string): PaletteGoItem =>
    ({ id, group: 'docs', label: f.title || f.path, keywords: [f.path], icon: 'file-text', to })
  return [
    ...ws.map((f) => doc('wsdoc:' + f.path, f, wsDocsRoute(f.path))),
    ...repo.filter((f) => validDocsPath(f.path)).map((f) => doc('doc:' + f.path, f, docsRoute(f.path))),
  ]
}

/** The Settings modal opens over the current view (CLE-77853). */
function settingsRows(t: Translate, here: { path: string, query: LocationQuery }): PaletteGoItem[] {
  return SETTINGS_SECTIONS.map((s) => ({ id: 'settings:' + s.id, group: 'settings', label: t(s.label), icon: 'settings', to: { path: here.path, query: { ...here.query, [SETTINGS_QUERY]: s.id } } }))
}

/** The repo docs tree.json, as pages/docs.vue reads it; [] when off or failed. */
async function readRepoDocs(api: SpoolApi): Promise<TreeFile[]> {
  let body: { files?: TreeFile[] } | null
  if (api.mock) {
    const { mockDocs } = await import('~/utils/docs-mock.mjs')
    const raw = mockDocs('tree.json')
    body = raw ? JSON.parse(raw) as { files?: TreeFile[] } : null
  } else {
    const headers: Record<string, string> = {}
    if (api.token) headers.authorization = `Bearer ${api.token}`
    const r = await fetch(`${api.base}/v1/docs/tree.json`, { credentials: api.credentials, headers, cache: 'no-cache' })
    body = r.ok ? await r.json().catch(() => null) as { files?: TreeFile[] } | null : null
  }
  return Array.isArray(body?.files) ? body.files : []
}

export function usePaletteItems() {
  const { t } = useI18n()
  const api = useSpoolApi()
  const localePath = useLocalePath()
  const route = useRoute()
  const sidePane = useSidePane()
  const names = useHumanNames()
  const wsDocs = useWorkspaceDocs()
  const channel = useChannelStore()
  const roster = useRosterStore()
  const viewer = useViewerStore()
  const access = useAccessStore()
  const acting = computed(() => Boolean(access.me?.actAs))

  const sections = computed(() => sectionRows(t, { acting: acting.value, tenantSettings: tenantSettingsVisible(access.me, { mock: api.mock }) }))
  const channels = computed(() => channelRows(channel.ordered))
  const people = computed(() => (acting.value ? [] : personRows(roster.peers, names.label)))
  const topics = computed(() => topicRows(viewer.topics))
  const docs = computed(() => docRows(wsDocs.files.value, repoDocs.value))
  const settings = computed(() => settingsRows(t, { path: route.path, query: route.query }))

  /** Every go-to row, group by group; rankItems orders them for a query. */
  const items = computed<PaletteGoItem[]>(() => [
    ...sections.value, ...channels.value, ...people.value, ...topics.value, ...docs.value, ...settings.value,
  ])

  /**
   * Fill the lists the sidebar may not have read yet (the dialog calls it on
   * open). A failed read leaves its group empty; the rest still show.
   */
  function load(): void {
    if (viewer.topics.length === 0 && !viewer.loading) void viewer.loadTopics()
    if (wsDocs.files.value.length === 0 && wsDocs.treeState.value !== 'off') void wsDocs.loadTree()
    repoLoad ||= readRepoDocs(api).then((files) => { repoDocs.value = files }, () => { repoLoad = null })
  }

  /** Go to a row, and remember it as recent (spool.palette-recent). */
  async function go(item: PaletteGoItem): Promise<void> {
    if (import.meta.client) {
      try { pushRecent(window.localStorage, item.id) } catch { /* storage off: no recents */ }
    }
    if (item.pane) sidePane.request(item.pane)
    else if (item.to) await navigateTo(typeof item.to === 'string' ? localePath(item.to) : item.to)
  }

  return { items, sections, channels, people, topics, docs, settings, load, go }
}
