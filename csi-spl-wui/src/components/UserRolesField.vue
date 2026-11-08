<!-- SPL-5056 (specs/025 §10.2 item 7): the member's 1..* roles, one tick per
     role, and which of them is primary once there are several. A held role
     the reader cannot grant shows ticked and locked. -->
<template>
  <fieldset class="roles-field" data-test="users-pane-roles" :disabled="disabled">
    <legend>{{ t('users.roles') }}</legend>
    <div v-for="o in options" :key="o.id" class="roles-field__row">
      <label class="roles-field__pick">
        <input
          type="checkbox"
          :checked="roles.includes(o.id)"
          :disabled="o.locked"
          :data-test="'users-pane-role-' + o.id"
          @change="toggle(o.id, ($event.target as HTMLInputElement).checked)"
        >
        <span>{{ roleName(o.id) }}</span>
      </label>
      <small v-if="o.locked" class="muted" :data-test="'users-pane-role-locked-' + o.id">{{ t('users.role_locked') }}</small>
      <label v-if="roles.length > 1 && roles.includes(o.id)" class="roles-field__primary">
        <input
          type="radio"
          name="users-pane-primary"
          :checked="primary === o.id"
          :disabled="o.locked"
          :data-test="'users-pane-primary-' + o.id"
          @change="emit('update:primary', o.id)"
        >
        <span>{{ t('users.role_primary') }}</span>
      </label>
    </div>
    <small v-if="!roles.length" class="roles-field__empty" role="alert" data-test="users-pane-roles-empty">{{ t('users.roles_need_one') }}</small>
    <small v-else-if="exclusivePicked" class="muted" data-test="users-pane-roles-exclusive">{{ t('users.roles_exclusive') }}</small>
  </fieldset>
</template>

<script setup lang="ts">
import { useRoleName } from '~/composables/useRoleName'
import { EXCLUSIVE_ROLES, toggleRole } from '~/utils/member-roles.mjs'

const props = defineProps<{
  roles: string[]
  primary: string
  options: { id: string, locked: boolean }[]
  disabled: boolean
}>()
const emit = defineEmits<{
  'update:roles': [roles: string[]]
  'update:primary': [primary: string]
}>()

const { t } = useI18n({ useScope: 'global' })
const roleName = useRoleName()
const exclusivePicked = computed(() => props.roles.some((r) => EXCLUSIVE_ROLES.includes(r)))

function toggle(id: string, on: boolean) {
  const next = toggleRole({ roles: props.roles, primary: props.primary }, id, on)
  emit('update:roles', next.roles)
  emit('update:primary', next.primary)
}
</script>

<style scoped>
.roles-field {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
  margin: 0;
  padding: 0;
  border: 0;
}
.roles-field legend { padding: 0; margin-bottom: 4px; }
.roles-field__row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 2px 12px;
  min-width: 0;
}
.roles-field__pick,
.roles-field__primary {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  overflow-wrap: anywhere;
}
.roles-field__primary { color: var(--color-muted); font-size: 0.8125rem; }
.roles-field__empty { color: var(--color-danger); }
@media (max-width: 820px) {
  .roles-field__pick,
  .roles-field__primary { min-height: var(--tap, 44px); }
}
</style>
