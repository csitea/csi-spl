/**
 * The role picker of the user edit pane (specs/025 §10.2 item 7): a member
 * holds 1..* roles, one of them primary. Its own module so only the pane's
 * chunk carries it. The hub re-checks every set; this decides what is offered.
 */

/** A role that holds a set alone (025 §10.2 rule 3, the hub's rbac.Exclusive). */
export const EXCLUSIVE_ROLES = ['demo_user', 'channel_guest']

const exclusive = (id) => EXCLUSIVE_ROLES.includes(id)

/**
 * The picked { roles, primary } after ticking (`on`) or unticking role `id`.
 * Ticking an exclusive role replaces the set; ticking another drops an
 * exclusive one. The primary stays while the set holds it.
 */
export function toggleRole(picked, id, on) {
  if (on && exclusive(id)) return { roles: [id], primary: id }
  const others = picked.roles.filter((r) => r !== id && !(on && exclusive(r)))
  const roles = on ? [...others, id] : others
  const primary = roles.includes(picked.primary) ? picked.primary : (roles[0] || '')
  return { roles, primary }
}

/**
 * What the picker lists: every role the actor may grant, and a held role it
 * may not (or the workspace no longer lists) as locked. A role neither
 * grantable nor held is not offered.
 */
export function roleOptions(catalogue, held) {
  const listed = catalogue.filter((r) => r.grantable || held.includes(r.id)).map((r) => ({ id: r.id, locked: !r.grantable }))
  const unlisted = held.filter((id) => !catalogue.some((r) => r.id === id)).map((id) => ({ id, locked: true }))
  return [...listed, ...unlisted]
}

/** Whether the picked set can be saved: not empty, and not what the member holds. */
export function rolesDirty(member, picked) {
  if (!picked.roles.length) return false
  const held = new Set(member.roles)
  return picked.primary !== member.role || picked.roles.length !== held.size || picked.roles.some((r) => !held.has(r))
}
