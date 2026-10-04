// HUM-10 (topic cd357c76): the hub id lookup. Kept apart from mjs-shims.d.ts;
// these blocks merge with its '~/utils/id-links.mjs' module.
declare module '~/utils/id-links.mjs' {
  export function resolveId(token: string, index: IdIndex): { kind: string, href: string } | null
}

declare module '~/utils/id-lookup.mjs' {
  export const LOOKUP_MAX: number
  export function bodyTokens(text: unknown): string[]
  export function hitRows(hits: Iterable<unknown>, self?: string): { topics: unknown[], messages: unknown[] }
  export function createIdLookup(opts: {
    fetchIds: (ids: string[]) => Promise<unknown>
    resolves: (token: string, index: unknown) => boolean
    onHits: () => void
    schedule?: (fn: () => void) => void
    max?: number
  }): { note(text: string, index: unknown): void, rows(self?: string): { topics: unknown[], messages: unknown[] }, readonly version: number }
  export function mockLookupIds(rows: unknown[], archived: unknown[], ids: string[], self?: string): { ids: unknown[] }
}
