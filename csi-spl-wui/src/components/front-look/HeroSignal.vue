<!-- spec 116 4.2, direction B "Signal field": today's sign-in wallpaper grown
     into the hero. Beads of light run between person and agent avatars
     scattered over the field; low opacity, dark most of their cycle. The
     layout's wallpaper shows through in dark; light gets a pale veil. Phone:
     fewer beads and avatars, only at the edges. Reduced motion: a still field. -->
<template>
  <div class="hs" data-test="front-look-hero-b">
    <div class="hs__veil" />
    <svg class="hs__beads" viewBox="0 0 100 100" preserveAspectRatio="none">
      <path v-for="(b, i) in BEADS" :key="i" class="hs__bead" :class="{ 'hs__bead--warm': b.warm, 'hs__bead--extra': b.extra }" :style="{ '--d': b.dur + 's', '--w': b.delay + 's' }" pathLength="100" :d="b.d" />
    </svg>
    <span v-for="(a, i) in AVATARS" :key="i" class="hs__av" :class="{ 'hs__av--agent': a.agent, 'hs__av--extra': a.extra }" :style="{ left: a.x + '%', top: a.y + '%', '--hue': a.hue }">{{ a.agent ? '◆' : a.l }}</span>
  </div>
</template>

<script setup lang="ts">
/* Each bead runs from one avatar to another (the ends sit on avatar spots). */
const AVATARS = [
  { x: 5, y: 20, l: 'm', hue: 28 },
  { x: 7, y: 66, agent: true, hue: 190 },
  { x: 30, y: 10, agent: true, hue: 270, extra: true },
  { x: 42, y: 94, l: 'j', hue: 340, extra: true },
  { x: 94, y: 12, agent: true, hue: 160 },
  { x: 96, y: 52, l: 'a', hue: 48, extra: true },
  { x: 74, y: 95, agent: true, hue: 210, extra: true },
]
const BEADS = [
  { d: 'M 5 20 C 14 36, 2 52, 7 66', dur: 11, delay: 0.5 },
  { d: 'M 7 66 C 20 84, 30 98, 42 94', dur: 13, delay: 4, warm: true, extra: true },
  { d: 'M 42 94 C 60 80, 80 40, 94 12', dur: 12, delay: 2, extra: true },
  { d: 'M 94 12 C 76 2, 50 18, 30 10', dur: 14, delay: 7, extra: true },
  { d: 'M 30 10 C 22 30, 40 60, 74 95', dur: 10, delay: 9, warm: true, extra: true },
  { d: 'M 74 95 C 90 86, 84 64, 96 52', dur: 15, delay: 3, extra: true },
  { d: 'M 5 20 C 30 4, 64 30, 94 12', dur: 16, delay: 6, warm: true },
]
</script>

<style scoped>
.hs { position: absolute; inset: 0; }
.hs__veil {
  position: absolute;
  inset: 0;
  background:
    radial-gradient(70% 60% at 30% 40%, transparent, rgba(6, 9, 18, 0.55) 100%);
}
.hs__beads { position: absolute; inset: 0; width: 100%; height: 100%; overflow: visible; }
.hs__bead {
  fill: none;
  stroke: var(--color-accent);
  stroke-width: 2.5px;
  stroke-linecap: round;
  vector-effect: non-scaling-stroke;
  filter: drop-shadow(0 0 3px var(--color-accent)) drop-shadow(0 0 9px var(--color-glow));
  stroke-dasharray: 7 93;
  opacity: 0;
  animation: hs-bead var(--d) ease-in-out var(--w) infinite;
}
.hs__bead--warm {
  stroke: var(--color-warn);
  filter: drop-shadow(0 0 3px var(--color-warn)) drop-shadow(0 0 9px var(--color-warn));
}
/* the faint track each bead runs on, so the still field still reads */
@keyframes hs-bead {
  0%, 50% { opacity: 0; stroke-dashoffset: 8; }
  58% { opacity: 0.9; }
  84% { opacity: 0.6; stroke-dashoffset: -92; }
  92%, 100% { opacity: 0; stroke-dashoffset: -100; }
}
.hs__av {
  position: absolute;
  transform: translate(-50%, -50%);
  display: grid;
  place-items: center;
  width: 40px;
  height: 40px;
  border-radius: 50%;
  font-weight: 700;
  font-size: 0.95rem;
  color: hsl(var(--hue) 100% 97%);
  background: radial-gradient(circle at 30% 30%, hsl(var(--hue) 80% 62%), hsl(var(--hue) 70% 32%));
  box-shadow: 0 0 0 2px rgba(255, 255, 255, 0.18), 0 0 24px hsl(var(--hue) 90% 60% / 0.55);
  opacity: 0.85;
  animation: hs-float 9s ease-in-out infinite alternate;
}
.hs__av--agent { border-radius: var(--radius-md); font-size: 0.8rem; }
.hs__av:nth-child(odd) { animation-duration: 11s; animation-direction: alternate-reverse; }
@keyframes hs-float {
  from { transform: translate(-50%, -50%); }
  to { transform: translate(-50%, calc(-50% - 8px)); }
}
@media (max-width: 820px) {
  .hs__bead--extra, .hs__av--extra { display: none; }
  .hs__av { width: 32px; height: 32px; font-size: 0.8rem; }
}
@media (prefers-reduced-motion: reduce) {
  .hs__bead { animation: none; opacity: 0.35; stroke-dasharray: none; }
  .hs__av { animation: none; }
}
</style>

<style>
/* Light theme: a pale veil over the field. Not scoped:
   the theme attribute sits on <html>; the hs__ names are this file's own. */
:root[data-theme="light"] .hs__veil {
  background:
    radial-gradient(60rem 30rem at 20% 20%, color-mix(in srgb, var(--color-accent) 18%, transparent), transparent 70%),
    radial-gradient(50rem 30rem at 90% 90%, color-mix(in srgb, var(--color-accent-2) 16%, transparent), transparent 70%),
    color-mix(in srgb, var(--color-bg) 86%, transparent);
}
</style>
