/**
 * The card payment step of /checkout (spec 006 T021w, contracts/checkout-v1.md
 * §1.2 rail=card): csi-rel's storefront path, copied — the card vendor's JS
 * SDK, its Payment Element mounted into the page, confirmPayment with
 * return_url = the success page, redirect only when the method needs one.
 *
 * This is the ONLY WUI file allowed to name the card vendor
 * (csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh, with a CONTROL).
 * Every other file speaks of "card".
 *
 * Card details are typed into the vendor's iframe and go from there to the
 * vendor: they never reach this page's JavaScript, the hub, storage or a log.
 * The client secret only authorises confirming THIS payment; it is held in
 * memory and never stored or put in a URL by this module.
 */

/** The vendor SDK; the WUI CSP admits its origin from cnf (env.payment.wui_csp). */
export const CARD_SDK_URL = 'https://js.stripe.com/v3/'

/** Query parameters the vendor appends on a redirect-return to the success page. */
export const CARD_RETURN_PARAMS = ['payment_intent', 'payment_intent_client_secret', 'redirect_status', 'setup_intent', 'setup_intent_client_secret']

let sdkPromise = null

/** Load the SDK once per page; resolves to its factory. `doc`/`win` are injectable for tests. */
export function loadCardSdk({ doc = globalThis.document, win = globalThis } = {}) {
  if (win && typeof win.Stripe === 'function') return Promise.resolve(win.Stripe)
  if (sdkPromise) return sdkPromise
  sdkPromise = new Promise((resolve, reject) => {
    const s = doc.createElement('script')
    s.src = CARD_SDK_URL
    s.async = true
    s.onload = () => (typeof win.Stripe === 'function' ? resolve(win.Stripe) : reject(new Error('card_sdk')))
    s.onerror = () => {
      sdkPromise = null
      reject(new Error('card_sdk'))
    }
    doc.head.appendChild(s)
  })
  return sdkPromise
}

/** Forget a loaded SDK (tests). */
export function resetCardSdk() {
  sdkPromise = null
}

/** A publishable key in the vendor's shape (public; never a secret key). */
export function cardKeyUsable(key) {
  return /^pk_(test|live)_[A-Za-z0-9]+$/.test(String(key || ''))
}

/**
 * Mount the Payment Element into `el` for this checkout's payment. Resolves to
 * { confirm(returnUrl), destroy() }; rejects with Error('card_sdk' |
 * 'card_config') when it cannot. `confirm` resolves (never throws) to
 * { ok: true, status } when no redirect was needed, or { ok: false, error }
 * with error 'card_declined' (the buyer can correct and retry) or
 * 'card_failed'. A method that needs a redirect leaves the page for the
 * vendor and comes back to `returnUrl`.
 */
export async function mountCardPayment({ publishableKey, clientSecret, el, locale, sdk } = {}) {
  if (!cardKeyUsable(publishableKey) || !String(clientSecret || '').includes('_secret_') || !el) {
    throw new Error('card_config')
  }
  const factory = sdk || (await loadCardSdk())
  const vendor = factory(publishableKey, { locale: locale || 'auto' })
  const elements = vendor.elements({ clientSecret })
  const payment = elements.create('payment')
  payment.mount(el)
  return {
    async confirm(returnUrl) {
      let r
      try {
        r = await vendor.confirmPayment({ elements, confirmParams: { return_url: String(returnUrl) }, redirect: 'if_required' })
      } catch {
        return { ok: false, error: 'card_failed' }
      }
      if (r && r.error) {
        const type = String(r.error.type || '')
        return { ok: false, error: type === 'card_error' || type === 'validation_error' ? 'card_declined' : 'card_failed' }
      }
      return { ok: true, status: String((r && r.paymentIntent && r.paymentIntent.status) || '') }
    },
    destroy() {
      try { payment.destroy() } catch { /* already gone */ }
    },
  }
}

/**
 * The success page's URL without the vendor's redirect-return parameters (the
 * client secret must not stay in the address bar or the history); null when
 * there is nothing to strip.
 */
export function cardReturnCleanUrl(href) {
  let u
  try { u = new URL(String(href)) } catch { return null }
  let hit = false
  for (const p of CARD_RETURN_PARAMS) {
    if (u.searchParams.has(p)) {
      u.searchParams.delete(p)
      hit = true
    }
  }
  return hit ? `${u.pathname}${u.search}${u.hash}` : null
}
