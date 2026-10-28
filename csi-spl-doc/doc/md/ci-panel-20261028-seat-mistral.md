# CI Panel 2026-10-28: Mistral Seat Review

**Seat**: Mistral (m-025)
**Editor Draft**: v0.1 (c-005, claude)
**Status**: Signed with **W (work) items**

## 1. Table Sent to Editor
See the spool message sent to `<EDITOR_SEAT>` on task `1f860d3c-f5c6-5b3a-bc8b-965820478e42`.

## 2. Review of v0.1

### Agreement
1. **Rows 1, 2, 3, 6, 8, 12, 16, 17, 18, 19, 20, 22, 23, 24, 26, 27**: Agree with classification and fixes.
2. **Rows 4, 7, 10, 11, 14, 15, 25, 28**: Correctly classified as **infra**, **plant**, or **ops**. No action needed.
3. **Open Defects (Section 3)**: Agree with analysis and proposed fixes (**F1-F4**).

### Work Items (W)
1. **Row 13 (wf 20 dev revision not Ready)**:
   - **Issue**: The hub image failed to start, causing a rollback and a red deploy gate.
   - **Smell**: No investigation into the **Cloud Run logs** or **container health checks**.
   - **Proposed Fix**: Add a row to trace the failure (e.g., `gcloud run services describe`, `gcloud logging read`).

2. **Row 25 (wf 30 dev live proof 404)**:
   - **Issue**: The live proof returned a **404**, blocking the WUI deploy gate.
   - **Smell**: No investigation into the **hub logs** or **tenant mapping**.
   - **Proposed Fix**: Add a row to trace the 404 (e.g., `kubectl logs`, `gcloud run services describe`).

3. **Row 5 (Infra: ubuntu-26.04 image window)**:
   - **Issue**: The ubuntu-26.04 image caused **15 red jobs** in 7 runs.
   - **Smell**: No audit of the **image for missing dependencies** (e.g., `gcloud`, `docker`, `PostgreSQL`).
   - **Proposed Fix**: Add a row to audit the image (e.g., `docker run --rm ubuntu:26.04 <tool> --version`).

## 3. Signature
Signed with **W items** above. The editor may fold these into v1.0 or spawn them as separate rows.