<!-- Top-right user control (CLE-3402), after the reference storefront's header
     account control: signed in → the person's avatar (member HUM-*: the stored
     IdP picture, else the deterministic identicon — SpoolAvatar; no member id:
     initials, else a silhouette). CLE-3406: first the person's OWN IdP picture
     (auth-v1 GET /api/v1/auth/avatar, session only, no membership needed, as
     a data: URL); a 404 or any failure falls back to the above. Clicking it
     opens a dropdown: who they are, Settings, Sign out. Signed out → the sign-in entry.
     WAI-ARIA menu button: Enter/Space (click) and ArrowDown open on the first item,
     ArrowUp on the last; arrows wrap, Home/End jump, Escape closes and returns
     focus to the button, Tab or a click outside closes. -->
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
        <span class="user-menu__avatar" :class="'user-menu__avatar--' + (ownPic ? 'member' : mode)" aria-hidden="true">
          <img v-if="ownPic" class="spool-avatar" data-test="user-menu-picture" :src="ownPic" :width="32" :height="32" :style="{ width: '32px', height: '32px' }" alt="" draggable="false" @error="ownPic = ''">
          <SpoolAvatar v-else-if="mode === 'member'" :id="me.hum" :size="32" />
          <template v-else-if="mode === 'initials'">{{ initials }}</template>
          <UiIcon v-else name="user" :size="20" />
        </span>
      </button>
      <div
        v-show="open"
        :id="menuId"
        class="user-menu__panel"
        data-test="user-menu-panel"
      >
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
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { avatarMode, menuButtonLabelKey, nextMenuIndex, ownAvatarUrl, signInRedirect, userIdentity, userInitials } from '~/utils/user-menu.mjs'
import { loadAvatarImageUrl } from '~/utils/avatar.mjs'
import { useAuthBase } from '~/composables/useAuthClient'

const session = useSessionStore()
const access = useAccessStore()
const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const menuId = 'user-menu-panel'

const signedIn = computed(() => session.state === 'in' && !!session.claims)
// specs/025 FR-008: the member's role in the active tenant, under the name.
watch(signedIn, (v) => { if (v) access.load() }, { immediate: true })
const me = computed(() => userIdentity(session.claims))
const mode = computed(() => avatarMode(session.claims))
const initials = computed(() => userInitials(session.claims))

// CLE-3406: the signed-in person's own IdP picture, '' until loaded / none.
const authBase = useAuthBase()
const ownPic = ref('')
const ownPicUrl = computed(() => (signedIn.value ? ownAvatarUrl(authBase, session.claims) : ''))
watch(ownPicUrl, async (url) => {
  ownPic.value = ''
  const got = await loadAvatarImageUrl(url, { credentials: 'include' })
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

function items(): HTMLElement[] {
  return [item0.value?.$el, item1.value].filter((el): el is HTMLElement => !!el)
}

async function focusItem(i: number) {
  focused.value = i
  await nextTick()
  items()[i]?.focus()
}

function openAt(i: number) {
  open.value = true
  void focusItem(i)
}

function close(refocus: boolean) {
  open.value = false
  focused.value = -1
  if (refocus) trigger.value?.focus()
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

function onDocPointer(e: PointerEvent) {
  if (open.value && root.value && !root.value.contains(e.target as Node)) close(false)
}

onMounted(() => document.addEventListener('pointerdown', onDocPointer))
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocPointer))
watch(() => route.fullPath, () => { if (open.value) close(false) })
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
  font-size: 14px;
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
  right: 0;
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
.user-menu__primary { font-size: 14px; }
.user-menu__secondary { font-size: 12px; color: var(--color-muted); }
.user-menu__items { list-style: none; margin: 6px 0 0; padding: 0; }
.user-menu__item {
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
  font-size: 14px;
  text-align: left;
  text-decoration: none;
  cursor: pointer;
}
.user-menu__item:hover, .user-menu__item:focus { background: var(--color-surface-hover); }
@media (max-width: 640px) {
  .user-menu__signin-label { display: none; }
}
</style>
