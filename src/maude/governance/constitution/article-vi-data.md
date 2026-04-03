---
title: "Article VI — Data"
type: constitution
article: VI
version: 4.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-29
status: SUPREME LAW
---

# Article VI — Data

Every data store serves a single domain. Data does not cross domain
boundaries through shared stores, cross-domain queries, or commingled
schemas. Data sovereignty parallels Room sovereignty — each domain owns
its data completely.

---

## Section 1. Domain Isolation

Each data store has a defined purpose and scope.

- Data from one domain must not be stored in or queried through
  another domain's store.
- Domain boundaries are enforced architecturally, not by convention
  alone.
- Cross-domain data needs are served through sanctioned interfaces,
  never through direct access to another domain's store.

## Section 2. Schema Integrity

Production schemas are protected assets.

- Before altering any production schema, a verified backup must
  exist. No exceptions.
- The backup is verified before the change begins, not after.
- Schema changes follow the same blast radius and consent rules
  as any other cross-cutting change (Article IV).

## Section 3. Transaction Integrity

Multi-statement writes must use explicit transactions.

- Partial writes are unacceptable. Either the entire operation
  succeeds or none of it does.
- Transaction boundaries align with logical operation boundaries.

## Section 4. Data Retention

Data has a lifecycle. Retention policies define how long data is
kept and when it transitions to archival or disposal.

- Every data store with time-series or transactional data must have
  a documented retention policy.
- Retention policies are enforced automatically, not by manual
  intervention.
- Disposal follows Article IV — data is archived, not destroyed,
  unless The Management explicitly authorizes destruction.

## Section 5. Data Classification

Not all data carries equal sensitivity or consequence.

- Data is classified by its sensitivity and regulatory requirements
  at the time of creation.
- Classification determines access controls, backup frequency, and
  retention obligations.
- Reclassification requires the same audit trail as any other
  state-modifying action (Article III).

## Section 6. Cross-Site Replication

When data is replicated across sites, sovereignty rules still apply.

- The originating site retains authority over the canonical copy.
  Replicas are read-only unless explicitly delegated.
- Replication does not transfer ownership. Site sovereignty
  (Article II Sec. 4) applies to replicated data.
- Replication agreements document what is replicated, how
  frequently, and who has authority over conflict resolution.
