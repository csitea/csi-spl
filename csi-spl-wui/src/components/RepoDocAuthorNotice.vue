<!-- spec 075 repo-edit §4.2 (T11): the one-time author notice. The repo is
     public, so before a member's first save under an identity the hub
     answers 428 and this dialog shows EXACTLY the name and email git will
     publish; nothing is written until "I understand, save". Cancel (and Esc,
     the backdrop) drops the save. Content only: the caller owns the identity
     and the consent call (the repoEdit store), so T12's "My edits" can show
     the same notice for an agent's requester. -->
<template>
  <UiDialog :open="Boolean(identity)" :title="t('docs.repoEdit.authorNotice.title')" size="sm" @update:open="(v) => { if (!v && !busy) emit('cancel') }">
    <div v-if="identity" class="repo-notice" data-test="repo-edit-notice">
      <p>{{ t('docs.repoEdit.authorNotice.lead') }}</p>
      <p class="repo-notice__who" data-test="repo-edit-notice-identity" dir="ltr">{{ identity.git_name }} &lt;{{ identity.git_email }}&gt;</p>
      <p>{{ t('docs.repoEdit.authorNotice.public') }}</p>
      <p>{{ t('docs.repoEdit.authorNotice.other') }}</p>
    </div>
    <p v-if="error" class="repo-notice__error" role="alert" data-test="repo-edit-notice-error">{{ error }}</p>
    <template #footer>
      <div class="repo-notice__actions">
        <button type="button" class="btn ghost" data-autofocus data-test="repo-edit-notice-cancel" :disabled="busy" @click="emit('cancel')">{{ t('common.cancel') }}</button>
        <button type="button" class="btn" data-test="repo-edit-notice-confirm" :disabled="busy" @click="emit('confirm')">{{ busy ? t('docs.ws.saving') : t('docs.repoEdit.authorNotice.confirm') }}</button>
      </div>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
import type { RepoEditIdentity } from '~/utils/repo-edit.mjs'

withDefaults(defineProps<{ identity: RepoEditIdentity | null, busy?: boolean, error?: string }>(), { busy: false, error: '' })
const emit = defineEmits<{ cancel: [], confirm: [] }>()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.repo-notice { padding: 8px 24px; line-height: 1.5; overflow-wrap: anywhere; }
.repo-notice p { margin: 0 0 12px; }
.repo-notice p:last-child { margin-bottom: 0; }
.repo-notice__who { font-weight: 700; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.repo-notice__error { margin: 8px 24px 0; color: var(--color-danger); overflow-wrap: anywhere; }
.repo-notice__actions { display: flex; justify-content: flex-end; gap: 12px; flex-wrap: wrap; }
.repo-notice__actions .btn { min-width: 104px; }
.repo-notice__actions .btn:disabled { opacity: 0.6; cursor: default; }
@media (max-width: 600px) {
  .repo-notice { padding: 24px 16px 8px; }
  .repo-notice__error { margin: 8px 16px 0; }
  .repo-notice__actions { flex-direction: column-reverse; gap: 8px; }
  .repo-notice__actions .btn { width: 100%; min-height: 44px; }
}
</style>
