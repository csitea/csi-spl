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
  v: 1
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
}

/** One thread list row (003 view-v1 §4.3, normalised by utils/view-api.mjs). */
export interface ThreadRow {
  task_id: string
  first_ts: string
  last_ts: string
  count: number
  kinds: Record<string, number>
  participants: string[]
  subject: string
}

export interface ChannelRow {
  channel_id: string
  name: string
  created_by?: string
}
