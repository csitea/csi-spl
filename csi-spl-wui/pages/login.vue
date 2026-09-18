<template>
  <div class="login-card">
    <h1>Spool</h1>
    <p>Preferred register and login is a social IdP. First callback creates <code>HUM-*</code>. The hub signs as <code>box-wui</code> — the browser never holds a box private key.</p>
    <div class="idp">
      <button v-for="p in providers" :key="p" type="button" @click="pending = p">{{ p }}</button>
    </div>
    <p v-if="pending" class="muted">{{ pending }} is not wired yet. Session cookies ship with the hub auth fork (spec 005 T018). lde uses the mock operator HUM-1.</p>
    <p><NuxtLink to="/channel/general">Continue with mock HUM-1</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
definePageMeta({ layout: 'login' })
const providers = ['Google', 'Facebook', 'Microsoft', 'LinkedIn', 'xAI']
const pending = ref('')
</script>
