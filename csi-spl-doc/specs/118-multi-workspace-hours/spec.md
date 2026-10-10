# 118 Multi-Workspace Hours Tracking

**Status**: Draft

## 1. Context and Goals
The goal is to allow each person to individually report and track their own hours across multiple workspaces at once, in a unified view. Each person sees and tracks (enters, not read-only) their own hours across all workspaces they belong to. Cross-workspace reads remain person-only and RLS-safe.

## 2. Requirements

- **REQ-1 (Workspace Scope & Overlaps)**: Hours stay per workspace for approval and accounting. A tracked minute counts in one workspace only. However, across workspaces, the same minute may count in multiple workspaces (e.g., a component invoiced to two organizations). Double counting across workspaces is allowed, but double counting within a single workspace is forbidden.
- **REQ-2 (Working-Time Limits)**: Working-time limits are evaluated on the cross-workspace total by the person themselves. Foremen and time-accountants see only inside their own workspace and cannot enforce global cross-workspace limits.
- **REQ-3 (Standard Days)**: The standard day is set and configured on a per-workspace basis (e.g., 8 hours in Workspace A, and 4 hours in Workspace B).
- **REQ-4 (Unified Tracking UI)**: The user must be able to see and track (enter) their hours from multiple workspaces in one unified place. Each entry is saved into its respective workspace.

## 3. Owner Decisions

**D1: Visibility of Double Counting (REQ-1)**
The personal view shows two numbers: **reported time** (sum of all workspaces) and **actual time** (overlapping minutes counted once). It visually marks overlapping hours so the user can stand behind both invoices. This is shown on the PERSONAL view only, never a workspace view.

**D2: Splitting Hours Across Workspaces (REQ-1)**
There is **NO split option**. The system does not track customer cost-sharing consent, so the system only records actual time worked per workspace, allowing the same physical hour to be billed to multiple workspaces simultaneously if the user chooses to enter it in both.

**D3: Working-Time Limit Warnings (REQ-2)**
The working-time warning is a **person-only UI warning** based on actual time versus a person-set limit. There is no reporting of this limit or warning to any workspace, and no data is shared with the foremen.

**D4: Retaining Access After Leaving a Workspace (REQ-4)**
A leaver keeps a read-only receipt of their own hours (days/weeks, hours, workspace name, job/site label, approval state, and approver). They do NOT keep the workspace content behind them. 

## 4. Architectural Dependency: The Personal Realm (Spec 119)
As decided by the owner, there will be a **Personal Realm** (a person-level layer above workspaces), which will be defined in a separate **Spec 119**. 
For Spec 118, the following components **live in the Personal Realm** (and do not need to be designed here):
- The cross-workspace unified view.
- The person's limit setting (for the working-time warnings).
- The leaver's read-only receipts of their own past hours.

<!-- version: 0.5.0 · updated: 2026-10-10 · last-edit: 2026-10-10T10:46:00Z -->
