<template>
  <img
    class="spool-avatar"
    :src="src"
    :width="size"
    :height="size"
    :style="{ width: `${size}px`, height: `${size}px` }"
    :alt="alt"
    draggable="false"
    @error="shown = ''"
  >
</template>

<script setup lang="ts">
import { avatarAltKey, avatarDataUri, avatarImageUrl, isHuman, loadAvatarImageUrl, loadAvatarFiles } from '~/utils/avatar.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { useHumanNames } from '~/composables/useHumanNames'

/*
 * SPEC-spool-avatars §2: robot for agents, identicon for HUM-*; deterministic,
 * generated (no image files). Gap A5: a member HUM-* with a stored IdP picture
 * (view-v1 §4.1 avatar_file_id) shows it: GET /v1/files/{id} fetched and shown
 * as a data: URL (the deployed CSP's img-src is 'self' data:, no hub origin
 * and no blob:); a missing id, a 404,
 * non-image bytes or any load error keep the default. The box is fixed at
 * size×size before and after the swap, so nothing shifts.
 */
const props = withDefaults(defineProps<{ id: string, box?: string, size?: number }>(), { box: '', size: 36 })

const api = useSpoolApi()
const files = useState<Record<string, string>>('spool.avatar-files', () => ({}))
const shown = ref('')

const fallback = computed(() => avatarDataUri(props.id, props.box))
const picture = computed(() => (api.mock ? '' : avatarImageUrl(api.base, props.id, props.box, files.value)))
const src = computed(() => shown.value || fallback.value)
const { t } = useI18n({ useScope: 'global' })
const people = useHumanNames()
const alt = computed(() => {
  const a = avatarAltKey(props.id, props.box)
  if (isHuman(props.id)) {
    const name = people.label(props.id)
    if (name && name !== props.id) return t(a.key, { ...a.params, who: name })
  }
  return t(a.key, a.params)
})

watch(picture, async (url) => {
  shown.value = ''
  const got = await loadAvatarImageUrl(url, { credentials: api.credentials })
  if (url === picture.value) shown.value = got
}, { immediate: true })

/* The roster needs a member session: read it once the probe says 'in', never
   before (a signed-out read is a 401, and it used to go out on every page,
   /login included). It joins the roster store's read in flight. */
const session = useSessionStore()
let asked = false
onMounted(() => {
  if (api.mock || !isHuman(props.id)) return
  watch(() => session.state, async (st) => {
    if (st !== 'in' || asked) return
    asked = true
    const got = await loadAvatarFiles({ base: api.base, token: api.token, credentials: api.credentials, read: () => api.rosterView() })
    if (JSON.stringify(got) !== JSON.stringify(files.value)) files.value = got
  }, { immediate: true })
})
</script>

<style scoped>
.spool-avatar { object-fit: cover; }
</style>
