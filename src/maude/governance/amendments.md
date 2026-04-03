---
title: "Amendment Log"
type: governance
version: 1.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-29
---

# Amendment Log

Tracks all constitutional amendments per Article VIII requirements.
The Constitution version increments with each ratified amendment.

---

## Constitutional Convention — 2026-03-06

**Version:** v3.0.0 → v4.0.0
**Ratified:** 2026-03-15
**Migration map:** `governance/MAPPING.md`

### Amendment A2 — Demote Code Quality to Federal Standard

**Proposal:** Move code quality rules from Article VII to a Federal
Standard (`standards/code-quality.md`).

**Rationale:** Engineering style is convention, not supreme law.
Implementation details (dead code removal, duplication preferences)
belong at the standards level where they can evolve without
constitutional amendment.

**Impact:** Article VII renumbered. Former Art. VIII (Enforcement) →
Art. VII. Former Art. IX (Amendments) → Art. VIII.

### Amendment A3 — Executive Authority via Negative Enumeration

**Proposal:** Rewrite Art. I Sec. 2 to grant the Executive full
operational authority with 6 explicit hard limits, rather than
enumerating permitted actions.

**Rationale:** Positive enumeration (listing what the Executive CAN
do) creates gaps. Negative enumeration (listing what it CANNOT do)
is more robust — anything not prohibited is permitted.

**Hard limits established:**
1. Cannot modify constitution or standards
2. Cannot destroy production data without Management approval
3. Cannot override Room sovereignty
4. Cannot act without audit trail
5. Cannot delegate executive authority
6. Cannot bypass guards

### Amendment A4 — Representation Enhanced

**Proposal:** Strengthen Bill of Rights Article VI (Representation)
with a 24-hour objection window and mandatory documented rationale
for overrides.

**Rationale:** "Right to be heard" is meaningless without
consequences. The objection mechanism gives Rooms actual power to
pause cross-cutting changes.

**Impact:** Objections now suspend triggering changes for 24 hours
pending Management review. Silence after 24 hours = approval.
Overrides require documented rationale in audit log.

### Amendment A7 — Bill of Rights Remedies Section

**Proposal:** Add a self-executing Remedies section to the Bill of
Rights.

**Rationale:** "A right without a remedy is a suggestion." Remedies
must be automatic (not requiring Management initiation) to be
effective.

**Impact:** Three-tier enforcement: immediate halt/rollback,
24-hour justification requirement, Excommunicado review for
unjustified violations. Anti-retaliation clause added.

---

## Corrections — 2026-03-29

**Version:** v4.0.0 (no version bump — corrections, not amendments)

### Bill of Rights Citation Fixes

- Fixed dangling reference: "Article IX" → "Article VIII" (Art. IX
  no longer exists after A2 renumbering)
- Fixed Excommunicado citation: "Art. VIII Sec. 3" → "Art. VII
  Sec. 3" (Excommunicado is in Enforcement, not Amendments)

### Registry Corrections

- Fixed site locations in registry
- Added `status` field to all sites (operational, pre-operational,
  satellite)
- Filled all empty `mcp_port` fields (18 rooms)
- Fixed document search routing port in entity map generator

### Agent Corrections

- Updated site-specific regulatory references to correct jurisdictions

---

## Ratified Amendments — 2026-03-29

**Version:** v4.0.0 → v4.1.0
**Ratified:** 2026-03-29
**Convention:** Constitutional convention audit

### Amendment P1 — Enrich Article VI (Data)

**Status:** RATIFIED
**Article:** VI — Data
**Proposed by:** Constitutional convention audit, 2026-03-29

**Problem:** Article VI has only 3 sections (domain isolation, schema
integrity, transaction integrity). The audit found no constitutional
provisions for data retention, data classification, cross-site
replication, or data archival. The `database-access.md` standard
compensates at implementation level, but constitutional principles
should be more complete.

**Proposed additions:**

**Section 4. Data Retention**

Data has a lifecycle. Retention policies define how long data is
kept and when it transitions to archival or disposal.

- Every data store with time-series or transactional data must
  have a documented retention policy.
- Retention policies are enforced automatically, not by manual
  intervention.
- Disposal follows Article IV — data is archived, not destroyed,
  unless Management explicitly authorizes destruction.

**Section 5. Data Classification**

Not all data carries equal sensitivity or consequence.

- Data is classified by its sensitivity and regulatory
  requirements at the time of creation.
- Classification determines access controls, backup frequency,
  and retention obligations.
- Reclassification requires the same audit trail as any other
  state-modifying action (Article III).

**Section 6. Cross-Site Replication**

When data is replicated across sites, sovereignty rules still apply.

- The originating site retains authority over the canonical copy.
  Replicas are read-only unless explicitly delegated.
- Replication does not transfer ownership. Site sovereignty
  (Article II Sec. 4) applies to replicated data.
- Replication agreements document what is replicated, how
  frequently, and who has authority over conflict resolution.

**Rationale:** The organization operates across multiple sites with active backup
replication (Site-A to Site-B daily). Without constitutional guidance, data
replication operates on convention alone. Article VI should establish
principles that prevent data sovereignty violations during
replication, ensure retention compliance, and clarify classification
responsibilities.

**Impact:** Adds 3 sections to Article VI. No changes to existing
sections. No renumbering required.

---

### Amendment P2 — Room Decommission Process (Article II)

**Status:** RATIFIED
**Article:** II — Sovereignty, new Section 7
**Proposed by:** Constitutional convention audit, 2026-03-29

**Problem:** Article II Sec. 6 covers Room admission but there is
no corresponding process for Room retirement or decommission. The
constitution currently covers how Rooms are born but not how they
gracefully exit.

**Proposed addition:**

**Section 7. Retirement of Rooms**

A Room may be retired when its purpose is fulfilled, superseded,
or no longer required.

- Retirement requires stated reason in the audit log and
  notification to all consumers listed in the Room's registry
  entry.
- A Room's territory (data, configuration, knowledge) is
  archived per Article IV Sec. 4 — never destroyed.
- Consumer dependencies must be resolved before retirement
  completes. A Room with active consumers cannot be retired
  without those consumers acknowledging the change.
- The Room's registry entry is marked as retired, not removed.
  Identity persists even after retirement (Bill of Rights,
  Right I).
- Retirement follows the same blast radius assessment required
  by Article IV Sec. 3.

**Rationale:** A data collection project was archived in 2026-03-26 (tools
moved to a successor room, memory to the control plane). This was done correctly but
without constitutional guidance. As the infrastructure grows, Room
retirement will become more common. A defined process prevents data
loss, consumer breakage, and identity confusion.

**Impact:** Adds 1 section to Article II. No changes to existing
sections. No renumbering required.
