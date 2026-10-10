/* t1 f265541a: a member's sign-in emails (utils/sign-in-emails.mjs) */
declare module '~/utils/sign-in-emails.mjs' {
  type Api = { mock?: boolean, base?: string, token?: string, credentials?: RequestCredentials }
  export type SignInEmailRow = { email: string, state: 'active' | 'pending', providers: string[], main: boolean }
  export type SignInEmailAdded = { human_id: string, email: string, state: string, reason: string }
  export const SIGN_IN_EMAIL_PROVIDERS: string[]
  export function signInEmailProviderName(p: string): string
  export function normalizeSignInEmail(r: unknown): SignInEmailRow
  export function signInEmailRows(body: unknown): SignInEmailRow[]
  export function signInEmailConfirmProviders(enabled: unknown): string[]
  export function signInEmailConfirmHref(provider: string, email: string, redirect: string, tenant?: string, base?: string): string
  export function signInEmailAddress(v: unknown): string
  export function signInEmailAddedKey(answer: unknown): string
  export function signInEmailErrorKey(err: unknown): string
  export function loadSignInEmails(api: Api, humanId: string): Promise<unknown>
  export function addSignInEmail(api: Api, humanId: string, email: string): Promise<SignInEmailAdded>
  export function removeSignInEmail(api: Api, humanId: string, email: string): Promise<null>
  export function mockSignInEmailProviders(): Promise<string[]>
}
