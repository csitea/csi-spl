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
    createChannel(opts: { channel_id?: string, name?: string }): Promise<import('./spool').ChannelRow>
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
    requestToken(): Promise<Record<string, unknown>>
    send(opts: import('./spool').SendFrame): Promise<import('./spool').AckFrame>
  }
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
  export function formatBytes(n: number | undefined): string
  export function formatTs(ts: string): string
  export function renderBody(src: string): string
  export function channelSlug(name: string): string
  export function retentionLabel(row: { channel_id?: string, channel?: string, retention_days?: number }): string
  export function connectionHealth(state: string): 'ok' | 'warn' | 'down'
  export function feedRow<T>(row: T): T
  export function belongsTo(msg: unknown, where: { channel?: string | null, peer?: string | null }): boolean
  export function mergeLive<T>(rows: T[], msg: unknown): T[]
  export function followPlan(current: Iterable<string>, want: string[], keep?: string): { add: string[], drop: string[] }
  export function channelFollow(current: string, view?: { channel?: string | null, peer?: string | null }): { sub: string, unsub: string, next: string }
  export function rowFromAck(ack: unknown, frame: unknown, who?: { from?: string, channel?: string | null }): Record<string, unknown>
  export function rootsByTask<T extends { task_id?: string }>(messages: T[]): T[]
  export function threadReplies(messages: { task_id?: string, parent_task_id?: string | null }[], taskId: string): number
  export function channelView<T>(messages: T[], opts?: { search?: string, visible?: number }): { rows: T[], hasOlder: boolean }
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
  export function createAuthClient(opts?: { fetchFn?: typeof fetch, base?: string, locale?: string | (() => string) }): {
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
  export function subjectOf(body: string): string
  export function hubField(v: unknown): string | null
  export function channelReadQuery(read: Record<string, string>): string[]
  export function isDownloadable(file: { mode?: string, file_id?: string, sha256?: string }): boolean
}

declare module '~/utils/feed.mjs' {
  export function newestFirst<T>(messages: T[]): T[]
  export function windowed<T>(rows: T[], count: number): { rows: T[], hasOlder: boolean }
  export function parseOmnibox(text: string): { search?: string, send?: string }
  export function matchesSearch(m: unknown, q: string): boolean
  export function rootAndReplies<T>(messages: T[]): { root: T | null, replies: T[] }
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
  export function loadAvatarBlobUrl(url: string, o?: {
    credentials?: RequestCredentials
    fetchFn?: typeof fetch
    createObjectURL?: (b: Blob) => string
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
    | { state: 'ok', result: { tenant_id: string, tenant_url: string, root_private_key: string } }
    | { state: 'claimed' | 'expired' | 'failed' | 'cancelled' | 'stopped' }
    | { state: 'error', error: string }
  export interface CheckoutClient {
    plan(): Promise<CheckoutResult>
    start(b: { tenant_id: string, email: string }): Promise<CheckoutResult>
    status(id: string): Promise<CheckoutResult>
    claim(b: { checkout_id: string, claim_token: string }): Promise<CheckoutResult>
    fakePay(id: string): Promise<CheckoutResult>
  }
  export function checkoutErrorMessage(code: string): string
  export function formatPrice(cents: unknown, currency: unknown): string
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
  export function methodLabel(p: unknown): string
  export function menuButtonLabel(claims: unknown): string
  export function nextMenuIndex(current: number, key: string, count: number): number
  export function signInRedirect(fullPath: string): string
}

declare module '~/utils/pane-widths.mjs' {
  export const SIDEBAR_DEFAULT: number
  export const THREAD_DEFAULT: number
  export const SIDEBAR_MIN: number
  export const SIDEBAR_MAX: number
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
