# Local search performance baseline

Measured on 2026-09-07 with the unchanged search SQL from the initial commit. Environment: arm64 macOS, Docker Desktop / Engine 29.1.3, local Supabase CLI 2.109.1, PostgreSQL 17, and Node.js 22. These are synthetic local measurements, not physical-iPhone/cloud results.

## Method

`supabase/tests/performance/search.mjs` creates two disposable verified users and one household with 10,000 purchases. Names, descriptions, brands, and models vary across common household categories. One hundred requests vary query terms, case, cross-field tokens, literal wildcard characters, empty/no-match queries, offsets, and page sizes of 50/100. Seed sizes are representative examples, not worst-case maximum-length descriptions.

The script restarts only this project's database once, then records a first pass and a repeated warm pass of 100 calls. Server durations include SQL RPC execution and JSON generation, excluding transport. Another 100 requests measure the actual authenticated local HTTP boundary. All fixture purchases/accounts are removed afterward.

**Cache limitation:** restarting clears PostgreSQL shared buffers, but not Docker VM/host filesystem caches. Only the first request begins after that restart; subsequent first-pass requests progressively warm caches. Its p95 is not an independently cold-cache p95. We deliberately do not flush machine-wide caches or interrupt unrelated Docker projects.

## Results

| Measurement | Samples | p50 | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Database restart-first-pass | 100 | 3.227 ms | 5.809 ms | 7.620 ms |
| Warm database | 100 | 3.178 ms | 5.616 ms | 5.987 ms |
| Warm local HTTP | 100 | 5.514 ms | 8.600 ms | 15.421 ms |

The first search after restart took 5.809 ms. Warm database p95 is below the 500 ms budget; local HTTP p95 is below the 1,500 ms local check. The performance skill's measure-first workflow found no reason to change the query or add caching. The script asserts those warm budgets on each run.

## Reproduce

Run alone: this benchmark restarts HouseKeeping's database and must not overlap other project-local tests or development requests.

```sh
node scripts/start-local.mjs
node supabase/tests/performance/search.mjs
supabase stop
```

Set `HK_SUPABASE_CLI` to a complete trusted installation if it is not on PATH. No cloud target, real credentials, or real inventory is accepted. Full AC-09 remains pending independently cold measurements on an approved deployment target and end-to-end tests on a physical iPhone over a measured connection.
