<!-- Top-right user control, after the reference storefront's header
     account control: signed in → the person's avatar (member HUM-*: the stored
     IdP picture, else the deterministic identicon — SpoolAvatar; no member id:
     initials, else a silhouette). CLE-3406: first the person's OWN IdP picture
     (auth-v1 GET /api/v1/auth/avatar, session only, no membership needed, as
     a data: URL); a 404 or any failure falls back to the above. Clicking it
     opens a dropdown: who they are, Settings, Sign out. Signed out → the sign-in entry.
     WAI-ARIA menu button: Enter/Space (click) and ArrowDown open on the first item,
     ArrowUp on the last; arrows wrap, Home/End jump, Escape closes and returns
     focus to the button, Tab or a click outside closes.
     SPL-990 (<= 820 px): the panel is a bottom sheet over a scrim, and it
     carries what the phone top bar has no room for - language, theme and the
     notification toggles (the rail's copy hides itself there). -->
<template>
  <div ref="root" class="user-menu" data-test="user-menu">
    <template v-if="signedIn">
      <button
        ref="trigger"
        type="button"
        class="user-menu__trigger"
        data-test="user-menu-trigger"
        aria-haspopup="menu"
        :aria-expanded="open ? 'true' : 'false'"
        :aria-controls="menuId"
        :aria-label="buttonLabel"
        :title="me.primary || t('user_menu.account')"
        @click="toggle"
        @keydown="onTriggerKey"
      >
        <span class="user-menu__avatar" :class="['user-menu__avatar--' + (ownPic ? 'member' : mode), { 'user-menu__avatar--acting': actingAs }]" aria-hidden="true">
          <img v-if="ownPic" class="spool-avatar" data-test="user-menu-picture" :src="ownPic" :width="32" :height="32" :style="{ width: '32px', height: '32px' }" alt="" draggable="false" @error="ownPic = ''">
          <SpoolAvatar v-else-if="mode === 'member'" :id="me.hum" :size="32" />
          <template v-else-if="mode === 'initials'">{{ initials }}</template>
          <UiIcon v-else name="user" :size="20" />
        </span>
      </button>
      <!-- specs/054 (owner 18597eaa): a slim "Acting as X · Stop" line directly
           under the avatar, warning colour as a thin accent — not a full-width
           band. Shown only while acting. -->
      <div v-if="actingAs" class="user-menu__acting" data-test="actas-banner" role="status">
        <span class="user-menu__acting-text">{{ t('act_as.acting_as', { name: actingAs.targetName }) }}</span>
        <span class="user-menu__acting-sep" aria-hidden="true">·</span>
        <button type="button" class="user-menu__acting-stop" data-test="actas-stop" @click="stopActing">
          {{ t('act_as.stop') }}
        </button>
      </div>
      <div
        v-if="open"
        class="user-menu__scrim"
        data-test="user-menu-scrim"
        aria-hidden="true"
        @click="close(true)"
      />
      <div
        v-show="open"
        :id="menuId"
        class="user-menu__panel"
        data-test="user-menu-panel"
      >
        <span class="user-menu__grip" aria-hidden="true" />
        <div class="user-menu__who" data-test="user-menu-who">
          <span class="user-menu__avatar user-menu__avatar--lg" :class="'user-menu__avatar--' + (ownPic ? 'member' : mode)" aria-hidden="true">
            <img v-if="ownPic" class="spool-avatar" data-test="user-menu-picture" :src="ownPic" :width="40" :height="40" :style="{ width: '40px', height: '40px' }" alt="" draggable="false" @error="ownPic = ''">
            <SpoolAvatar v-else-if="mode === 'member'" :id="me.hum" :size="40" />
            <template v-else-if="mode === 'initials'">{{ initials }}</template>
            <UiIcon v-else name="user" :size="24" />
          </span>
          <span class="user-menu__names">
            <strong class="user-menu__primary" data-test="user-menu-primary">{{ me.primary || t('user_menu.signed_in') }}</strong>
            <span v-if="me.secondary" class="user-menu__secondary" data-test="user-menu-secondary">{{ me.secondary }}</span>
            <span v-if="access.roleKey" class="user-menu__secondary" data-test="user-menu-role">{{ t('user_menu.role', { role: t(access.roleKey) }) }}</span>
          </span>
        </div>
        <!-- mounted while open, SHOWN only <= 820 px (CSS), so the phone
             never depends on script to reach these controls -->
        <div v-if="open" class="user-menu__prefs" data-test="user-menu-prefs">
          <div class="user-menu__pref" data-test="user-menu-language">
            <span class="user-menu__pref-label">{{ t('nav.lang_label') }}</span>
            <LanguageSwitcher />
          </div>
          <div class="user-menu__pref" data-test="user-menu-theme">
            <span class="user-menu__pref-label">{{ t('settings.theme') }}</span>
            <ThemeToggle align="end" />
          </div>
          <div class="user-menu__pref" data-test="user-menu-notify">
            <span class="user-menu__pref-label">{{ t('settings.notifications') }}</span>
            <NotificationCenter placement="menu" />
          </div>
          <!-- owner 2026-09-27 (topic 86a570ea): the hub connection lives here
               on phones, next to the bell and the note, not on the start screen -->
          <div class="user-menu__pref" data-test="user-menu-connection" role="status">
            <span class="user-menu__pref-label"><ConnectionStatus /></span>
          </div>
        </div>
        <ul role="menu" class="user-menu__items" :aria-label="buttonLabel" @keydown="onMenuKey">
          <li role="none">
            <NuxtLink
              ref="item0"
              role="menuitem"
              tabindex="-1"
              class="user-menu__item"
              data-test="user-menu-settings"
              :to="localePath('/settings')"
              @click="close(false)"
            >
              <UiIcon name="settings" :size="18" />
              <span>{{ t('user_menu.settings') }}</span>
            </NuxtLink>
          </li>
          <!-- SPL-1037 (specs/046): Tenant settings for admins and biz_owners;
               on desktop the same entry is the sidebar's bottom-left icon -->
          <li v-if="tenantSettingsShown" role="none">
            <NuxtLink
              ref="itemTenant"
              role="menuitem"
              tabindex="-1"
              class="user-menu__item"
              data-test="user-menu-tenant-settings"
              :to="localePath('/tenant-settings')"
              @click="close(false)"
            >
              <UiIcon name="building" :size="18" />
              <span>{{ t('tenant_settings.title') }}</span>
            </NuxtLink>
          </li>
          <!-- specs/054 (owner 18597eaa): "Act as…" above Sign out for an admin -->
          <li v-if="canActAs" role="none">
            <button
              ref="itemActAs"
              role="menuitem"
              tabindex="-1"
              type="button"
              class="user-menu__item"
              data-test="user-menu-act-as"
              @click="openActAs"
            >
              <UiIcon name="users" :size="18" />
              <span>{{ t('user_menu.act_as') }}</span>
            </button>
          </li>
          <!-- specs/054: end the act-as clone (sign-out), above Sign out -->
          <li v-if="actingAs" role="none">
            <button
              ref="itemActAsStop"
              role="menuitem"
              tabindex="-1"
              type="button"
              class="user-menu__item"
              data-test="user-menu-stop-acting"
              @click="stopActing"
            >
              <UiIcon name="log-out" :size="18" />
              <span>{{ t('user_menu.stop_acting_as', { name: actingAs.targetName }) }}</span>
            </button>
          </li>
          <li role="none">
            <button
              ref="item1"
              role="menuitem"
              tabindex="-1"
              type="button"
              class="user-menu__item"
              data-test="user-menu-signout"
              @click="signOut"
            >
              <UiIcon name="log-out" :size="18" />
              <span>{{ t('user_menu.sign_out') }}</span>
            </button>
          </li>
        </ul>
      </div>
      <!-- specs/054: the "Act as…" picker (teleports; open state from the menu item) -->
      <ActAsPicker :open="actAsOpen" @update:open="actAsOpen = $event" />
    </template>
    <NuxtLink
      v-else-if="session.state !== 'loading'"
      class="user-menu__signin"
      data-test="user-menu-signin"
      :to="{ path: localePath('/login'), query: { redirect: signInRedirect(route.fullPath) } }"
      :title="t('nav.login')"
      :aria-label="t('nav.login')"
    >
      <span class="user-menu__avatar user-menu__avatar--silhouette" aria-hidden="true">
        <UiIcon name="log-in" :size="18" />
      </span>
      <span class="user-menu__signin-label">{{ t('nav.login') }}</span>
    </NuxtLink>
  </div>
</template>

<script setup lang="ts">
import ThemeToggle from '@/components/ThemeToggle.vue'
/* SPL-990: only a phone's sheet mounts these two; async keeps them out of
   the first paint */
const LanguageSwitcher = defineAsyncComponent(() => import('@/components/LanguageSwitcher.vue'))
const NotificationCenter = defineAsyncComponent(() => import('@/components/NotificationCenter.vue'))
/* topic 86a570ea: reads the live socket state - async keeps the live store out of the entry */
const ConnectionStatus = defineAsyncComponent(() => import('@/components/ConnectionStatus.vue'))
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { MEMBERS_IMPERSONATE } from '~/utils/access.mjs'
import { tenantSettingsVisible } from '~/utils/tenant-settings-nav.mjs'
import { avatarMode, menuButtonLabelKey, nextMenuIndex, ownAvatarUrl, signInRedirect, userIdentity, userInitials } from '~/utils/user-menu.mjs'
import { applyPopover, focusWithoutScroll, readViewport } from '~/utils/place-popover.mjs'
import { loadAvatarImageUrl } from '~/utils/avatar.mjs'
import { useAuthBase } from '~/composables/useAuthClient'
import { useMobileStack } from '~/composables/useMobileStack'

const session = useSessionStore()
const access = useAccessStore()
const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const menuId = 'user-menu-panel'

const signedIn = computed(() => session.state === 'in' && !!session.claims)
const tenantSettingsShown = computed(() => signedIn.value && tenantSettingsVisible(access.me))
// specs/054: while this session is an act-as clone, the menu offers "Stop
// acting as X" above Sign out (the same exit as the banner).
const actingAs = computed(() => access.me?.actAs ?? null)
// specs/054 (owner 18597eaa): "Act as…" above Sign out for an admin who is not
// already acting; it opens the picker dialog.
const canActAs = computed(() => signedIn.value && !actingAs.value && access.can(MEMBERS_IMPERSONATE))
const actAsOpen = ref(false)
// specs/025 FR-008: the member's role in the active tenant, under the name.
watch(signedIn, (v) => { if (v) access.load() }, { immediate: true })
const me = computed(() => userIdentity(session.claims))
const mode = computed(() => avatarMode(session.claims))
const initials = computed(() => userInitials(session.claims))

// the signed-in person's own IdP picture, '' until loaded / none.
const authBase = useAuthBase()
const ownPic = ref('')
const ownPicUrl = computed(() => (signedIn.value ? ownAvatarUrl(authBase, session.claims) : ''))
watch(ownPicUrl, async (url) => {
  ownPic.value = ''
  /* a member with no stored picture got a 404 on every load */
  let missStore: Storage | null = null
  try { missStore = window.localStorage } catch { /* blocked */ }
  const got = await loadAvatarImageUrl(url, { credentials: 'include', missStore })
  if (url === ownPicUrl.value) ownPic.value = got
}, { immediate: true })
const buttonLabel = computed(() => {
  const k = menuButtonLabelKey(session.claims)
  return t(k.key, k.params)
})

const open = ref(false)
const focused = ref(-1)
const root = ref<HTMLElement | null>(null)
const trigger = ref<HTMLButtonElement | null>(null)
const item0 = ref<{ $el: HTMLElement } | null>(null)
const item1 = ref<HTMLButtonElement | null>(null)
const itemTenant = ref<{ $el: HTMLElement } | null>(null)
const itemActAs = ref<HTMLButtonElement | null>(null)
const itemActAsStop = ref<HTMLButtonElement | null>(null)

function items(): HTMLElement[] {
  return [item0.value?.$el, itemTenant.value?.$el, itemActAs.value, itemActAsStop.value, item1.value].filter((el): el is HTMLElement => !!el)
}

/* SPL-990: <= 820 px is the phone layout; M1's stack owns that answer. The
   media query is read too, for a shell that has not installed the stack. */
const narrow = useMobileStack().isMobile
const phone = () => narrow.value || window.matchMedia('(max-width: 820px)').matches

function placePanel() {
  // the bottom sheet is placed by CSS, not next to the button
  if (phone()) return
  const panel = root.value?.querySelector<HTMLElement>('.user-menu__panel')
  const btn = trigger.value
  if (!panel || !btn) return
  const r = btn.getBoundingClientRect()
  applyPopover(panel, {
    left: r.left,
    right: r.right,
    top: r.top,
    bottom: r.bottom,
    align: 'end',
    gap: 6,
  }, readViewport())
}

async function focusItem(i: number) {
  focused.value = i
  await nextTick()
  placePanel()
  focusWithoutScroll(items()[i])
}

function openAt(i: number) {
  open.value = true
  void focusItem(i)
}

function close(refocus: boolean) {
  open.value = false
  focused.value = -1
  if (refocus) focusWithoutScroll(trigger.value)
}

function toggle() {
  if (open.value) close(false)
  else openAt(0)
}

function onTriggerKey(e: KeyboardEvent) {
  if (e.key === 'ArrowDown') {
    e.preventDefault()
    openAt(0)
  } else if (e.key === 'ArrowUp') {
    e.preventDefault()
    openAt(items().length - 1)
  } else if (e.key === 'Escape' && open.value) {
    e.preventDefault()
    close(true)
  }
}

function onMenuKey(e: KeyboardEvent) {
  const n = items().length
  const next = nextMenuIndex(focused.value, e.key, n)
  if (next === -1) {
    // Tab moves on naturally; Escape returns to the button
    if (e.key === 'Escape') { e.preventDefault(); close(true) } else close(false)
    return
  }
  if (next !== focused.value) {
    e.preventDefault()
    void focusItem(next)
  }
}

async function signOut() {
  close(false)
  await session.logout()
}

async function stopActing() {
  close(false)
  await session.stopActingAs()
}

function openActAs() {
  close(false)
  actAsOpen.value = true
}

function onDocPointer(e: PointerEvent) {
  if (open.value && root.value && !root.value.contains(e.target as Node)) close(false)
}

onMounted(() => {
  document.addEventListener('pointerdown', onDocPointer)
})
onBeforeUnmount(() => {
  document.removeEventListener('pointerdown', onDocPointer)
})
/* a rotation across the line: the popover styles of one layout must not
   stick to the other */
watch(narrow, () => {
  const panel = root.value?.querySelector<HTMLElement>('.user-menu__panel')
  if (panel) panel.removeAttribute('style')
  if (open.value) close(false)
})
watch(() => route.fullPath, () => { if (open.value) close(false) })
/* SPL-994: the phone's avatar sheet is the top level while open - Back closes it */
useMobileStack().overlay(open, () => close(false))
watch(signedIn, (v) => { if (!v) close(false) })
</script>

<style scoped>
.user-menu {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: flex-end;
  min-width: var(--tap, 44px);
  min-height: var(--tap, 44px);
}
/* specs/054: while acting as a member the avatar wears a thin warning ring, and
   a slim "Acting as X · Stop" pill sits directly under it (owner 18597eaa: one
   slim line under the avatar, not a full-width band). */
.user-menu__avatar--acting {
  box-shadow: 0 0 0 2px var(--color-danger);
}
.user-menu__acting {
  /* fixed like BuildUpdateBar: an absolute pill sits in the top bar's stacking
     context and the shell paints over it. Fixed + a high z floats it above the
     shell, just under the avatar (12px = the top bar's inline padding). */
  position: fixed;
  top: calc(var(--top-bar-h) + 2px);
  inset-inline-end: 12px;
  z-index: calc(var(--z-banner) + 10);
  display: inline-flex;
  align-items: center;
  gap: 5px;
  max-width: min(72vw, 260px);
  box-sizing: border-box;
  height: 20px;
  padding: 0 8px;
  border: 1px solid var(--color-danger);
  border-radius: var(--radius-pill);
  background: var(--color-surface);
  color: var(--color-fg);
  font-size: 0.75rem;
  font-weight: 600;
  line-height: 1;
  white-space: nowrap;
  box-shadow: var(--focus-3d);
}
.user-menu__acting-text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}
.user-menu__acting-sep {
  flex: none;
  color: var(--color-muted);
}
.user-menu__acting-stop {
  flex: none;
  border: none;
  background: none;
  padding: 0;
  margin: 0;
  min-height: 0;
  color: var(--color-danger);
  font: inherit;
  font-weight: 700;
  cursor: pointer;
  text-decoration: underline;
}
.user-menu__acting-stop:hover { text-decoration: none; }
.user-menu__trigger,
.user-menu__signin {
  appearance: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  min-width: var(--tap, 44px);
  min-height: var(--tap, 44px);
  padding: 0 4px;
  border: 0;
  border-radius: var(--radius-pill, 999px);
  background: transparent;
  color: var(--color-fg);
  cursor: pointer;
  text-decoration: none;
  font-size: 0.875rem;
}
.user-menu__trigger:hover .user-menu__avatar,
.user-menu__trigger[aria-expanded='true'] .user-menu__avatar,
.user-menu__signin:hover .user-menu__avatar {
  border-color: var(--color-accent);
}
.user-menu__trigger:focus-visible,
.user-menu__signin:focus-visible,
.user-menu__item:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: 2px;
}
.user-menu__avatar {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 36px;
  height: 36px;
  border-radius: 50%;
  border: 1.5px solid var(--color-border-strong);
  background: var(--color-surface);
  color: var(--color-muted);
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.02em;
  line-height: 1;
  overflow: hidden;
  flex-shrink: 0;
}
.user-menu__avatar--lg { width: 44px; height: 44px; font-size: 14px; }
.user-menu__avatar--member { padding: 0; }
.user-menu__avatar--member :deep(.spool-avatar) { border-radius: 50%; display: block; }
.user-menu__avatar--initials {
  background: color-mix(in srgb, var(--color-accent) 16%, var(--color-surface));
  color: var(--color-accent);
}
.user-menu__panel {
  position: absolute;
  top: calc(100% + 6px);
  inset-inline-end: 0;
  width: 272px;
  max-width: 272px;
  background: var(--color-bg-2);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-md, 12px);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  padding: 8px 0;
  z-index: var(--z-overlay, 1000);
}
.user-menu__who {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 14px 12px;
  border-bottom: 1px solid var(--color-border);
  min-width: 0;
}
.user-menu__names { display: flex; flex-direction: column; min-width: 0; }
.user-menu__primary, .user-menu__secondary { overflow-wrap: anywhere; min-width: 0; }
.user-menu__primary { font-size: 0.875rem; }
.user-menu__secondary { font-size: 0.75rem; color: var(--color-muted); }
.user-menu__items { list-style: none; margin: 6px 0 0; padding: 0; }
.user-menu__item {
  border-radius: var(--radius-sm);
  display: flex;
  align-items: center;
  justify-content: flex-start;
  gap: 10px;
  width: 100%;
  min-height: var(--tap, 44px);
  padding: 0 14px;
  border: 0;
  background: transparent;
  color: var(--color-fg);
  font-size: 0.875rem;
  text-align: start;
  text-decoration: none;
  cursor: pointer;
}
.user-menu__item:hover, .user-menu__item:focus { background: var(--color-surface-hover); }
@media (max-width: 640px) {
  .user-menu__signin-label { display: none; }
}
.user-menu__grip, .user-menu__prefs { display: none; }
/* SPL-990: the bottom sheet. !important beats a leftover inline popover
   style from a desktop open before a rotation (the watch clears it too). */
@media (max-width: 820px) {
  .user-menu__scrim {
    position: fixed;
    inset: 0;
    z-index: var(--z-overlay, 1000);
    background: rgb(0 0 0 / .45);
  }
  .user-menu__panel {
    position: fixed !important;
    inset-inline: 0 !important;
    top: auto !important;
    bottom: 0 !important;
    width: auto !important;
    max-width: none !important;
    max-height: 85dvh;
    overflow-y: auto;
    overscroll-behavior: contain;
    border-radius: var(--radius-md, 12px) var(--radius-md, 12px) 0 0;
    border-bottom: 0;
    padding: 6px 0 calc(8px + env(safe-area-inset-bottom, 0px));
    z-index: calc(var(--z-overlay, 1000) + 1);
  }
  .user-menu__grip {
    display: block;
    width: 36px;
    height: 4px;
    margin: 2px auto 6px;
    border-radius: var(--radius-pill, 999px);
    background: var(--color-border-strong);
  }
  .user-menu__prefs {
    display: flex;
    flex-direction: column;
    padding: 6px 0;
    border-bottom: 1px solid var(--color-border);
  }
  .user-menu__pref {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    min-height: var(--tap, 44px);
    padding: 2px 14px;
    min-width: 0;
  }
  .user-menu__pref-label {
    font-size: 0.875rem;
    color: var(--color-fg);
    min-width: 0;
    overflow-wrap: anywhere;
  }
  .user-menu__item { min-height: 48px; }
  /* async child: its root does not carry this scope id, hence :deep.
     Content-sized (SPL-1184): the control shrink-wraps to the longest locale
     name, capped at 14rem, shrinkable on a phone. No width:100% force — it
     defeated the control's max-content width and left a dead gap. */
  .user-menu__pref :deep(.lang-switcher) { flex: 0 1 auto; min-width: 0; max-width: 14rem; }
  .user-menu__pref-label { flex: 0 0 auto; }
}
</style>
