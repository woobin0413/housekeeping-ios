import { createClient } from "@supabase/supabase-js";
import { cleanupLimit, runCleanup } from "./cleanup.ts";

const headers = { "Cache-Control": "no-store", "Content-Type": "application/json" };

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
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > 256)) throw new Error();
  const reader = request.body?.getReader();
  if (!reader) throw new Error();
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > 256) {
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

Deno.serve(async (request) => {
  const path = new URL(request.url).pathname.replace(/\/+$/, "");
  if (path !== "/cleanup" && path !== "/functions/v1/cleanup") {
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

  let limit: number;
  try {
    limit = cleanupLimit(await input(request));
  } catch {
    return failure(422, "VALIDATION_ERROR");
  }

  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  try {
    const result = await runCleanup({
      async enqueueExpired(batchSize) {
        const { error } = await admin.rpc("enqueue_expired_photos", {
          p_input: { limit: batchSize },
        });
        if (error) throw new Error("DATABASE_ERROR");
      },
      async claim(batchSize) {
        const { data, error } = await admin.rpc("claim_photo_cleanup", {
          p_input: { limit: batchSize },
        });
        if (error) throw new Error("DATABASE_ERROR");
        return data;
      },
      async removeObject(objectKey) {
        const { error } = await admin.storage.from("purchase-photos").remove([objectKey]);
        if (error) throw new Error("STORAGE_ERROR");
      },
      async finish(jobId, succeeded, errorCode) {
        const body: Record<string, unknown> = { jobId, succeeded };
        if (errorCode) body.errorCode = errorCode;
        const { error } = await admin.rpc("finish_photo_cleanup", { p_input: body });
        if (error) throw new Error("DATABASE_ERROR");
      },
    }, limit);
    return reply(200, result);
  } catch {
    return failure(500, "INTERNAL_ERROR", true);
  }
});
