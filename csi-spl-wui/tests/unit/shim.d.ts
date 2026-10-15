// tests/unit/shim.d.ts
// Type shims for test dependencies

declare module 'vitest' {
  import { vi } from 'vitest';
  export { vi };
  export const describe: any;
  export const it: any;
  export const expect: any;
  export const Mock: any;
}