---
title: "Article V — Credentials"
type: constitution
article: V
version: 4.0.0
authors:
  - "John Broadway"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-06
status: SUPREME LAW
---

# Article V — Credentials

Trust is never implicit within Maude. Every credential is a
contract: scoped, auditable, and revocable.

---

## Section 1. No Open Borders

Every system, service, and Room holds its own credentials. A key to
one Room does not open another.

- Shared credentials across trust boundaries are forbidden.

## Section 2. Credentials Are Contracts

Service-to-service credentials are issued with explicit scope, purpose,
and expiration.

- When the terms are fulfilled or the relationship ends, the
  credential is retired.
- Credentials carry terms that are honored by all parties.

## Section 3. Production and Development Separation

Production credentials are a separate domain from development.

- A development credential must not unlock production resources.
- Production access is granted deliberately, not inherited.

## Section 4. Credentials Never Travel in the Open

Source code, configuration files, logs, terminal output, commit
history — credentials must not appear in any of these. Ever.

## Section 5. Issuance Authority

Credentials are issued by system administrators, not self-provisioned.

- The Management grants access. Services do not mint their own keys
  to other services.

## Section 6. Auditability

All credential usage is auditable.

- Who used what credential, when, from where, and why.
- If credential usage cannot be audited, the credential should not
  exist.

## Section 7. Revoke First

When a credential is compromised, it is revoked immediately.

- Root cause analysis happens after the breach is contained, not
  before.

## Section 8. Rotatability

No system may be designed such that rotating a credential requires
redesign.

- Hardwired secrets are architectural debt.
