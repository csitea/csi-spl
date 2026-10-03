export type MsgKind = 'task' | 'result' | 'note' | 'reject' | 'blocker' | 'msg'

/** v:1 files[] entry (002 message-schema; internal/msg/msg.go Attachment). */
export interface FileRef {
  mode?: 'blob' | 'path'
  kind?: 'file' | 'dir'
  file_id?: string
  path?: string
  name: string
  bytes?: number
  sha256?: string
}

export interface SpoolMessage {
  v: 1 | 2
  msg_id: string
  task_id: string
  ts: string
  from: string
  to: string
  kind: MsgKind | string
  body: string
  files?: FileRef[]
  channel?: string | null
  parent_task_id?: string | null
  /** rdb 0034. 1 when sent outside the open topics pane. 0 when that pane is open and the topics tab is selected. */
  is_parent?: 0 | 1
  from_box?: string
  to_box?: string
  cursor?: string
  received_at?: string
  deliveries?: { to_box: string, state: string }[]
  /** 013 US7 FR-013: our own send, shown before the hub echo / ack confirms it. */
  pending?: boolean
  /**
   * message-edit-v1 §2. All three are OMITTED until a message has
   * been edited — `edited_at` is an RFC3339 UTC string and its PRESENCE is
   * the marker's test, `revision` counts bodies with the original included
   * (2 after the first edit). They ride at the element's top level, beside
   * `cursor`, not inside `env.msg`.
   */
  edited_at?: string
  edited_by?: string
  revision?: number
  /**
   * specs/036 FR-011 (rdb 0040): the HUM-* the hub VERIFIED typed this line
   * at the `from` agent's terminal. Omitted for every other row. The card
   * then shows the human, with a "via terminal <agent>" badge.
   */
  typed_by?: string
  /**
   * spec 068 (rdb 0110): the seat `<id>@<box>` that must deal with this
   * message. Omitted while nobody is; the card then shows nothing.
   */
  responsible?: string
  /**
   * Emoji added to this message (rdb 0037). Present on an opening message
   * (is_parent 1) and on a reply (is_parent 0). Empty when nobody has added one.
   */
  reactions?: MessageReaction[]
  /**
   * SPL-1024 move-v1 §5: present only while the row is not where its envelope
   * says (moved to another channel / topic). `moved_from_*` name its home.
   */
  moved_at?: string
  moved_by?: string
  moved_from_channel?: string
  moved_from_task?: string
}

/** One emoji and the members who added it. */
export interface MessageReaction {
  emoji: string
  actors: string[]
}

/** PUT/DELETE /v1/messages/{msg_id}/reactions, and the live message_reaction frame. */
export interface ReactionUpdate {
  msg_id: string
  task_id?: string
  reactions: MessageReaction[]
}

/** One topic list row (003 view-v1 §4.3, normalised by utils/view-api.mjs). */
export interface TopicRow {
  task_id: string
  /** Hub-envelope fields of the topic's first message (channels-v1 §2); null when absent. */
  parent_task_id?: string | null
  channel?: string | null
  first_ts: string
  last_ts: string
  count: number
  kinds: Record<string, number>
  participants: string[]
  subject: string
  /** t1 8fb802cd: set only on a row of an archived topic (lists leave those out); the row is marked */
  archived_at?: string
}

/** One channel (channels-v1 §5.2, normalised by utils/view-api.mjs channelsFromView). */
export interface ChannelRow {
  channel_id: string
  name: string
  /** What the channel is for, as its creator typed it (channels-v1 §5.1). */
  description?: string
  created_by?: string
  created_at?: string
  default?: boolean
  retention_days?: number
  count?: number
  /** Messages after the `read=` cursor sent with listChannels (else = count). */
  unread?: number
  last_ts?: string | null
  last_cursor?: string | null
  members?: { agents: number, boxes: number, posters: number }
}

/** view door (view-v1 §2): `session` makes the client send cookies (010 FR-009). */
export type ViewDoor = 'off' | 'token' | 'session' | ''

/** wui-live-ws §3.2 presence frame. `peer` = `<agent>@<box>`; last writer wins per peer. */
export interface PresenceFrame {
  type: 'presence'
  peer: string
  status: 'online' | 'offline'
}

/** wui-live-ws §3.2 ack frame. */
export interface AckFrame {
  type?: 'ack'
  msg_id: string
  task_id: string
  cursor?: string
  received_at?: string
  /**
   * What the hub did with it (contracts/flush.md): `sent` = handed to the
   * recipient's box, `queued` = the box is offline and it is held, `local`,
   * `pending`. This is the delivery RECEIPT - the evidence a human has that
   * their message arrived, ~83 ms after send, without waiting for a reply
   * that contains a model turn.
   */
  delivery?: string
  /** the box the hub routed it to */
  to_box?: string
}

/** wui-live-ws §4 send fields (the live-ws client adds type and msg_id). */
export interface SendFrame {
  task_id: string
  kind?: string
  body?: string
  files?: unknown[]
  to?: string
  /** specs/058: the box of `to` (an <ID>@<box> address) */
  to_box?: string
  channel?: string
  parent_task_id?: string
  is_parent?: 0 | 1
  msg_id?: string
}
