declare module '~/utils/spool-client.mjs' {
  export function sha256Hex(buf: ArrayBuffer): Promise<string>
  export function credentialsFor(door: string): 'include' | 'omit'
  export function createSpoolClient(opts?: {
    base?: string
    fetchFn?: typeof fetch
    mock?: boolean
    token?: string
    tenant?: string
    configError?: string
    door?: import('./spool').ViewDoor
    sender?: ((frame: import('./spool').SendFrame) => Promise<unknown>) | null
  }): {
    mock: boolean
    tenant: string
    configError: string
    base: string
    readonly token: string
    readonly door: string
    readonly credentials: 'include' | 'omit'
    setDoor(door: import('./spool').ViewDoor | string): void
    setSender(fn: ((frame: import('./spool').SendFrame) => Promise<unknown>) | null): void
    uploadFile(file: Blob, uploadToken?: string): Promise<{ file_id: string, sha256: string, bytes: number }>
    downloadFile(fileId: string): Promise<ArrayBuffer>
    setToken(token: string): void
    hasToken(): boolean
    healthz(): Promise<unknown>
    search(opts?: { q?: string, cursor?: string, limit?: number, sort?: string }): Promise<import('~/utils/search.mjs').SearchResult>
    searchOperators(): Promise<import('~/utils/search.mjs').SearchOperator[]>
    listThreads(opts?: {
      limit?: number
      before?: string
      channel?: string
      dm?: boolean
      peer?: string
      agent?: string
      roots?: boolean
    }): Promise<{
      threads: import('./spool').ThreadRow[]
      next: string | null
    }>
    getThread(taskId: string, opts?: { limit?: number, after?: string, order?: 'desc', before?: string }): Promise<{
      task_id: string
      messages: import('./spool').SpoolMessage[]
      next: string | null
    }>
    me(): Promise<Record<string, unknown> | null>
    listChannels(opts?: { read?: Record<string, string> }): Promise<import('./spool').ChannelRow[]>
    listMessages(opts?: {
      channel?: string
      peer?: string
      limit?: number
      since?: string
      threads?: number
      before?: string
    }): Promise<{ messages: import('./spool').SpoolMessage[], next: string | null }>
    listRoster(): Promise<unknown>
    sendMessage(opts: {
      channel?: string | null
      peer?: string
      text: string
      task_id?: string
      parent_task_id?: string
      files?: unknown[]
      from?: string
      msg_id?: string
    }): Promise<import('./spool').SpoolMessage>
    createChannel(opts: { channel_id?: string, name?: string, description?: string }): Promise<import('./spool').ChannelRow>
    /** message-edit-v1 §1: PATCH /v1/messages/{msg_id} with { body }. */
    editMessage(msgId: string, body: string): Promise<import('./spool').SpoolMessage>
    fileUrl(fileId: string): string
  }
}

declare module '~/utils/live-ws.mjs' {
  export const FRAMES: Record<string, string>
  export const WS_PATH: string
  export function wsUrl(base: string, path?: string): string
  export function backoffMs(attempt: number, opts?: { base?: number, cap?: number }): number
  export function messageFromFrame(f: unknown): Record<string, unknown>
  export const AGENT_ID_RE: RegExp
  export function cleanAs(s: string): string
  export function tokenStale(expiresAt: string, now?: number, skewMs?: number): boolean
  export function createLiveClient(opts: {
    url: string
    token?: string
    as?: string
    WebSocketImpl?: unknown
    onMessage?: (m: Record<string, unknown>, raw: unknown) => void
    onState?: (s: string) => void
    onWelcome?: (w: Record<string, unknown>) => void
    onToken?: (f: Record<string, unknown>) => void
    onPresence?: (f: import('./spool').PresenceFrame) => void
    onChannel?: (f: Record<string, unknown>) => void
    /** CLE-3445 `message_edited`: a replacement for a row already held. */
    onEdited?: (m: Record<string, unknown>, raw: unknown) => void
    onReconnected?: (welcome: Record<string, unknown>, info: { cursors: Record<string, string> }) => void
    ackTimeoutMs?: number
  }): {
    readonly state: string
    readonly welcome: Record<string, unknown> | null
    lastCursor(taskId: string): string
    connect(): void
    close(): void
    subscribe(taskId: string): void
    unsubscribe(taskId: string): void
    subscribeChannel(channel: string): void
    unsubscribeChannel(channel: string): void
    subscribePeer(peer: string): void
    unsubscribePeer(peer: string): void
    subscribeAll(): void
    unsubscribeAll(): void
    requestToken(): Promise<Record<string, unknown>>
    send(opts: import('./spool').SendFrame): Promise<import('./spool').AckFrame>
  }
}

declare module '~/utils/sidebar-tabs.mjs' {
  export const SIDE_TABS: readonly ['dm', 'channels', 'threads', 'flow']
  export function tabForPath(path: string): 'dm' | 'channels' | 'threads' | 'flow' | null
  export function switchPaneOf(text: string): 'dm' | 'channels' | 'threads' | 'flow' | '' | null
  export function flowRows(src?: {
    channels?: unknown[]
    peers?: unknown[]
    threads?: unknown[]
    liveAt?: Record<string, string>
    dmAt?: Record<string, string>
  }): {
    kind: 'channel' | 'dm' | 'thread'
    key: string
    id: string
    at: string
    label: string
    box?: string
    online?: boolean
  }[]
}

declare module '~/utils/channel-feed.mjs' {
  export function topLevel<T extends { parent_task_id?: string | null, ts?: string }>(messages: T[]): T[]
  export function threadOf<T extends { task_id?: string, parent_task_id?: string | null, ts?: string }>(
    messages: T[],
    parentTaskId: string | null,
  ): T[]
  export function replyCount(messages: { parent_task_id?: string | null }[], taskId: string): number
  export function applyVerbosity<T extends { kind?: string, body?: string }>(messages: T[], level: string): T[]
  export function parseMention(text: string): { to: string, kind: string, body: string }
  export function displayName(id: string, box?: string): string
  export function initials(id: string): string
  export function hueFor(id: string): number
  export function formatBytes(n: number | undefined, locale?: string): string
  export function formatTs(ts: string, locale?: string): string
  export function formatAbsTs(ts: string): string
  export function formatIsoTs(ts: string): string
  export function recipientOf(msg: unknown): { id: string, box: string } | null
  export function formatElapsed(sec: number): string
  export function formatThreadTs(ts: string, originMs?: number): string
  export function renderBody(src: string): string
  export function channelSlug(name: string): string
  export function retentionLabel(row: { channel_id?: string, channel?: string, retention_days?: number }): string
  export function retentionDays(row: { channel_id?: string, channel?: string, retention_days?: number }): number
  export function connectionHealth(state: string): 'ok' | 'warn' | 'down'
  export function feedRow<T>(row: T): T
  export function belongsTo(msg: unknown, where: { channel?: string | null, peer?: string | null }): boolean
  export function mergeLive<T>(rows: T[], msg: unknown): T[]
  export function followPlan(current: Iterable<string>, want: string[], keep?: string): { add: string[], drop: string[] }
  export function channelFollow(current: string, view?: { channel?: string | null, peer?: string | null }): { sub: string, unsub: string, next: string }
  export function dmFollow(current: string, view?: { peer?: string | null }): { sub: string, unsub: string, next: string }
  export function mergePage<T>(rows: T[], incoming: T[]): T[]
  export function rowFromAck(ack: unknown, frame: unknown, who?: { from?: string, channel?: string | null }): Record<string, unknown>
  export function rootsByTask<T extends { task_id?: string }>(messages: T[]): T[]
  export function threadReplies(messages: { task_id?: string, parent_task_id?: string | null }[], taskId: string): number
  export function channelView<T>(messages: T[], opts?: { search?: string, visible?: number, lobby?: boolean }): { rows: T[], hasOlder: boolean }
  export function threadCards<T extends { task_id?: string }>(messages: T[]): T[]
  export function channelActivity(row: unknown, liveAt?: Record<string, string>): string
  export function orderChannels<T extends { channel_id?: string }>(rows: T[], liveAt?: Record<string, string>): T[]
  export function orderPeers<T extends { label?: string, online?: boolean }>(rows: T[], lastAt?: Record<string, string>): T[]
  export function dmActivity(threads: unknown[], self?: string): Record<string, string>
  export function dmPeerOf(msg: unknown, self?: string): string
  export function noteActivity(
    maps: { channels?: Record<string, string>, peers?: Record<string, string> },
    msg: unknown,
    self?: string,
  ): { channels: Record<string, string>, peers: Record<string, string> }
  export function addChannelRow<T>(rows: T[], frame: unknown): T[]
}

declare module '~/utils/mock-data.mjs' {
  export const MOCK_MESSAGES: Record<string, unknown>[]
  export const MOCK_LOBBY_TASK_ID: string
  export function cloneMock(): unknown
}

declare module '~/utils/mention-autocomplete.mjs' {
  export function isAgentId(id: string): boolean
  export function activeMentionQuery(text: string, cursor?: number): string | null
  export function filterRosterMentions(
    peers: { id: string, box?: string, label?: string, online?: boolean }[],
    query: string,
  ): { id: string, box?: string, label?: string, online?: boolean }[]
  export function insertMention(
    text: string,
    cursor: number,
    id: string,
  ): { text: string, cursor: number }
}

declare module '~/utils/thread-in.mjs' {
  export function activeInQuery(text: string, cursor?: number): string | null
  export function filterThreadTitles<T extends { title?: string }>(threads: T[], query: string): T[]
  export function insertInClause(text: string, cursor: number, title: string): { text: string, cursor: number }
  export function threadChoices(src?: {
    threads?: unknown[]
    messages?: unknown[]
  }): { taskId: string, title: string, channel: string }[]
  export function resolveInClause(
    text: string,
    choices: { taskId?: string, title?: string, channel?: string }[],
  ): { taskId: string, channel: string, title: string, body: string }
}


declare module '~/utils/born-threads.mjs' {
  export function noteBornThread<T>(rows: T[] | null | undefined, paneOpen: unknown, threadId: unknown, row: unknown): T[]
  export function dismissBornThread<T extends { msg_id?: string }>(rows: T[] | null | undefined, msgId: string): T[]
}

declare module '~/utils/auth-client.mjs' {
  export const AUTH_PREFIX: string
  export function authErrorMessage(code: string): string
  export function providerName(p: string): string
  export function providerLabel(p: string): string
  export function safeRedirect(path: string): string
  export function authOrigin(base: string): string
  export function startHref(provider: string, redirect: string, tenant?: string, base?: string): string
  export function retryAfterMessage(seconds: number): string
  export interface NativeResult {
    ok: boolean
    status: number
    data: Record<string, unknown> | null
    error: string
    detail: string
    retryAfter: number
  }
  export function nativeErrorMessage(out: Partial<NativeResult> | null): string
  export interface CopyKey { key: string, params: Record<string, unknown> }
  export function authErrorKey(code: string): CopyKey | null
  export function retryAfterKey(seconds: number): CopyKey
  export function nativeErrorKey(out: Partial<NativeResult> | null): CopyKey | null
  export function createAuthClient(opts?: { fetchFn?: typeof fetch, base?: string, locale?: string | (() => string), sendLocale?: boolean }): {
    loadProviders(): Promise<{ status: 'ok' | 'unavailable', reason: string, providers: string[], native: boolean }>
    register(b: { email: string, password: string, name?: string }): Promise<NativeResult>
    verifyEmail(token: string): Promise<NativeResult>
    login(b: { email: string, password: string, tenant?: string, redirect?: string }): Promise<NativeResult>
    forgotPassword(email: string): Promise<NativeResult>
    resetPassword(b: { token: string, password: string }): Promise<NativeResult>
    changePassword(b: { current: string, next: string }): Promise<NativeResult>
    savePreferences(b: { preferred_locale: string }): Promise<NativeResult>
    providers(): Promise<string[]>
    session(): Promise<{ state: 'in' | 'out' | 'unknown', claims: Record<string, unknown> | null }>
    logout(): Promise<boolean>
  }
}

declare module '~/utils/tenant.mjs' {
  export const RESERVED_TENANTS: Set<string>
  export function validTenant(s: string): boolean
  export function pickTenant(opts?: { query?: string, stored?: string, fallback?: string }): string
  export function apiBaseFor(template: string, tenant: string): { base: string, error: string }
}

declare module '~/utils/view-api.mjs' {
  export const BROWSER_BOX: string
  export function rosterFromView(data: unknown): { roster: Record<string, string[]>, online: string[] }
  export function subjectOf(body: string): string
  export function hubField(v: unknown): string | null
  export function channelReadQuery(read: Record<string, string>): string[]
  export function isDownloadable(file: { mode?: string, file_id?: string, sha256?: string }): boolean
  export function normalizeViewMessage(el: unknown): import('./spool').SpoolMessage
  export function copyEditFields<T extends Record<string, unknown>>(src: unknown, out: T): T
}

declare module '~/utils/msg-edit.mjs' {
  import type { SpoolMessage } from './spool'
  /** what the editor holds while it is open: the draft, and what Escape restores */
  export interface MsgEditState { msgId: string, original: string, draft: string }
  export const EDIT_KEY: string
  export function isOwnMessage(msg: unknown, viewer: { id?: string, box?: string } | null): boolean
  export function canEditMessage(msg: unknown, viewer: { id?: string, box?: string } | null): boolean
  export function wantsEdit(ev: KeyboardEvent, opts?: { editable?: boolean }): boolean
  export function beginEdit(msg: unknown): MsgEditState | null
  export function withDraft(state: MsgEditState | null, draft: string): MsgEditState | null
  export function editWireBody(draft: string): string
  export function editIsDirty(state: MsgEditState | null): boolean
  export function editKeyAction(ev: KeyboardEvent, opts?: { inCode?: boolean }): '' | 'cancel' | 'commit' | 'newline'
  export function commitEdit(state: MsgEditState | null): { action: 'commit' | 'unchanged' | 'empty', body: string, error?: Error }
  export function cancelEdit(state: MsgEditState | null): string
  export function isEdited(msg: unknown): boolean
  export function revisionOf(msg: unknown): number
  export function applyEdit<T>(rows: T[], edited: unknown): T[]
  export function editFailureKey(err: unknown): string
}

declare module '~/utils/feed.mjs' {
  export function newestFirst<T>(messages: T[]): T[]
  export function activityOf(row: unknown): string
  export function newestActivityFirst<T>(rows: T[]): T[]
  export function windowed<T>(rows: T[], count: number): { rows: T[], hasOlder: boolean }
  export function parseOmnibox(text: string): { search?: string, send?: string }
  export function matchesSearch(m: unknown, q: string): boolean
  export function rootAndReplies<T>(messages: T[]): { root: T | null, replies: T[] }
  export function mergeById<T>(rows: T[], incoming: T[]): { rows: T[], added: T[], confirmed: number }
  export function pendingRow(o: {
    msg_id: string
    task_id: string
    from?: string
    to?: string
    kind?: string
    body?: string
    files?: unknown[]
    channel?: string | null
    parent_task_id?: string | null
    now?: Date
  }): import('./spool').SpoolMessage
  export function withoutMsg<T>(rows: T[], msgId: string): T[]
}

declare module '~/utils/scroll-anchor.mjs' {
  export const NEAR_TOP_PX: number
  export function prependedCount(prevKeys: string[], nextKeys: string[]): number
  export function anchorAfterPrepend(o: {
    top?: number
    prevHeight?: number
    nextHeight?: number
    added?: number
    pill?: number
    nearTop?: number
    anchorBefore?: number | null
    anchorAfter?: number | null
  }): { top: number, pill: number, moved: boolean }
  export function firstVisibleRow(root: Element | null, edge: number): Element | null
  export function layoutTop(el: HTMLElement | null): number
  export function scrollerOf(el: Element | null, doc?: Document): Element
}

declare module '~/utils/thread-list.mjs' {
  export function bumpThread<T>(threads: T[], m: Record<string, unknown>): T[]
  export function mergeThreadPage<T>(threads: T[], page: T[]): T[]
}

declare module '~/utils/avatar.mjs' {
  export function hashSeed(s: string): number
  export function isHuman(id: string): boolean
  export function isMember(id: string): boolean
  export function prefixOf(id: string): string
  export function robotSvg(key: string): string
  export function identiconSvg(key: string): string
  export function avatarSvg(id: string, box?: string): string
  export function avatarDataUri(id: string, box?: string): string
  export function avatarFilesFromView(data: unknown): Record<string, string>
  export function avatarImageUrl(base: string, id: string, box: string | undefined, files: Record<string, string>): string
  export function avatarAlt(id: string, box?: string): string
  export function avatarAltKey(id: string, box?: string): { key: string, params: Record<string, string> }
  export const AVATAR_FILES_TTL_MS: number
  export function loadAvatarFiles(o?: {
    base?: string
    token?: string
    credentials?: RequestCredentials
    fetchFn?: typeof fetch
    now?: () => number
    ttlMs?: number
  }): Promise<Record<string, string>>
  export function avatarImageMime(bytes: ArrayBuffer | Uint8Array): string
  export function bytesToDataUri(bytes: ArrayBuffer | Uint8Array, type: string): string
  export function loadAvatarImageUrl(url: string, o?: {
    credentials?: RequestCredentials
    fetchFn?: typeof fetch
  }): Promise<string>
  export function resetAvatarFiles(): void
}

declare module '~/utils/checkout-client.mjs' {
  export const CHECKOUT_PREFIX: string
  export const CHECKOUT_STORE_ID: string
  export const CHECKOUT_STORE_CLAIM: string
  export interface CheckoutResult {
    ok: boolean
    status: number
    data: Record<string, any> | null
    error: string
  }
  export type ClaimOutcome =
    | { state: 'ok', result: { tenant_id: string, tenant_url: string, root_private_key: string, tenant_host?: string, host_status?: string } }
    | { state: 'claimed' | 'expired' | 'failed' | 'cancelled' | 'stopped' }
    | { state: 'error', error: string }
  export interface CheckoutClient {
    plan(): Promise<CheckoutResult>
    /** `locale` (spec 021 T022): the active UI locale, kept on the checkout row so the claim mail speaks it. */
    start(b: { tenant_id: string, email: string, locale?: string }): Promise<CheckoutResult>
    status(id: string): Promise<CheckoutResult>
    claim(b: { checkout_id: string, claim_token: string }): Promise<CheckoutResult>
    fakePay(id: string): Promise<CheckoutResult>
  }
  export function checkoutErrorMessage(code: string): string
  export function checkoutErrorKey(code: string): { key: string, params: Record<string, unknown> } | null
  export function checkoutErrorCopy(): Record<string, string>
  export function formatPrice(cents: unknown, currency: unknown, locale?: string): string
  export function checkoutMode(plan: Record<string, unknown> | null | undefined): 'fake' | 'none' | 'unsupported'
  export function keyFileName(tenant: string): string
  export function readClaimFragment(hash: string): { id: string, token: string }
  export function saveCheckout(b: { checkout_id?: unknown, claim_token?: unknown }, storage?: Storage): boolean
  export function loadCheckout(storage?: Storage): { id: string, token: string }
  export function dropClaimToken(storage?: Storage): void
  export function forgetCheckout(storage?: Storage): void
  export function createCheckoutClient(opts?: { fetchFn?: typeof fetch, base?: string }): CheckoutClient
  export function claimOnce(client: CheckoutClient, c: { id: string, token: string }, storage?: Storage): Promise<ClaimOutcome>
  export function resetClaim(id: string): Promise<void>
  export function pollAndClaim(client: CheckoutClient, c: { id: string, token: string }, opts?: {
    storage?: Storage
    intervalMs?: number
    maxPolls?: number
    sleep?: (ms: number) => Promise<void>
    isStopped?: () => boolean
    onStatus?: (s: string) => void
  }): Promise<ClaimOutcome>
  export function pollHostReady(client: CheckoutClient, id: string, opts?: {
    intervalMs?: number
    maxPolls?: number
    sleep?: (ms: number) => Promise<void>
    isStopped?: () => boolean
  }): Promise<string>
}

declare module '~/utils/user-menu.mjs' {
  export interface UserIdentity {
    hum: string
    name: string
    email: string
    method: string
    tenant: string
    primary: string
    secondary: string
  }
  export function userIdentity(claims: unknown): UserIdentity
  export function userInitials(claims: unknown): string
  export function avatarMode(claims: unknown): 'member' | 'initials' | 'silhouette'
  export function ownAvatarUrl(authBase: string, claims: unknown): string
  export function methodLabel(p: unknown): string
  export function menuButtonLabel(claims: unknown): string
  export function methodLabelKey(p: unknown): { key: string, params: Record<string, unknown> }
  export function menuButtonLabelKey(claims: unknown): { key: string, params: Record<string, unknown> }
  export function nextMenuIndex(current: number, key: string, count: number): number
  export function signInRedirect(fullPath: string): string
}

declare module '~/utils/pane-widths.mjs' {
  export const SIDEBAR_DEFAULT: number
  export const THREAD_DEFAULT: number
  export const SIDEBAR_MIN: number
  export const SIDEBAR_MAX_RATIO: number
  export function sidebarMaxPx(viewportW: number): number
  export const THREAD_MIN: number
  export const THREAD_MAX: number
  export const MAIN_MIN: number
  export const DIVIDER_W: number
  export const STEP: number
  export const PANE_WIDTHS_KEY: string
  export const SIDEBAR_NARROW_MAX: number
  export const THREAD_NARROW_MAX: number
  export function num(v: unknown, fallback: number): number
  export function clamp(n: number, min: number, max: number): number
  export function sidebarShown(viewportW: number): boolean
  export function threadShown(viewportW: number, threadOpen: boolean): boolean
  export function clampSidebar(width: unknown, ctx?: {
    viewportW?: number, threadOpen?: boolean, threadW?: number, sidebarW?: number
  }): number
  export function clampThread(width: unknown, ctx?: {
    viewportW?: number, threadOpen?: boolean, threadW?: number, sidebarW?: number
  }): number
  export function clampPair(sidebar: unknown, thread: unknown, ctx?: {
    viewportW?: number, threadOpen?: boolean
  }): { sidebar: number, thread: number }
  export function sidebarRange(ctx?: {
    viewportW?: number, threadOpen?: boolean, threadW?: number, sidebarW?: number
  }): { min: number, max: number }
  export function threadRange(ctx?: {
    viewportW?: number, threadOpen?: boolean, threadW?: number, sidebarW?: number
  }): { min: number, max: number }
  export function applySeparatorKey(
    pane: 'sidebar' | 'thread',
    key: string,
    current: number,
    min: number,
    max: number,
  ): number
  export function pointerDelta(
    pane: 'sidebar' | 'thread',
    startWidth: number,
    startX: number,
    clientX: number,
  ): number
  export function loadPaneWidths(store?: unknown): { sidebar: number, thread: number }
  export function savePaneWidths(widths: { sidebar: number, thread: number }, store?: unknown): boolean
  export function resetPane(pane: 'sidebar' | 'thread'): number
}

declare module '~/utils/code-blocks.mjs' {
  export type BodyPart = { type: 'text' | 'strong' | 'mention' | 'inline', text: string }
  export type BodyBlock =
    | { type: 'code', text: string, lang: string, closed: boolean }
    | { type: 'para', parts: BodyPart[] }
  export function normalizeNewlines(src: string): string
  export function parseBody(src: string): BodyBlock[]
  export function bodyToHtml(src: string): string
  export function fenceStateAt(text: string, caret?: number): { inCode: boolean, lang: string }
  export function enterAction(o: { inCode?: boolean, shift?: boolean, alt?: boolean, mod?: boolean }): 'send' | 'newline'
  export function exitFence(text: string, caret?: number): { text: string, cursor: number }
  export function closeOpenFence(text: string): string
}

declare module '~/utils/code-view.mjs' {
  /** one highlighted run: raw text plus the grammar's class names */
  export interface CodeToken { text: string, cls: string }
  export type CodeLine = CodeToken[]
  export interface CodeSize { lines: number, chars: number, pages: number }
  export interface CodePreview {
    text: string
    truncated: boolean
    shownLines: number
    totalLines: number
    hiddenLines: number
    totalChars: number
  }
  export interface OversizeBlock { index: number, lang: string, lines: number, chars: number, pages: number }
  export interface CodeSendError {
    key: 'code.too_big'
    params: { pages: number, lines: number, chars: number, actual_lines: number, actual_chars: number }
    blocks: OversizeBlock[]
  }
  export const A4_PAGE: { readonly lines: number, readonly chars: number }
  export const MAX_SEND_PAGES: number
  export const SEND_LIMIT: { readonly lines: number, readonly chars: number }
  export const PREVIEW_LIMIT: { readonly lines: number, readonly chars: number }
  export const LANG_ALIASES: Readonly<Record<string, string>>
  export const SUPPORTED_LANGS: readonly string[]
  export const AUTODETECT_LANGS: readonly string[]
  export function countLines(text: string): number
  export function measureCode(text: string): CodeSize
  export function overSendLimit(text: string): boolean
  export function oversizeBlocks(body: string): OversizeBlock[]
  export function sendLimitError(body: string): CodeSendError | null
  export function previewOf(text: string, limit?: { lines: number, chars: number }): CodePreview
  export function normalizeLang(tag: string): string
  export function scopeToClass(name: string, prefix?: string): string
  export function createTokenEmitter(): new (options?: { classPrefix?: string }) => {
    options: Record<string, unknown>
    prefix: string
    tokens: CodeToken[]
    scopes: string[]
    readonly cls: string
    addText(value: string): void
    openNode(name: string): void
    closeNode(): void
    startScope(name: string): void
    endScope(): void
    __addSublanguage(other: { tokens: CodeToken[] }, name: string): void
    finalize(): void
    toHTML(): string
  }
  export function plainTokens(text: string): CodeToken[]
  export function tokensToLines(tokens: CodeToken[]): CodeLine[]
  export function plainLines(text: string): CodeLine[]
  export function lineText(line: CodeLine): string
}

declare module '~/utils/code-langs.mjs' {
  export const LANG_LOADERS: Readonly<Record<string, () => Promise<{ default: unknown }>>>
}

declare module '~/utils/highlighter.mjs' {
  import type { CodeLine, CodeToken } from '~/utils/code-view.mjs'
  export const MIN_AUTODETECT_RELEVANCE: number
  export function loadGrammar(lang: string): Promise<string>
  export function loadedGrammars(): string[]
  export function highlightTokens(text: string, langTag: string): Promise<CodeToken[]>
  export function highlightLines(text: string, langTag: string): Promise<CodeLine[]>
  export function __resetHighlighter(): void
}

declare module '~/utils/search.mjs' {
  export type SearchGroupType = 'robots' | 'users' | 'channels' | 'boxes' | 'threads' | 'files' | 'messages'
  export interface SearchOperator { op: string, example?: string, values?: string[] }
  export interface SearchRow {
    type: SearchGroupType
    key: string
    display: { text: string, highlights: unknown[] }
    [k: string]: any
  }
  export interface SearchGroup { type: SearchGroupType, items: SearchRow[], next: string | null }
  export interface SearchResult {
    query: string
    groups: SearchGroup[]
    warnings: { token: string, pos: number, detail: string }[]
  }
  export const SEARCH_GROUPS: SearchGroupType[]
  export const SEARCH_OPERATORS: SearchOperator[]
  export function normalizeOperators(data: unknown): SearchOperator[]
  export function shouldLoadOperators(o?: { mock?: boolean, sessionState?: string }): boolean
  export function rowAt(row: unknown): string
  export function omniboxMode(text: string): 'search' | 'send'
  export function searchQueryOf(text: string): string
  export function searchPath(q: string): string
  export function searchApiQuery(o: { q?: string, cursor?: string, limit?: number, sort?: string }): string
  export function operatorTokenAt(text: string, caret?: number): { token: string, start: number, end: number } | null
  export function completeOperators(token: string, catalogue?: SearchOperator[]): { insert: string, label: string }[]
  export function applyCompletion(text: string, tok: { start: number, end: number }, insert: string): { text: string, cursor: number }
  export function highlightSegments(text: string, highlights: unknown): { text: string, mark: boolean }[]
  export function normalizeSearchResponse(data: unknown): SearchResult
  export function mergeSearchPage(cur: SearchResult, page: SearchResult): SearchResult
  export function flattenGroups(groups: SearchGroup[]): SearchRow[]
  export function moveIndex(i: number, n: number, key: string): number
  export function searchTarget(row: unknown): { thread: string, focus: string } | { path: string } | { search: string } | null
  export function mockSearch(messages: unknown[], q: string): unknown
}


declare module '~/utils/slash-focus.mjs' {
  export const MOBILE_MAX: number
  export function isTypingTarget(el: EventTarget | null | undefined): boolean
  export function isOpenModal(root: { querySelector: (sel: string) => Element | null } | null | undefined): boolean
  export function isMobileViewport(width: number | undefined, max?: number): boolean
  export function eventInOmnibox(target: EventTarget | null | undefined, omniboxRoot: ParentNode | null | undefined): boolean
  export function slashFocusAction(ev: { key: string, defaultPrevented?: boolean, isComposing?: boolean, repeat?: boolean, ctrlKey?: boolean, metaKey?: boolean, altKey?: boolean }, ctx?: Record<string, unknown>): 'focus' | 'restore' | 'ignore'
  export function slashFocusContext(ev: { target?: EventTarget | null }, opts?: {
    omniboxRoot?: ParentNode | null
    document?: { querySelector: (sel: string) => Element | null } | null
    viewportWidth?: number
    hasRestore?: boolean
  }): {
    inOmnibox: boolean
    inTypingTarget: boolean
    inModal: boolean
    isMobile: boolean
    pickerOpen: boolean
    inCode: boolean
    hasRestore: boolean
  }
}

declare module '~/utils/access.mjs' {
  export const ROLE_IDS: string[]
  export function normalizeMe(body: unknown): { humanId: string | null, role: string | null, tenantOwner: boolean, permissions: string[] | null }
  export function accessAllows(me: { permissions: string[] | null } | null | undefined, perm: string): boolean
  export function roleLabelKey(role: string | null | undefined): string
}

declare module '~/utils/theme.mjs' {
  export type SpoolTheme = 'dark' | 'light'
  export const THEME_KEY: 'spool-theme'
  export const THEME_DEFAULT: 'dark'
  export function parseTheme(raw: unknown, fallback?: SpoolTheme): SpoolTheme
  export function nextTheme(current: unknown): SpoolTheme
  export function iconForTheme(current: unknown): 'sun' | 'moon'
  export function labelKeyForTheme(current: unknown): 'theme.to_light' | 'theme.to_dark'
  export function readStoredTheme(store?: unknown, fallback?: SpoolTheme): SpoolTheme
  export function writeStoredTheme(theme: unknown, store?: unknown): boolean
  export function applyThemeAttr(theme: unknown, el?: { setAttribute?(k: string, v: string): void } | null): SpoolTheme
}

