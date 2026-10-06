// The version a person reads. One leading "v", never "vv".
// "dev" and an empty value stay as they are. Comparisons, data-version
// and /releases/<ref> stay on the plain value; call this only where the
// version is shown.
//
// A deploy sets NUXT_PUBLIC_APP_VERSION to the bare semver. Nuxt uses that
// raw string as public.appVersion, so a display would otherwise read "1.2.4".

/**
 * @param {unknown} v
 * @returns {string}
 */
export function displayVersion(v) {
  const s = String(v ?? '').trim()
  if (!s || s === 'dev') return s
  if (s[0] === 'v' || s[0] === 'V') return s
  return 'v' + s
}
