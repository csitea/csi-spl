/** Title for the signed-out frame's top bar.
 *  A named build env (`dev`, `prd`) wins. A local `nuxt dev` with no env
 *  is `dev`, so the bar reads spool-dev. A generate with no env reads spool-hub
 *  (CLE-34994: the product is spool-hub, never bare spool).
 *  Production reads spool-hub, the product name, not the env code.
 */
export function loginBarTitle(envName, isDev) {
  const named = String(envName || '').trim().toLowerCase()
  const env = /^[a-z0-9]{1,12}$/.test(named) ? named : (isDev ? 'dev' : '')
  if (env === 'prd') return 'spool-hub'
  return env ? `spool-${env}` : 'spool-hub'
}
