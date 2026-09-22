export type MsgKind = 'task' | 'result' | 'note' | 'reject'

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
  from_box?: string
  to_box?: string
  cursor?: string
  received_at?: string
  deliveries?: { to_box: string, state: string }[]
  /** 013 US7 FR-013: our own send, shown before the hub echo / ack confirms it. */
  pending?: boolean
  /**
   * message-edit-v1 §2 (CLE-3445). All three are OMITTED until a message has
   * been edited — `edited_at` is an RFC3339 UTC string and its PRESENCE is
   * the marker's test, `revision` counts bodies with the original included
   * (2 after the first edit). They ride at the element's top level, beside
   * `cursor`, not inside `env.msg`.
   */
  edited_at?: string
  edited_by?: string
  revision?: number
}

/** One thread list row (003 view-v1 §4.3, normalised by utils/view-api.mjs). */
export interface ThreadRow {
  task_id: string
  /** Hub-envelope fields of the thread's first message (channels-v1 §2); null when absent. */
  parent_task_id?: string | null
  channel?: string | null
  first_ts: string
  last_ts: string
  count: number
  kinds: Record<string, number>
  participants: string[]
  subject: string
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
   * that contains a model turn (CLE-3435).
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
  channel?: string
  parent_task_id?: string
  msg_id?: string
}
