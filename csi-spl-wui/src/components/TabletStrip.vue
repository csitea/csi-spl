<!-- SPL-2145 (owner HUM-10, t1 1061f05f msg 4d63f24c, UI review suggestion 3):
     a tablet (600..820 px, MOBILE_TABLET_QUERY) on level 2 or 3 of the mobile
     stack keeps this narrow strip of the channels beside the page, so the
     next channel is one tap away instead of Back + tap. Each channel is its
     initials (the name on title / aria-label); the top button expands to the
     full list (level 1, useMobileStack.home). Phones under 600 px never mount
     it: their one-pane stack (SPL-989) is unchanged. layouts/default.vue
     decides when it shows.

     Lazy (LazyTabletStrip) and on demand: its own string waits in the second
     catalogue (utils/i18n-first-screen.mjs); until it is merged the expand
     button is named by the core "Channels". CSP: classes only, no :style. -->
<template>
  <nav class="tablet-strip" data-testid="tablet-strip" :aria-label="t('sidebar.channels')">
    <button
      type="button"
      class="tablet-strip__item tablet-strip__expand"
      data-testid="tablet-strip-expand"
      :aria-label="expandLabel"
      :title="expandLabel"
      @click="stack.home()"
    >
      <UiIcon name="menu" :size="20" />
    </button>
    <NuxtLink
      v-for="c in rows"
      :key="c.channel_id"
      class="tablet-strip__item"
      data-testid="tablet-strip-channel"
      :data-key="c.channel_id"
      :to="localePath('/channel/' + c.channel_id)"
      :title="'#' + c.name"
      :aria-label="'#' + c.name"
      :aria-current="channel.active === c.channel_id && !channel.peer ? 'page' : undefined"
    >{{ mobileChannelInitials(c.name) }}</NuxtLink>
  </nav>
</template>

<script setup lang="ts">
import { useMobileStack } from '~/composables/useMobileStack'
import { useChannelStore } from '~/stores/channel'
import { mobileChannelInitials } from '~/utils/mobile-stack.mjs'
import { feedbackChannelCopy } from '~/utils/feedback-channel.mjs'

const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const stack = useMobileStack()
const channel = useChannelStore()
/* the second catalogue names the button; until it is merged, the core "Channels" */
const expandLabel = computed(() => (te('mobile.tablet_expand') ? t('mobile.tablet_expand') : t('sidebar.channels')))
/* the sidebar's order (unread first is the sidebar's own); #feedback by its locale name */
const rows = computed(() => channel.ordered.map((c) => {
  const copy = feedbackChannelCopy(c.channel_id, { name: t('channels.feedback.name'), description: '' }, c.description)
  return { channel_id: c.channel_id, name: copy ? copy.name : c.name }
}))
</script>

<style scoped>
.tablet-strip {
  flex: 0 0 60px;
  width: 60px;
  min-height: 0;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  padding: 8px 0 calc(8px + var(--composer-dock-h, 0px));
  overflow-x: hidden;
  overflow-y: auto;
  background: var(--color-sidebar);
  border-inline-end: 1px solid var(--color-border);
}
.tablet-strip__item {
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: var(--tap, 44px);
  height: var(--tap, 44px);
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-muted);
  font-size: 0.8125rem;
  font-weight: 700;
  text-decoration: none;
  cursor: pointer;
}
.tablet-strip__item:hover { background: var(--color-surface-hover); color: var(--color-fg); }
.tablet-strip__item[aria-current="page"] { background: var(--color-surface-hover); color: var(--color-fg); }
.tablet-strip__expand { margin-bottom: 4px; }
</style>
