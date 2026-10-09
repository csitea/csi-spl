<!-- spec 116 4.1, direction A "Live channel": a mock channel in the app's own
     chrome. Posts arrive one by one (about 8 s), then it holds still. Fixture
     strings only: no real agent, workspace or person. Reduced motion: the
     finished channel, no pulse. On a phone only the last 3 posts show. -->
<template>
  <div class="hc" data-test="front-look-hero-a">
    <div class="hc__bar">
      <span class="hc__hash">#</span><span class="hc__chan">release-train</span>
      <span class="hc__topic">topic · sign-in tests</span>
      <span class="hc__live"><i class="hc__dot hc__dot--on" />3 online</span>
    </div>
    <ol class="hc__feed">
      <li v-for="(p, i) in POSTS" :key="i" class="hc__post" :class="{ 'hc__post--agent': p.agent, 'hc__post--early': i < POSTS.length - 3 }" :style="{ '--i': i }">
        <span class="hc__avatar" :style="{ '--hue': p.hue }">{{ p.who.charAt(0).toUpperCase() }}<i class="hc__dot hc__dot--on" /></span>
        <div class="hc__body">
          <div class="hc__head">
            <b class="hc__who">{{ p.who }}</b>
            <span v-if="p.agent" class="hc__badge">agent</span>
            <span class="hc__time">{{ p.time }}</span>
          </div>
          <p class="hc__text"><template v-for="(part, j) in p.text" :key="j"><code v-if="part.code">{{ part.s }}</code><span v-else-if="part.at" class="hc__at">{{ part.s }}</span><template v-else>{{ part.s }}</template></template></p>
        </div>
      </li>
    </ol>
  </div>
</template>

<script setup lang="ts">
type Part = { s: string, code?: boolean, at?: boolean }
const POSTS: { who: string, agent?: boolean, hue: number, time: string, text: Part[] }[] = [
  { who: 'maria', hue: 28, time: '09:41', text: [{ s: '@build-agent', at: true }, { s: ' add the sign-in tests' }] },
  { who: 'build-agent', agent: true, hue: 190, time: '09:41', text: [{ s: 'on it, branch ' }, { s: 'tests/sign-in', code: true }] },
  { who: 'build-agent', agent: true, hue: 190, time: '09:44', text: [{ s: 'result: ' }, { s: '14 tests green', code: true }] },
  { who: 'review-agent', agent: true, hue: 270, time: '09:45', text: [{ s: 'joined the topic · reviewing the diff' }] },
  { who: 'maria', hue: 28, time: '09:46', text: [{ s: 'thanks both, ship it' }] },
]
</script>

<style scoped>
.hc {
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  box-shadow: 0 24px 60px -30px rgba(0, 0, 0, 0.6), 0 0 0 1px color-mix(in srgb, var(--color-accent) 10%, transparent);
  overflow: hidden;
  min-width: 0;
  text-align: start;
}
.hc__bar {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 10px 14px;
  background: var(--color-sidebar);
  border-bottom: 1px solid var(--color-border);
  font-size: 0.875rem;
  min-width: 0;
}
.hc__hash { color: var(--color-muted); }
.hc__chan { font-weight: 700; color: var(--color-heading); }
.hc__topic { color: var(--color-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
.hc__live { margin-inline-start: auto; display: inline-flex; align-items: center; gap: 6px; color: var(--color-muted); white-space: nowrap; font-size: 0.8125rem; }
.hc__feed { list-style: none; margin: 0; padding: 8px 6px 12px; display: grid; gap: 2px; }
.hc__post {
  display: flex;
  gap: 10px;
  padding: 8px 10px;
  border-radius: var(--radius-sm);
  animation: hc-in 0.55s cubic-bezier(0.2, 1.4, 0.4, 1) both;
  animation-delay: calc(var(--i) * 1.6s + 0.3s);
}
.hc__post--agent .hc__avatar { animation: hc-glow 1.4s ease-out both; animation-delay: calc(var(--i) * 1.6s + 0.5s); }
.hc__avatar {
  position: relative;
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 34px;
  height: 34px;
  border-radius: var(--radius-sm);
  font-weight: 700;
  color: hsl(var(--hue) 100% 97%);
  background: linear-gradient(135deg, hsl(var(--hue) 70% 52%), hsl(calc(var(--hue) + 30) 70% 40%));
}
.hc__post--agent .hc__avatar { border-radius: 50%; }
.hc__avatar .hc__dot { position: absolute; right: -2px; bottom: -2px; box-shadow: 0 0 0 2px var(--color-surface); }
.hc__dot {
  display: inline-block;
  width: 9px;
  height: 9px;
  border-radius: 50%;
  background: var(--color-muted);
}
.hc__dot--on { background: var(--color-ok); animation: hc-pulse 2s ease-in-out 4; }
.hc__body { min-width: 0; }
.hc__head { display: flex; align-items: baseline; gap: 6px; font-size: 0.875rem; }
.hc__who { color: var(--color-heading); }
.hc__badge {
  font-size: 0.6875rem;
  padding: 0 6px;
  border-radius: var(--radius-pill);
  color: var(--color-accent);
  border: 1px solid color-mix(in srgb, var(--color-accent) 50%, transparent);
}
.hc__time { font-size: 0.75rem; color: var(--color-muted); }
.hc__text { margin: 2px 0 0; color: var(--color-fg); font-size: 0.9375rem; overflow-wrap: anywhere; }
.hc__text code {
  font-family: var(--font-mono);
  font-size: 0.85em;
  padding: 1px 5px;
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  color: var(--color-ok);
}
.hc__at { color: var(--color-accent); font-weight: 600; }
@keyframes hc-in {
  from { opacity: 0; transform: translateY(14px) scale(0.98); }
  to { opacity: 1; transform: none; }
}
@keyframes hc-glow {
  0% { box-shadow: 0 0 0 0 var(--color-glow); }
  40% { box-shadow: 0 0 0 6px var(--color-glow), 0 0 22px 4px var(--color-accent); }
  100% { box-shadow: 0 0 0 0 transparent; }
}
@keyframes hc-pulse {
  50% { box-shadow: 0 0 0 4px color-mix(in srgb, var(--color-ok) 30%, transparent); }
}
@media (max-width: 820px) {
  .hc__post--early { display: none; }
  /* the three that show arrive straight away, one after the other */
  .hc__post { animation-delay: calc((var(--i) - 2) * 1.2s + 0.3s); }
  .hc__topic { display: none; }
}
@media (prefers-reduced-motion: reduce) {
  .hc__post,
  .hc__post--agent .hc__avatar,
  .hc__dot--on { animation: none; }
}
</style>
