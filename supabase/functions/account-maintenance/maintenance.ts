export type MaintenanceInput =
  | {
    action: "removeMember";
    confirmation: "REMOVE MEMBER";
    householdId: string;
    operationId: string;
    userId: string;
  }
  | {
    action: "closeHousehold";
    confirmation: "CLOSE HOUSEHOLD";
    householdId: string;
    operationId: string;
  };

export interface TransferJob {
  byteSize: number;
  checksum: string;
  jobId: string;
  sourceObjectKey: string;
  stagingObjectKey: string;
}

export interface TransferDependencies {
  copy(source: string, destination: string): Promise<void>;
  download(key: string): Promise<Uint8Array | null>;
  finish(jobId: string, succeeded: boolean, errorCode?: string): Promise<void>;
  move(source: string, destination: string): Promise<void>;
  remove(key: string): Promise<void>;
}

const uuidText = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const uuidPattern = new RegExp(`^${uuidText}$`, "i");
const sourceKeyPattern = new RegExp(`^${uuidText}/${uuidText}/${uuidText}\\.jpg$`, "i");
const stagingKeyPattern = new RegExp(`^\\.account-transfer/${uuidText}/${uuidText}\\.jpg$`, "i");

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("VALIDATION_ERROR");
  }
  return value as Record<string, unknown>;
}

function exactKeys(value: Record<string, unknown>, keys: string[]): void {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error("VALIDATION_ERROR");
  }
}

function uuid(value: unknown): string {
  if (typeof value !== "string" || !uuidPattern.test(value)) throw new Error("VALIDATION_ERROR");
  return value.toLowerCase();
}

export function maintenanceInput(value: unknown): MaintenanceInput {
  const input = record(value);
  if (input.action === "removeMember") {
    exactKeys(input, ["action", "confirmation", "householdId", "operationId", "userId"]);
    if (input.confirmation !== "REMOVE MEMBER") throw new Error("VALIDATION_ERROR");
    return {
      action: "removeMember",
      confirmation: "REMOVE MEMBER",
      householdId: uuid(input.householdId),
      operationId: uuid(input.operationId),
      userId: uuid(input.userId),
    };
  }
  if (input.action === "closeHousehold") {
    exactKeys(input, ["action", "confirmation", "householdId", "operationId"]);
    if (input.confirmation !== "CLOSE HOUSEHOLD") throw new Error("VALIDATION_ERROR");
    return {
      action: "closeHousehold",
      confirmation: "CLOSE HOUSEHOLD",
      householdId: uuid(input.householdId),
      operationId: uuid(input.operationId),
    };
  }
  throw new Error("VALIDATION_ERROR");
}

export function transferJobs(value: unknown, limit: number): TransferJob[] {
  if (
    !Number.isSafeInteger(limit) || limit < 1 || limit > 25 || !Array.isArray(value) ||
    value.length > limit
  ) {
    throw new Error("INVALID_JOB_RESPONSE");
  }
  return value.map((candidate) => {
    const job = record(candidate);
    exactKeys(job, [
      "byteSize",
      "checksum",
      "jobId",
      "sourceObjectKey",
      "stagingObjectKey",
    ]);
    if (
      typeof job.checksum !== "string" || !/^[0-9a-f]{64}$/.test(job.checksum) ||
      !Number.isSafeInteger(job.byteSize) || (job.byteSize as number) < 1 ||
      (job.byteSize as number) > 5_242_880 || typeof job.sourceObjectKey !== "string" ||
      !sourceKeyPattern.test(job.sourceObjectKey) || typeof job.stagingObjectKey !== "string" ||
      !stagingKeyPattern.test(job.stagingObjectKey)
    ) throw new Error("INVALID_JOB_RESPONSE");
    return {
      byteSize: job.byteSize as number,
      checksum: job.checksum,
      jobId: uuid(job.jobId),
      sourceObjectKey: job.sourceObjectKey,
      stagingObjectKey: job.stagingObjectKey,
    };
  });
}

async function checksum(bytes: Uint8Array): Promise<string> {
  const input = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(input).set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", input);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function verify(bytes: Uint8Array | null, job: TransferJob): Promise<Uint8Array> {
  if (!bytes || bytes.byteLength !== job.byteSize || await checksum(bytes) !== job.checksum) {
    throw new Error("OBJECT_VERIFICATION_FAILED");
  }
  return bytes;
}

export async function transferPhoto(
  dependencies: TransferDependencies,
  job: TransferJob,
): Promise<boolean> {
  try {
    const source = await dependencies.download(job.sourceObjectKey);
    let staging = await dependencies.download(job.stagingObjectKey);
    if (!source && !staging) throw new Error("OBJECT_MISSING");
    if (source) await verify(source, job);
    if (staging) await verify(staging, job);

    if (!staging) {
      await dependencies.copy(job.sourceObjectKey, job.stagingObjectKey);
      staging = await dependencies.download(job.stagingObjectKey);
      await verify(staging, job);
    }
    if (source) await dependencies.remove(job.sourceObjectKey);
    await dependencies.move(job.stagingObjectKey, job.sourceObjectKey);
    await verify(await dependencies.download(job.sourceObjectKey), job);
    if (await dependencies.download(job.stagingObjectKey)) {
      throw new Error("STAGING_OBJECT_REMAINS");
    }
    await dependencies.finish(job.jobId, true);
    return true;
  } catch {
    await dependencies.finish(job.jobId, false, "STORAGE_TRANSFER_FAILED");
    return false;
  }
}

export async function runTransferBatch(
  dependencies: TransferDependencies,
  value: unknown,
  limit: number,
): Promise<{ failed: number; succeeded: number }> {
  let failed = 0;
  let succeeded = 0;
  for (const job of transferJobs(value, limit)) {
    if (await transferPhoto(dependencies, job)) succeeded += 1;
    else failed += 1;
  }
  return { failed, succeeded };
}
