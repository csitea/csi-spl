/**
 * A person changes their own picture, the simplest version (owner HUM-10,
 * t1 ccaee528): the account menu's "Change picture" PUTs the picked file to
 * the hub's /api/v1/auth/avatar, "Remove picture" DELETEs it (back to the
 * sign-in provider's picture). UserMenu imports this on the first pick only,
 * so it stays out of the initial chunk. The hub is the gate (it sniffs the
 * type and caps the size); the same checks here only answer sooner.
 */

export const OWN_PICTURE_TYPES = ['image/png', 'image/jpeg', 'image/webp']
/** auth.AvatarMaxBytes on the hub. */
export const OWN_PICTURE_MAX_BYTES = 256 * 1024

/** What is wrong with a picked file before any request: '' | 'type' | 'size'. */
export function ownPictureProblem(file) {
  if (!file || !OWN_PICTURE_TYPES.includes(file.type)) return 'type'
  if (!(file.size > 0) || file.size > OWN_PICTURE_MAX_BYTES) return 'size'
  return ''
}

function avatarUrl(authBase) {
  return `${String(authBase || '').replace(/\/+$/, '')}/api/v1/auth/avatar`
}

/** The hub's answer as a problem: '' (stored), 'type' (415), 'size' (413), else 'failed'. */
export function ownPictureAnswer(status) {
  if (status === 204 || status === 200) return ''
  if (status === 415) return 'type'
  if (status === 413) return 'size'
  return 'failed'
}

/** Upload `file` as the signed-in person's picture: '' | 'type' | 'size' | 'failed'. */
export async function putOwnPicture(authBase, file, fetchFn = globalThis.fetch) {
  const bad = ownPictureProblem(file)
  if (bad) return bad
  try {
    const res = await fetchFn(avatarUrl(authBase), {
      method: 'PUT', credentials: 'include', headers: { 'Content-Type': file.type }, body: file,
    })
    return ownPictureAnswer(res.status)
  } catch {
    return 'failed'
  }
}

/** Back to the sign-in provider's picture: '' | 'failed'. */
export async function deleteOwnPicture(authBase, fetchFn = globalThis.fetch) {
  try {
    const res = await fetchFn(avatarUrl(authBase), { method: 'DELETE', credentials: 'include' })
    return ownPictureAnswer(res.status) ? 'failed' : ''
  } catch {
    return 'failed'
  }
}
