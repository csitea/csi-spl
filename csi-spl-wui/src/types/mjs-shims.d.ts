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
  export type ChannelAgentState = '' | 'online' | 'offline' | 'unseated'
  export function channelAgentState(raw: { online?: boolean, seated?: boolean, state?: string } | null | undefined): ChannelAgentState
  export function channelFallbackLine(raw: unknown): { id: string, box: string, active: boolean, off: boolean, recent: { count: number, id: string, at: string } } | null
  export function channelAgentRows(agents: readonly { id?: string, box?: string, online?: boolean, seated?: boolean }[] | null | undefined): { id: string, box: string, state?: Exclude<ChannelAgentState, ''> }[]
  export function channelAgentCandidates(roster: Record<string, readonly string[]> | null | undefined, current: readonly { id?: string, box?: string }[] | null | undefined): { id: string, box: string }[]
  export function defaultChannelRows(roster: Record<string, readonly string[]> | null | undefined, subscribed: readonly { id?: string, box?: string, online?: boolean, seated?: boolean }[] | null | undefined): { people: string[], agents: { id: string, box: string, state?: Exclude<ChannelAgentState, ''> }[] }
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
    mockChannelOrder(): string[] | null
    setChannelOrder(ids: string[]): Promise<{ channel_order: string[] | null }>
    removeMember(humanId: string): Promise<null>
    listTenantUsers(): Promise<unknown>
    inviteTenantUser(opts: { email: string, role?: string, locale?: string }): Promise<{ email?: string, role?: string, mail?: string } | null>
    setTenantUserRole(humanId: string, role: string, fromRole?: string): Promise<unknown>
    removeTenantUser(humanId: string): Promise<null>
    auditClones(): Promise<Array<{ clone_hum?: string, target_hum?: string, created_by?: string, role?: string, created_at?: string, expires_at?: string, ended_at?: string | null, end_reason?: string }>>
    memberActivity(humanId: string): Promise<Array<{ at?: string, kind?: string, detail?: string, by?: string, ip?: string }>>
    revokeTenantInvite(email: string): Promise<null>
    patchTenantUser(humanId: string, patch: { display_name?: string, locale?: string, disabled?: boolean }): Promise<null>
    getTenantSettings(): Promise<unknown>
    patchTenantSettings(patch: { display_name?: string, default_locale?: string, responders?: string[] }): Promise<unknown>
    listTenantChannels(): Promise<unknown>
    setTenantChannelNoFallback(channel: string, off: boolean): Promise<unknown>
    archiveTenantChannel(channel: string): Promise<null>
    listChannels(opts?: { read?: Record<string, string> }): Promise<import('./spool').ChannelRow[]>
    listMessages(opts?: {
      channel?: string
      peer?: string
      limit?: number
      since?: string
      topics?: number
      before?: string
    }): Promise<{ messages: import('./spool').SpoolMessage[], next: string | null, totals?: Record<string, { count: number, last_ts: string }> }>
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
    listChannelMembers(channel: string): Promise<{ channel: string, default: boolean, members: string[], members_open_invite: boolean, created_by: string, agents: { id: string, box: string, online?: boolean, seated?: boolean }[] }>
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
    /** fold msgId into intoId (one hub transaction); resolves with the kept row. */
    mergeMessage(msgId: string, intoId: string): Promise<import('./spool').SpoolMessage & { merged_from: string }>
    /** Add (`op` add) or remove the viewer's emoji. Same call for is_parent 0 and 1. */
    setReaction(msgId: string, emoji: string, op: 'add' | 'remove', current?: { emoji: string, actors: string[] }[]): Promise<import('./spool').ReactionUpdate>
    /** SPL-952: set a sent message's kind (author, biz_owner or admin). */
    setMessageKind(msgId: string, kind: string): Promise<import('./spool').SpoolMessage>
    /** SPL-983 (specs/041): archive (true) or unarchive (false) a topic card. */
    archiveTopic(msgId: string, archived?: boolean): Promise<{ msg_id: string, task_id: string, archived: boolean, archived_at?: string, archived_by?: string }>
    /** SPL-983: the confirm dialog's reply count and what the caller may do. */
    topicSize(msgId: string): Promise<{ msg_id: string, task_id: string, replies: number, task_ids: string[], can_delete: boolean, can_archive: boolean }>
    /** SPL-983: delete a topic card and every child, one transaction. */
    deleteTopic(msgId: string): Promise<{ msg_id: string, task_id: string, deleted: number, msg_ids: string[], task_ids: string[] }>
    /** SPL-983: the archived cards this member may read, newest archived first. */
    listArchived(opts?: { before?: string }): Promise<{ cards: import('~/utils/topic-archive.mjs').ArchivedCard[], next: string | null }>
    /** SPL-1024 move-v1 §2: move a topic's card (and every row under it) to another channel. */
    moveTopic(msgId: string, toChannel: string): Promise<import('~/utils/move-apply.mjs').MoveAnswer>
    /** SPL-1024 move-v1 §3: move a reply (and its own thread) to another topic. */
    moveMessage(msgId: string, toTask: string): Promise<import('~/utils/move-apply.mjs').MoveAnswer>
    /** 714c7028: merge this card's whole topic into another topic. */
    mergeTopic(msgId: string, toTask: string): Promise<import('~/utils/move-apply.mjs').MoveAnswer>
    /** 714c7028: undo a merge - put the source topic back. */
    mergeUndo(msgId: string, fromTask: string, msgIds: string[]): Promise<import('~/utils/move-apply.mjs').MoveAnswer>
    /** SPL-1024 move-v1 §4: what the caller may do with the row. */
    moveInfo(msgId: string): Promise<{ msg_id: string, task_id: string, channel: string | null, is_card: boolean, can_move: boolean, moved_from_channel?: string, moved_from_task?: string }>
    fileUrl(fileId: string): string
    bindIssuesMock(factory: (me: string) => unknown): void
    listIssues(opts?: { filter?: import('~/utils/issues.mjs').IssueFilter, sort?: string }): Promise<import('~/utils/issues.mjs').IssueList>
    getIssue(ref: string): Promise<{ issue: import('~/utils/issues.mjs').Issue }>
    createIssue(body: import('~/utils/issues.mjs').IssueBody): Promise<{ issue: import('~/utils/issues.mjs').Issue }>
    updateIssue(ref: string, patch: import('~/utils/issues.mjs').IssueBody): Promise<{ issue: import('~/utils/issues.mjs').Issue }>
    deleteIssue(ref: string, opts?: { cascade?: boolean }): Promise<{ issue: import('~/utils/issues.mjs').Issue, descendants?: string[] }>
    archiveIssue(ref: string, opts?: { cascade?: boolean }): Promise<{ issue: import('~/utils/issues.mjs').Issue, descendants?: string[] }>
    createIssueLabel(opts: { name: string, color?: string }): Promise<{ label: import('~/utils/issues.mjs').IssueLabel }>
  }
}

declare module '~/utils/live-ws.mjs' {
  export const FRAMES: Record<string, string>
  export const WS_PATH: string
  export function wsUrl(base: string, path?: string): string
  export function backoffMs(attempt: number, opts?: { base?: number, cap?: number }): number
  export function reconnectDelayMs(attempt: number, random?: () => number): number
  export const REFUSED_PROBE_AFTER: number
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
    /** true only when the session probe answers signed out: parks the client in `signed_out`. */
    isSignedOut?: () => Promise<boolean>
    random?: () => number
    onWelcome?: (w: Record<string, unknown>) => void
    onToken?: (f: Record<string, unknown>) => void
    onPresence?: (f: import('./spool').PresenceFrame) => void
    onChannel?: (f: Record<string, unknown>) => void
    /** CLE-3445 `message_edited`: a replacement for a row already held. */
    onEdited?: (m: Record<string, unknown>, raw: unknown) => void
    /** `message_deleted`: drop a row. */
    onDeleted?: (m: Record<string, unknown>, raw: unknown) => void
    /** SPL-983 `topic_archived` / `topic_deleted`. */
    onTopic?: (f: Record<string, unknown>) => void
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
    redialForToken(): Promise<Record<string, unknown>>
    send(opts: import('./spool').SendFrame): Promise<import('./spool').AckFrame>
  }
}

declare module '~/utils/sidebar-tabs.mjs' {
  export const SIDE_TABS: readonly ['dm', 'channels', 'topics', 'flow']
  export const USERS_TAB: 'users'
  export const EVENTS_TAB: 'events'
  export const ISSUES_TAB: 'issues'
  export const ARCHIVE_TAB: 'archive'
  export const PEOPLE_TAB: 'people'
  export const AGENTS_TAB: 'agents'
  export const BOXES_TAB: 'boxes'
  export function tabForPath(path: string): 'dm' | 'channels' | 'topics' | 'flow' | 'users' | 'events' | 'issues' | 'archive' | 'people' | 'agents' | 'boxes' | null
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
  export function namedRuns(text: string, names: Record<string, string> | null | undefined): { text: string, title?: string }[]
  export function namedText(text: string, names: Record<string, string> | null | undefined): string
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
  export function phoneCardTime(text: string, ts: unknown, nowMs?: number): string
  export function recipientOf(msg: unknown): { id: string, box: string } | null
  export function headerRecipientOf(msg: unknown): { id: string, box: string } | null
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
  export type TopicTotal = { count: number, last_ts: string }
  export function topicReplies(messages: { task_id?: string, parent_task_id?: string | null }[], taskId: string, total?: TopicTotal | null): number
  export type TopicReplyIndex = { rowOf: Map<unknown, unknown>, children: Map<unknown, number>, same: Map<unknown, unknown[]> }
  export function topicReplyIndex(messages: { task_id?: string, parent_task_id?: string | null }[]): TopicReplyIndex
  export function topicRepliesIn(index: TopicReplyIndex, taskId: string, total?: TopicTotal | null): number
  export function mergeTopicTotals(held: Record<string, TopicTotal> | null | undefined, incoming: Record<string, TopicTotal> | null | undefined): Record<string, TopicTotal>
  export function dropFromTotals<T extends Record<string, TopicTotal>>(totals: T, msg: unknown): T
  export function channelView<T>(messages: T[], opts?: { search?: string, visible?: number, lobby?: boolean }): { rows: T[], hasOlder: boolean }
  export function rowsForRightPane<T>(topicRows: T[], held: T[], topicId: string): T[]
  export function topicCards<T extends { task_id?: string }>(messages: T[]): T[]
  export function channelActivity(row: unknown, liveAt?: Record<string, string>): string
  export function orderChannels<T extends { channel_id?: string }>(rows: T[], liveAt?: Record<string, string>): T[]
  export function orderPeers<T extends { label?: string, online?: boolean }>(rows: T[], lastAt?: Record<string, string>): T[]
  export function dmActivity(topics: unknown[], self?: string): Record<string, string>
  export function unreadFromDms(topics: unknown, cursors: Record<string, unknown>, self?: string): Record<string, number>
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
  export function mentionFieldName(id: string, names: Record<string, string> | null | undefined): string
  export function encodeMentions(text: string, picks: Record<string, string> | null | undefined): string
  export function decodeMentions(text: string, names: Record<string, string> | null | undefined): { text: string, picks: Record<string, string> }
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
  export function mentionCandidates(a: {
    peers?: { id: string, box?: string, label?: string, online?: boolean }[]
    names?: Record<string, string> | null
    owners?: string[]
    selfId?: string
    query: string
    ownersFirst?: boolean
    isOnline?: ((id: string) => boolean) | null
  }): { id: string, box?: string, label?: string, online?: boolean, owner?: boolean }[]
}

declare module '~/utils/mention-poke.mjs' {
  export const EXCERPT_MAX: number
  export type MentionAccess =
    | { kind: 'open' }
    | { kind: 'dm', ends: string[] }
    | { kind: 'channel', humans: string[], agents: string[], responders?: string[] }
    | null
  export function pokeTargets(a: { text: string, before?: string, selfId?: string, addressee?: string }): string[]
  export function pokeExcerpt(text: string): string
  export function pokeBody(a: { author: string, link: string, text: string }): string
  export function cardLink(origin: string, taskId: string): string
  export function issueLink(origin: string, key: string): string
  export function splitByAccess(ids: string[], access: MentionAccess): { ok: string[], refused: string[] }
  export function channelAccess(list: { default?: boolean, members?: string[], agents?: ({ id: string } | string)[], responders?: string[] } | null): MentionAccess
  export function topicWhere(rows: unknown[], taskId: string): { channel: string } | { ends: string[] } | null
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
  export function createAuthClient(opts?: { fetchFn?: typeof fetch, base?: string, locale?: string | (() => string), sendLocale?: boolean, mock?: boolean }): {
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
    saveInterests(interests: string): Promise<NativeResult>
    saveTheme(theme: string): Promise<NativeResult>
    saveSubmitKey(key: string): Promise<NativeResult>
    saveRailOrder(order: string[] | null): Promise<NativeResult>
    saveViewPref(key: 'message_order' | 'composer_position' | 'issues_view' | 'close_buttons', value: string | null): Promise<NativeResult>
    saveIssueColumns(cols: Record<string, number> | null): Promise<NativeResult>
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
  export const TENANT_DESKTOP_ARROW_GAP_PX: number
  export const TENANT_TEXT_PAD_PX: 2
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
  export function copyMoveFields<T extends Record<string, unknown>>(src: unknown, out: T): T
}

declare module '~/utils/pane-focus.mjs' {
  export const MIDDLE: 'middle'
  export const RIGHT: 'right'
  export function paneOfTarget(el: unknown): '' | 'middle' | 'right'
  export function paneTakesLine(opts?: { paneOpen?: boolean, lastPane?: string }): boolean
  export const KEY_NAV_MS: number
  export function eventChoosesPane(ev?: { type?: string, onScrollbar?: boolean, keyNavAt?: number, now?: number }): boolean
  export function isKeyNav(ev: { key?: string, target?: unknown }): boolean
  export function onScrollbar(ev: { target?: unknown, offsetX?: number, offsetY?: number }): boolean
}

declare module '~/utils/typed-by.mjs' {
  export function typedByAuthor(msg: { from?: string, from_box?: string, typed_by?: string } | null | undefined): { id: string, box: string, via: string, viaBox: string }
}

declare module '~/utils/touch-ui.mjs' {
  export const LONG_PRESS_MS: number
  export const LONG_PRESS_SLOP_PX: number
  export const KEYBOARD_MIN_PX: number
  export const COMPOSER_FOCUS_EVENT: string
  export function keyboardInset(innerHeight: number, vv: { height?: number, offsetTop?: number } | null | undefined): number
  export function isTouchPointer(pointerType: string | undefined): boolean
  export function createLongPress(opts: {
    onPress: (x: number, y: number) => void
    delay?: number
    slop?: number
    setTimer?: (fn: () => void, ms: number) => unknown
    clearTimer?: (id: unknown) => void
  }): {
    down(ev: { pointerType?: string, clientX: number, clientY: number, isPrimary?: boolean }): void
    move(ev: { clientX: number, clientY: number }): void
    up(): void
    cancel(): void
    takeClick(): boolean
    readonly pending: boolean
  }
}

declare module '~/utils/msg-menu.mjs' {
  export function msgMenuItems(opts?: { editable?: boolean, mergePrev?: boolean, mergeNext?: boolean, parent?: boolean, topic?: boolean, touch?: boolean, kind?: boolean, moveChannel?: boolean, moveTopic?: boolean, mergeTopic?: boolean }): { id: 'reply' | 'react' | 'open' | 'parent' | 'edit' | 'copy' | 'copy-text' | 'kind' | 'merge-prev' | 'merge-next' | 'move-channel' | 'move-topic' | 'merge-topic' | 'delete' | 'archive' | 'delete-topic', icon: 'reply' | 'smile' | 'open' | 'parent' | 'pencil' | 'copy' | 'tag' | 'merge' | 'move' | 'trash' | 'archive' | 'delete', labelKey: string }[]
  export function messageLink(msg: unknown, pathFor: (path: string) => string): string
  export function topicPaneLink(msg: unknown, where?: { path?: string, query?: Record<string, unknown>, currentTaskId?: string }): string
  export function threadLineLink(msg: unknown, where?: { path?: string, query?: Record<string, unknown>, pathFor?: (path: string) => string }): string
  export function threadNeighbor(rows: unknown[], msg: unknown, which: 'previous' | 'next'): Record<string, unknown> | null
  export function mergeableSource(rows: unknown[], msg: unknown, lobbyTaskId?: string): boolean
  export type ThreadNeighborIndex = Map<string, { previous: Record<string, unknown> | null, next: Record<string, unknown> | null }>
  export function threadNeighbors(rows: unknown[]): ThreadNeighborIndex
  export function neighborIn(index: ThreadNeighborIndex, msg: unknown, which: 'previous' | 'next'): Record<string, unknown> | null
  export function mergeableSourceIn(index: ThreadNeighborIndex, msg: unknown, lobbyTaskId?: string): boolean
  export function joinBodies(older: unknown, newer: unknown): string
}

declare module '~/utils/move.mjs' {
  export type MoveDrag = { kind: 'topic' | 'message', msgId: string, taskId: string, topicTask: string, channel: string, title?: string }
  export type MeLike = { role?: string | null, tenantOwner?: boolean } | null
  export const MOVE_BLOCKED_CHANNELS: readonly string[]
  export function moveChan(v: unknown): string
  export function moveBlocked(channel: unknown): boolean
  export function isMovableTopic(msg: unknown, lobbyTaskId?: string): boolean
  export function mayMoveTopic(msg: unknown, viewerId: string, me: MeLike, lobbyTaskId?: string): boolean
  export function mayMoveMessage(msg: unknown, viewerId: string, me: MeLike, opts?: { openerId?: string, lobbyTaskId?: string, channel?: string | null }): boolean
  export function isChannelDropTarget(drag: MoveDrag | null, channelId: string, listed?: unknown[] | null): boolean
  export function isCardDropTarget(drag: MoveDrag | null, card: unknown, lobbyTaskId?: string): boolean
  export function isMergeCardDropTarget(drag: MoveDrag | null, card: unknown, lobbyTaskId?: string): boolean
  export function movedNote(msg: unknown): { kind: 'channel', channel: string } | { kind: 'topic', task: string } | null
}

declare module '~/utils/move-drag.mjs' {
  export type MoveHit = { kind: 'channel' | 'card', id: string, scope: string, ok: boolean, title: string }
  export const MOVE_HANDLE_PX: number
  export const MOVE_DRAG_START_PX: number
  export const MOVE_TOUCH_HOLD_MS: number
  export const MOVE_TOUCH_SLOP_PX: number
  export function moveHit(el: unknown, drag: { kind?: string } | null | undefined): MoveHit | null
  export function sameHit(a: MoveHit | null, b: MoveHit | null): boolean
  type Pt = { pointerId: number, pointerType?: string, button?: number, clientX: number, clientY: number }
  export type HandleDrag = { readonly state: 'idle' | 'pressed' | 'lifted' | 'held', down(ev: Pt): boolean, move(ev: Pt): void, up(ev: Pt): void, cancel(): void, takeClick(): boolean }
  export function createHandleDrag(opts: {
    onStart: (x: number, y: number) => void, onMove: (x: number, y: number) => void,
    onDrop: (x: number, y: number) => void, onCancel: () => void, onHold?: () => boolean,
    startPx?: number, holdMs?: number, slopPx?: number,
    setTimer?: (fn: () => void, ms: number) => unknown, clearTimer?: (id: unknown) => void,
  }): HandleDrag
}

declare module '~/utils/move-apply.mjs' {
  export type MoveDrag = import('~/utils/move.mjs').MoveDrag
  export type MoveFrame = { type: 'topic_moved' | 'message_moved' | 'topic_merged' | 'topic_unmerged', msg_id: string, task_id: string, from_task: string, channel: string, from_channel: string, moved?: boolean, moved_by: string, moved_at?: string, msg_ids: string[] }
  export type MoveAnswer = { kind: 'topic' | 'message' | 'merge' | 'unmerge', msg_id: string, task_id: string, from_task?: string, channel?: string, from_channel?: string, moved?: boolean, merged?: number, unmerged?: number, moved_by: string, moved_at?: string, received_at?: string, msg_ids: string[], undo?: { to_channel?: string, to_task?: string, from_task?: string, msg_ids?: string[] } }
  export type MergeFrame = { type: 'topic_merged' | 'topic_unmerged', msg_id: string, task_id: string, from_task: string, channel: string, from_channel: string, msg_ids: string[] }
  export function moveChannelTargets(channels: unknown, current?: string | null): { channel_id: string, name: string }[]
  export function moveFrame(frame: unknown): MoveFrame | null
  export function moveFrameFromAnswer(answer: unknown): MoveFrame | null
  export function applyMoveRows<T>(rows: T[], frame: unknown): T[]
  export function moveLeavesTask(frame: unknown, taskId: string | null | undefined): string[]
  export function moveJoinsTask(frame: unknown, taskId: string | null | undefined): boolean
  export function moveErrorKey(e: unknown): string
  export function mergeErrorKey(e: unknown): string
  export function queryTasks(query: unknown): string[]
  export function movedChannelFor(rows: unknown, current: string | null | undefined): string
  export function moveTopicChoices(topics: unknown, opts?: { channels?: unknown[], exclude?: string[], query?: string, lobbyTaskId?: string }): { task_id: string, channel: string, title: string, last_ts: string }[]
  export function applyMoveToStores(frame: unknown, stores: { channel?: unknown, main?: unknown, pane?: unknown, viewer?: unknown, topic?: unknown, getTopic?: (id: string) => Promise<{ messages?: unknown[] }> }): MoveFrame | null
  export function mergeFrame(frame: unknown): MergeFrame | null
  export function mergeFrameFromAnswer(answer: unknown): MergeFrame | null
  export function applyMergeToStores(frame: unknown, stores: { channel?: unknown, main?: unknown, pane?: unknown, viewer?: unknown, getTopic?: (id: string) => Promise<{ messages?: unknown[] }> }): MergeFrame | null
}

declare module '~/utils/move-mock.mjs' {
  export function mockMove(state: unknown, id: string, body: { to_channel?: string, to_task?: string }): import('~/utils/move-apply.mjs').MoveAnswer
  export function mockMergeTopic(state: unknown, id: string, body: { to_task?: string, undo?: { from_task?: string, msg_ids?: string[] } }): import('~/utils/move-apply.mjs').MoveAnswer
}

declare module '~/utils/topic-archive.mjs' {
  export type ArchivedCard = {
    message: import('./spool').SpoolMessage
    msg_id: string
    task_id: string
    channel?: string | null
    archived_at: string
    archived_by: string
    replies: number
    can_delete: boolean
  }
  export const TOPIC_ADMIN_ROLES: readonly string[]
  export function isTopicCard(msg: unknown): boolean
  export function openingCardId(messages: unknown, fallbackId?: string): string
  export function mayChangeTopic(msg: unknown, viewerId: string, me: { role?: string | null, tenantOwner?: boolean } | null): boolean
  export function topicFrameDrops(frame: unknown): string[]
  export function topicFrameTasks(frame: unknown, lobbyTaskId?: string): string[]
  export function topicErrorKey(e: unknown, scope?: string): string
  export function archivedRow(card: unknown): { msg_id: string, task_id: string, channel: string, from: string, from_box: string, title: string, archived_at: string, archived_by: string, replies: number, can_delete: boolean }
  export function withoutCards<T>(rows: T[], ids: string[]): T[]
  export type RowTopicState = { state: 'none' | 'ready', msgId: string, canArchive: boolean, canDelete: boolean, replies: number }
  export function rowCardCandidates(taskId: string, first: { msg_id?: string } | null | undefined, lobbyTaskId?: string): string[]
  export function isRowTopic(size: unknown, taskId: string, msgId: string, lobbyTaskId?: string): boolean
  export function rowTopicState(size: unknown, msgId: string): RowTopicState
  export function topicFrameRows(frame: unknown, lobbyTaskId?: string): string[]
  export function withoutTopics<T>(rows: T[], taskIds: string[]): T[]
}

declare module '~/utils/place-popover.mjs' {
  export const POPOVER_MARGIN: number
  export function placePopover(
    anchor: { x?: number, y?: number, flipFrom?: number },
    size: { width?: number, height?: number },
    viewport: { width?: number, height?: number },
    margin?: number,
  ): { left: number, top: number, flipped: boolean, maxWidth: number, maxHeight: number }
  export function readViewport(): { width: number, height: number }
  export function applyPopover(
    el: HTMLElement | null | undefined,
    anchor: { left: number, right: number, top: number, bottom: number, align?: 'start' | 'end', gap?: number, lockWidth?: boolean },
    viewport?: { width: number, height: number },
    margin?: number,
  ): { left: number, top: number, flipped: boolean, maxWidth: number, maxHeight: number } | null
  export function applyPopoverAtPoint(
    el: HTMLElement | null | undefined,
    x: number,
    y: number,
    viewport?: { width: number, height: number },
  ): { left: number, top: number, flipped: boolean, maxWidth: number, maxHeight: number } | null
  export function focusWithoutScroll(el?: { focus?: (opts?: { preventScroll?: boolean }) => void } | null): void
  export function observePopover(
    host: HTMLElement | null | undefined,
    opts: { panel: string, anchor: string, align?: 'start' | 'end', gap?: number },
  ): () => void
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
  export const EMOJI_NAME_SLUG: Record<string, string>
  export function validEmoji(s: string): boolean
  export function canonicalEmoji(s: string): string
  export function emojiNameKey(emoji: string): string
  export function emojiName(emoji: string, t?: (key: string) => string): string
  export function normalizeReactions(list: unknown): { emoji: string, actors: string[] }[]
  export function reactionChips(list: unknown, me?: string): { emoji: string, count: number, showCount: boolean, actors: string[], mine: boolean }[]
  export function reactionOp(list: unknown, emoji: string, me?: string): 'add' | 'remove'
  export function applyReactions<T>(list: T[], update: unknown): T[]
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
  export const NEAR_BOTTOM_PX: number
  export function distanceFromBottom(o: { top?: number, height?: number, client?: number }): number
  export function appendedCount(prevKeys: string[], nextKeys: string[]): number
  export function isFreshList(prevKeys: string[], nextKeys: string[]): boolean
  export function anchorAfterAppend(o: {
    top?: number
    atBottom?: boolean
    own?: boolean
    anchorBefore?: number | null
    anchorAfter?: number | null
    added?: number
    pill?: number
  }): { bottom: boolean, top: number, pill: number }
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
  export const AVATAR_MISS_KEY: string
  export function loadAvatarImageUrl(url: string, o?: {
    credentials?: RequestCredentials
    fetchFn?: typeof fetch
    missStore?: Pick<Storage, 'getItem' | 'setItem'> | null
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
    | { state: 'ok', result: { tenant_id: string, tenant_url: string, root_private_key: string, tenant_host?: string, host_status?: string, email?: string } }
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
  export function looksLikeMarkdown(src: string): boolean
  export function markdownSource(src: string): string
  export function mentionParts(text: string): BodyPart[]
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
  export function setLinkSite(siteUrl: string): void
  export function classifyHref(raw: string, pageOrigin?: string, site?: string): { href: string, internal: boolean } | null
  export function linkOpen(href: string, pageOrigin?: string, site?: string): { href: string, internal: boolean, target?: string, rel?: string } | null
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
  export interface MdOptions { breaks?: boolean, html?: boolean }
  export function markdownTree(src: string, opts?: MdOptions): MdNode[]
  export function htmlTableNodes(html: string): MdNode[]
  export function treeToHtml(nodes: MdNode[], origin?: string): string
  export function markdownToHtml(src: string, origin?: string, opts?: MdOptions): string
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
  /** 022 §10: the right menu of a row and its original */
  export function isPlacedRow(row: unknown): boolean
  export function searchRowMenuItems(row: unknown): { id: 'original' | 'here' | 'copy', icon: import('~/utils/uiIcons').UiIconName, labelKey: string }[]
  export function topicPageOf(row: unknown): string
  export function originalHref(row: unknown, opts?: { self?: string, pathFor?: (path: string) => string }): string
}

declare module '~/utils/search-original.mjs' {
  export function openOriginal(row: unknown, deps: { self: string, api: unknown, router: unknown, localePath: (p: string) => string, fallback: string }): Promise<boolean>
  export function markHit(msgId: string, opts?: { tries?: number, every?: number, hold?: number }): void
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

declare module '~/utils/channel-order.mjs' {
  export const CHANNEL_ORDER_MAX: number
  export const MOCK_CHANNEL_ORDER_KEY: string
  export function normalizeChannelOrder(raw: unknown): string[]
}

declare module '~/utils/channel-order-edit.mjs' {
  export function mergeChannelOrder(displayed: readonly string[], stored: readonly string[]): string[]
  export function stepChannelOrder(displayed: readonly string[], id: string, step: -1 | 1): string[] | null
  export function sameChannelOrder(a: readonly string[] | null | undefined, b: readonly string[] | null | undefined): boolean
}

declare module '~/utils/access.mjs' {
  export const ROLE_IDS: string[]
  export const MEMBERS_INVITE: 'members.invite'
  export const MEMBERS_IMPERSONATE: 'members.impersonate'
  export type ActAs = { targetHum: string, targetName: string, expiresAt: string }
  export function normalizeActAs(a: unknown): ActAs | null
  export function normalizeMe(body: unknown): { humanId: string | null, role: string | null, tenantOwner: boolean, permissions: string[] | null, channelOrder: string[] | null, actAs: ActAs | null }
  export function accessAllows(me: { permissions: string[] | null } | null | undefined, perm: string): boolean
  export function canRemoveMember(
    me: { permissions?: string[] | null } | null | undefined,
    ctx: { targetId?: string, selfId?: string, targetIsOwner?: boolean, ownerCount?: number },
  ): boolean
  export function roleLabelKey(role: string | null | undefined): string
}

declare module '~/utils/tenant-users.mjs' {
  export type UserMember = { kind: 'member', key: string, humanId: string, displayName: string, email: string, role: string, since: string, disabled: boolean, suspended: boolean, lastSeen: string, you: boolean, manageable: boolean, orderedBy: string, orderedByName: string, orderedVia: string, invitedOn: string }
  export type UserInvite = { kind: 'invite', key: string, email: string, role: string, invitedBy: string, createdAt: string, expiresAt: string, expired: boolean, orderedBy: string, orderedByName: string, orderedVia: string, tenant: string }
  export type UserRow = UserMember | UserInvite
  export const USERS_PERMISSION: string
  export const USER_PANE_SIDE: 'left' | 'right'
  export function usersEntryVisible(me: { permissions: string[] | null } | null | undefined, opts?: { mock?: boolean }): boolean
  export function normalizeDirectory(body: unknown): { you: string, members: UserMember[], invites: UserInvite[], roles: { id: string, grantable: boolean }[] }
  export function memberLabel(row: UserRow | null | undefined): string
  export function userErrorKey(err: unknown): string
  export function looksLikeEmail(s: unknown): boolean
  export function inviteLink(origin: unknown, tenant: unknown): string
}

declare module '~/utils/tenant-users-mock.mjs' {
  export function createMockDirectory(now?: () => Date): unknown
}

declare module '~/utils/tenant-settings-nav.mjs' {
  export type TenantSection = { id: string, label: string, perm: string }
  export const TENANT_SETTINGS_SECTIONS: TenantSection[]
  export const TENANT_SETTINGS_PERMS: string[]
  export function tenantSettingsSections(me: { permissions: string[] | null } | null | undefined, opts?: { mock?: boolean }): TenantSection[]
  export function tenantSettingsVisible(me: { permissions: string[] | null } | null | undefined, opts?: { mock?: boolean }): boolean
  export function tenantSettingsSectionOf(path: string): string
}

declare module '~/utils/tenant-settings.mjs' {
  export type TenantSettings = { tenantId: string, displayName: string, defaultLocale: string, responders: string[], maxResponders: number, issuePrefix: string }
  export type TenantChannel = { channel: string, name: string, description: string, visibility: 'default' | 'members', members: number, agents: number, messages: number, noFallback: boolean, createdBy: string, lastTs: string, archivable: boolean }
  export function normalizeTenantSettings(body: unknown): TenantSettings
  export function normalizeTenantChannels(body: unknown): TenantChannel[]
  export function validResponderId(s: unknown): boolean
  export function issuePrefixOf(s: unknown): string
  export function moveItem<T>(list: T[], i: number, delta: number): T[]
  export function tenantSettingsErrorKey(err: unknown): string
}

declare module '~/utils/connect-agent.mjs' {
  export const SPOOL_REPO: string
  export function validAgentId(s: unknown): boolean
  export function validBoxId(s: unknown): boolean
  export function keyFileArg(path: unknown): string
  export function boxHubUrl(apiBase: unknown, origin: unknown, tenant?: unknown): string
  export function spoolEnv(o: { hubUrl: string, tenant: string, box: string }): string
  export function connectAgentScript(o: { hubUrl: string, tenant: string, box: string, agent: string, keyFile: string }): string
  export function cursorMcpJson(o: { agent: string }): string
  export function firstPrompt(agent: string): string
}

declare module '~/utils/first-run.mjs' {
  export type FirstRunStep = { id: 'invite' | 'agent' | 'topic', to: string, done: boolean }
  export const FIRST_RUN_STEPS: { id: string, to: string }[]
  export function firstRunHiddenKey(tenant: unknown): string
  export function firstRunSteps(o?: { members?: number | null, invites?: number | null, roster?: Record<string, string[]> | null, topics?: number }): FirstRunStep[]
  export function firstRunVisible(o: { canSetUp: boolean, hidden: boolean, steps: FirstRunStep[] }): boolean
}

declare module '~/utils/help.mjs' {
  export const HELP_REPO_BASE: string
  export function validHelpSlug(s: unknown): boolean
  export function helpHref(raw: unknown, route?: (slug: string) => string): string
  export function rewriteHelpLinks(md: unknown, route?: (slug: string) => string): string
  export function fillHelpHosts(md: unknown, hosts?: { api?: string, site?: string }): string
  export function hostOf(url: unknown): string
}

declare module '~/utils/tenant-settings-mock.mjs' {
  export function createMockTenant(): unknown
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
  export function saveThemeToAccount(
    theme: unknown,
    io: { claims: { hum?: unknown, preferred_theme?: unknown } | null | undefined, save: (theme: SpoolTheme) => Promise<{ ok: boolean }>, apply: (theme: SpoolTheme) => void },
  ): Promise<boolean>
  export function readStoredTheme(store?: unknown, fallback?: SpoolTheme): SpoolTheme
  export function writeStoredTheme(theme: unknown, store?: unknown): boolean
  export function applyThemeAttr(theme: unknown, el?: { setAttribute?(k: string, v: string): void } | null): SpoolTheme
}

declare module '~/utils/display-name.mjs' {
  export const MAX_DISPLAY_NAME: number
  export function sameNames(a: Record<string, string> | null | undefined, b: Record<string, string> | null | undefined): boolean
  export function validDisplayName(raw: unknown): { ok: boolean, name: string }
  export function applyDisplayName(
    raw: unknown,
    io: { current: unknown, save: (name: string) => Promise<{ ok: boolean, data?: unknown }>, apply: (name: string) => void },
  ): Promise<{ ok: boolean, name: string, reason?: 'invalid' | 'unchanged' | 'refused', out?: unknown }>
}

declare module '~/utils/submit-key.mjs' {
  export type SubmitKey = 'enter' | 'ctrl-enter'
  export const SUBMIT_KEYS: readonly SubmitKey[]
  export const DEFAULT_SUBMIT_KEY: SubmitKey
  export function parseSubmitKey(raw: unknown): SubmitKey
  export function submitKeyAction(
    ev: { key?: string, shiftKey?: boolean, altKey?: boolean, ctrlKey?: boolean, metaKey?: boolean, isComposing?: boolean, keyCode?: number } | null | undefined,
    opts?: { mode?: unknown, inCode?: boolean },
  ): 'submit' | 'newline' | ''
  export function submitHintKey(mode: unknown, byMode: Record<string, string>): string
  export function applySubmitKeySetting(
    want: unknown,
    io: { current: unknown, apply: (k: string) => void, save: (k: string) => Promise<{ ok: boolean }> },
  ): Promise<{ ok: boolean, value: SubmitKey, out?: unknown }>
}

declare module '~/utils/view-prefs.mjs' {
  export type MessageOrder = 'newest-first' | 'newest-last'
  export type ComposerPosition = 'top' | 'bottom'
  export type IssuesView = 'list' | 'status'
  export type CloseButtons = 'mac' | 'windows'
  export type ViewPrefKey = 'message_order' | 'composer_position' | 'issues_view' | 'close_buttons'
  export const MESSAGE_ORDERS: readonly MessageOrder[]
  export const COMPOSER_POSITIONS: readonly ComposerPosition[]
  export const ISSUES_VIEWS: readonly IssuesView[]
  export const CLOSE_BUTTONS: readonly CloseButtons[]
  export const VIEW_PREFS: Readonly<{ message_order: readonly MessageOrder[], composer_position: readonly ComposerPosition[], issues_view: readonly IssuesView[], close_buttons: readonly CloseButtons[] }>
  export const DEFAULT_MESSAGE_ORDER: MessageOrder
  export const DEFAULT_COMPOSER_POSITION: ComposerPosition
  export function parseViewPref(key: ViewPrefKey, raw: unknown): string
  export function parseMessageOrder(raw: unknown): MessageOrder
  export function parseComposerPosition(raw: unknown): ComposerPosition
  export function parseIssuesView(raw: unknown): IssuesView
  export function parseCloseButtons(raw: unknown): CloseButtons
  export function closeButtonShown(side: 'start' | 'end', pref: unknown): boolean
  export function displayOrder<T>(rows: readonly T[] | null | undefined, order: unknown): T[]
  export function applyViewPref(
    key: ViewPrefKey,
    want: unknown,
    io: { current: unknown, apply: (v: string) => void, save: (v: string) => Promise<{ ok: boolean }> },
  ): Promise<{ ok: boolean, value: string, out?: unknown }>
}

declare module '~/utils/rail-order.mjs' {
  export type RailId = 'dm' | 'channels' | 'issues' | 'topics' | 'flow' | 'events' | 'archive'
  export const RAIL_TABS: readonly { readonly id: RailId, readonly icon: import('~/utils/uiIcons').UiIconName, readonly labelKey: string }[]
  export const RAIL_IDS: readonly RailId[]
  export const DRAG_THRESHOLD_PX: number
  export function isRailOrder(raw: unknown): boolean
  export function parseRailOrder(raw: unknown): RailId[]
  export function sameOrder(a: unknown, b: unknown): boolean
  export function moveTo<T extends string>(order: readonly T[], id: T, to: number): T[]
  export function moveBy<T extends string>(order: readonly T[], id: T, delta: number): T[]
  export function dropIndex(mids: readonly number[], from: number, pos: number): number
  export function isDrag(dx: number, dy: number, threshold?: number): boolean
  export function applyRailOrder(
    want: string[] | null,
    io: { current: unknown, apply: (o: string[] | null) => void, save: (o: string[] | null) => Promise<{ ok: boolean }> },
  ): Promise<{ ok: boolean, value: string[] | null, out?: unknown }>
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
  export function tickWhileShown(queue: { tick(): boolean, items(): unknown[], subscribe(fn: (items: unknown[]) => void): () => void }, timers?: { every?: (fn: () => void, ms: number) => unknown, cancel?: (id: unknown) => void }): () => void
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
  export type IssueStatus = 'eval' | 'todo' | 'wip' | 'diss' | 'blocked' | 'onhold' | 'qas' | 'done'
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
  export function groupIssues(list: import('~/utils/issues.mjs').Issue[], opts?: { sort?: string, filter?: import('~/utils/issues.mjs').IssueFilter, me?: string, hideEmpty?: boolean, by?: 'status' | 'none' }): import('~/utils/issues.mjs').IssueGroup[]
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
  export function deadlineText(local: string): string
  export const SHEET_COLUMNS: string[]
  export function nextSort(col: string, cur?: { col: string, dir: string }): { col: string, dir: '' | 'asc' | 'desc' }
  export function sortFromQuery(q?: Record<string, unknown>): { col: string, dir: '' | 'asc' | 'desc' }
  export function hubSort(s: { col: string, dir: string }): string
  export function sortSheet(list: import('~/utils/issues.mjs').Issue[], s?: { col: string, dir: string }, opts?: { name?: (id: string) => string, labelName?: (id: string) => string }): import('~/utils/issues.mjs').Issue[]
  export function parseDeadlineText(text: string, defaultTime?: string): string | null
  export function monthOf(local: string, today?: string): string
  export function shiftMonth(ym: string, delta: number): string
  export function monthGrid(ym: string): { date: string, day: number, inMonth: boolean }[][]
}

declare module '~/utils/chunk-reload.mjs' {
  export const RELOAD_GUARD_MS: number
  export function isChunkLoadError(err: unknown): boolean
  export function shouldReload(last: number, now?: number): boolean
}

declare module '~/utils/tenant-host.mjs' {
  export function siteHostOf(siteUrl: string): string
  export function pageTenant(hostname: string, siteUrl: string, apexTenant: string): string
  export function tenantOrigin(tenant: string, siteUrl: string, apexTenant: string): string
  export function tenantUrl(tenant: string, siteUrl: string, apexTenant: string, path?: string): string
  export function switchPath(path: string): string
  export function isTenantHostOf(url: string, siteUrl: string): boolean
  export function tenantParamHop(href: string, siteUrl: string, apexTenant: string): string
  export function oldLinkId(href: string): string
  export function homeTenant(claims: unknown, page: string): string
}

declare module '~/utils/tenant-host-core.mjs' {
  export function siteHostOf(siteUrl: string): string
  export function pageTenant(hostname: string, siteUrl: string, apexTenant: string): string
  export function isTenantHostOf(url: string, siteUrl: string): boolean
}

declare module '~/utils/tenant-host-boot.mjs' {
  export function bootTenantHost(opts: {
    pub: Record<string, unknown>
    page: string
    session: { state: string, claims: unknown }
    notMember: { value: { tenant: string, home: string } }
  }): void
}

declare module '~/utils/date-iso.mjs' {
  export function isoDate(value: unknown): string
  export function isoDateTime(value: unknown): string
  export function parseIsoDate(value: unknown): string
}

declare module '~/utils/tab-title.mjs' {
  export const PRODUCT: string
  export function tenantTabName(claims: unknown, pageTenant: string, apexTenant: string): string
  export function tabTitle(pageTitle: string | undefined | null, tabName: string): string
}

declare module '~/utils/mobile-stack.mjs' {
  export type MobileLevel = 1 | 2 | 3
  export const MOBILE_STACK_MAX_PX: number
  export const MOBILE_STACK_QUERY: string
  export const MOBILE_LEVEL_KEY: string
  export const MOBILE_BELOW_KEY: string
  export const MOBILE_SWIPE_MIN_DX: number
  export const MOBILE_SWIPE_MAX_DY: number
  export const MOBILE_SWIPE_EDGE_RATIO: number
  export function mobileLevelOf(s: { home: boolean, topicOpen: boolean }): MobileLevel
  export function isMobileFrontDoor(path: string): boolean
  export function mobileInitialLevel(path: string, query: Record<string, unknown> | null | undefined): MobileLevel
  export function mobileTaggedLevel(state: unknown): MobileLevel | null
  export function mobileHasBelow(state: unknown): boolean
  export function mobileTagState(state: unknown, level: MobileLevel, below?: number): Record<string, unknown>
  export function mobileHistoryStep(tagged: MobileLevel | null, next: MobileLevel): 'tag' | 'push' | 'none'
  export function isMobileBackSwipe(g: { x0: number, y0: number, x1: number, y1: number, width: number, rtl?: boolean }): boolean
  export const MOBILE_OVERLAY_KEY: 'splOverlay'
  export function mobileOverlayOf(state: unknown): number | null
  export function mobileOverlayState(state: unknown, id: number | null): Record<string, unknown>
  export function mobileOverlayPop(open: number[], state: unknown, lastPos: number | null):
    | { kind: 'none' } | { kind: 'close', keep: number } | { kind: 'leave' } | { kind: 'dead', back: boolean }
}

declare module '~/utils/now-tick.mjs' {
  export function createNowTick(deps: {
    set: (ms: number) => void
    now?: () => number
    doc?: { visibilityState?: string, addEventListener?: (t: string, fn: () => void) => void, removeEventListener?: (t: string, fn: () => void) => void } | null
    every?: (fn: () => void, ms: number) => unknown
    cancel?: (id: unknown) => void
  }): { enable(on: boolean): void, running(): boolean, dispose(): void }
}

declare module '~/utils/viewport-resize.mjs' {
  export function createViewportResize(env?: { win?: { addEventListener: (...a: unknown[]) => void, removeEventListener: (...a: unknown[]) => void } | null, frame?: (fn: () => void) => unknown }): { subscribe(fn: () => void): () => void, size(): number }
  export function onViewportResize(fn: () => void): () => void
}

declare module '~/utils/issue-columns-pref.mjs' {
  export const ISSUE_COLUMNS: readonly string[]
  export const ISSUE_COLUMN_MIN: number
  export const ISSUE_COLUMN_MAX: number
  export function parseIssueColumns(raw: unknown): Record<string, number>
  export function sameIssueColumns(a: unknown, b: unknown): boolean
  export function applyIssueColumns(
    want: unknown,
    io: {
      current: unknown,
      apply: (v: Record<string, number> | null) => void,
      save: (v: Record<string, number> | null) => Promise<{ ok: boolean }>,
    },
  ): Promise<{ ok: boolean, value: Record<string, number>, out?: unknown }>
}

declare module '~/utils/issues-colw.mjs' {
  export type ColWidths = Record<string, number>
  export const ISSUES_COLW_KEY: string
  export const ISSUES_COLW_COLS: string[]
  export const COLW_MIN: number
  export const COLW_MIN_BY_COL: Record<string, number>
  export const COLW_MAX: number
  export const COLW_STEP: number
  export function colMin(col: string): number
  export function clampColWidth(px: unknown, col?: string): number | null
  export function cleanColWidths(raw: unknown): ColWidths
  export function loadColWidths(store?: unknown): ColWidths
  export function saveColWidths(widths: ColWidths, store?: unknown): boolean
  export function dragWidth(startPx: number, dx: number, rtl?: boolean, col?: string): number | null
  export function keyWidth(currentPx: number, key: string, rtl?: boolean, col?: string): number | null
  export function withColWidth(widths: ColWidths, col: string, px: number | null): ColWidths
  export function colWidthVars(widths: ColWidths): Record<string, string>
  export function colWidthClasses(widths: ColWidths): string[]
}
