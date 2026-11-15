// SPL-5601: the WUI's workspaceDir never follows a file above the repo.
//
// Nuxt resolves workspaceDir with pkg-types findWorkspaceDir(rootDir): first
// the closest `.git/config`, then the FURTHEST lockfile up the tree. In a git
// worktree `.git` is a file, so the first test misses and a stray lockfile in
// any parent dir (e.g. one level above the worktree) becomes the workspace:
// nuxt then adds `<that dir>/node_modules` to modulesDir and puts its build
// cache there. nuxt.config.ts pins `workspaceDir: "."` (the rootDir).
//
// The case is built in a temp dir, never next to a real checkout:
//   <tmp>/pnpm-lock.yaml        the lockfile one level above the worktree
//   <tmp>/wt/.git               a worktree's `.git` FILE
//   <tmp>/wt/csi-spl-wui  ->    symlink to this WUI
// Red control: drop the pin and workspaceDir reads <tmp>.
import { describe, it, after } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createRequire } from 'node:module'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

describe('nuxt workspaceDir (SPL-5601)', () => {
  const tmp = mkdtempSync(join(tmpdir(), 'wui-workspace-dir-'))
  after(() => rmSync(tmp, { recursive: true, force: true }))

  it('stays the WUI rootDir with a lockfile one level above a worktree', async () => {
    writeFileSync(join(tmp, 'pnpm-lock.yaml'), "lockfileVersion: '9.0'\n")
    mkdirSync(join(tmp, 'wt'))
    writeFileSync(join(tmp, 'wt', '.git'), 'gitdir: /nonexistent/.git/worktrees/wt\n')
    const root = join(tmp, 'wt', 'csi-spl-wui')
    symlinkSync(WUI, root, 'dir')

    const req = createRequire(join(WUI, 'package.json'))
    const kit = await import(pathToFileURL(req.resolve('@nuxt/kit')).href)
    const opts = await kit.loadNuxtConfig({ cwd: root })

    assert.equal(opts.rootDir, root)
    assert.equal(opts.workspaceDir, root,
      `workspaceDir followed a file above the repo: ${opts.workspaceDir}`)
  })
})
