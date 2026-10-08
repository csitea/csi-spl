// Hours settings types (spec 107 T016). Kept apart from mjs-shims.d.ts.
declare module '~/utils/hours-settings.mjs' {
  export type HoursSettings = { period: string, graceDays: number, idleMinutes: number, tz: string }
  export type HoursSettingsForm = { period: string, graceDays: number | string, idleMinutes: number | string, tz: string }
  export const HOURS_KEY_PERIOD: string
  export const HOURS_KEY_GRACE: string
  export const HOURS_KEY_IDLE: string
  export const HOURS_KEY_TZ: string
  export const HOURS_PERIOD_OPTIONS: readonly string[]
  export const HOURS_GRACE_RANGE: { min: number, max: number }
  export const HOURS_IDLE_RANGE: { min: number, max: number }
  export const HOURS_DEFAULTS: HoursSettings
  export function hoursSettingsOf(settings: unknown): HoursSettings
  export function hoursSettingsPatch(stored: HoursSettings, form: HoursSettingsForm): Record<string, string | number>
  export function hoursSettingValid(key: string, v: unknown): boolean
  export function hoursReadingOn(claim: unknown): boolean
}
