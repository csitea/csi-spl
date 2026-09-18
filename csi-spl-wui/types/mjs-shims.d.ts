declare module '~/utils/spool-client.mjs' {
  export function createSpoolClient(opts?: {
    base?: string
    fetchFn?: typeof fetch
    mock?: boolean
  }): {
    mock: boolean
    healthz(): Promise<unknown>
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
  export function formatBytes(n: number): string
  export function formatTs(ts: string): string
  export function renderBody(src: string): string
}

declare module '~/utils/mock-data.mjs' {
  export const MOCK_MESSAGES: Record<string, unknown>[]
  export function cloneMock(): unknown
}
