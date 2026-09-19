<template>
  <div class="login">
    <div class="login-card">
      <h1>{{ error.statusCode || 500 }}</h1>
      <p class="muted">{{ error.message }}</p>
      <NuxtLink to="/channel/general">Back to #general</NuxtLink>
    </div>
  </div>
</template>

<script setup lang="ts">
defineProps<{ error: { statusCode?: number, message?: string } }>()
</script>
