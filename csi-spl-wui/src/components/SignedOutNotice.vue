<!-- CLE-3433 — the signed-out state of a member-only view.

     layouts/default.vue mounts the whole shell for everyone, so a visitor
     who is not signed in used to land on an EMPTY feed next to a composer
     whose every send can only 401: an app that looks alive and does
     nothing. That is what the owner read as "completely broken" on
     2026-09-21. /settings already did this right — it says "{link} to see
     your settings." — so this is that same block, lifted out so the feed
     routes can share it instead of each inventing one.

     It is a NOTICE, not a redirect: /, /lobby and /t/<id> also serve
     anonymous readers who hold a view-door token (ViewTokenForm), and a
     blanket bounce to /login would break that flow. -->
<template>
  <p class="muted signed-out-notice" data-test="signed-out-notice">
    <i18n-t :keypath="props.keypath" scope="global">
      <template #link>
        <NuxtLink :to="{ path: localePath('/login'), query: { redirect: route.fullPath } }">{{ t('nav.login') }}</NuxtLink>
      </template>
    </i18n-t>
  </p>
</template>

<script setup lang="ts">
const props = withDefaults(defineProps<{ keypath?: string }>(), { keypath: 'auth.signed_out_view' })
const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
</script>
