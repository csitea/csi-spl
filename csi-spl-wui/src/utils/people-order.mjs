/**
 * Spec 154 section 2.7 (build row B9): the People panel's one list in three
 * groups, A-Z inside each. Ships on the first screen with ChannelSidebar, so
 * it holds only the order and the filter; contacts-client.mjs and the rows
 * are lazy (C25).
 *
 *   online    the workspace's members the roster calls online right now
 *   members   the other workspace members
 *   contacts  the reader's contacts who are no member here
 *
 * A contact whose member_id names a listed member is that member's row, with
 * contactId set for its "contact" tag, never a second row (C24e). A member_id
 * naming nobody listed (the roster has not answered yet) stays a contact, so a
 * contact is never lost.
 */

export const PEOPLE_FILTER_KEY = 'spool.people.filter'
export const PEOPLE_FILTER_ALL = 'all'
export const PEOPLE_FILTER_WORKSPACE = 'workspace'

/** The stored filter, the default (All) for anything else. */
export function parsePeopleFilter(raw) {
  return raw === PEOPLE_FILTER_WORKSPACE ? PEOPLE_FILTER_WORKSPACE : PEOPLE_FILTER_ALL
}

/** The name a contact shows: first + last, else its email, else its phone. */
export function contactName(contact) {
  const c = contact || {}
  const name = [c.first_name, c.last_name].map((s) => String(s || '').trim()).filter(Boolean).join(' ')
  return name || String(c.email || '') || String(c.phone || '')
}

/**
 * @template {{ id: string, online?: boolean }} M
 * @param {M[]} members the member rows, each with `online`
 * @param {{ contact_id: string, member_id?: string | null }[]} contacts
 * @param {{ locale?: string, nameOf?: (m: M) => string, filter?: string }} [opts]
 * @returns {{ online: (M & { contactId?: string })[], members: (M & { contactId?: string })[], contacts: any[] }}
 */
export function peopleOrder(members, contacts, { locale, nameOf = (m) => m.id, filter } = {}) {
  const collator = new Intl.Collator(locale, { sensitivity: 'base' })
  const az = (name, key) => (a, b) => collator.compare(name(a), name(b)) || String(key(a)).localeCompare(String(key(b)))
  const listed = new Set((members || []).map((m) => m.id))
  const tagOf = new Map()
  const others = []
  for (const c of contacts || []) {
    if (c.member_id && listed.has(c.member_id)) {
      if (!tagOf.has(c.member_id)) tagOf.set(c.member_id, c.contact_id)
    } else others.push(c)
  }
  const rows = (members || []).map((m) => (tagOf.has(m.id) ? { ...m, contactId: tagOf.get(m.id) } : m))
  const byMember = az(nameOf, (m) => m.id)
  return {
    online: rows.filter((m) => m.online).sort(byMember),
    members: rows.filter((m) => !m.online).sort(byMember),
    contacts: parsePeopleFilter(filter) === PEOPLE_FILTER_WORKSPACE ? [] : others.sort(az(contactName, (c) => c.contact_id)),
  }
}
