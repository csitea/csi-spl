<!-- Spec 025 section 13 (SPL-5706): the People panel's inactive members, the
     people holding an open invite to this workspace who have not signed in
     yet. Owner HUM-10, t1 028ac340: "Once invited, the members of a workspace
     must become actual members of the workspace but just be inactive." They
     follow the members, marked inactive, with no person page (no HUM-* yet).
     A lazy chunk with invited-members-client.mjs, so the initial download
     never carries it. No list (an act-as session, an older hub) shows none. -->
<template>
  <div v-if="rows.length" class="people-invited" data-test="people-invited-rows">
    <div v-for="r in rows" :key="r.id" class="nav-row">
      <span class="nav-item people-invited__row" :data-key="r.id" data-test="people-invited-row" :title="t('people.inactive_hint')">
        <SpoolAvatar :id="r.id" box="box-wui" :size="22" />
        <span class="label people-invited__label">{{ r.label }}</span>
        <span class="muted people-row__tag" data-test="people-inactive-tag">{{ t('people.inactive') }}</span>
      </span>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { invitedMembers } from '~/utils/invited-members-client.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const rows = ref<Array<{ id: string, label: string }>>([])

onMounted(async () => {
  try {
    rows.value = await withSessionRetry(api, () => invitedMembers(api))
  } catch {
    rows.value = []
  }
})
</script>

<style scoped>
.people-invited__row { cursor: default; }
.people-invited__label { opacity: 0.7; }
/* the sidebar's tag, which its scoped style does not reach here */
.people-row__tag { margin-inline-start: auto; font-size: 0.6875rem; flex-shrink: 0; }
</style>
