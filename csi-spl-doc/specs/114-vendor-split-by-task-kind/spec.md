# Spec 114: Vendor Split by Task Kind

## 1. Goals
Distribute agent workloads across different AI vendors based on the *kind* of task rather than a single global split ratio. This maximizes cost-efficiency and leverages each vendor's strengths:
- **AGY (anti-gravity):** Main vendor for specs and documentation. Zero weight on coding for now.
- **Mistral:** Main vendor for test execution and simple coding tasks.
- **Claude:** Main vendor for complex, hardcore coding tasks. Backup for other kinds when they get stuck.

## 2. Task Kinds & Vendor Assignments
Tasks are categorized into distinct kinds. Each kind explicitly designates a **main** and a **backup** vendor:
1. **specs_and_docs**: Specifications, documentation, and non-coding planning tasks.
   - Main: AGY
   - Backup: Claude
2. **tests**: Writing tests.
   - Main: Claude
   - Backup: Mistral
3. **simple_coding**: Execution of tests and simple/routine coding tasks.
   - Main: Mistral
   - Backup: Claude (to rescue stuck simple-task lanes)
4. **complex_coding**: Complex coding, architecture implementation, and hi-fi tasks.
   - Main: Claude
   - Backup: Mistral
5. **i18n**: Multilingual text and translations.
   - Main: AGY
   - Backup: Claude (AGY retains the final word on multilingual text)
6. **secret**: Tasks involving secrets, personal data, or compliance-restricted data.
   - Main: Claude
   - Backup: Mistral

## 3. Configuration & Weights Setting
The single `env.box.agent_split` setting will be replaced (or extended) by a per-kind mapping that specifies the main and backup vendor. 

**CNF Mapping (example):**
```yaml
env:
  box:
    agent_split_by_kind:
      specs_and_docs: { main: agy, backup: claude }
      tests: { main: claude, backup: mistral }
      simple_coding: { main: mistral, backup: claude }
      complex_coding: { main: claude, backup: mistral }
      i18n: { main: agy, backup: claude }
      secret: { main: claude, backup: mistral }
```
This configuration will be mirrored in the Hub Workspace Setting (rdb), replacing or alongside the existing overall `do_spl_agent_split_show` setting.

## 4. `lane_mix` Picker Logic
The picker `do_spl_lane_mix` will read the task's assigned kind (`LANE_MIX_KIND`) and retrieve the corresponding main vendor from the config.
- If no kind is specified, it falls back to a legacy default profile.
- The current hardcoded overrides (e.g., sending `kind=spec` to mistral) will be removed in favor of the data-driven config.

## 5. Backup & Fallback Mechanism
The backup vendor takes over after **2 failed tries** of the main vendor.
A "failed try" is defined as:
- Spawn fail
- Stuck / no progress
- Red result

*Data Privacy Rule:* Secrets and personal data MUST NEVER fall back to qwen, grok, or agy.
*i18n Rule:* If Claude takes over an i18n task as a backup, an AGY review is ultimately required.

## 6. Migration
1. **Schema Update:** Introduce `agent_split_by_kind` in CNF and the Hub workspace rdb.
2. **Backwards Compatibility:** Unclassified legacy tasks fallback to a default kind using a generic split (e.g., the current 60/20/20 split).
3. **Rollout:** Populate the new per-kind configurations based on the owner's desired distribution. Deprecate the old overall split setting once all workspaces are migrated.

## 7. Tests
- **Zero Coding for AGY:** A counting test verifying that, over a statistically significant number of simulated lane picks for `simple_coding` and `complex_coding`, AGY is never picked as main or backup.
- **Privacy Enforcement:** A test verifying that tasks with kind `secret` never pick qwen, grok, or agy, even under fallback scenarios.
- **i18n Authority:** A test ensuring `i18n` tasks heavily favor AGY or enforce AGY as the final reviewer if the backup was used.
