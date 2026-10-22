<!-- Spec 148 row B7 (SPL-2912): the local dev toolbar. Two helpers for a
     developer running the whole stack on their own machine
     (`./run -a do_dev_mode_up`):

       • "Dev login": POST /api/v1/auth/dev-login (spec 2.3.2, row B3) signs
         this browser in as the workspace owner, then the page reloads into
         the app (owner HUM-10 msg 5ae83885).
       • "Mailpit inbox": the captured mail on loopback port 8025 (spec 2.2,
         owner msg d0a66b04).

     WHO SEES IT: nobody on dev or prd. BOTH must hold, read in the browser
     after mount (so no prerendered page ever carries it):
       1. config.json names envName "lde", the hub's local dev env
          (config.LocalDevEnv); the compose web container writes it from
          SPOOL_ENV_NAME, and every deployed env names something else;
       2. the page is served from a loopback host (localhost, 127.x, ::1):
          local dev publishes on 127.0.0.1 only (spec 2.4).
     The gate is a v-if, never CSS. The hub refuses the endpoint itself
     outside local dev (404, spec 3.2); this gate only keeps the button
     from being offered where it cannot work.

     Unit-tested by tests/unit/dev-toolbar.test.mjs. -->
<template>
  <div
    v-if="visible"
    class="dev-toolbar"
    role="toolbar"
    :aria-label="t('dev_toolbar.aria')"
    data-testid="dev-toolbar"
  >
    <button
      type="button"
      class="dev-toolbar__login"
      data-testid="dev-toolbar-login"
      :disabled="busy"
      @click="signIn"
    >
      {{ t('dev_toolbar.login') }}
    </button>
    <a
      class="dev-toolbar__mail"
      data-testid="dev-toolbar-mailpit"
      :href="mailHref"
      target="_blank"
      rel="noopener noreferrer"
    >
      {{ t('dev_toolbar.mailbox') }}
    </a>
    <span v-if="failed" class="dev-toolbar__error" role="alert" data-testid="dev-toolbar-error">
      {{ t('auth.error.failed') }}
    </span>
  </div>
</template>

<script lang="ts">
import { AUTH_PREFIX, authOrigin } from '~/utils/auth-client.mjs'

/** The hub's local dev env name (csi-spl-api config.LocalDevEnv). */
export const LOCAL_DEV_ENV = 'lde'

/** Mailpit's web UI and REST API port (spec 2.2, published on loopback only). */
export const MAILPIT_PORT = 8025

const IPV4_LOOPBACK = /^127(\.\d{1,3}){3}$/

/** The page host is this machine: localhost, *.localhost, 127.0.0.0/8 or ::1. */
export function isLoopbackHost(hostname: unknown): boolean {
  const h = String(hostname || '').trim().toLowerCase().replace(/^\[|\]$/g, '')
  if (h === 'localhost' || h.endsWith('.localhost') || h === '::1') return true
  return IPV4_LOOPBACK.test(h)
}

/** Show the toolbar: config names local dev AND the page is on loopback. */
export function devToolbarVisible(envName: unknown, hostname: unknown): boolean {
  return String(envName || '').trim().toLowerCase() === LOCAL_DEV_ENV && isLoopbackHost(hostname)
}

/** Mailpit on the loopback name the page uses (a 127.x address stays one). */
export function mailpitHref(hostname: unknown): string {
  const h = String(hostname || '').trim().toLowerCase()
  return `http://${IPV4_LOOPBACK.test(h) ? h : 'localhost'}:${MAILPIT_PORT}/`
}

/** The dev-login endpoint on the auth origin ('' = same origin, the compose Caddy). */
export function devLoginUrl(authBase: unknown): string {
  return `${authOrigin(String(authBase || ''))}${AUTH_PREFIX}/dev-login`
}

/**
 * POST the dev login. Resolves (never throws) to true when the hub set the
 * session (2xx, or a redirect the fetch followed), false on any refusal or
 * a hub that could not be reached.
 */
export async function postDevLogin(fetchFn: typeof fetch, authBase: unknown): Promise<boolean> {
  try {
    const res = await fetchFn(devLoginUrl(authBase), {
      method: 'POST',
      credentials: 'include',
      headers: { accept: 'application/json', 'content-type': 'application/json' },
      body: '{}',
    })
    return Boolean(res && res.ok)
  } catch {
    return false
  }
}
</script>

<script setup lang="ts">
import { safeRedirect } from '~/utils/auth-client.mjs'

const { t } = useI18n()
const config = useRuntimeConfig()

const host = ref('')
const busy = ref(false)
const failed = ref(false)

onMounted(() => {
  host.value = window.location.hostname
})

const visible = computed(() => devToolbarVisible(config.public.envName, host.value))
const mailHref = computed(() => mailpitHref(host.value))

async function signIn() {
  if (busy.value) return
  busy.value = true
  failed.value = false
  const ok = await postDevLogin(window.fetch.bind(window), config.public.authBase)
  if (ok) {
    // a full load: the session probe and every store start signed in
    window.location.assign(safeRedirect(new URLSearchParams(window.location.search).get('redirect') || '/'))
    return
  }
  failed.value = true
  busy.value = false
}
</script>

<style scoped>
.dev-toolbar {
  position: fixed;
  left: 8px;
  bottom: 8px;
  z-index: var(--z-banner);
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 8px;
  border: 1px dashed var(--color-warn);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  color: var(--color-fg);
  font-size: 0.8125rem;
}

.dev-toolbar__login {
  padding: 4px 10px;
  border: 0;
  border-radius: var(--radius-xs);
  background: var(--color-accent);
  color: var(--color-on-accent);
  font: inherit;
  cursor: pointer;
}

.dev-toolbar__login:disabled {
  opacity: 0.6;
  cursor: progress;
}

.dev-toolbar__mail {
  color: var(--color-accent);
}

.dev-toolbar__error {
  color: var(--color-danger);
}
</style>
