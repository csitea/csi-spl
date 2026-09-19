<template>
  <img
    class="spool-avatar"
    :src="src"
    :width="size"
    :height="size"
    :style="{ width: `${size}px`, height: `${size}px` }"
    :alt="alt"
    draggable="false"
    @error="failed = true"
  >
</template>

<script setup lang="ts">
import { avatarAlt, avatarDataUri, avatarImageUrl, isHuman, loadAvatarFiles } from '~/utils/avatar.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'

/*
 * SPEC-spool-avatars §2: robot for agents, identicon for HUM-*; deterministic,
 * generated (no image files). Gap A5: a member HUM-* with a stored IdP picture
 * (view-v1 §4.1 avatar_file_id) shows it, loaded from GET /v1/files/{id}; a
 * missing id, a 404 or any load error falls back to the default. The box is
 * fixed at size×size before and after the swap, so nothing shifts.
 */
const props = withDefaults(defineProps<{ id: string, box?: string, size?: number }>(), { box: '', size: 36 })

const api = useSpoolApi()
const files = useState<Record<string, string>>('spool.avatar-files', () => ({}))
const failed = ref(false)

const fallback = computed(() => avatarDataUri(props.id, props.box))
const picture = computed(() => (api.mock ? '' : avatarImageUrl(api.base, props.id, props.box, files.value)))
const src = computed(() => (picture.value && !failed.value ? picture.value : fallback.value))
const alt = computed(() => avatarAlt(props.id, props.box))

watch(picture, () => {
  failed.value = false
})

onMounted(async () => {
  if (api.mock || !isHuman(props.id)) return
  const got = await loadAvatarFiles({ base: api.base, token: api.token, credentials: api.credentials })
  if (JSON.stringify(got) !== JSON.stringify(files.value)) files.value = got
})
</script>

<style scoped>
.spool-avatar { object-fit: cover; }
</style>
