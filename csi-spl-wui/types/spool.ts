export type MsgKind = 'task' | 'result' | 'note' | 'reject'

export interface FileRef {
  file_id: string
  name: string
  bytes: number
  sha256: string
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
}

export interface ChannelRow {
  channel_id: string
  name: string
  created_by?: string
}
