declare module '~/utils/spool-client.mjs' {
  export function sha256Hex(buf: ArrayBuffer): Promise<string>
  export function createSpoolClient(opts?: {
    base?: string
    fetchFn?: typeof fetch
    mock?: boolean
    token?: string
    tenant?: string
    configError?: string
  }): {
    mock: boolean
    tenant: string
    configError: string
    base: string
    readonly token: string
    uploadFile(file: Blob, uploadToken?: string): Promise<{ file_id: string, sha256: string, bytes: number }>
    downloadFile(fileId: string): Promise<ArrayBuffer>
    setToken(token: string): void
    hasToken(): boolean
    healthz(): Promise<unknown>
    listThreads(opts?: { limit?: number, before?: string }): Promise<{
      threads: import('./spool').ThreadRow[]
      next: string | null
    }>
    getThread(taskId: string, opts?: { limit?: number, after?: string, order?: 'desc', before?: string }): Promise<{
      task_id: string
      messages: import('./spool').SpoolMessage[]
      next: string | null
    }>
    listChannels(): Promise<{ channel_id: string, name: string, created_by?: string }[]>
    listMessages(opts?: {
      channel?: string
      peer?: string
      limit?: number
      since?: string
    }): Promise<Record<string, unknown>[]>
    listRoster(): Promise<unknown>
    sendMessage(opts: {
      channel?: string | null
      peer?: string
      text: string
      parent_task_id?: string
      files?: unknown[]
    }): Promise<Record<string, unknown>>
    createChannel(opts: { channel_id?: string, name?: string }): Promise<{
      channel_id: string
      name: string
      created_by?: string
    }>
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
    ackTimeoutMs?: number
  }): {
    readonly state: string
    readonly welcome: Record<string, unknown> | null
    connect(): void
    close(): void
    subscribe(taskId: string): void
    unsubscribe(taskId: string): void
    requestToken(): Promise<Record<string, unknown>>
    send(opts: { task_id: string, kind?: string, body?: string, files?: unknown[], to?: string }): Promise<Record<string, unknown>>
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
  export function startHref(provider: string, redirect: string, tenant?: string): string
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
  export function createAuthClient(opts?: { fetchFn?: typeof fetch, base?: string }): {
    loadProviders(): Promise<{ status: 'ok' | 'unavailable', reason: string, providers: string[], native: boolean }>
    register(b: { email: string, password: string, name?: string }): Promise<NativeResult>
    verifyEmail(token: string): Promise<NativeResult>
    login(b: { email: string, password: string, tenant?: string, redirect?: string }): Promise<NativeResult>
    forgotPassword(email: string): Promise<NativeResult>
    resetPassword(b: { token: string, password: string }): Promise<NativeResult>
    changePassword(b: { current: string, next: string }): Promise<NativeResult>
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
  export function prefixOf(id: string): string
  export function robotSvg(key: string): string
  export function identiconSvg(key: string): string
  export function avatarSvg(id: string, box?: string): string
  export function avatarDataUri(id: string, box?: string): string
}
