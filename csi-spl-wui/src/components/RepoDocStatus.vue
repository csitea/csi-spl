<!-- spec 075 repo-edit §3 (T12): the doc header's status chip for an
     editable repo doc. It reads GET /v1/docs/edits?path=<doc> (the
     repoEdit store) and shows the newest edit of the doc: the one this page
     just saved, else the path's newest row (another member's conflict is
     theirs alone). While the push is owed it asks again every few seconds.
     Retry requeues a failed edit here; resolve asks the page to open the
     conflict view. A lazy chunk of the docs page. -->
<template>
  <span v-if="edit" class="repo-status" data-test="repo-edit-status">
    <RepoDocStatusChip :edit="edit" :busy="store.busy" @retry="retry" @resolve="(id) => emit('resolve', id)" />
    <span v-if="message" class="repo-status__error" role="alert" data-test="repo-edit-chip-error">{{ message }}</span>
  </span>
</template>

<script setup lang="ts">
import RepoDocStatusChip from '~/components/RepoDocStatusChip.vue'
import { useRepoEditStore } from '~/stores/repoEdit'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { headerEdit, isPending } from '~/utils/repo-edit.mjs'

const props = withDefaults(defineProps<{ path: string, me?: string }>(), { me: '' })
const emit = defineEmits<{ resolve: [id: string] }>()
const { t } = useI18n({ useScope: 'global' })
const store = useRepoEditStore()
/* the hub's worker takes 2 min to push (coalescing); the mock steps at once */
const POLL_MS = useSpoolApi().mock ? 700 : 15000

const edit = computed(() => headerEdit(store.byPath[props.path], props.path, props.me, store.edits[props.path]))
const message = computed(() => (store.error && !store.notice ? t(store.error.key, store.error.params) : ''))

let timer: ReturnType<typeof setTimeout> | undefined
let alive = true
async function poll() {
  clearTimeout(timer)
  const path = props.path
  await store.loadPath(path)
  if (alive && path === props.path && isPending(edit.value)) timer = setTimeout(() => void poll(), POLL_MS)
}
async function retry(id: string) {
  await store.retry(id)
  void poll()
}
watch(() => props.path, () => { store.error = null; void poll() })
/* a save on this page starts the polling again */
watch(() => store.edits[props.path]?.edit_id, (id) => { if (id) void poll() })
onMounted(() => void poll())
onBeforeUnmount(() => { alive = false; clearTimeout(timer) })
</script>

<style scoped>
.repo-status { display: inline-flex; align-items: center; flex-wrap: wrap; gap: 8px; min-width: 0; }
.repo-status__error { color: var(--color-danger); font-size: 0.8125rem; overflow-wrap: anywhere; }
</style>
