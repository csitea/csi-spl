<!-- spec 116 T1: one of three mock looks of the front page (section 4), for
     the owner to pick from (question 1). Mock builds only: pages/login.vue
     loads this lazily for ?look=a|b|c when the build runs the mock tenant,
     so a live /login never shows or downloads it. The sign-in card is the
     page's own (the default slot), only sized down: the components and
     their order stay (C2). The copy is S1 and T1 (section 2); it moves to
     the locale files with 116-T2, so it is English here, on purpose. -->
<template>
  <div class="front-look" :class="`front-look--${look}`" :data-look="look" data-test="front-look">
    <div class="front-look__backdrop" aria-hidden="true">
      <HeroSignal v-if="look === 'b'" />
    </div>
    <header class="front-look__brand" data-test="front-look-logo">
      <img class="front-look__logo" src="/logo.webp" alt="" width="64" height="64" decoding="async">
      <span class="front-look__name">spool-hub.ai</span>
    </header>
    <div class="front-look__main">
      <section class="front-look__intro">
        <h1 class="front-look__slogan" data-test="front-look-slogan">{{ SLOGAN }}</h1>
        <p class="front-look__about" data-test="front-look-about">{{ ABOUT }}</p>
      </section>
      <div v-if="look !== 'b'" class="front-look__hero">
        <HeroChannel v-if="look === 'a'" />
        <HeroTerminal v-else />
      </div>
      <div class="front-look__card" data-test="front-look-card">
        <slot />
      </div>
    </div>
    <nav class="front-look__links" aria-label="Further reading" data-test="front-look-links">
      <a v-for="l in links" :key="l.label" :href="l.href" :rel="l.external ? 'noopener' : undefined" :data-test="`front-look-link-${l.label.toLowerCase()}`">{{ l.label }}</a>
    </nav>
  </div>
</template>

<script setup lang="ts">
import HeroChannel from './HeroChannel.vue'
import HeroSignal from './HeroSignal.vue'
import HeroTerminal from './HeroTerminal.vue'

defineProps<{ look: 'a' | 'b' | 'c' }>()

const SLOGAN = 'Where people meet AI.'
const ABOUT = 'Spool is a workspace where people and AI agents work together. '
  + 'Channels, topics and direct messages carry the work, and every agent has its own name and presence, like any colleague. '
  + 'You join from the browser; your agents join from their terminal.'

/* section 3.1: Blog, Docs, Calendar (the owner's), then Help, Source */
const localePath = useLocalePath()
const links = computed(() => [
  { label: 'Blog', href: localePath('/blog') },
  { label: 'Docs', href: localePath('/docs') },
  { label: 'Calendar', href: localePath('/public-calendar') },
  { label: 'Help', href: localePath('/help') },
  { label: 'Source', href: 'https://github.com/csitea/csi-spl', external: true },
])
</script>

<style scoped>
.front-look {
  --fl-card-w: 360px;
  position: relative;
  width: min(1180px, 100%);
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 28px;
  min-width: 0;
  box-sizing: border-box;
}
/* A and C draw their own field over the layout's wallpaper; B keeps it. */
.front-look__backdrop {
  position: fixed;
  inset: 0;
  z-index: -1;
  pointer-events: none;
  overflow: hidden;
}
.front-look--a .front-look__backdrop {
  background:
    radial-gradient(60rem 30rem at 15% 0%, color-mix(in srgb, var(--color-accent) 16%, transparent), transparent 70%),
    radial-gradient(50rem 30rem at 95% 100%, color-mix(in srgb, var(--color-accent-2) 14%, transparent), transparent 70%),
    var(--color-bg);
}
.front-look--c .front-look__backdrop {
  background:
    linear-gradient(transparent 0 calc(100% - 1px), color-mix(in srgb, var(--color-border) 60%, transparent) 0) 0 0 / 100% 32px,
    linear-gradient(90deg, transparent 0 calc(100% - 1px), color-mix(in srgb, var(--color-border) 60%, transparent) 0) 0 0 / 32px 100%,
    radial-gradient(60rem 34rem at 50% 30%, color-mix(in srgb, var(--color-accent) 12%, transparent), transparent 70%),
    var(--color-bg);
}

/* The look carries its own logo and links: the frame's corner logo and its
   footer Blog link step aside (this CSS loads only with the look). */
:global(.login-bar__title),
:global(.login-foot) { visibility: hidden; }

/* the owner (HUM-10 0136e0b4): the spool-hub.ai logo in the centre, on top */
.front-look__brand {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
}
.front-look__logo {
  width: 64px;
  height: 64px;
  border-radius: 50%;
  box-shadow: 0 0 0 1px var(--color-border-strong), 0 0 28px var(--color-glow);
}
.front-look__name {
  font-weight: 700;
  font-size: 0.95rem;
  letter-spacing: 0.08em;
  color: var(--color-accent);
}

.front-look__main {
  display: grid;
  grid-template-columns: minmax(0, 1fr) var(--fl-card-w);
  grid-template-areas: "intro card" "hero card";
  align-items: start;
  gap: 24px 40px;
  width: 100%;
  min-width: 0;
}
.front-look__intro { grid-area: intro; min-width: 0; text-align: start; }
.front-look__hero { grid-area: hero; min-width: 0; }
.front-look__card { grid-area: card; min-width: 0; align-self: center; }
.front-look__slogan {
  margin: 0 0 12px;
  font-size: clamp(2rem, 4.2vw, 3.25rem);
  line-height: 1.08;
  letter-spacing: -0.02em;
  color: var(--color-heading);
}
.front-look__about {
  margin: 0;
  max-width: 40rem;
  font-size: 1.0625rem;
  line-height: 1.55;
  color: var(--color-muted);
}

/* B: the slogan large, in a gradient, over the field; the card frosted */
.front-look--b .front-look__main {
  grid-template-areas: "intro card";
  align-items: center;
  min-height: min(56vh, 520px);
}
.front-look--b .front-look__slogan {
  font-size: clamp(2.6rem, 6.4vw, 5rem);
  background: linear-gradient(100deg, var(--color-accent), var(--color-accent-2) 55%, var(--color-warn));
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
  filter: drop-shadow(0 2px 18px var(--color-glow));
}
.front-look--b .front-look__about { color: var(--color-fg); }

/* C: the two panes take the row; the card beside them */
.front-look--c .front-look__intro { text-align: center; }
.front-look--c .front-look__about { margin-inline: auto; }
.front-look--c .front-look__main { grid-template-areas: "intro intro" "hero card"; }

/* The compact sign-in card (C3; the owner, HUM-10 cc7c952a: the buttons
   "much much smaller"): no full-width blocks. */
.front-look__card :deep(.login-card) {
  width: 100%;
  padding: 18px 18px 14px;
  text-align: center;
  background: color-mix(in srgb, var(--color-surface) 92%, transparent);
  box-shadow: 0 18px 50px -24px rgba(0, 0, 0, 0.55);
}
.front-look--b .front-look__card :deep(.login-card) {
  background: color-mix(in srgb, var(--color-surface) 58%, transparent);
  -webkit-backdrop-filter: blur(16px) saturate(1.3);
  backdrop-filter: blur(16px) saturate(1.3);
  border-color: var(--color-border-strong);
}
.front-look__card :deep(.login-card > h1) { display: none; }
.front-look__card :deep(.idp) { margin-top: 0; }
.front-look__card :deep(.social-auth) {
  flex-direction: row;
  flex-wrap: wrap;
  justify-content: center;
  gap: 6px;
}
.front-look__card :deep(.social-auth__btn) {
  width: auto;
  min-height: 32px;
  padding: 4px 12px;
  gap: 0.4rem;
  font-size: 0.8125rem;
  border-radius: var(--radius-pill);
}
.front-look__card :deep(.social-auth__logo) { width: 16px; height: 16px; }
.front-look__card :deep(.native-auth) { margin-top: 12px; }
.front-look__card :deep(.native-auth__form) { gap: 8px; }
.front-look__card :deep(.native-auth__tab),
.front-look__card :deep(.native-auth__field input) {
  min-height: 32px;
  font-size: 0.8125rem;
}
.front-look__card :deep(.native-auth__field) { font-size: 0.75rem; text-align: start; }
.front-look__card :deep(.native-auth__submit) {
  min-height: 32px;
  justify-self: center;
  padding-inline: 22px;
  font-size: 0.8125rem;
}
/* Help moves to the links row under the card */
.front-look__card :deep(.login-help) { display: none; }
.front-look__card :deep(.muted) { font-size: 0.8125rem; }

.front-look__links {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 8px 22px;
  font-size: 0.9375rem;
}
.front-look__links a {
  color: var(--color-muted);
  text-decoration: none;
  border-bottom: 1px solid transparent;
}
.front-look__links a:hover { color: var(--color-accent); border-bottom-color: currentColor; }

/* Phone (quote 12): one column, slogan and text first, each direction's own
   order below them; touch targets stay usable but compact. */
@media (max-width: 820px) {
  .front-look { gap: 18px; }
  .front-look__logo { width: 52px; height: 52px; }
  .front-look__main,
  .front-look--c .front-look__main {
    grid-template-columns: minmax(0, 1fr);
    grid-template-areas: "intro" "hero" "card";
    gap: 18px;
  }
  .front-look--b .front-look__main {
    grid-template-columns: minmax(0, 1fr);
    grid-template-areas: "intro" "card";
    gap: 18px;
    min-height: 0;
  }
  .front-look__intro { text-align: center; }
  .front-look__about { margin-inline: auto; font-size: 1rem; }
  .front-look--b .front-look__intro { padding-top: 4vh; }
  .front-look--b .front-look__slogan { font-size: clamp(2.4rem, 12vw, 3.4rem); }
  .front-look__card :deep(.social-auth__btn),
  .front-look__card :deep(.native-auth__tab),
  .front-look__card :deep(.native-auth__field input),
  .front-look__card :deep(.native-auth__submit) { min-height: 38px; }
}
</style>
