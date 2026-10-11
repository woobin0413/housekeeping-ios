# Recognition fixtures

Automated recognition tests use synthetic JSON responses constructed in
`supabase/tests/functions/recognition.test.ts`. They never call a provider and contain no image,
credential, signed URL, or personal data.

The fixture cases cover:

- a single generic product with absent brand and model;
- multiple products reported as `UNRECOGNIZED`;
- refusal content outside the requested JSON schema;
- invalid JSON, missing fields, inconsistent outcomes, incomplete output, and invalid usage;
- a bounded timeout and a database-checkpoint ambiguity that must not repeat provider work.

Representative image evaluation belongs to task 23. Add only authorized, non-personal or licensed
images there, with provenance and expected-review metadata in the separate evaluation manifest.
No actual provider response body should be committed or logged.

The tracked `manifest.example.json` defines the required five-category, 40-image shape. Copy it into
the ignored `evaluation/` directory before adding images. The bounded runner and approval process are
documented in [`docs/recognition-evaluation.md`](../../docs/recognition-evaluation.md).
