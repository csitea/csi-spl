declare module '~/utils/spool-client.mjs' {
  export function sha256Hex(buf: ArrayBuffer): Promise<string>
  export function credentialsFor(door: string): 'include' | 'omit'
  export function normalizeChannelId(channel: string): string
  export function isPublicChannel(channel: string): boolean
  export function rosterHumanIds(roster: Record<string, readonly string[]> | null | undefined): string[]
  export function channelInviteCandidates(rosterIds: readonly string[], memberIds: readonly string[]): string[]
  export function filterPeopleContains(ids: readonly string[] | null | undefined, query?: string, names?: Record<string, string> | null): string[]
  export function filterAgentsContains(rows: readonly { id?: string, box?: string }[] | null | undefined, query?: string): { id: string, box: string }[]
  export function inviteErrorToken(err: unknown): string
  export function signedInHuman(me: { humanId?: string | null } | null | undefined, opts?: { mock?: boolean, rosterMe?: string }): string
  export function viewerHumanId(me: { humanId?: string | null } | null | undefined, socketId?: string, opts?: { mock?: boolean, rosterMe?: string }): string
  export function canAddChannelMember(opts: { selfId?: string, createdBy?: string, membersOpenInvite?: boolean }): boolean
  export function canEditOpenInvite(opts: { selfId?: string, createdBy?: string }): boolean
  export function canDeleteChannel(opts: { selfId?: string, row?: { channel_id?: string, default?: boolean, created_by?: string } }): boolean
  export function channelAgentRows(agents: readonly { id?: string, box?: string }[] | null | undefined): { id: string, box: string }[]
  export function channelAgentCandidates(roster: Record<string, readonly string[]> | null | undefined, current: readonly { id?: string, box?: string }[] | null | undefined): { id: string, box: string }[]
  export function defaultChannelRows(roster: Record<string, readonly string[]> | null | undefined, subscribed: readonly { id?: string, box?: string }[] | null | undefined): { people: string[], agents: { id: string, box: string }[] }
  export function aboutChannelName(row: { name?: string, channel_id?: string, channel?: string } | null | undefined): string
  export function aboutChannelDescription(row: { description?: string } | null | undefined): string
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
    guessDoor(door: import('./spool').ViewDoor | string): void
    readonly doorGuessed: boolean
    rosterView(): Promise<unknown>
    setSender(fn: ((frame: import('./spool').SendFrame) => Promise<unknown>) | null): void
    uploadFile(file: Blob, uploadToken?: string): Promise<{ file_id: string, sha256: string, bytes: number }>
    downloadFile(fileId: string): Promise<ArrayBuffer>
    setToken(token: string): void
    hasToken(): boolean
    healthz(): Promise<unknown>
    search(opts?: { q?: string, cursor?: string, limit?: number, sort?: string }): Promise<import('~/utils/search.mjs').SearchResult>
    searchOperators(): Promise<import('~/utils/search.mjs').SearchOperator[]>
    listTopics(opts?: {
      limit?: number
      before?: string
      channel?: string
      dm?: boolean
      peer?: string
      agent?: string
      roots?: boolean
      perTopic?: number
    }): Promise<{
      topics: Array<import('./spool').TopicRow & { inline?: { task_id: string, messages: import('./spool').SpoolMessage[], next: string | null } }>
      next: string | null
    }>
    getTopic(taskId: string, opts?: { limit?: number, after?: string, order?: 'desc', before?: string }): Promise<{
      task_id: string
      messages: import('./spool').SpoolMessage[]
      next: string | null
    }>
    me(): Promise<Record<string, unknown> | null>
    removeMember(humanId: string): Promise<null>
    listTenantUsers(): Promise<unknown>
    inviteTenantUser(opts: { email: string, role?: string, locale?: string }): Promise<{ email?: string, role?: string, mail?: string } | null>
    setTenantUserRole(humanId: string, role: string, fromRole?: string): Promise<unknown>
    removeTenantUser(humanId: string): Promise<null>
    revokeTenantInvite(email: string): Promise<null>
    listChannels(opts?: { read?: Record<string, string> }): Promise<import('./spool').ChannelRow[]>
    listMessages(opts?: {
      channel?: string
      peer?: string
      limit?: number
      since?: string
      topics?: number
      before?: string
    }): Promise<{ messages: import('./spool').SpoolMessage[], next: string | null }>
    listRoster(): Promise<unknown>
    sendMessage(opts: {
      channel?: string | null
      peer?: string
      text: string
      task_id?: string
      parent_task_id?: string
      is_parent?: 0 | 1
      files?: unknown[]
      from?: string
      msg_id?: string
    }): Promise<import('./spool').SpoolMessage>
    createChannel(opts: { channel_id?: string, name?: string, description?: string }): Promise<import('./spool').ChannelRow>
    listChannelMembers(channel: string): Promise<{ channel: string, default: boolean, members: string[], members_open_invite: boolean, created_by: string, agents: { id: string, box: string }[] }>
    addChannelMember(channel: string, humanId: string): Promise<{ channel: string, human_id: string, added_by?: string }>
    addChannelAgent(channel: string, agentId: string, box: string): Promise<{ channel: string, id: string, box: string }>
    removeChannelMember(channel: string, humanId: string): Promise<null>
    removeChannelAgent(channel: string, agentId: string, box: string): Promise<null>
    setMembersOpenInvite(channel: string, open: boolean): Promise<{ channel: string, members_open_invite: boolean }>
    /** SPL-72: the creator deletes a channel (soft, channels-v1 §5.4). */
    deleteChannel(channel: string): Promise<null>
    /** message-edit-v1 §1: PATCH /v1/messages/{msg_id} with { body }. */
    editMessage(msgId: string, body: string): Promise<import('./spool').SpoolMessage>
    deleteMessage(msgId: string): Promise<null>
    /** Add (`op` add) or remove the viewer's emoji. Same call for is_parent 0 and 1. */
    setReaction(msgId: string, emoji: string, op: 'add' | 'remove', current?: { emoji: string, actors: string[] }[]): Promise<import('./spool').ReactionUpdate>
    fileUrl(fileId: string): string
    bindIssuesMock(factory: (me: string) => unknown): void
    listIssues(opts?: { filter?: import('~/utils/issues.mjs').IssueFilter, sort?: string }): Promise<import('~/utils/issues.mjs').IssueList>
    getIssue(ref: string): Promise<{ issue: import('~/utils/issues.mjs').Issue }>
    createIssue(body: import('~/utils/issues.mjs').IssueBody): Promise<{ issue: import('~/utils/issues.mjs').Issue }>
    updateIssue(ref: string, patch: import('~/utils/issues.mjs').IssueBody): Promise<{ issue: import('~/utils/issues.mjs').Issue }>
    createIssueLabel(opts: { name: string, color?: string }): Promise<{ label: import('~/utils/issues.mjs').IssueLabel }>
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
    /** `message_deleted`: drop a row. */
    onDeleted?: (m: Record<string, unknown>, raw: unknown) => void
    /** `message_reaction`: replace the emoji list on a held row. */
    onReaction?: (m: Record<string, unknown>, raw: unknown) => void
    onIssue?: (f: Record<string, unknown>) => void
    onIssueLabel?: (f: Record<string, unknown>) => void
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
  export const SIDE_TABS: readonly ['dm', 'channels', 'topics', 'flow']
  export const USERS_TAB: 'users'
  export const EVENTS_TAB: 'events'
  export const ISSUES_TAB: 'issues'
  export function tabForPath(path: string): 'dm' | 'channels' | 'topics' | 'flow' | 'users' | 'events' | 'issues' | null
  export function switchPaneOf(text: string): 'dm' | 'channels' | 'topics' | 'flow' | '' | null
  export function flowRows(src?: {
    channels?: unknown[]
    peers?: unknown[]
    topics?: unknown[]
    liveAt?: Record<string, string>
    dmAt?: Record<string, string>
  }): {
    kind: 'channel' | 'dm' | 'topic'
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
  export function topicOf<T extends { task_id?: string, parent_task_id?: string | null, ts?: string }>(
    messages: T[],
    parentTaskId: string | null,
  ): T[]
  export function replyCount(messages: { parent_task_id?: string | null }[], taskId: string): number
  export function applyVerbosity<T extends { kind?: string, body?: string }>(messages: T[], level: string): T[]
  export function parseMention(text: string): { to: string, kind: string, body: string }
  export function displayName(id: string, box?: string): string
  export function personLabel(id: string, box: string | undefined, names: Record<string, string> | null | undefined): string
  export function mentionDisplay(text: string, names: Record<string, string> | null | undefined): { text: string, title: string }
  export function peopleLabels(peers: readonly string[] | null | undefined, names: Record<string, string> | null | undefined): string
  export function shownPerson(id: string, box: string | undefined, names: Record<string, string> | null | undefined): string
  export function personTitle(id: string, box: string | undefined, names: Record<string, string> | null | undefined): string
  export function namedLine(line: string, names: Record<string, string> | null | undefined): { text: string, title: string }
  export function initials(id: string): string
  export function hueFor(id: string): number
  export function formatBytes(n: number | undefined, locale?: string): string
  export function formatTs(ts: string, locale?: string): string
  export function formatAbsTs(ts: string): string
  export function formatIsoTs(ts: string): string
  export function formatMsgListTs(ts: string): string
  export function recipientOf(msg: unknown): { id: string, box: string } | null
  export function formatElapsed(sec: number): string
  export function formatTopicTs(ts: string, originMs?: number): string
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
  export function topicReplies(messages: { task_id?: string, parent_task_id?: string | null }[], taskId: string): number
  export function channelView<T>(messages: T[], opts?: { search?: string, visible?: number, lobby?: boolean }): { rows: T[], hasOlder: boolean }
  export function rowsForRightPane<T>(topicRows: T[], held: T[], topicId: string): T[]
  export function topicCards<T extends { task_id?: string }>(messages: T[]): T[]
  export function channelActivity(row: unknown, liveAt?: Record<string, string>): string
  export function orderChannels<T extends { channel_id?: string }>(rows: T[], liveAt?: Record<string, string>): T[]
  export function orderPeers<T extends { label?: string, online?: boolean }>(rows: T[], lastAt?: Record<string, string>): T[]
  export function dmActivity(topics: unknown[], self?: string): Record<string, string>
  export function dmPeerOf(msg: unknown, self?: string): string
  export function noteActivity(
    maps: { channels?: Record<string, string>, peers?: Record<string, string> },
    msg: unknown,
    self?: string,
  ): { channels: Record<string, string>, peers: Record<string, string> }
  export function addChannelRow<T>(rows: T[], frame: unknown): T[]
  export function applyChannelFrame<T>(rows: T[], frame: unknown): T[]
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
    names?: Record<string, string> | null,
  ): { id: string, box?: string, label?: string, online?: boolean, owner?: boolean }[]
  export function insertMention(
    text: string,
    cursor: number,
    id: string,
  ): { text: string, cursor: number }
  export function ownerMentions(
    owners: string[] | undefined,
    query: string,
    names?: Record<string, string> | null,
    selfId?: string,
    isOnline?: ((id: string) => boolean) | null,
  ): { id: string, box: string, label: string, owner: true, online: boolean }[]
}


declare module '~/utils/feedback-channel.mjs' {
  export const FEEDBACK_CHANNEL_ID: string
  export function isFeedbackChannel(id: string | null | undefined): boolean
  export function feedbackChannelFromPath(path: string | null | undefined): string
  export function feedbackChannelCopy(
    channelId: string | null | undefined,
    copy: { name?: string, description?: string } | null | undefined,
    storedDescription?: string,
  ): { name: string, description: string } | null
}

declare module '~/utils/topic-in.mjs' {
  export function activeInQuery(text: string, cursor?: number): string | null
  export function filterTopicTitles<T extends { title?: string }>(topics: T[], query: string): T[]
  export function insertInClause(text: string, cursor: number, title: string): { text: string, cursor: number }
  export function topicChoices(src?: {
    topics?: unknown[]
    messages?: unknown[]
  }): { taskId: string, title: string, channel: string }[]
  export function resolveInClause(
    text: string,
    choices: { taskId?: string, title?: string, channel?: string }[],
  ): { taskId: string, channel: string, title: string, body: string }
}


declare module '~/utils/born-topics.mjs' {
  export function noteBornTopic<T>(rows: T[] | null | undefined, paneOpen: unknown, topicId: unknown, row: unknown): T[]
  export function dismissBornTopic<T extends { msg_id?: string }>(rows: T[] | null | undefined, msgId: string): T[]
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
    verifyEmail(a: { token: string; password: string }): Promise<NativeResult>
    login(b: { email: string, password: string, tenant?: string, redirect?: string }): Promise<NativeResult>
    forgotPassword(email: string): Promise<NativeResult>
    resetPassword(b: { token: string, password: string }): Promise<NativeResult>
    changePassword(b: { current: string, next: string }): Promise<NativeResult>
    savePreferences(b: { preferred_locale: string }): Promise<NativeResult>
    saveDiagnostics(on: boolean): Promise<NativeResult>
    saveDisplayName(name: string): Promise<NativeResult>
    switchTenant(tenant: string): Promise<NativeResult>
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

declare module '~/utils/tenant-switcher.mjs' {
  export function fixedTenantOption(claims: unknown, configured?: unknown): { id: string, label: string }
  export function tenantSwitchOptions(claims: unknown, configured?: unknown): { selected: string, canSwitch: boolean, options: { id: string, label: string }[] }
  export function tenantHint(box: { selected: string, canSwitch: boolean, options: { id: string, label: string }[] }, t: (key: string, params?: Record<string, string>) => string): string
  export const TENANT_ARROW_GAP_PX: 3
  export function tenantDrawnLabels(options: unknown, fallback: unknown): string[]
  export function widestLabelWidth(labels: unknown, measure: (label: string) => number): number
  export function tenantClosedWidthPx(widestTextPx: unknown, arrowPx: unknown, gapPx?: unknown): number
  export function tenantNameArrowGapPx(box: {
    selLeft: number
    selRight: number
    padStartPx?: number
    widestPx: number
    arrowLeft: number
    arrowRight: number
    direction?: string
  }): number
  export function measureControlText(source: object | null | undefined, text: unknown): number
}

declare module '~/utils/view-api.mjs' {
  export const BROWSER_BOX: string
  export function rosterFromView(data: unknown): { roster: Record<string, string[]>, online: string[], owners: string[] }
  export function subjectOf(body: string): string
  export function topicOpening(text: string): string
  export function topicTitleFromRows(rows: unknown, pinnedRoot?: { body?: string, ts?: string } | null): string
  export function hubField(v: unknown): string | null
  export function channelReadQuery(read: Record<string, string>): string[]
  export function isDownloadable(file: { mode?: string, file_id?: string, sha256?: string }): boolean
  export function normalizeViewMessage(el: unknown): import('./spool').SpoolMessage
  export function copyEditFields<T extends Record<string, unknown>>(src: unknown, out: T): T
}

declare module '~/utils/pane-focus.mjs' {
  export const MIDDLE: 'middle'
  export const RIGHT: 'right'
  export function paneOfTarget(el: unknown): '' | 'middle' | 'right'
  export function paneTakesLine(opts?: { paneOpen?: boolean, lastPane?: string }): boolean
}

declare module '~/utils/typed-by.mjs' {
  export function typedByAuthor(msg: { from?: string, from_box?: string, typed_by?: string } | null | undefined): { id: string, box: string, via: string, viaBox: string }
}

declare module '~/utils/msg-menu.mjs' {
  export function msgMenuItems(opts?: { editable?: boolean, mergePrev?: boolean, mergeNext?: boolean, parent?: boolean }): { id: 'open' | 'parent' | 'edit' | 'copy' | 'merge-prev' | 'merge-next' | 'delete', icon: 'open' | 'parent' | 'pencil' | 'copy' | 'merge' | 'trash', labelKey: string }[]
  export function messageLink(msg: unknown, pathFor: (path: string) => string): string
  export function topicPaneLink(msg: unknown, where?: { path?: string, query?: Record<string, unknown>, currentTaskId?: string }): string
  export function threadLineLink(msg: unknown, where?: { path?: string, query?: Record<string, unknown>, pathFor?: (path: string) => string }): string
  export function threadNeighbor(rows: unknown[], msg: unknown, which: 'previous' | 'next'): Record<string, unknown> | null
  export function joinBodies(older: unknown, newer: unknown): string
}

declare module '~/utils/parent-section.mjs' {
  export const ISSUE_CHANNEL: 'issues'
  export interface ParentSection { path: string, query: Record<string, string>, hash: string, kind: 'channel' | 'dm' | 'issue' }
  export function parentChannelOf(msg: unknown): string
  export function parentTopicOf(msg: unknown): string
  export function mayBeIssueTopic(msg: unknown): boolean
  export function parentSection(msg: unknown, opts?: { self?: string, target?: { taskId?: string, mode?: string, parentTaskId?: string } | null, issueKey?: string }): ParentSection | null
  export function parentSectionHref(section: { path: string, query?: Record<string, string>, hash?: string } | null, pathFor?: (path: string) => string): string
  export function issueKeyForTask(list: unknown, taskId: string): string
}

declare module '~/utils/parent-section-open.mjs' {
  export const REVEAL_PAGES: number
  export function openParentSection(msg: unknown, deps: { self: string, api: unknown, router: unknown, localePath: (p: string) => string }): Promise<boolean>
}

declare module '~/utils/msg-edit.mjs' {
  import type { SpoolMessage } from './spool'
  /** what the editor holds while it is open: the draft, and what Escape restores */
  export interface MsgEditState { msgId: string, original: string, draft: string }
  export const EDIT_KEY: string
  export function isOwnMessage(msg: unknown, viewer: { id?: string, box?: string } | null): boolean
  export function canEditMessage(msg: unknown, viewer: { id?: string, box?: string } | null): boolean
  export function wantsEdit(ev: KeyboardEvent, opts?: { editable?: boolean }): boolean
  export function wantsDblClickEdit(ev: MouseEvent, opts?: { editable?: boolean, interactive?: boolean }): boolean
  export const DELETE_KEYS: string[]
  export function wantsDelete(ev: KeyboardEvent, opts?: { deletable?: boolean }): boolean
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

declare module '~/utils/emoji.mjs' {
  export const EMOJI_CHOICES: string[]
  export function validEmoji(s: string): boolean
  export function normalizeReactions(list: unknown): { emoji: string, actors: string[] }[]
  export function reactionChips(list: unknown, me?: string): { emoji: string, count: number, mine: boolean }[]
  export function reactionOp(list: unknown, emoji: string, me?: string): 'add' | 'remove'
  export function applyReactions<T>(list: T[], update: unknown): T[]
  export function readRecent(storage?: Storage | null): string[]
  export function rememberEmoji(emoji: string, storage?: Storage | null): string[]
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
    is_parent?: 0 | 1
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

declare module '~/utils/pane-scroll.mjs' {
  export function scrollRowToTop(scroller: HTMLElement, row: Element): void
  export function openThreadRow(row: HTMLElement | null | undefined): void
}

declare module '~/utils/topic-list.mjs' {
  export function bumpTopic<T>(topics: T[], m: Record<string, unknown>): T[]
  export function mergeTopicPage<T>(topics: T[], page: T[]): T[]
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
  export function humanNamesFromView(data: unknown): Record<string, string>
  export function loadHumanNames(o?: { base?: string, token?: string, credentials?: RequestCredentials, read?: (() => Promise<unknown>) | null }): Promise<Record<string, string>>
  export function avatarImageUrl(base: string, id: string, box: string | undefined, files: Record<string, string>): string
  export function avatarAlt(id: string, box?: string): string
  export function avatarAltKey(id: string, box?: string): { key: string, params: Record<string, string> }
  export const AVATAR_FILES_TTL_MS: number
  export function loadAvatarFiles(o?: {
    base?: string
    token?: string
    credentials?: RequestCredentials
    fetchFn?: typeof fetch
    read?: (() => Promise<unknown>) | null
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
  export function forgetRosterRead(): void
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
  export const TOPIC_DEFAULT: number
  export const SIDEBAR_MIN: number
  export const SIDEBAR_MAX_RATIO: number
  export function sidebarMaxPx(viewportW: number): number
  export const TOPIC_MIN: number
  export const TOPIC_MAX_RATIO: number
  export function topicMaxPx(viewportW: number): number
  export const MAIN_MIN: number
  export const DIVIDER_W: number
  export const STEP: number
  export const PANE_WIDTHS_KEY: string
  export const SIDEBAR_NARROW_MAX: number
  export const TOPIC_NARROW_MAX: number
  export function num(v: unknown, fallback: number): number
  export function clamp(n: number, min: number, max: number): number
  export function sidebarShown(viewportW: number): boolean
  export function topicShown(viewportW: number, topicOpen: boolean): boolean
  export function clampSidebar(width: unknown, ctx?: {
    viewportW?: number, topicOpen?: boolean, topicW?: number, sidebarW?: number
  }): number
  export function clampTopic(width: unknown, ctx?: {
    viewportW?: number, topicOpen?: boolean, topicW?: number, sidebarW?: number
  }): number
  export function clampPair(sidebar: unknown, topic: unknown, ctx?: {
    viewportW?: number, topicOpen?: boolean
  }): { sidebar: number, topic: number }
  export function sidebarRange(ctx?: {
    viewportW?: number, topicOpen?: boolean, topicW?: number, sidebarW?: number
  }): { min: number, max: number }
  export function topicRange(ctx?: {
    viewportW?: number, topicOpen?: boolean, topicW?: number, sidebarW?: number
  }): { min: number, max: number }
  export function applySeparatorKey(
    pane: 'sidebar' | 'topic' | 'issue',
    key: string,
    current: number,
    min: number,
    max: number,
  ): number
  export function pointerDelta(
    pane: 'sidebar' | 'topic' | 'issue',
    startWidth: number,
    startX: number,
    clientX: number,
  ): number
  export function loadPaneWidths(store?: unknown): { sidebar: number, topic: number }
  export function savePaneWidths(widths: { sidebar: number, topic: number }, store?: unknown): boolean
  export function resetPane(pane: 'sidebar' | 'topic'): number
}

declare module '~/utils/code-blocks.mjs' {
  export type BodyPart =
    | { type: 'text' | 'strong' | 'em' | 'mention' | 'inline', text: string }
    | { type: 'link', text: string, href: string }
  export type BodyBlock =
    | { type: 'code', text: string, lang: string, closed: boolean }
    | { type: 'para' | 'quote', parts: BodyPart[] }
    | { type: 'heading', level: number, parts: BodyPart[] }
    | { type: 'list', ordered: boolean, items: { parts: BodyPart[] }[] }
  export function normalizeNewlines(src: string): string
  export function parseBody(src: string): BodyBlock[]
  export function bodyToHtml(src: string, origin?: string): string
  export function isMarkdownLang(lang: string | null | undefined): boolean
  export function hasMarkdownBlock(src: string): boolean
  export function linkParts(text: string): BodyPart[]
  export function fenceStateAt(text: string, caret?: number): { inCode: boolean, lang: string }
  export function enterAction(o: { inCode?: boolean, shift?: boolean, alt?: boolean, mod?: boolean }): 'send' | 'newline'
  export function exitFence(text: string, caret?: number): { text: string, cursor: number }
  export function closeOpenFence(text: string): string
}

declare module '~/utils/omnibox-size.mjs' {
  export const OMNIBOX_LINE_PX: 36
  export function omniboxFocusHeight(
    userHeight: number | null | undefined,
    openHeight: number | null | undefined,
    maxPx: number,
  ): number | null
  export function omniboxRememberHeight(s: {
    userHeight?: number | null
    openHeight?: number | null
    measured: number
    keep: boolean
  }): number | null
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

declare module '~/utils/link-target.mjs' {
  export const NEW_TAB_REL: string
  export function classifyHref(raw: string, pageOrigin?: string): { href: string, internal: boolean } | null
  export function linkOpen(href: string, pageOrigin?: string): { href: string, internal: boolean, target?: string, rel?: string } | null
  export function sameTabPath(href: string, pageHref: string): string | null
  export function followSameTabLink(
    event: { button?: number, metaKey?: boolean, ctrlKey?: boolean, shiftKey?: boolean, altKey?: boolean, defaultPrevented?: boolean, preventDefault?: () => void },
    href: string,
    pageHref: string,
    navigate: (path: string) => unknown,
  ): boolean
}

declare module '~/utils/markdown.mjs' {
  export type MdNode = string | { tag: string, attrs: Record<string, string>, children: MdNode[] }
  export const TAGS: Set<string>
  export const ATTRS: Record<string, Set<string>>
  export function safeHref(raw: string): string
  export function markdownTree(src: string): MdNode[]
  export function treeToHtml(nodes: MdNode[], origin?: string): string
  export function markdownToHtml(src: string, origin?: string): string
  export function renderMarkdown(src: string, origin?: string): string
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
  export type SearchGroupType = 'robots' | 'users' | 'channels' | 'boxes' | 'tenants' | 'topics' | 'files' | 'messages' | 'events' | 'issues'
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
  export const SEARCH_OPERATORS: SearchOperator[]
  export const OP_PICKER_CAP: number
  export function ensureSearchOperators(catalogue?: SearchOperator[]): SearchOperator[]
  export function operatorHelpRows(catalogue?: SearchOperator[]): { op: string, example: string, values: string[], hintKey: string }[]
  export function shouldLoadOperators(o?: { mock?: boolean, sessionState?: string }): boolean
  export function omniboxMode(text: string): 'search' | 'send'
  export function omniboxTextLeavingSearch(text: string): string
  export function searchQueryOf(text: string): string
  export function searchPath(q: string): string
  export function searchApiQuery(o: { q?: string, cursor?: string, limit?: number, sort?: string }): string
  export function operatorTokenAt(text: string, caret?: number): { token: string, start: number, end: number } | null
  export function completeOperators(token: string, catalogue?: SearchOperator[], roster?: { id: string, label?: string }[]): { insert: string, label: string }[]
  export function applyCompletion(text: string, tok: { start: number, end: number }, insert: string): { text: string, cursor: number }
}


declare module '~/utils/search-results.mjs' {
  import type { SearchGroup, SearchGroupType, SearchOperator, SearchResult, SearchRow } from '~/utils/search.mjs'
  export const SEARCH_GROUPS: SearchGroupType[]
  export function normalizeOperators(data: unknown): SearchOperator[]
  export function rowAt(row: unknown): string
  export function highlightSegments(text: string, highlights: unknown): { text: string, mark: boolean }[]
  export function normalizeSearchResponse(data: unknown): SearchResult
  export function mergeSearchPage(cur: SearchResult, page: SearchResult): SearchResult
  export function flattenGroups(groups: SearchGroup[]): SearchRow[]
  export function moveIndex(i: number, n: number, key: string): number
  export function searchTarget(row: unknown): { topic: string, focus: string } | { path: string } | { search: string } | { tenant: string } | null
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

declare module '~/utils/tenant-users.mjs' {
  export type UserMember = { kind: 'member', key: string, humanId: string, displayName: string, email: string, role: string, since: string, disabled: boolean, you: boolean, manageable: boolean }
  export type UserInvite = { kind: 'invite', key: string, email: string, role: string, invitedBy: string, createdAt: string, expiresAt: string, expired: boolean }
  export type UserRow = UserMember | UserInvite
  export const USERS_PERMISSION: string
  export const USER_PANE_SIDE: 'left' | 'right'
  export function usersEntryVisible(me: { permissions: string[] | null } | null | undefined, opts?: { mock?: boolean }): boolean
  export function normalizeDirectory(body: unknown): { you: string, members: UserMember[], invites: UserInvite[], roles: { id: string, grantable: boolean }[] }
  export function memberLabel(row: UserRow | null | undefined): string
  export function userErrorKey(err: unknown): string
  export function looksLikeEmail(s: unknown): boolean
  export function createMockDirectory(now?: () => Date): unknown
}

declare module '~/utils/theme.mjs' {
  export type SpoolTheme = 'dark' | 'light' | 'light-violet' | 'light-green' | 'light-yellow' | 'light-orange' | 'light-red'
  export type SpoolThemeOption = { id: SpoolTheme, labelKey: string, swatch: [string, string] }
  export const THEME_KEY: 'spool-theme'
  export const THEME_DEFAULT: 'dark'
  export const THEMES: SpoolThemeOption[]
  export const THEME_IDS: SpoolTheme[]
  export function parseTheme(raw: unknown, fallback?: SpoolTheme): SpoolTheme
  export function labelKeyForTheme(theme: unknown): string
  export function themeIndex(theme: unknown): number
  export function readStoredTheme(store?: unknown, fallback?: SpoolTheme): SpoolTheme
  export function writeStoredTheme(theme: unknown, store?: unknown): boolean
  export function applyThemeAttr(theme: unknown, el?: { setAttribute?(k: string, v: string): void } | null): SpoolTheme
}

declare module '~/utils/display-name.mjs' {
  export const MAX_DISPLAY_NAME: number
  export function validDisplayName(raw: unknown): { ok: boolean, name: string }
  export function applyDisplayName(
    raw: unknown,
    io: { current: unknown, save: (name: string) => Promise<{ ok: boolean, data?: unknown }>, apply: (name: string) => void },
  ): Promise<{ ok: boolean, name: string, reason?: 'invalid' | 'unchanged' | 'refused', out?: unknown }>
}

declare module '~/utils/debug-pane.mjs' {
  export function applyDebugPaneSetting(
    want: unknown,
    io: { current: unknown, apply: (on: boolean) => void, save: (on: boolean) => Promise<{ ok: boolean }> },
  ): Promise<{ ok: boolean, value: boolean, out?: unknown }>
}

declare module '~/utils/font-size.mjs' {
  export const FONT_SIZE_KEY: 'spool-font-size'
  export const FONT_SIZE_MIN: 1
  export const FONT_SIZE_MAX: 5
  export const FONT_SIZE_DEFAULT: 3
  export const FONT_SIZE_PERCENT: Readonly<Record<1 | 2 | 3 | 4 | 5, number>>
  export const FONT_SIZE_LEVELS: readonly number[]
  export function parseFontSize(raw: unknown, fallback?: number): number
  export function stepFontSize(level: unknown, delta: number): number
  export function canShrinkFont(level: unknown): boolean
  export function canGrowFont(level: unknown): boolean
  export function readStoredFontSize(store?: unknown, fallback?: number): number
  export function writeStoredFontSize(level: unknown, store?: unknown): boolean
  export function applyFontSizeAttr(level: unknown, el?: { setAttribute?(k: string, v: string): void } | null): number
}


declare module '~/utils/transfer-files.mjs' {
  export function carriesFiles(dt: DataTransfer | null | undefined): boolean
  export function filesOf(dt: DataTransfer | null | undefined): File[]
  export function pasteAttaches(dt: DataTransfer | null | undefined): boolean
}

declare module '~/utils/file-preview.mjs' {
  export const PREVIEW_MAX_BYTES: number
  export function isPreviewableImage(name: string | null | undefined, bytes?: number | null): boolean
  export function previewImageMime(bytes: ArrayBuffer | Uint8Array | null | undefined): string
  export type FileKind = 'pdf' | 'doc' | 'sheet' | 'slides' | 'image' | 'archive' | 'code' | 'media' | 'other'
  export function fileExt(name: string | null | undefined): string
  export function fileKind(name: string | null | undefined): {
    kind: FileKind
    icon: 'file' | 'file-text' | 'file-spreadsheet' | 'file-slides' | 'file-image' | 'file-archive' | 'file-code' | 'file-media'
    ext: string
  }
  export function readDataUrl(file: Blob): Promise<string>
  export const PREVIEW_CACHE_MAX: number
  export function sharedPreview(fileId: string, load: () => Promise<string>): Promise<string>
  export function resetSharedPreviews(): void
}

declare module '~/utils/error-snackbar.mjs' {
  export const SNACKBAR_MAX: number
  export const SNACKBAR_TTL_MS: number
  export const SNACKBAR_COALESCE_MS: number
  export const SNACKBAR_TICK_MS: number
  export const SNACKBAR_REPLAY_MS: number
  export const SNACKBAR_TEXT_CHARS: number
  export function snackbarText(rec: unknown): string
  export interface SnackbarItem {
    id: string
    errorId: string
    text: string
    source: string
    status: number
    count: number
    at: string
    expiresAt: number
    held: boolean
  }
  export function createSnackbarQueue(opts?: {
    now?: () => number
    max?: number
    ttlMs?: number
    coalesceMs?: number
  }): {
    push(rec: unknown): string
    dismiss(id: string): void
    hold(id: string, on: boolean): void
    tick(): boolean
    clear(): void
    subscribe(fn: (items: SnackbarItem[]) => void): () => void
    items(): SnackbarItem[]
  }
  export function bindSnackbarToJournal(
    queue: ReturnType<typeof createSnackbarQueue>,
    journal: {
      getErrors: () => unknown[]
      subscribeErrors: (fn: (r: unknown[]) => void) => () => void
      now?: () => number
    },
  ): () => void
}

declare module '~/utils/event-log.mjs' {
  export const EVENT_FIELDS: Readonly<Record<string, string>>
  export const EVENT_CAPS: Readonly<Record<string, number>>
  export const EVENT_BATCH_MAX: number
  export const EVENT_QUEUE_MAX: number
  export const EVENT_FLUSH_DELAY_MS: number
  export const EVENT_RETRY_MAX: number
  export function toEventPayload(rec: unknown): Record<string, unknown> | null
  export interface EventsClientResult {
    ok: boolean
    status: number
    data: unknown
    error: string
    retryAfter: number
  }
  export function createEventsClient(opts?: { fetchFn?: typeof fetch, base?: string }): {
    list(opts?: { limit?: number, before?: number }): Promise<EventsClientResult>
    add(events: unknown[]): Promise<EventsClientResult>
    clear(): Promise<EventsClientResult>
  }
  export function createEventShipper(opts: {
    client: ReturnType<typeof createEventsClient>
    session: () => string
    setTimer?: (fn: () => void, ms: number) => unknown
    clearTimer?: (h: unknown) => void
    delayMs?: number
  }): {
    note(rec: unknown): void
    flush(): Promise<number>
    sessionChanged(): void
    stop(): void
    size(): number
  }
  export function bindShipperToJournal(
    shipper: { note: (r: unknown) => void },
    journal: { getErrors: () => unknown[], subscribeErrors: (fn: (r: unknown[]) => void) => () => void },
  ): () => void
  export function eventsErrorKey(error: string): string
}

declare module '~/utils/issues.mjs' {
  export type IssueStatus = 'eval' | 'todo' | 'wip' | 'diss' | 'qas' | 'done'
  export interface Issue {
    kind: 'epic' | 'feature' | 'issue' | 'subtask'
    epic: string
    key: string
    number: number
    title: string
    description: string
    status: IssueStatus
    priority: number
    level: number
    assignee: string
    labels: string[]
    deadline: string
    parent: string
    task_id: string
    channel: string
    created_by: string
    created_at: string
    updated_by: string
    updated_at: string
    completed_at: string
    canceled_at: string
  }
  export interface IssueLabel { id: string, name: string, color: string }
  export interface IssueFilter {
    kind?: string
    epic?: string[]
    parent?: string[]
    status?: string[]
    priority?: number[]
    level?: number[]
    assignee?: string[]
    label?: string[]
    deadlineBefore?: string
    deadlineAfter?: string
  }
  export interface IssueBody {
    title?: string
    description?: string
    status?: string
    priority?: number
    level?: number
    assignee?: string
    labels?: string[]
    deadline?: string
    parent?: string
    epic?: string
    kind?: 'epic' | 'feature' | 'issue'
  }
  export interface IssueList {
    prefix: string
    statuses: IssueStatus[]
    counts: Record<string, number>
    issues: Issue[]
    labels: IssueLabel[]
    channel: string
    epics?: EpicSummary[]
  }
  export interface EpicSummary {
    key: string
    kind?: 'epic' | 'feature'
    number: number
    title: string
    status: string
    total: number
    done: number
    canceled: number
    counts: Record<string, number>
  }
  export interface IssueGroup { status: IssueStatus, count: number, issues: Issue[] }
  export const ISSUE_STATUSES: IssueStatus[]
  export const ISSUE_KINDS: string[]
  export const PRIO_DEFAULT: number
  export function normalizeStatus(s: string): string
  export function isTopKind(kind: string): boolean
  export const ISSUE_PRIORITIES: number[]
  export const ISSUE_LEVELS: number[]
  export const LEVEL_SHORT: string[]
  export const ISSUE_SORTS: string[]
  export function statusKey(s: string): string
  export function priorityKey(p: number): string
  export function levelKey(l: number): string
  export function normalizeIssue(raw: unknown): Issue
  export function normalizeLabel(raw: unknown): IssueLabel
  export function sortIssues(list: Issue[], by?: string): Issue[]
  export function matchIssue(issue: Issue, f?: IssueFilter, me?: string): boolean
  export function groupIssues(list: Issue[], opts?: { sort?: string, filter?: IssueFilter, me?: string, hideEmpty?: boolean }): IssueGroup[]
  export function visibleOrder(groups: IssueGroup[], collapsed?: Record<string, boolean>): Issue[]
  export function stepKey(order: Issue[], current: string, delta: number): string
  export function applyIssueFrame(list: Issue[], frame: unknown): Issue[]
  export function applyLabelFrame(labels: IssueLabel[], frame: unknown): IssueLabel[]
  export function patchIssue(issue: Issue, patch: Partial<Issue>): Issue
  export function deadlineToLocalInput(iso: string, offsetMin?: number): string
  export function localInputToDeadline(value: string, offsetMin?: number): string | null
  export function isOverdue(issue: Issue, now?: number): boolean
  export function issueQuery(filter?: IssueFilter, sort?: string): string
  export function createMockIssues(opts?: { me?: string, now?: () => string }): unknown
}

declare module '~/utils/issues-view.mjs' {
  export const ISSUE_PRIORITIES: number[]
  export const ISSUE_LEVELS: number[]
  export const LEVEL_SHORT: string[]
  export const ISSUE_SORTS: string[]
  export function statusKey(s: string): string
  export function priorityKey(p: number): string
  export function levelKey(l: number): string
  export function groupIssues(list: import('~/utils/issues.mjs').Issue[], opts?: { sort?: string, filter?: import('~/utils/issues.mjs').IssueFilter, me?: string, hideEmpty?: boolean }): import('~/utils/issues.mjs').IssueGroup[]
  export function visibleOrder(groups: import('~/utils/issues.mjs').IssueGroup[], collapsed?: Record<string, boolean>): import('~/utils/issues.mjs').Issue[]
  export function stepKey(order: import('~/utils/issues.mjs').Issue[], current: string, delta: number): string
  export function applyIssueFrame(list: import('~/utils/issues.mjs').Issue[], frame: unknown): import('~/utils/issues.mjs').Issue[]
  export function applyLabelFrame(labels: import('~/utils/issues.mjs').IssueLabel[], frame: unknown): import('~/utils/issues.mjs').IssueLabel[]
  export function patchIssue(issue: import('~/utils/issues.mjs').Issue, patch: Partial<import('~/utils/issues.mjs').Issue>): import('~/utils/issues.mjs').Issue
  export function deadlineToLocalInput(iso: string, offsetMin?: number): string
  export function localInputToDeadline(value: string, offsetMin?: number): string | null
  export function isOverdue(issue: import('~/utils/issues.mjs').Issue, now?: number): boolean
  export const ISSUE_PANE_DEFAULT: number
  export const ISSUE_PANE_MIN: number
  export const ISSUE_PANE_MAX: number
  export function clampIssuePane(width: unknown, ceiling?: number): number
  export function loadIssuePane(store?: unknown): number
  export function saveIssuePane(width: number, store?: unknown): boolean
  export function epicProgress(e: { total?: number, done?: number, canceled?: number }): number
  export const STATUS_LABEL: Record<string, string>
  export function statusLabel(s: string): string
  export function controlLabel(name: string, value: string): string
  export function statusHintKey(s: string): string
  export const DEADLINE_FIRST_HOUR: number
  export const DEADLINE_LAST_HOUR: number
  export const DEADLINE_STEP_MIN: number
  export const DEADLINE_DEFAULT_TIME: string
  export function deadlineTimes(keep?: string): string[]
  export function splitLocal(local: string): { date: string, time: string }
  export function joinLocal(date: string, time?: string): string
}

declare module '~/utils/chunk-reload.mjs' {
  export const RELOAD_GUARD_MS: number
  export function isChunkLoadError(err: unknown): boolean
  export function shouldReload(last: number, now?: number): boolean
}
