<template>
  <div class="login-card">
    <h1>Spool</h1>
    <p v-if="error" class="login-error" role="alert">{{ error }}</p>
    <div v-if="providers.length" class="idp">
      <a
        v-for="p in providers"
        :key="p"
        class="btn idp-btn"
        :href="startHref(p, redirect, tenant)"
      >{{ providerLabel(p) }}</a>
    </div>
    <p v-else-if="loaded" class="muted">Sign-in is not available yet.</p>
    <p v-if="session.state === 'unknown'" class="muted">Session unavailable — the hub did not answer.</p>
    <p v-if="session.state === 'in'" class="muted">
      Signed in as {{ session.label }} ·
      <button class="btn ghost" type="button" @click="session.logout()">Sign out</button>
    </p>
    <p><NuxtLink :to="redirect">Continue to threads</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
import { authErrorMessage, createAuthClient, providerLabel, safeRedirect, startHref } from '~/utils/auth-client.mjs'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'

definePageMeta({ layout: 'login' })

const route = useRoute()
const router = useRouter()
const session = useSessionStore()
const providers = ref<string[]>([])
const loaded = ref(false)
const error = ref('')
const redirect = computed(() => safeRedirect(String(route.query.redirect || '/')))
/* auth-v1 §1: tenant is optional on start; send the one the viewer reads from */
const tenant = computed(() => String(route.query.tenant || useSpoolApi().tenant || ''))

onMounted(async () => {
  error.value = authErrorMessage(String(route.query.auth_error || ''))
  if (route.query.auth_error) {
    // auth-v1 §2: drop auth_error so a reload does not repeat it; keep redirect
    const { auth_error: _drop, ...rest } = route.query
    void router.replace({ query: rest })
  }
  const [list] = await Promise.all([createAuthClient().providers(), session.probe()])
  providers.value = list
  loaded.value = true
})
</script>
