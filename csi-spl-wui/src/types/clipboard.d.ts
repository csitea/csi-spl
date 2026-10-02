declare module '~/utils/clipboard.mjs' {
  export function writeClipboard(text: string, env?: { nav?: Navigator, doc?: Document }): Promise<boolean>
}
