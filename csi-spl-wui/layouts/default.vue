<template>
  <ClientOnly>
    <div class="spool-shell">
      <ChannelSidebar />
      <main class="spool-main">
        <slot />
      </main>
      <ThreadPane />
    </div>
    <template #fallback>
      <div class="login"><p class="muted">Loading Spool…</p></div>
    </template>
  </ClientOnly>
</template>
