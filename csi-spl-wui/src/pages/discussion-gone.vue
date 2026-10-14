<!-- /discussion-gone?topic=<uuid>&issue=<key>: where an issue's link to a
     deleted discussion lands (SPL-1593). Owner HUM-10 (t1 fcf09921, msg
     28b479fd): when a linked discussion was deleted, "some kind of default
     page explaining that, okay, no can do". An archived discussion is not
     gone: its link opens the topic. -->
<template>
  <div class="discussion-gone" data-test="discussion-gone">
    <h1>{{ t('discussion_gone.title') }}</h1>
    <p>{{ t('discussion_gone.body') }}</p>
    <p v-if="topic" class="muted" data-test="discussion-gone-topic">{{ t('discussion_gone.topic', { id: topic }) }}</p>
    <p>
      <NuxtLink
        v-if="issue"
        data-test="discussion-gone-back"
        :to="localePath({ path: '/issues', query: { issue } })"
      >{{ t('discussion_gone.back', { key: issue }) }}</NuxtLink>
      <NuxtLink v-else data-test="discussion-gone-back" :to="localePath('/issues')">{{ t('discussion_gone.back_issues') }}</NuxtLink>
    </p>
  </div>
</template>

<script setup lang="ts">
import { useSettledQuery } from '~/composables/useSettledQuery'

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const topicQ = useSettledQuery('topic')
const issueQ = useSettledQuery('issue')
/* only a topic id and an issue key are shown back, never other text */
const topic = computed(() => (/^[0-9a-f-]{8,36}$/.test(String(topicQ.value.value || '')) ? String(topicQ.value.value) : ''))
const issue = computed(() => (/^[A-Z][A-Z0-9]{0,9}-\d+$/.test(String(issueQ.value.value || '')) ? String(issueQ.value.value) : ''))
</script>

<style scoped>
.discussion-gone {
  max-width: 40rem;
  margin: 0 auto;
  padding: 24px 16px;
}
</style>
