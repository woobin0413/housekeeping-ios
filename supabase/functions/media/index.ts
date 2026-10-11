import { createClient } from "@supabase/supabase-js";
import { ImageValidationError, MAX_IMAGE_BYTES, validateImage } from "./validateImage.ts";

const jsonHeaders = { "Cache-Control": "no-store", "Content-Type": "application/json" };
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function response(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function failure(status: number, code: string, retryable = false): Response {
  return response(status, {
    code,
    message: code,
    requestId: crypto.randomUUID(),
    retryable,
  });
}

function errorStatus(code: string | undefined): number {
  switch (code) {
    case "PT401":
      return 401;
    case "PT404":
      return 404;
    case "PT409":
      return 409;
    case "PT422":
      return 422;
    default:
      return 500;
  }
}

function errorCode(status: number): string {
  switch (status) {
    case 401:
      return "UNAUTHENTICATED";
    case 404:
      return "NOT_FOUND";
    case 409:
      return "CONFLICT";
    case 422:
      return "VALIDATION_ERROR";
    default:
      return "INTERNAL_ERROR";
  }
}

function databaseFailure(error: { code?: string; message?: string }): Response {
  const status = errorStatus(error.code);
  const safeMessages = new Set([
    "CONFLICT",
    "NOT_FOUND",
    "RESERVATION_EXPIRED",
    "UPLOAD_INCOMPLETE",
    "VALIDATION_ERROR",
  ]);
  const code = safeMessages.has(error.message ?? "") ? error.message! : errorCode(status);
  return failure(status, code, status === 500 || code === "UPLOAD_INCOMPLETE");
}

async function jsonInput(request: Request): Promise<unknown> {
  const declaredLength = request.headers.get("Content-Length");
  if (declaredLength && (!/^\d+$/.test(declaredLength) || Number(declaredLength) > 4096)) {
    throw new Error("body too large");
  }

  const chunks: Uint8Array[] = [];
  let byteLength = 0;
  const reader = request.body?.getReader();
  if (!reader) throw new Error("body required");
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    byteLength += value.byteLength;
    if (byteLength > 4096) {
      await reader.cancel();
      throw new Error("body too large");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(byteLength);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder().decode(body));
}

async function hasBody(request: Request): Promise<boolean> {
  const declaredLength = request.headers.get("Content-Length");
  if (declaredLength && declaredLength !== "0") return true;
  const reader = request.body?.getReader();
  if (!reader) return false;
  while (true) {
    const { done, value } = await reader.read();
    if (done) return false;
    if (value.byteLength > 0) {
      await reader.cancel();
      return true;
    }
  }
}

function validReservation(data: unknown): data is {
  photoId: string;
  objectKey: string;
  expiresAt: string;
} {
  if (!data || typeof data !== "object") return false;
  const value = data as Record<string, unknown>;
  return typeof value.photoId === "string" && typeof value.objectKey === "string" &&
    typeof value.expiresAt === "string";
}

Deno.serve(async (request: Request) => {
  const path = new URL(request.url).pathname.replace(/\/+$/, "");
  const isReservation = path === "/media/photos" || path === "/functions/v1/media/photos";
  const completionMatch = path.match(
    /^\/(?:functions\/v1\/)?media\/photos\/([0-9a-f-]+)\/completion$/i,
  );
  const deletionMatch = path.match(
    /^\/(?:functions\/v1\/)?media\/photos\/([0-9a-f-]+)$/i,
  );
  if (!isReservation && !completionMatch && !deletionMatch) return failure(404, "NOT_FOUND");
  if (
    (deletionMatch && request.method !== "DELETE") || (!deletionMatch && request.method !== "POST")
  ) {
    return failure(405, "METHOD_NOT_ALLOWED");
  }

  const authorization = request.headers.get("Authorization");
  const token = authorization?.match(/^Bearer ([^\s]+)$/)?.[1];
  if (!token) return failure(401, "UNAUTHENTICATED");

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !key) return failure(500, "INTERNAL_ERROR", true);
  const client = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: authorization } },
  });
  const { data: authData, error: authError } = await client.auth.getUser(token);
  if (authError || !authData.user) return failure(401, "UNAUTHENTICATED");

  if (deletionMatch) {
    const photoId = deletionMatch[1].toLowerCase();
    if (!uuidPattern.test(photoId) || await hasBody(request)) {
      return failure(422, "VALIDATION_ERROR");
    }
    const { error } = await client.rpc("discard_photo", { p_input: { photoId } });
    if (error) return databaseFailure(error);
    return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
  }

  let input: unknown;
  try {
    input = await jsonInput(request);
  } catch {
    return failure(422, "VALIDATION_ERROR");
  }

  if (isReservation) {
    const { data, error } = await client.rpc("reserve_photo", { p_input: input });
    if (error) return databaseFailure(error);
    if (!validReservation(data)) return failure(500, "INTERNAL_ERROR", true);
    return response(201, data);
  }

  const photoId = completionMatch![1].toLowerCase();
  if (
    !uuidPattern.test(photoId) || !input || typeof input !== "object" ||
    Array.isArray(input) || Object.keys(input).length !== 0
  ) {
    return failure(422, "VALIDATION_ERROR");
  }
  const { data: photo, error: photoError } = await client
    .from("photos")
    .select("id,object_key,state,expires_at")
    .eq("id", photoId)
    .maybeSingle();
  if (photoError) return failure(500, "INTERNAL_ERROR", true);
  if (!photo) return failure(404, "NOT_FOUND");
  if (photo.state === "READY") return response(200, { photoId, state: "READY" });
  if (photo.state !== "RESERVED") return failure(409, "CONFLICT");
  const expiresAt = Date.parse(photo.expires_at);
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
    return failure(409, "RESERVATION_EXPIRED");
  }

  const { data: object, error: downloadError } = await client.storage
    .from("purchase-photos")
    .download(photo.object_key);
  if (downloadError || !object) return failure(409, "UPLOAD_INCOMPLETE", true);
  if (object.size > MAX_IMAGE_BYTES) return failure(422, "IMAGE_TOO_LARGE");

  let validated;
  try {
    validated = await validateImage(new Uint8Array(await object.arrayBuffer()));
  } catch (error) {
    if (error instanceof ImageValidationError) {
      const timeout = error.code === "VALIDATION_TIMEOUT";
      return failure(timeout ? 503 : 422, error.code, timeout);
    }
    return failure(500, "INTERNAL_ERROR", true);
  }

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceKey) return failure(500, "INTERNAL_ERROR", true);
  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: finalized, error: finalizeError } = await admin.rpc("finalize_photo", {
    p_input: {
      byteSize: validated.byteSize,
      checksum: validated.checksum,
      mimeType: validated.mimeType,
      photoId,
      uploaderUserId: authData.user.id,
    },
  });
  if (finalizeError) return databaseFailure(finalizeError);
  if (!finalized || finalized.photoId !== photoId || finalized.state !== "READY") {
    return failure(500, "INTERNAL_ERROR", true);
  }
  return response(200, finalized);
});
