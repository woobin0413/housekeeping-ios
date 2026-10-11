# Recognition provider adapter

Task 21 implements the vision-provider execution path without selecting a production model or
making a paid request. Task 22 now connects its editable review flow; task 23 still requires an
authorized evaluation budget and model configuration before real suggestions are enabled.

## Provider boundary

- The server accepts only the fixed `openai` provider identifier and fixed OpenAI Responses API
  origin. `OPENAI_MODEL`, `OPENAI_API_KEY`, and a conservative
  `RECOGNITION_ESTIMATED_COST_MICROUSD` are all required server settings; there is no default model,
  key, cost, or caller-controlled URL.
- The request uses one server-downloaded, checksum-verified private JPEG as an `input_image` with
  `detail: "high"`. It sets `store: false` and requests a strict JSON Schema through `text.format`,
  following the official OpenAI [image input](https://developers.openai.com/api/docs/guides/images-vision)
  and [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
  interfaces.
- The prompt permits one generic product suggestion from visible evidence. It forbids inferred
  price, purchase date, retailer, ownership, and unsupported exact brand/model claims. Text inside
  the image is treated as data rather than instructions.
- The complete fetch and bounded response read share a 25-second abort budget. Provider responses
  are capped at 64 KiB, parsed from exactly one output-text item, and validated again in TypeScript
  after strict provider-side schema enforcement. Refusal content is handled separately because the
  official API may return it outside the requested schema.

## Durable outcomes

Only service-role RPCs can finish or fail a reserved analysis. Completion rechecks current
membership, validates normalized suggestion lengths and token usage, and is idempotent only for an
identical result. Definite refusal or invalid output is stored as a stable failure. Timeout/network
ambiguity requires a new request ID and retains the reserved quota; the same request cannot invoke
the provider again. No path creates or edits a purchase.

Logs contain no image, token, object path, access token, API key, or provider response body. The
current implementation emits no provider payload logs at all.

## Verification

- All 225 pgTAP assertions pass after a clean 14-migration rebuild. Ten task-21 checks cover direct
  client denial, validated completion, idempotent/conflicting replay, usage validation, durable
  refusal, timeout ambiguity, and retained quota.
- Eleven recognition Deno tests pass. Fake responses cover explicit configuration, absent
  brand/model, multiple products, refusal, malformed/incomplete output, inconsistent usage,
  timeout, and checkpoint ambiguity without network access.
- Deno type-check, format, and lint pass. Strict `public`/`private` database lint passes after using
  the volatility PostgreSQL reports for the JSON normalization helpers.

No provider credential, actual model choice, paid request, personal image, or cloud project was
used. Task 23 remains the separate approval boundary for real evaluation and spending.
