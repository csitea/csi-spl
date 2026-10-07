<!-- spec 075 repo-edit §3 (T12): the status chip of one repo doc edit.
     queued / pushing "Saved · pushing", pushed "Pushed · <sha7>" (a link to
     the commit when cnf repo_web_url + repo_commit_path are set, as HUM-10's
     commit links), conflict "Conflict ·
     resolve", failed "Not pushed · retry" with the reason; published and
     superseded show nothing. Content only: the doc header (RepoDocStatus)
     and My edits (RepoDocMyEdits) own the calls behind retry and resolve. -->
<template>
  <span v-if="chip" class="repo-chip" :class="'repo-chip--' + chip.status" data-test="repo-edit-chip" :data-status="chip.status" :data-edit="edit?.edit_id" :title="reason || undefined">
    <template v-if="chip.status === 'pushed'">
      <span>{{ t(chip.key) }} ·&#32;</span>
      <a v-if="url" :href="url" target="_blank" rel="noopener noreferrer nofollow" class="repo-chip__sha" data-test="repo-edit-chip-commit">{{ chip.sha7 }}</a>
      <code v-else class="repo-chip__sha" data-test="repo-edit-chip-commit">{{ chip.sha7 }}</code>
      <span v-if="chip.merged7" class="repo-chip__merged">&#32;({{ t('docs.repoEdit.chip.merged', { sha: chip.merged7 }) }})</span>
    </template>
    <span v-else>{{ t(chip.key) }}<template v-if="chip.action"> ·&#32;</template></span>
    <button v-if="chip.action === 'retry'" type="button" class="repo-chip__act" data-test="repo-edit-chip-retry" :disabled="busy" @click="emit('retry', edit!.edit_id)">{{ t('docs.repoEdit.chip.retry') }}</button>
    <button v-else-if="chip.action === 'resolve'" type="button" class="repo-chip__act" data-test="repo-edit-chip-resolve" :disabled="busy" @click="emit('resolve', edit!.edit_id)">{{ t('docs.repoEdit.chip.resolve') }}</button>
  </span>
</template>

<script setup lang="ts">
import { chipOf } from '~/utils/repo-edit.mjs'
import { commitHref, commitPrefix } from '~/utils/commit-links.mjs'

type ChipEdit = { edit_id: string, status: string, commit_sha?: string, merged_with?: string, last_error?: string }
const props = withDefaults(defineProps<{ edit: ChipEdit | null, busy?: boolean }>(), { busy: false })
const emit = defineEmits<{ retry: [id: string], resolve: [id: string] }>()
const { t } = useI18n({ useScope: 'global' })

const chip = computed(() => chipOf(props.edit))
const pub = useRuntimeConfig().public
const prefix = commitPrefix(String(pub.repoWebUrl || ''), String(pub.repoCommitPath || ''))
const url = computed(() => commitHref(prefix, props.edit?.commit_sha))
const reason = computed(() => (props.edit?.status === 'failed' || props.edit?.status === 'conflict' ? props.edit.last_error ?? '' : ''))
</script>

<style scoped>
.repo-chip {
  display: inline-flex;
  align-items: center;
  flex-wrap: wrap;
  white-space: pre-wrap;
  padding: 2px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  font-size: 0.8125rem;
  line-height: 1.5;
  color: var(--color-muted);
  max-width: 100%;
  overflow-wrap: anywhere;
}
.repo-chip--pushed { color: var(--color-fg); }
.repo-chip--conflict, .repo-chip--failed { color: var(--color-danger); border-color: currentColor; }
.repo-chip__sha { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
a.repo-chip__sha { color: var(--color-accent); text-decoration: underline; }
.repo-chip__act {
  border: 0;
  padding: 0;
  background: none;
  color: var(--color-accent);
  font: inherit;
  text-decoration: underline;
  cursor: pointer;
}
.repo-chip__act:disabled { opacity: 0.6; cursor: default; }
@media (max-width: 820px) {
  .repo-chip__act { min-height: 44px; padding: 0 4px; }
}
</style>
