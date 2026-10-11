import { createClient } from "@supabase/supabase-js";
import { runCleanup } from "../cleanup/cleanup.ts";
import { maintenanceInput, runTransferBatch } from "./maintenance.ts";

const headers = { "Cache-Control": "no-store", "Content-Type": "application/json" };
const transferLimit = 10;
const cleanupLimit = 25;

function reply(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

function failure(status: number, code: string, retryable = false): Response {
  return reply(status, { code, message: code, requestId: crypto.randomUUID(), retryable });
}

function sameSecret(left: string | undefined, right: string): boolean {
  if (!left) return false;
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  if (a.byteLength !== b.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < a.byteLength; index += 1) difference |= a[index] ^ b[index];
  return difference === 0;
}

async function input(request: Request): Promise<unknown> {
  const declared = request.headers.get("Content-Length");
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > 512)) throw new Error();
  const reader = request.body?.getReader();
  if (!reader) throw new Error();
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > 512) {
      await reader.cancel();
      throw new Error();
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder().decode(bytes));
}

function missing(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const status = (error as { status?: unknown; statusCode?: unknown }).statusCode ??
    (error as { status?: unknown }).status;
  return status === 404 || status === "404";
}

Deno.serve(async (request) => {
  const path = new URL(request.url).pathname.replace(/\/+$/, "");
  if (path !== "/account-maintenance" && path !== "/functions/v1/account-maintenance") {
    return failure(404, "NOT_FOUND");
  }
  if (request.method !== "POST") return failure(405, "METHOD_NOT_ALLOWED");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = request.headers.get("Authorization");
  if (!serviceKey || !sameSecret(authorization ?? undefined, `Bearer ${serviceKey}`)) {
    return failure(401, "UNAUTHENTICATED");
  }
  const url = Deno.env.get("SUPABASE_URL");
  if (!url) return failure(500, "INTERNAL_ERROR", true);

  let body: ReturnType<typeof maintenanceInput>;
  try {
    body = maintenanceInput(await input(request));
  } catch {
    return failure(422, "VALIDATION_ERROR");
  }
  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const rpc = async (name: string, value: Record<string, unknown>): Promise<unknown> => {
    const { data, error } = await admin.rpc(name, { p_input: value });
    if (error) throw new Error("DATABASE_ERROR");
    return data;
  };

  try {
    const operation = body.action === "removeMember"
      ? await rpc("begin_member_removal", {
        operationId: body.operationId,
        householdId: body.householdId,
        userId: body.userId,
      }) as Record<string, unknown>
      : await rpc("begin_household_closure", {
        operationId: body.operationId,
        householdId: body.householdId,
      }) as Record<string, unknown>;
    if (operation.state === "COMPLETED") {
      return reply(200, {
        status: "COMPLETED",
        cleanup: { claimed: 0, failed: 0, succeeded: 0 },
        transfers: { failed: 0, succeeded: 0 },
      });
    }

    const bucket = admin.storage.from("purchase-photos");
    const claimed = body.action === "removeMember"
      ? await rpc("claim_account_photo_transfers", {
        operationId: body.operationId,
        limit: transferLimit,
      })
      : [];
    const transfers = await runTransferBatch(
      {
        async copy(source, destination) {
          const { error } = await bucket.copy(source, destination);
          if (error) throw error;
        },
        async download(key) {
          const { data, error } = await bucket.download(key);
          if (error) {
            if (missing(error)) return null;
            throw error;
          }
          return new Uint8Array(await data.arrayBuffer());
        },
        async finish(jobId, succeeded, errorCode) {
          const value: Record<string, unknown> = { jobId, succeeded };
          if (errorCode) value.errorCode = errorCode;
          await rpc("finish_account_photo_transfer", value);
        },
        async move(source, destination) {
          const { error } = await bucket.move(source, destination);
          if (error) throw error;
        },
        async remove(key) {
          const { error } = await bucket.remove([key]);
          if (error) throw error;
        },
      },
      claimed,
      transferLimit,
    );

    const cleanup = await runCleanup({
      async enqueueExpired(limit) {
        await rpc("enqueue_expired_photos", { limit });
      },
      async claim(limit) {
        return await rpc("claim_photo_cleanup", { limit });
      },
      async removeObject(objectKey) {
        const { error } = await bucket.remove([objectKey]);
        if (error) throw error;
      },
      async finish(jobId, succeeded, errorCode) {
        const value: Record<string, unknown> = { jobId, succeeded };
        if (errorCode) value.errorCode = errorCode;
        await rpc("finish_photo_cleanup", value);
      },
    }, cleanupLimit);

    const readiness = await rpc("account_operation_readiness", {
      operationId: body.operationId,
    }) as Record<string, unknown>;
    if (readiness.readyForIdentityDeletion === true) {
      const subjects = readiness.subjectUserIds;
      if (!Array.isArray(subjects) || subjects.some((value) => typeof value !== "string")) {
        throw new Error("DATABASE_ERROR");
      }
      for (const userId of subjects as string[]) {
        const { error } = await admin.auth.admin.deleteUser(userId);
        if (error) {
          const { data, error: lookupError } = await admin.auth.admin.getUserById(userId);
          if (data.user || (lookupError && !missing(lookupError))) {
            throw new Error("AUTH_DELETE_FAILED");
          }
        }
      }
      await rpc("finish_account_operation", { operationId: body.operationId });
      return reply(200, {
        status: "COMPLETED",
        cleanup,
        transfers,
      });
    }
    return reply(202, {
      status: "IN_PROGRESS",
      cleanup,
      transfers,
      pending: {
        ownedObjects: readiness.ownedObjectCount,
        photos: readiness.photoPending,
        transfers: readiness.transferPending,
      },
    });
  } catch {
    return failure(500, "OPERATION_FAILED", true);
  }
});
