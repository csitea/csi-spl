<!-- specs/077 T020: the demo intro on the sign-in page (owner HUM-10,
     2026-10-05): what the demo is, what a visitor can and cannot do there,
     and the "Try the demo" sign-ins, which start with tenant=<demo id> (the
     T007 open admission). login.vue mounts it lazily and only after
     GET /v1/demo answered 200, so with the flag off the page is unchanged
     and the first download never carries it. Every limit shown comes from
     that answer; the hub enforces each deny (the WUI only explains). -->
<template>
  <section class="demo-intro" data-test="demo-intro" aria-labelledby="demo-intro-title">
    <h2 id="demo-intro-title" class="demo-intro__title">{{ t('demo.intro.title') }}</h2>
    <p>{{ t('demo.intro.what') }}</p>
    <p>{{ t('demo.intro.can') }}</p>
    <p>{{ t('demo.intro.cannot') }}</p>
    <p v-if="maxLive > 0" data-test="demo-intro-limit">{{ t('demo.intro.limit', { n: maxLive }) }}</p>
    <div class="demo-intro__try">
      <a
        v-for="p in providers"
        :key="p"
        class="btn demo-intro__btn"
        :data-test="`demo-try-${p}`"
        :href="startHref(p, back, workspace, authBase)"
        rel="nofollow"
        @click="leavingToSignIn"
      >{{ t('demo.intro.try_with', { provider: providerName(p) }) }}</a>
    </div>
  </section>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { providerName, startHref } from '~/utils/auth-client.mjs'
import { demoProviders } from '~/utils/demo-info.mjs'
import { writeSignedOutHint } from '~/utils/signed-out-hint.mjs'
import { useAuthBase, useAuthClient } from '~/composables/useAuthClient'

const props = withDefaults(defineProps<{
  /** The demo workspace id from GET /v1/demo. */
  workspace: string
  /** Live visitors at a time from GET /v1/demo; 0 = not stated. */
  maxLive?: number
  /** Post-login destination. */
  redirect?: string
}>(), { maxLive: 0, redirect: '/' })

const { t } = useI18n({ useScope: 'global' })
const authBase = useAuthBase()
const siteUrl = String(useRuntimeConfig().public.siteUrl || '')
const providers = ref<string[]>([])
/* SPL-959: with tenant hosts on, the OAuth return lands on the apex; a
   ?tenant=<demo id> there hops the new visitor to the demo's own host. */
const back = computed(() => {
  if (String(useRuntimeConfig().public.tenantHosts || '0') !== '1') return props.redirect
  const [path, hash = ''] = props.redirect.split('#', 2)
  return path + (path.includes('?') ? '&' : '?') + 'tenant=' + props.workspace + (hash ? '#' + hash : '')
})

/* the same registry the sign-in buttons read (an in-flight read is shared) */
onMounted(async () => {
  const out = await useAuthClient().loadProviders()
  providers.value = demoProviders(out.providers)
})

/* P3-02, as SocialAuthButtons: leaving for the IdP drops the signed-out hint */
function leavingToSignIn() {
  writeSignedOutHint(document, false, { hostname: location.hostname, protocol: location.protocol, siteUrl })
}
</script>

<style scoped>
.demo-intro {
  margin: 0 auto 18px;
  max-width: 34rem;
  padding: 14px 16px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-surface-hover);
  text-align: start;
  min-width: 0;
  box-sizing: border-box;
}
.demo-intro__title {
  margin: 0 0 6px;
  font-size: 1.05rem;
  color: var(--color-fg);
}
.demo-intro p {
  margin: 4px 0;
  font-size: 0.875rem;
}
.demo-intro__try {
  display: flex;
  flex-wrap: wrap;
  gap: var(--spacing-sm);
  margin-top: 10px;
}
.demo-intro__btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: var(--tap);
  padding: 6px 14px;
  flex: 1 1 auto;
  min-width: 0;
  font-weight: 600;
  text-decoration: none;
  overflow-wrap: anywhere;
  text-align: center;
}
</style>
