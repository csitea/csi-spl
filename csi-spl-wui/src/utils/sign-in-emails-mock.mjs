/**
 * The mock hub's sign-in emails (t1 f265541a, NUXT_PUBLIC_USE_MOCK=1). Its own
 * module so a live bundle never loads it. Shapes and refusals match the hub
 * (csi-spl-api internal/hub/sign_in_emails.go): an add is pending, a taken
 * address is 409 email_taken, the main address and the last sign-in are not
 * removed. One store per page, so a remove survives a reload of the list.
 */

function mockErr(status, token) {
  return Object.assign(new Error(`spool ${status} ${token}`), { status, token })
}

/** Addresses another mock member holds: adding one is 409 email_taken. */
const TAKEN = ['taken@example.com']

/** A fresh store; HUM-1 (the mock session) starts with one active and one pending address. */
export function createSignInEmailsMock() {
  const byHuman = new Map([
    ['HUM-1', [
      { email: 'member@example.com', state: 'active', providers: ['google'], main: true },
      { email: 'member.work@example.com', state: 'pending', providers: [], main: false },
    ]],
  ])
  const rowsOf = (hum) => {
    if (!byHuman.has(hum)) byHuman.set(hum, [{ email: `${String(hum).toLowerCase()}@example.com`, state: 'active', providers: ['password'], main: true }])
    return byHuman.get(hum)
  }
  return {
    list(hum) {
      return { human_id: hum, emails: rowsOf(hum).map((r) => ({ ...r, providers: [...r.providers] })) }
    },
    add(hum, email) {
      const e = String(email || '').trim().toLowerCase()
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) throw mockErr(400, 'bad_email')
      const own = rowsOf(hum).find((r) => r.email === e)
      if (own) return { human_id: hum, email: e, state: own.state, reason: own.state === 'active' ? 'already_active' : 'pending_until_provider_sign_in' }
      const elsewhere = TAKEN.includes(e) || [...byHuman].some(([h, rows]) => h !== hum && rows.some((r) => r.email === e))
      if (elsewhere) throw mockErr(409, 'email_taken')
      rowsOf(hum).push({ email: e, state: 'pending', providers: [], main: false })
      return { human_id: hum, email: e, state: 'pending', reason: 'pending_until_provider_sign_in' }
    },
    remove(hum, email) {
      const rows = rowsOf(hum)
      const e = String(email || '').trim().toLowerCase()
      const i = rows.findIndex((r) => r.email === e)
      if (i < 0) throw mockErr(404, 'not_found')
      if (rows[i].main) throw mockErr(409, 'main_email')
      if (rows[i].state === 'active' && rows.filter((r) => r.state === 'active').length === 1) throw mockErr(409, 'last_sign_in')
      rows.splice(i, 1)
      return null
    },
    providers() {
      return ['google', 'microsoft']
    },
  }
}

let store = null

/** The page's one mock store. */
export function signInEmailsMock() {
  return (store ||= createSignInEmailsMock())
}
