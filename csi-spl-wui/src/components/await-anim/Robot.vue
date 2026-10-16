<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a small robot running to the right: legs and arms swing, it bobs (SPL-2027).
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <g fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
      <path class="await-robot__speed" d="M.8 6.5h2M.4 9.5h2.4" stroke-width="1" />
      <path d="M8 2.6V1.2" />
      <rect x="4.6" y="2.6" width="6.8" height="4.4" rx="1.3" />
      <rect x="5.6" y="7.6" width="4.8" height="3.8" rx=".8" />
      <path class="await-robot__limb await-robot__arm-a" d="M8 8.6l2.6 1.6" />
      <path class="await-robot__limb await-robot__arm-b" d="M8 8.6 5.4 10.2" />
      <path class="await-robot__limb await-robot__leg-a" d="M7 11.4v3.4" />
      <path class="await-robot__limb await-robot__leg-b" d="M9 11.4v3.4" />
    </g>
    <circle cx="8" cy="1" r=".9" fill="currentColor" />
    <circle cx="9.7" cy="4.6" r=".9" fill="currentColor" />
  </svg>
</template>

<style scoped>
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-reply__glyph { animation: await-robot 0.5s ease-in-out infinite; }
  .await-reply--spin .await-robot__limb {
    animation: await-robot-limb 0.5s ease-in-out infinite alternate;
    transform-box: view-box;
  }
  .await-reply--spin .await-robot__leg-a { transform-origin: 7px 11.4px; }
  .await-reply--spin .await-robot__leg-b { transform-origin: 9px 11.4px; animation-direction: alternate-reverse; }
  .await-reply--spin .await-robot__arm-a { transform-origin: 8px 8.6px; animation-direction: alternate-reverse; }
  .await-reply--spin .await-robot__arm-b { transform-origin: 8px 8.6px; }
  .await-reply--spin .await-robot__speed { animation: await-robot-speed 0.5s linear infinite; }
}
@keyframes await-robot {
  0%, 100% { transform: translateY(0); }
  50% { transform: translateY(-1px); }
}
@keyframes await-robot-limb {
  from { transform: rotate(-28deg); }
  to { transform: rotate(28deg); }
}
@keyframes await-robot-speed {
  0% { opacity: 0.9; transform: translateX(0); }
  100% { opacity: 0; transform: translateX(-2px); }
}
</style>
