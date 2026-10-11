export interface CleanupJob {
  jobId: string;
  objectKey: string;
}

export interface CleanupDependencies {
  enqueueExpired(limit: number): Promise<void>;
  claim(limit: number): Promise<unknown>;
  removeObject(objectKey: string): Promise<void>;
  finish(jobId: string, succeeded: boolean, errorCode?: string): Promise<void>;
}

export interface CleanupResult {
  claimed: number;
  failed: number;
  succeeded: number;
}

const uuidText = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const uuidPattern = new RegExp(`^${uuidText}$`, "i");
const objectKeyPattern = new RegExp(`^${uuidText}/${uuidText}/${uuidText}\\.jpg$`, "i");

export function cleanupLimit(input: unknown): number {
  if (
    !input || typeof input !== "object" || Array.isArray(input) ||
    Object.keys(input).length !== 1 || !("limit" in input)
  ) throw new Error("VALIDATION_ERROR");
  const limit = (input as { limit?: unknown }).limit;
  if (!Number.isSafeInteger(limit) || (limit as number) < 1 || (limit as number) > 25) {
    throw new Error("VALIDATION_ERROR");
  }
  return limit as number;
}

function cleanupJobs(value: unknown, limit: number): CleanupJob[] {
  if (!Array.isArray(value) || value.length > limit) {
    throw new Error("INVALID_JOB_RESPONSE");
  }
  return value.map((candidate) => {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
      throw new Error("INVALID_JOB_RESPONSE");
    }
    const job = candidate as Record<string, unknown>;
    if (
      Object.keys(job).length !== 2 || typeof job.jobId !== "string" ||
      typeof job.objectKey !== "string" || !uuidPattern.test(job.jobId) ||
      !objectKeyPattern.test(job.objectKey)
    ) throw new Error("INVALID_JOB_RESPONSE");
    return { jobId: job.jobId, objectKey: job.objectKey };
  });
}

export async function runCleanup(
  dependencies: CleanupDependencies,
  limit: number,
): Promise<CleanupResult> {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 25) {
    throw new Error("VALIDATION_ERROR");
  }
  await dependencies.enqueueExpired(limit);
  const jobs = cleanupJobs(await dependencies.claim(limit), limit);
  let failed = 0;
  let succeeded = 0;
  for (const job of jobs) {
    try {
      await dependencies.removeObject(job.objectKey);
    } catch {
      await dependencies.finish(job.jobId, false, "STORAGE_DELETE_FAILED");
      failed += 1;
      continue;
    }
    await dependencies.finish(job.jobId, true);
    succeeded += 1;
  }
  return { claimed: jobs.length, failed, succeeded };
}
