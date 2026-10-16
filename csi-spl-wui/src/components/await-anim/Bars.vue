<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): four bars rising and falling, like a sound meter.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <g fill="currentColor">
      <rect class="await-bars__bar" x="1.6" y="3" width="2.4" height="11" rx=".8" />
      <rect class="await-bars__bar await-bars__bar--2" x="5.2" y="3" width="2.4" height="11" rx=".8" />
      <rect class="await-bars__bar await-bars__bar--3" x="8.8" y="3" width="2.4" height="11" rx=".8" />
      <rect class="await-bars__bar await-bars__bar--4" x="12.4" y="3" width="2.4" height="11" rx=".8" />
    </g>
  </svg>
</template>

<style scoped>
.await-bars__bar { transform-box: view-box; transform-origin: 0 14px; transform: scaleY(0.5); }
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-bars__bar { animation: await-bars 0.9s ease-in-out infinite alternate; }
  .await-reply--spin .await-bars__bar--2 { animation-delay: -0.3s; }
  .await-reply--spin .await-bars__bar--3 { animation-delay: -0.6s; }
  .await-reply--spin .await-bars__bar--4 { animation-delay: -0.45s; }
}
@keyframes await-bars {
  from { transform: scaleY(0.25); }
  to { transform: scaleY(1); }
}
</style>
