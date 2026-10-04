// Operator console types (spec 074 T008). Kept apart from mjs-shims.d.ts.
declare module '~/utils/operator-console.mjs' {
  export const OPERATOR_MOCK_KEY: string
  export const OPERATOR_MOCK_STORE_KEY: string
  export const OPERATOR_STATUSES: readonly ['active', 'suspended', 'archived']
  export const OPERATOR_BILLING: readonly string[]
  export const OPERATOR_WS_ID_RE: RegExp

  export type OperatorStatus = 'active' | 'suspended' | 'archived'
  export interface OperatorWorkspace {
    id: string
    displayName: string
    billingStatus: string
    planId: string
    createdAt: string
    suspendedAt: string
    archivedAt: string
    operator: boolean
  }
  export interface OperatorDraft {
    id?: string
    displayName?: string
    adminEmail?: string
    billingStatus?: string
  }

  export function operatorForbidden(err: unknown): boolean
  export function normalizeOperatorWorkspace(raw: unknown): OperatorWorkspace
  export function normalizeOperatorWorkspaces(body: unknown): OperatorWorkspace[]
  export function operatorWorkspaceStatus(ws: OperatorWorkspace | null | undefined): OperatorStatus
  export function operatorConsoleVisible(rows: unknown): boolean
  export function filterOperatorWorkspaces(rows: OperatorWorkspace[], opts?: { q?: string, status?: string }): OperatorWorkspace[]
  export function operatorCreateBody(draft?: OperatorDraft): { body?: Record<string, string>, error?: string }
  export function operatorRootKey(body: unknown): string
  export function replaceOperatorWorkspace(rows: OperatorWorkspace[], row: unknown): OperatorWorkspace[]
  export function operatorMockSeed(): Array<Record<string, unknown>>
  export function mockOperatorList(store?: Storage | null): { workspaces: Array<Record<string, unknown>> }
  export function mockOperatorCreate(body?: Record<string, unknown>, store?: Storage | null, now?: string): Record<string, unknown>
  export function mockOperatorPatch(id: string, patch?: Record<string, unknown>, store?: Storage | null, now?: string): { workspace: Record<string, unknown> }
  export function mockOperatorArchive(id: string, store?: Storage | null, now?: string): { workspace: Record<string, unknown> }
}
