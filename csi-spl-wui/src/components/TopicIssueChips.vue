<!-- Spec 153 row B5b (A3, section 3.5): the topic page shows the issues
     linked to this topic as chips, each to /issues?issue=<KEY>. Read from
     B5a's GET /v1/view/issues?discussion=<task_id>. None linked: no chip and
     no row. The status code stays untranslated, as in the issues list; its
     hover text is issues.status_hint.<id>. Mounted lazily by the topic page,
     so the page's initial chunk does not grow. -->
<template>
  <nav
    v-if="topic.open && chips.length"
    class="topic-issue-chips"
    data-test="topic-issue-chips"
    :aria-label="t('topic.issue_chips_label')"
  >
    <NuxtLink
      v-for="c in chips"
      :key="c.key"
      class="topic-issue-chip"
      data-test="topic-issue-chip"
      :data-key="c.key"
      :to="c.href"
      :aria-label="t('topic.issue_chip_aria', { key: c.key, status: c.status })"
      :title="t(statusHintKey(c.status))"
    ><span class="topic-issue-chip__key">{{ c.key }}</span> <span class="topic-issue-chip__status">{{ c.status }}</span></NuxtLink>
  </nav>
</template>

<script setup lang="ts">
import { useTopicStore } from '~/stores/topic'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { issueHref } from '~/utils/issue-key-links.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { createMockIssues } from '~/utils/issues.mjs'

const props = defineProps<{ taskId: string }>()

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const api = useSpoolApi()
const topic = useTopicStore()
/* the mock hub's issues are bound by whoever reads them first (as pages/issues.vue):
   a deep link to /t/<id> reads them here before the issues page ever loads */
if (api.mock) api.bindIssuesMock((me: string) => createMockIssues({ me }))

type Chip = { key: string, status: string, href: string }
const chips = ref<Chip[]>([])
const statusHintKey = (s: string) => `issues.status_hint.${s}`

let seq = 0
async function load(id: string) {
  const mine = ++seq
  chips.value = []
  if (!id) return
  try {
    const data = await withSessionRetry(api, () => api.listIssues({ filter: { discussion: id } }))
    if (mine !== seq) return
    const prefix = data?.prefix || ''
    chips.value = (data?.issues || [])
      .map((i) => ({ key: String(i.key || ''), status: String(i.status || ''), href: issueHref(prefix, i.key, (p) => localePath(p)) }))
      .filter((c) => c.href)
  } catch {
    /* a refused or failed read shows no chip: the thread is still the page */
  }
}

watch(() => props.taskId, (id) => { void load(id) }, { immediate: true })
</script>

<style scoped>
.topic-issue-chips {
  /* the page's thread column is a flex column: sit above the thread */
  order: -1;
  flex: none;
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  padding: 6px 12px;
  border-bottom: 1px solid var(--color-border);
}
.topic-issue-chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  font-size: 0.8rem;
  white-space: nowrap;
}
.topic-issue-chip__status {
  color: var(--color-muted);
}
</style>
