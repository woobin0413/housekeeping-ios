import assert from "node:assert/strict";
import {
  type CleanupDependencies,
  cleanupLimit,
  runCleanup,
} from "../../functions/cleanup/cleanup.ts";

const jobA = {
  jobId: "11111111-1111-4111-8111-111111111111",
  objectKey:
    "22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/44444444-4444-4444-8444-444444444444.jpg",
};
const jobB = {
  jobId: "55555555-5555-4555-8555-555555555555",
  objectKey:
    "22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/66666666-6666-4666-8666-666666666666.jpg",
};

function dependencies(jobs: unknown, failingKeys = new Set<string>()) {
  const calls = {
    claimedLimit: 0,
    enqueuedLimit: 0,
    finishes: [] as Array<[string, boolean, string?]>,
    removals: [] as string[],
  };
  const value: CleanupDependencies = {
    enqueueExpired(limit) {
      calls.enqueuedLimit = limit;
      return Promise.resolve();
    },
    claim(limit) {
      calls.claimedLimit = limit;
      return Promise.resolve(jobs);
    },
    removeObject(key) {
      calls.removals.push(key);
      if (failingKeys.has(key)) return Promise.reject(new Error("synthetic failure"));
      return Promise.resolve();
    },
    finish(id, succeeded, errorCode) {
      calls.finishes.push([id, succeeded, errorCode]);
      return Promise.resolve();
    },
  };
  return { calls, value };
}

Deno.test("cleanup input requires exactly one bounded integer limit", () => {
  assert.equal(cleanupLimit({ limit: 1 }), 1);
  assert.equal(cleanupLimit({ limit: 25 }), 25);
  for (const input of [{}, { limit: 0 }, { limit: 26 }, { limit: 1.5 }, { limit: 1, x: 2 }]) {
    assert.throws(() => cleanupLimit(input), /VALIDATION_ERROR/);
  }
});

Deno.test("successful and already-missing objects complete idempotently", async () => {
  const fake = dependencies([jobA, jobB]);
  const result = await runCleanup(fake.value, 2);
  assert.deepEqual(result, { claimed: 2, failed: 0, succeeded: 2 });
  assert.deepEqual(fake.calls.removals, [jobA.objectKey, jobB.objectKey]);
  assert.deepEqual(fake.calls.finishes, [[jobA.jobId, true, undefined], [
    jobB.jobId,
    true,
    undefined,
  ]]);
  assert.equal(fake.calls.enqueuedLimit, 2);
  assert.equal(fake.calls.claimedLimit, 2);
});

Deno.test("transient Storage failure is recorded and later jobs continue", async () => {
  const fake = dependencies([jobA, jobB], new Set([jobA.objectKey]));
  const result = await runCleanup(fake.value, 2);
  assert.deepEqual(result, { claimed: 2, failed: 1, succeeded: 1 });
  assert.deepEqual(fake.calls.finishes, [
    [jobA.jobId, false, "STORAGE_DELETE_FAILED"],
    [jobB.jobId, true, undefined],
  ]);
});

Deno.test("malformed claimed jobs never reach Storage", async () => {
  const fake = dependencies([{ ...jobA, objectKey: "../foreign.jpg" }]);
  await assert.rejects(() => runCleanup(fake.value, 1), /INVALID_JOB_RESPONSE/);
  assert.deepEqual(fake.calls.removals, []);
  assert.deepEqual(fake.calls.finishes, []);

  const oversized = dependencies([jobA, jobB]);
  await assert.rejects(() => runCleanup(oversized.value, 1), /INVALID_JOB_RESPONSE/);
  assert.deepEqual(oversized.calls.removals, []);
  assert.deepEqual(oversized.calls.finishes, []);
});

Deno.test("checkpoint failure surfaces for lease-based retry", async () => {
  const fake = dependencies([jobA]);
  const outcomes: boolean[] = [];
  fake.value.finish = (_id, succeeded) => {
    outcomes.push(succeeded);
    return Promise.reject(new Error("synthetic database outage"));
  };
  await assert.rejects(() => runCleanup(fake.value, 1), /synthetic database outage/);
  assert.deepEqual(outcomes, [true]);
});
