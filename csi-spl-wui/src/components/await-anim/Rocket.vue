<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a rocket on its way: the flame flickers, it bobs, stars stream past.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <path class="await-rocket__stars" d="M2 2.4v1.2M13.6 9.4v1.2M3.2 9v.9" fill="none" stroke="currentColor" stroke-width="1" stroke-linecap="round" />
    <g class="await-rocket__ship">
      <path class="await-rocket__flame" d="M6.8 12.2 8 15.4l1.2-3.2z" fill="currentColor" />
      <g fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round">
        <path d="M8 .8c2 1.6 2.6 4 2.4 7.4L9.4 12H6.6L5.6 8.2C5.4 4.8 6 2.4 8 .8z" />
        <path d="M5.7 8.6 3.8 10.6l.4 1.6 2.2-.4M10.3 8.6l1.9 2 -.4 1.6-2.2-.4" />
      </g>
      <circle cx="8" cy="5.2" r="1.1" fill="currentColor" />
    </g>
  </svg>
</template>

<style scoped>
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-rocket__ship { animation: await-rocket 0.6s ease-in-out infinite alternate; }
  .await-reply--spin .await-rocket__flame {
    animation: await-rocket-flame 0.15s linear infinite alternate;
    transform-box: view-box;
    transform-origin: 8px 12.2px;
  }
  .await-reply--spin .await-rocket__stars { animation: await-rocket-stars 0.6s linear infinite; }
}
@keyframes await-rocket {
  from { transform: translateY(0.4px); }
  to { transform: translateY(-0.8px); }
}
@keyframes await-rocket-flame {
  from { transform: scaleY(0.6); }
  to { transform: scaleY(1.15); }
}
@keyframes await-rocket-stars {
  from { transform: translateY(-2px); opacity: 1; }
  to { transform: translateY(3px); opacity: 0; }
}
</style>
