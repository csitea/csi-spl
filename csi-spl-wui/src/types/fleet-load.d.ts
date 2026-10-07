// Fleet load card types. Kept apart from mjs-shims.d.ts (that file is another lane's).
declare module '~/utils/fleet-load.mjs' {
  export const FLEET_OPERATOR_KEY: string
  export const FLEET_STORE_KEY: string
  export const FLEET_BOX_MAX: number
  export const FLEET_BAD_SETTING: string
  export const FLEET_DEFAULT_LOW: number
  export const FLEET_DEFAULT_HIGH: number

  export interface FleetBoxBand {
    box: string
    low: number
    high: number
  }
  export interface FleetLoadStored {
    low: number | null
    high: number | null
    boxOrder: string[] | null
    boxes?: FleetBoxBand[] | null
  }
  export interface FleetLoadView {
    low: number
    high: number
    boxOrder: string[]
    boxes: FleetBoxBand[]
    source: string
    stored: FleetLoadStored
    defaults: { low: number, high: number, boxOrder: string[] }
  }
  export interface FleetLoadDraft {
    low: number
    high: number
    boxOrder: string[]
    resetLow: boolean
    resetHigh: boolean
    resetOrder: boolean
    boxes?: FleetBoxBand[]
    resetBoxes?: boolean
  }

  export function validFleetBox(id: unknown): boolean
  export function fleetBandList(v: unknown): FleetBoxBand[]
  export function fleetBandMap(list: FleetBoxBand[]): Record<string, { low: number, high: number }>
  export function fleetBandOk(b: unknown): boolean
  export function fleetLoadForbidden(err: unknown): boolean
  export function fleetLoadStatusDetail(err: unknown): string
  export function normalizeFleetLoad(body: unknown): FleetLoadView
  export function fleetLoadPatchBody(saved: FleetLoadView, draft: FleetLoadDraft): Record<string, unknown>
  export function suggestFleetBoxes(stats: unknown): string[]
  export function fleetBoxBandOf(view: FleetLoadView | null | undefined, box: string): { low: number, high: number } | null
  export function fleetBoxBandPatch(view: FleetLoadView | null | undefined, box: string, band: { low: number, high: number } | null): Record<string, unknown>
  export function boxLoadPct(row: unknown): number | null
  export function fleetStoredOk(stored: FleetLoadStored | null | undefined): boolean
  export function applyFleetPatch(stored: FleetLoadStored | null | undefined, patch: Record<string, unknown>): FleetLoadStored | null
  export function mockFleetRead(store?: { getItem(key: string): string | null }): unknown
  export function mockFleetWrite(patch: Record<string, unknown>, store?: { getItem(key: string): string | null, setItem(key: string, value: string): void }): unknown
}
