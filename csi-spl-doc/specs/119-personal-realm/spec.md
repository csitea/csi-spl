# 119 Personal Realm

**Status**: Draft v0.1

## 1. Context and Goals
Based on the owner's feedback, there is a need for a "personal realm" — a person-level layer that exists above workspaces. When people leave a workspace, they should retain read-only copies of their own past hours (like pay receipts) without keeping the actual content of the work.

## 2. Scope
The personal realm is a person-level layer ABOVE workspaces, holding:
- Identity and profile.
- Personal views (e.g., 'my time across workspaces', cross-reference Spec 118).
- Personal settings (e.g., the working-time limit).
- Receipts: read-only copies of one's own past hours after leaving a workspace (hours only, NOT content).

Workspaces stay unchanged. Nothing flows from the personal realm down to the workspaces, and everything must be Row-Level Security (RLS) safe.

## 3. Requirements

- **REQ-1 (Identity and Profile)**: The system must maintain a personal identity and profile separate from workspace-specific profiles.
- **REQ-2 (Personal Views)**: The system must provide a unified view across all workspaces a user belongs to (see Spec 118 for 'my time across workspaces' details).
- **REQ-3 (Personal Settings)**: The system must support personal settings that apply across workspaces, such as working-time limits.
- **REQ-4 (Read-Only Receipts)**: Upon leaving a workspace, a person must retain a read-only receipt of their own past hours.
- **REQ-5 (Content Redaction on Departure)**: The read-only receipts must NOT contain the content of what was done, only the hours.
- **REQ-6 (Data Isolation)**: Data must not flow from the personal realm into workspaces, and must be completely RLS-safe.

## 4. Open Questions

**Q1: What exactly should be included in the "Identity/Profile" within the personal realm?**
- A) Only name and email.
- B) Name, email, personal avatar, and communication preferences.
- C) Full CV, skills, and portfolio.
- **Recommendation:** B. Name, email, avatar, and basic communication preferences provide a solid foundation for cross-workspace identity without unnecessary complexity.

**Q2: How should receipts be presented after leaving a workspace?**
- A) As a static document (e.g. PDF) generated at the time of leaving.
- B) As an interactive but read-only data view in the personal realm.
- **Recommendation:** B. An interactive data view allows better filtering and consistency with the rest of the personal realm UI.

**Q3: How much detail is retained in the read-only receipts (REQ-5)?**
- A) Only the total hours per day/week.
- B) Total hours, dates, workspace name, and high-level job/site label (as defined in Spec 118).
- **Recommendation:** B. Retaining the workspace name and high-level job label is necessary for the receipt to act like a useful pay receipt, without exposing the actual work content.

**Q4: What should be the NAME of the single database schema used for personal realms?**
- A) `personal` (recommended)
- B) `person`
- C) `own`
- **Recommendation:** A. `personal` is standard and aligns well with the concept of a "personal realm". *(Note: The schema name is decided to be `personal` - the business/UI/doc term is "the personal realm").*

## 5. Security

The personal realm introduces a new data layer requiring strict isolation. The baseline security architecture is:

- **Schema Architecture**: 
  - Workspaces stay on RLS in the shared schema.
  - There is ONE schema (named `personal`) for all personal realms with person-scoped RLS and its own grants (never a schema per person).
  - Hard isolation for a customer requires a dedicated DB (byo-gcp), not schema-per-tenant.
- **RLS Isolation**: Realm tables are keyed by `person_id` with a strict Row-Level Security (RLS) policy based on `app.person_id` (FORCE RLS, similar to the existing tenant NULLIF policies).
- **Scope Separation**: Workspace scope and realm scope are never set together.
- **Cross-Workspace Reads**: The cross-workspace view reads each workspace under its own RLS context as that person.
- **Receipt Isolation**: Receipts are strict COPIES taken at leave time. There are no Foreign Keys (FK) into workspace data to prevent data leakage.
- **Access Restrictions**: No foreman, admin, or owner can read another person's realm. Operator access is strictly logged.
- **Testing**: Per-table isolation tests + red control.
- **Future phases**: Phase 2 option for per-person encryption.
