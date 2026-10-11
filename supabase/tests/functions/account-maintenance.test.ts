import assert from "node:assert/strict";
import test from "node:test";
import {
  maintenanceInput,
  runTransferBatch,
  type TransferDependencies,
  type TransferJob,
  transferJobs,
} from "../../functions/account-maintenance/maintenance.ts";

const operationId = "11111111-1111-4111-8111-111111111111";
const householdId = "22222222-2222-4222-8222-222222222222";
const userId = "33333333-3333-4333-8333-333333333333";
const photoId = "44444444-4444-4444-8444-444444444444";
const jobId = "55555555-5555-4555-8555-555555555555";
const bytes = new TextEncoder().encode("verified jpeg fixture bytes");
const checksumInput = new ArrayBuffer(bytes.byteLength);
new Uint8Array(checksumInput).set(bytes);
const digest = await crypto.subtle.digest("SHA-256", checksumInput);
const expectedChecksum = Array.from(
  new Uint8Array(digest),
  (byte) => byte.toString(16).padStart(2, "0"),
).join("");
const job: TransferJob = {
  byteSize: bytes.byteLength,
  checksum: expectedChecksum,
  jobId,
  sourceObjectKey: `${householdId}/${userId}/${photoId}.jpg`,
  stagingObjectKey: `.account-transfer/${operationId}/${photoId}.jpg`,
};

function dependencies(initial: Record<string, Uint8Array>) {
  const objects = new Map(Object.entries(initial));
  const calls = {
    copies: [] as string[][],
    finishes: [] as Array<[string, boolean, string?]>,
    moves: [] as string[][],
    removals: [] as string[],
  };
  const value: TransferDependencies = {
    copy(source, destination) {
      calls.copies.push([source, destination]);
      const value = objects.get(source);
      if (!value || objects.has(destination)) return Promise.reject(new Error("copy failed"));
      objects.set(destination, value.slice());
      return Promise.resolve();
    },
    download(key) {
      return Promise.resolve(objects.get(key)?.slice() ?? null);
    },
    finish(id, succeeded, errorCode) {
      calls.finishes.push([id, succeeded, errorCode]);
      return Promise.resolve();
    },
    move(source, destination) {
      calls.moves.push([source, destination]);
      const value = objects.get(source);
      if (!value || objects.has(destination)) return Promise.reject(new Error("move failed"));
      objects.delete(source);
      objects.set(destination, value);
      return Promise.resolve();
    },
    remove(key) {
      calls.removals.push(key);
      objects.delete(key);
      return Promise.resolve();
    },
  };
  return { calls, objects, value };
}

test("maintenance input requires an exact destructive confirmation and shape", () => {
  assert.deepEqual(
    maintenanceInput({
      action: "removeMember",
      confirmation: "REMOVE MEMBER",
      householdId,
      operationId,
      userId,
    }),
    {
      action: "removeMember",
      confirmation: "REMOVE MEMBER",
      householdId,
      operationId,
      userId,
    },
  );
  assert.deepEqual(
    maintenanceInput({
      action: "closeHousehold",
      confirmation: "CLOSE HOUSEHOLD",
      householdId,
      operationId,
    }),
    {
      action: "closeHousehold",
      confirmation: "CLOSE HOUSEHOLD",
      householdId,
      operationId,
    },
  );
  for (
    const input of [
      { action: "removeMember", confirmation: "REMOVE MEMBER", householdId, operationId },
      { action: "removeMember", confirmation: "remove member", householdId, operationId, userId },
      { action: "closeHousehold", confirmation: "CLOSE HOUSEHOLD", householdId, operationId, x: 1 },
    ]
  ) assert.throws(() => maintenanceInput(input), /VALIDATION_ERROR/);
});

test("claimed transfer jobs are bounded and path constrained", () => {
  assert.deepEqual(transferJobs([job], 1), [job]);
  assert.throws(() => transferJobs([{ ...job, sourceObjectKey: "../foreign.jpg" }], 1));
  assert.throws(() => transferJobs([{ ...job, stagingObjectKey: job.sourceObjectKey }], 1));
  assert.throws(() => transferJobs([job, job], 1));
});

test("attached bytes stage, return to the original key, and checkpoint", async () => {
  const fake = dependencies({ [job.sourceObjectKey]: bytes });
  assert.deepEqual(await runTransferBatch(fake.value, [job], 1), { failed: 0, succeeded: 1 });
  assert.deepEqual(fake.calls.copies, [[job.sourceObjectKey, job.stagingObjectKey]]);
  assert.deepEqual(fake.calls.removals, [job.sourceObjectKey]);
  assert.deepEqual(fake.calls.moves, [[job.stagingObjectKey, job.sourceObjectKey]]);
  assert.deepEqual(fake.calls.finishes, [[job.jobId, true, undefined]]);
  assert.deepEqual(fake.objects.get(job.sourceObjectKey), bytes);
  assert.equal(fake.objects.has(job.stagingObjectKey), false);
});

test("a retry resumes from a verified staging object after source removal", async () => {
  const fake = dependencies({ [job.stagingObjectKey]: bytes });
  assert.deepEqual(await runTransferBatch(fake.value, [job], 1), { failed: 0, succeeded: 1 });
  assert.deepEqual(fake.calls.copies, []);
  assert.deepEqual(fake.calls.removals, []);
  assert.deepEqual(fake.calls.moves, [[job.stagingObjectKey, job.sourceObjectKey]]);
  assert.deepEqual(fake.calls.finishes, [[job.jobId, true, undefined]]);
});

test("missing or changed bytes fail closed and remain retryable", async () => {
  const missing = dependencies({});
  assert.deepEqual(await runTransferBatch(missing.value, [job], 1), { failed: 1, succeeded: 0 });
  assert.deepEqual(missing.calls.finishes, [[job.jobId, false, "STORAGE_TRANSFER_FAILED"]]);

  const changed = dependencies({ [job.sourceObjectKey]: new Uint8Array([1, 2, 3]) });
  assert.deepEqual(await runTransferBatch(changed.value, [job], 1), { failed: 1, succeeded: 0 });
  assert.deepEqual(changed.calls.copies, []);
  assert.deepEqual(changed.calls.removals, []);
  assert.deepEqual(changed.calls.finishes, [[job.jobId, false, "STORAGE_TRANSFER_FAILED"]]);
});
