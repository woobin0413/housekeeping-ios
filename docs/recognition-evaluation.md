# Recognition evaluation

Status: task 23 is prepared but not executed. No provider credential, paid request, representative
evaluation dataset, or model pin has been used. The remaining step requires an authorized 40-image
dataset and explicit approval of the exact dataset digest and one-dollar maximum spend.

## Proposed candidates and budget

The proposed comparison uses `gpt-5.6-luna` and `gpt-5.6-terra`. Official OpenAI documentation
describes Luna as the cost-sensitive GPT-5.6 tier and Terra as the tier balancing intelligence and
cost. Both accept image input through the Responses API and support structured output. Current
standard rates are $0.20/$1.20 per million input/output tokens for Luna and $2/$12 for Terra:

- [GPT-5.6 Luna model](https://developers.openai.com/api/docs/models/gpt-5.6-luna)
- [GPT-5.6 Terra model](https://developers.openai.com/api/docs/models/gpt-5.6-terra)
- [Image input sizing and token calculation](https://developers.openai.com/api/docs/guides/images-vision#calculating-costs)

The runner reserves 5,000 micro-USD per Luna request and 15,000 micro-USD per Terra request. Forty
requests to each model therefore reserve $0.80 under a hard $1.00 ceiling. It executes sequentially,
persists a sanitized checkpoint after every request, and never writes a raw provider response. The
calculated usage cost comes from returned input/output usage. Failed requests without usage remain
covered by the conservative reservation; the final report must reconcile the provider billing total.
Price changes require a code and manifest review before another approval.

## Dataset contract

Copy `fixtures/recognition/manifest.example.json` to the ignored
`fixtures/recognition/evaluation/manifest.json` and place its JPEGs in the adjacent ignored `images`
directory. The manifest requires at least eight cases in each category:

- labeled packaging;
- unbranded single objects;
- poor lighting;
- small labels;
- multiple products.

Every entry must state its provenance as synthetic, licensed, or user-owned non-personal material
and affirm that it contains no personal data. The runner rejects missing categories, duplicate IDs,
unexpected outcomes, unapproved models, paths outside the dataset, non-JPEG data, images over 5 MiB,
and budgets above one dollar. Images and detailed results stay ignored and machine-local.

## Approval and execution

Use the same pinned Deno toolchain as the recognition function. Validation reads the complete
dataset, makes no provider request, and prints the SHA-256 digest that binds approval to the exact
manifest bytes:

```sh
deno run --config supabase/functions/media/deno.json \
  --allow-read=fixtures/recognition/evaluation \
  scripts/evaluate-recognition.ts validate \
  fixtures/recognition/evaluation/manifest.json
```

After the user approves that digest, both model IDs, the listed images, and the $1 ceiling, set the
approval digest and API key only in the local process environment. The digest covers the manifest
and the SHA-256 hash of every validated image, so replacing any input invalidates approval. Never put the API key in the
manifest, command history, repository, or chat. The paid command additionally limits network access
to the fixed provider host and writes checkpointed, sanitized results under `/tmp`:

```sh
deno run --config supabase/functions/media/deno.json \
  --allow-read=fixtures/recognition/evaluation \
  --allow-write=/private/tmp \
  --allow-env=HK_RECOGNITION_EVALUATION_APPROVAL,OPENAI_API_KEY \
  --allow-net=api.openai.com \
  scripts/evaluate-recognition.ts run \
  fixtures/recognition/evaluation/manifest.json \
  /private/tmp/housekeeping-recognition.results.json
```

## Review and release decision

The local result contains only the strict product suggestion, sanitized error code, duration, token
usage, computed cost, and blank manual-review fields. A reviewer must inspect every result against
its source image and fill in name/description usefulness and unsupported brand/model claim flags.
Scoring refuses incomplete reviews:

```sh
deno run --config supabase/functions/media/deno.json \
  --allow-read=/private/tmp --allow-write=/private/tmp \
  scripts/evaluate-recognition.ts score \
  /private/tmp/housekeeping-recognition.results.json \
  /private/tmp/housekeeping-recognition.summary.json
```

AC-10 passes only when p95 request latency is at most 15 seconds. AC-11 passes only when at least
90% of single-product cases have a useful editable name/description and there are zero unsupported
brand/model claims. Eligibility also requires every multiple-product case to return `UNRECOGNIZED`
and zero provider errors. If neither candidate passes, task 23 remains open and the release criteria
are not weakened.
