import { createClient } from "@supabase/supabase-js";
import { providerConfiguration, ProviderError, recognizeProduct } from "./provider.ts";

const jsonHeaders = { "Cache-Control": "no-store", "Content-Type": "application/json" };
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface ProductSuggestion {
  name: string;
  description: string | null;
  brand: string | null;
  model: string | null;
}

export type RecognitionResponse =
  | {
    status: "SUGGESTED";
    analysisId: string;
    photoId: string;
    suggestion: ProductSuggestion;
  }
  | {
    status: "UNRECOGNIZED";
    analysisId: string;
    photoId: string;
    suggestion: null;
    reason: "UNCLEAR_IMAGE" | "MULTIPLE_PRODUCTS" | "NO_PRODUCT";
  };

interface RecognitionInput {
  photoId: string;
  requestId: string;
}

export interface RecognitionReservation {
  status: "RESERVED";
  analysisId: string;
  photoId: string;
  objectKey: string;
  checksum: string;
}

type ReservationResult =
  | RecognitionReservation
  | RecognitionResponse
  | {
    status: "IN_FLIGHT" | "RETRY_REQUIRED";
    analysisId: string;
    photoId: string;
    failureCode?: string;
  }
  | { status: "FAILED"; analysisId: string; photoId: string; failureCode: string };

export interface RecognitionDependencies {
  configured: boolean;
  estimatedCostMicrousd: number;
  authenticate(token: string): Promise<string | null>;
  reserve(
    input: RecognitionInput & {
      requesterUserId: string;
      estimatedCostMicrousd: number;
    },
  ): Promise<unknown>;
  execute(reservation: RecognitionReservation, token: string): Promise<unknown>;
  now?: () => Date;
}

export class RecognitionBackendError extends Error {
  constructor(public readonly databaseCode?: string, message = "") {
    super(message);
  }
}

export class RecognitionExecutionError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    public readonly retryable = false,
  ) {
    super(code);
  }
}

function response(status: number, body: unknown, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...jsonHeaders, ...headers },
  });
}

function failure(
  status: number,
  code: string,
  traceId: string,
  retryable = false,
  headers: HeadersInit = {},
): Response {
  return response(status, {
    error: { code, message: code, requestId: traceId, retryable },
  }, headers);
}

function backendFailure(error: RecognitionBackendError, traceId: string, now: Date): Response {
  switch (error.databaseCode) {
    case "PT404":
      return failure(404, "NOT_FOUND", traceId);
    case "PT409":
      return failure(
        409,
        error.message === "PHOTO_NOT_READY" ? "PHOTO_NOT_READY" : "CONFLICT",
        traceId,
      );
    case "PT422":
      return failure(422, "VALIDATION_ERROR", traceId);
    case "PT429": {
      const midnight = Date.UTC(
        now.getUTCFullYear(),
        now.getUTCMonth(),
        now.getUTCDate() + 1,
      );
      const seconds = Math.max(1, Math.ceil((midnight - now.getTime()) / 1000));
      return failure(429, "QUOTA_EXCEEDED", traceId, false, { "Retry-After": String(seconds) });
    }
    default:
      return failure(500, "INTERNAL_ERROR", traceId, true);
  }
}

async function jsonInput(request: Request): Promise<unknown> {
  const declaredLength = request.headers.get("Content-Length");
  if (declaredLength && (!/^\d+$/.test(declaredLength) || Number(declaredLength) > 4096)) {
    throw new Error("invalid body");
  }
  const reader = request.body?.getReader();
  if (!reader) throw new Error("invalid body");
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > 4096) {
        await reader.cancel();
        throw new Error("invalid body");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (!length) throw new Error("invalid body");
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(bytes));
}

function recognitionInput(value: unknown): RecognitionInput | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const object = value as Record<string, unknown>;
  if (
    Object.keys(object).length !== 2 || !("photoId" in object) || !("requestId" in object) ||
    typeof object.photoId !== "string" || typeof object.requestId !== "string" ||
    !uuidPattern.test(object.photoId) || !uuidPattern.test(object.requestId)
  ) return null;
  return { photoId: object.photoId.toLowerCase(), requestId: object.requestId.toLowerCase() };
}

function suggestion(value: unknown): value is ProductSuggestion {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const object = value as Record<string, unknown>;
  if (Object.keys(object).some((key) => !["name", "description", "brand", "model"].includes(key))) {
    return false;
  }
  return typeof object.name === "string" && object.name.length > 0 &&
    [object.description, object.brand, object.model].every(
      (field) => field === null || typeof field === "string",
    );
}

function hasExactKeys(object: Record<string, unknown>, keys: string[]): boolean {
  const actual = Object.keys(object);
  return actual.length === keys.length && keys.every((key) => key in object);
}

function reservationResult(value: unknown): ReservationResult | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const object = value as Record<string, unknown>;
  if (
    typeof object.status !== "string" || typeof object.analysisId !== "string" ||
    typeof object.photoId !== "string" || !uuidPattern.test(object.analysisId) ||
    !uuidPattern.test(object.photoId)
  ) return null;
  if (object.status === "RESERVED") {
    if (
      !hasExactKeys(object, ["status", "analysisId", "photoId", "objectKey", "checksum"]) ||
      typeof object.objectKey !== "string" || object.objectKey.length === 0 ||
      typeof object.checksum !== "string" || !/^[0-9a-f]{64}$/.test(object.checksum)
    ) return null;
    return object as unknown as RecognitionReservation;
  }
  if (object.status === "IN_FLIGHT" || object.status === "RETRY_REQUIRED") {
    const keys = ["status", "analysisId", "photoId"];
    if ("failureCode" in object) keys.push("failureCode");
    if (
      !hasExactKeys(object, keys) ||
      ("failureCode" in object && typeof object.failureCode !== "string")
    ) return null;
    return object as ReservationResult;
  }
  if (
    object.status === "FAILED" &&
    hasExactKeys(object, ["status", "analysisId", "photoId", "failureCode"]) &&
    typeof object.failureCode === "string"
  ) return object as ReservationResult;
  if (
    object.status === "SUGGESTED" &&
    hasExactKeys(object, ["status", "analysisId", "photoId", "suggestion"]) &&
    suggestion(object.suggestion)
  ) {
    return object as unknown as RecognitionResponse;
  }
  if (
    object.status === "UNRECOGNIZED" && object.suggestion === null &&
    hasExactKeys(object, ["status", "analysisId", "photoId", "suggestion", "reason"]) &&
    ["UNCLEAR_IMAGE", "MULTIPLE_PRODUCTS", "NO_PRODUCT"].includes(String(object.reason))
  ) return object as unknown as RecognitionResponse;
  return null;
}

export function createRecognitionHandler(dependencies: RecognitionDependencies) {
  return async (request: Request): Promise<Response> => {
    const traceId = crypto.randomUUID();
    const path = new URL(request.url).pathname.replace(/\/+$/, "");
    if (path !== "/recognitions" && path !== "/functions/v1/recognitions") {
      return failure(404, "NOT_FOUND", traceId);
    }
    if (request.method !== "POST") return failure(405, "METHOD_NOT_ALLOWED", traceId);

    const token = request.headers.get("Authorization")?.match(/^Bearer ([^\s]+)$/)?.[1];
    if (!token) return failure(401, "UNAUTHENTICATED", traceId);

    let requesterUserId: string | null;
    try {
      requesterUserId = await dependencies.authenticate(token);
    } catch {
      return failure(500, "INTERNAL_ERROR", traceId, true);
    }
    if (!requesterUserId || !uuidPattern.test(requesterUserId)) {
      return failure(401, "UNAUTHENTICATED", traceId);
    }

    let input: RecognitionInput | null;
    try {
      input = recognitionInput(await jsonInput(request));
    } catch {
      input = null;
    }
    if (!input) return failure(422, "VALIDATION_ERROR", traceId);
    if (!dependencies.configured) {
      return failure(503, "RECOGNITION_UNAVAILABLE", traceId, false);
    }
    if (
      !Number.isSafeInteger(dependencies.estimatedCostMicrousd) ||
      dependencies.estimatedCostMicrousd < 0 || dependencies.estimatedCostMicrousd > 1_000_000_000
    ) return failure(500, "INTERNAL_ERROR", traceId, true);

    let reserved: ReservationResult | null;
    try {
      reserved = reservationResult(
        await dependencies.reserve({
          ...input,
          requesterUserId: requesterUserId.toLowerCase(),
          estimatedCostMicrousd: dependencies.estimatedCostMicrousd,
        }),
      );
    } catch (error) {
      if (error instanceof RecognitionBackendError) {
        return backendFailure(error, traceId, (dependencies.now ?? (() => new Date()))());
      }
      return failure(500, "INTERNAL_ERROR", traceId, true);
    }
    if (!reserved) return failure(500, "INTERNAL_ERROR", traceId, true);
    if (reserved.status === "IN_FLIGHT") {
      return failure(409, "RECOGNITION_IN_PROGRESS", traceId, true);
    }
    if (reserved.status === "RETRY_REQUIRED") {
      return failure(409, "RECOGNITION_RETRY_REQUIRED", traceId, false);
    }
    if (reserved.status === "FAILED") {
      const code = ["PROVIDER_REFUSAL", "INVALID_PROVIDER_RESPONSE"].includes(
          reserved.failureCode,
        )
        ? reserved.failureCode
        : "INVALID_PROVIDER_RESPONSE";
      return failure(502, code, traceId, false);
    }
    if (reserved.status === "SUGGESTED" || reserved.status === "UNRECOGNIZED") {
      return response(200, reserved);
    }
    if (reserved.status !== "RESERVED") {
      return failure(500, "INTERNAL_ERROR", traceId, true);
    }

    let completed: ReservationResult | null;
    try {
      completed = reservationResult(await dependencies.execute(reserved, token));
    } catch (error) {
      if (error instanceof RecognitionExecutionError) {
        return failure(error.status, error.code, traceId, error.retryable);
      }
      return failure(503, "RECOGNITION_UNAVAILABLE", traceId, true);
    }
    if (
      !completed || (completed.status !== "SUGGESTED" && completed.status !== "UNRECOGNIZED") ||
      completed.analysisId !== reserved.analysisId || completed.photoId !== reserved.photoId
    ) return failure(502, "INVALID_PROVIDER_RESPONSE", traceId, false);
    return response(200, completed);
  };
}

function liveHandler() {
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const provider = providerConfiguration(Deno.env);
  const admin = url && serviceKey
    ? createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } })
    : null;
  return createRecognitionHandler({
    configured: provider !== null && admin !== null && Boolean(url && anonKey),
    estimatedCostMicrousd: provider?.estimatedCostMicrousd ?? 0,
    async authenticate(token) {
      if (!url || !anonKey) throw new Error("missing backend configuration");
      const client = createClient(url, anonKey, {
        auth: { autoRefreshToken: false, persistSession: false },
      });
      const { data, error } = await client.auth.getUser(token);
      return error ? null : data.user?.id ?? null;
    },
    async reserve(input) {
      if (!admin) throw new Error("missing backend configuration");
      const { data, error } = await admin.rpc("reserve_recognition", { p_input: input });
      if (error) throw new RecognitionBackendError(error.code, error.message);
      return data;
    },
    async execute(reservation, token) {
      if (!url || !anonKey || !admin || !provider) {
        throw new RecognitionExecutionError(503, "RECOGNITION_UNAVAILABLE");
      }
      const userClient = createClient(url, anonKey, {
        auth: { autoRefreshToken: false, persistSession: false },
        global: { headers: { Authorization: `Bearer ${token}` } },
      });
      const { data: object, error: downloadError } = await userClient.storage
        .from("purchase-photos")
        .download(reservation.objectKey);
      if (downloadError || !object) {
        throw new RecognitionExecutionError(404, "NOT_FOUND");
      }
      const bytes = new Uint8Array(await object.arrayBuffer());
      const checksum = Array.from(
        new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
        (byte) => byte.toString(16).padStart(2, "0"),
      ).join("");
      if (
        bytes.byteLength < 1 || bytes.byteLength > 5 * 1024 * 1024 ||
        checksum !== reservation.checksum
      ) {
        throw new RecognitionExecutionError(409, "PHOTO_NOT_READY");
      }

      let recognized;
      try {
        recognized = await recognizeProduct(bytes, provider);
      } catch (error) {
        if (!(error instanceof ProviderError)) throw error;
        await admin.rpc("fail_recognition", {
          p_input: {
            analysisId: reservation.analysisId,
            photoId: reservation.photoId,
            failureCode: error.code,
          },
        });
        const status = error.code === "PROVIDER_TIMEOUT"
          ? 504
          : error.code === "PROVIDER_UNAVAILABLE"
          ? 503
          : 502;
        throw new RecognitionExecutionError(status, error.code);
      }

      const result = recognized.result;
      const { data, error } = await admin.rpc("finish_recognition", {
        p_input: {
          analysisId: reservation.analysisId,
          photoId: reservation.photoId,
          state: result.outcome,
          suggestion: result.outcome === "SUGGESTED"
            ? {
              name: result.name,
              description: result.description,
              brand: result.brand,
              model: result.model,
            }
            : null,
          reason: result.reason,
          providerId: recognized.providerId,
          modelId: recognized.modelId,
          promptVersion: recognized.promptVersion,
          consumption: recognized.usage,
        },
      });
      if (error) throw new RecognitionExecutionError(503, "RECOGNITION_UNAVAILABLE");
      return data;
    },
  });
}

if (import.meta.main) Deno.serve(liveHandler());
