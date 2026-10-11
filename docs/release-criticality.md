# Open-task criticality

Status: measured September 14, 2026 against the approved core release in `spec.md`. Work is limited
to the critical chain below. Recognition stays disabled until its separate evaluation passes.

## Method

Each open task is scored from 0–3 on four release effects: core availability, security/privacy,
data/recovery, and release proof. A task is **critical** when its total is at least 7 or any single
effect is 3. A lower-scoring task is deferred when the implemented fallback preserves the core
release. This is a release-priority score, not an estimate of engineering effort.

| Task | Availability | Security/privacy | Data/recovery | Release proof | Total | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 05 — Cloud/device search timing | 1 | 0 | 0 | 2 | 3 | Fold measurement into task 27; no separate work |
| 23 — Recognition evaluation | 0 | 2 | 0 | 0 | 2 | Defer with provider unconfigured and manual fallback enabled |
| 24 — Cloud target and onboarding | 3 | 3 | 1 | 3 | 10 | **Critical** |
| 25 — Removal, cleanup, and restore | 1 | 3 | 3 | 3 | 10 | **Critical** |
| 26 — Private installation | 3 | 1 | 0 | 3 | 7 | **Critical** |
| 27 — Two-phone acceptance | 2 | 3 | 3 | 3 | 11 | **Critical** |

Task 05 has working search/pagination and a wide local warm margin: database p95 5.616 ms and local
HTTP p95 8.600 ms against the 500 ms server target. Its missing cloud/cold/device measurement remains
visible in AC-09 and is collected during task 27 because that environment does not exist before tasks
24 and 26.

Task 23 is conditional. The product specification calls recognition optional, and the implemented
failure path preserves manual entry and photo saving. The cloud deployment must omit all recognition
provider secrets and spending configuration. Enabling paid recognition changes task 23 to critical
and requires its authorized 40-image evaluation first.

## Critical execution order

1. Task 24: audit the exact hosted project, apply reviewed configuration/migrations/functions, and
   provision the two verified members.
2. Task 25: prove membership revocation, household closure, object cleanup, and separate records/image
   restore procedures in an isolated environment.
3. Task 26: select and configure the private signing/distribution route, then install the exact build
   on both authorized phones.
4. Task 27: run the acceptance matrix, including task 05's remaining cloud/device timing evidence.

Tasks 24 and 26 need external targets. Task 25 can be designed and tested locally, but its live
backup/restore acceptance waits for the isolated cloud environment created under task 24. Task 27
cannot close until both phones and all preceding critical controls are available.
