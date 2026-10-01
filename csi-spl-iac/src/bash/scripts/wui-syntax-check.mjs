// Per-file syntax gate for JS/TS/Vue (csi-spl-wui, csi-web-wui): one pass, touched files only.
// .vue: SFC parse + compileScript + compileTemplate (the dev-server transform rules);
// .ts/.tsx/.jsx: TypeScript parse diagnostics; .mjs/.js: node --check. Exit 1 on any finding.
// Usage (cwd = a dir whose node_modules has typescript, plus vue for .vue): node wui-syntax-check.mjs <file>...
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
const require = createRequire(process.cwd() + "/package.json");
let sfc; // loaded only when a .vue file is checked (csi-web has no vue)
const ts = require("typescript");
let bad = 0;
const tsSyntax = (file, code) => {
  const kind = file.endsWith(".tsx") ? ts.ScriptKind.TSX : file.endsWith(".jsx") ? ts.ScriptKind.JSX : ts.ScriptKind.TS;
  const sf = ts.createSourceFile(file, code, ts.ScriptTarget.Latest, true, kind);
  for (const d of sf.parseDiagnostics ?? []) {
    const { line, character } = sf.getLineAndCharacterOfPosition(d.start);
    console.log(`${file}:${line + 1}:${character + 1}: ${ts.flattenDiagnosticMessageText(d.messageText, "\n")}`); bad++;
  }
};
for (const f of process.argv.slice(2)) {
  const src = readFileSync(f, "utf8");
  if (f.endsWith(".vue")) {
    sfc ??= require("vue/compiler-sfc");
    const { descriptor, errors } = sfc.parse(src, { filename: f });
    for (const e of errors) { console.log(`${f}:${e.loc?.start.line ?? 0}: ${e.message}`); bad++; }
    if (errors.length) continue;
    const id = "x";
    let bindings;
    if (descriptor.script || descriptor.scriptSetup) {
      try { const s = sfc.compileScript(descriptor, { id }); bindings = s.bindings;
        if ((descriptor.scriptSetup ?? descriptor.script).lang === "ts") tsSyntax(f, s.content); }
      catch (e) { console.log(`${f}: script: ${e.message.split("\n")[0]}`); bad++; }
    }
    if (descriptor.template) {
      const t = sfc.compileTemplate({ source: descriptor.template.content, filename: f, id,
        compilerOptions: { bindingMetadata: bindings, isTS: true } });
      for (const e of t.errors) { const m = typeof e === "string" ? e : e.message;
        console.log(`${f}:${(e.loc?.start.line ?? 0) + descriptor.template.loc.start.line - 1}: template: ${m}`); bad++; }
    }
  } else if (/\.(ts|tsx|jsx)$/.test(f)) tsSyntax(f, src);
  else { const r = spawnSync(process.execPath, ["--check", f], { encoding: "utf8" });
    if (r.status) { console.log(r.stderr.trim().split("\n").slice(0, 5).join("\n")); bad++; } }
}
process.exit(bad ? 1 : 0);
