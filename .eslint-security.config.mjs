// ESLint flat config for the security gate over the WUI plain-JS (.mjs/.js).
// Consumed by do_sec_eslint (SEC_ESLINT) and .github/workflows/63_eslint-security.yml.
//
// eslint-plugin-security "recommended", minus four rules that are false-positive
// prone in this browser/mjs codebase and would only produce noise:
//   detect-object-injection      - flags every obj[var] access (196 hits, ~all FP)
//   detect-non-literal-fs-filename - no server fs in browser .mjs; matches by name
//   detect-unsafe-regex          - ReDoS heuristic, high FP on ordinary regex
//   detect-non-literal-regexp    - new RegExp(var) is common + guarded here
// The high-signal rules stay ON: detect-eval-with-expression, detect-child-process,
// detect-non-literal-require, detect-bidi-characters, detect-pseudoRandomBytes,
// detect-buffer-noassert, detect-disable-mustache-escape, detect-new-buffer,
// detect-no-csrf-before-method-override. A NEW hit of any of those (beyond the
// checked-in baseline) reddens the gate.
import security from "eslint-plugin-security";

export default [
  security.configs.recommended,
  {
    languageOptions: { ecmaVersion: 2022, sourceType: "module" },
    rules: {
      "security/detect-object-injection": "off",
      "security/detect-non-literal-fs-filename": "off",
      "security/detect-unsafe-regex": "off",
      "security/detect-non-literal-regexp": "off",
    },
  },
];
