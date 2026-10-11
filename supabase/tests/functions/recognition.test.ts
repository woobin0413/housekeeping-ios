import assert from "node:assert/strict";
import {
  createRecognitionHandler,
  RecognitionBackendError,
  type RecognitionDependencies,
  RecognitionExecutionError,
  type RecognitionReservation,
} from "../../functions/recognitions/index.ts";
import {
  type ProviderConfiguration,
  providerConfiguration,
  ProviderError,
  recognizeProduct,
} from "../../functions/recognitions/provider.ts";
import { parseProductRecognition } from "../../functions/recognitions/schema.ts";

const userId = "11111111-1111-4111-8111-111111111111";
const photoId = "22222222-2222-4222-8222-222222222222";
const requestId = "33333333-3333-4333-8333-333333333333";
const analysisId = "44444444-4444-4444-8444-444444444444";
const reservation: RecognitionReservation = {
  status: "RESERVED",
  analysisId,
  photoId,
  objectKey: `${userId}/${userId}/${photoId}.jpg`,
  checksum: "a".repeat(64),
};
const provider: ProviderConfiguration = {
  provider: "openai",
  apiKey: "synthetic-secret",
  model: "synthetic-vision-model",
  estimatedCostMicrousd: 7,
  timeoutMs: 25,
};

function dependencies(overrides: Partial<RecognitionDependencies> = {}) {
  const calls = {
    authenticated: [] as string[],
    executed: [] as RecognitionReservation[],
    reserved: [] as unknown[],
  };
  const value: RecognitionDependencies = {
    configured: true,
    estimatedCostMicrousd: 7,
    authenticate(token) {
      calls.authenticated.push(token);
      return Promise.resolve(userId);
    },
    reserve(input) {
      calls.reserved.push(input);
      return Promise.resolve(reservation);
    },
    execute(input) {
      calls.executed.push(input);
      return Promise.resolve({
        status: "SUGGESTED",
        analysisId,
        photoId,
        suggestion: { name: "Kettle", description: null, brand: null, model: null },
      });
    },
    ...overrides,
  };
  return { calls, value };
}

function request(
  body: unknown = { photoId, requestId },
  options: { method?: string; path?: string; token?: string; rawBody?: string } = {},
) {
  const rawBody = options.rawBody ?? JSON.stringify(body);
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (options.token !== "") headers.Authorization = `Bearer ${options.token ?? "session"}`;
  return new Request(`http://localhost${options.path ?? "/recognitions"}`, {
    method: options.method ?? "POST",
    headers,
    body: options.method === "GET" ? undefined : rawBody,
  });
}

async function json(response: Response) {
  return await response.json() as Record<string, unknown>;
}

Deno.test("recognition route authenticates and validates its exact bounded input", async () => {
  const fake = dependencies();
  const handler = createRecognitionHandler(fake.value);
  assert.equal((await handler(request({}, { path: "/other" }))).status, 404);
  assert.equal((await handler(request({}, { method: "GET" }))).status, 405);
  assert.equal((await handler(request({}, { token: "" }))).status, 401);
  for (
    const body of [
      {},
      { photoId, requestId, extra: true },
      { photoId: "not-a-uuid", requestId },
      { photoId, requestId: 4 },
    ]
  ) {
    assert.equal((await handler(request(body))).status, 422);
  }
  assert.equal((await handler(request(null, { rawBody: "{" }))).status, 422);
  assert.equal((await handler(request(null, { rawBody: "x".repeat(4097) }))).status, 422);
  assert.equal(fake.calls.reserved.length, 0);
});

Deno.test("disabled provider fails before reserving quota or analysis state", async () => {
  const fake = dependencies({ configured: false });
  const result = await createRecognitionHandler(fake.value)(request());
  assert.equal(result.status, 503);
  const body = await json(result) as {
    error: { code: string; message: string; requestId: string; retryable: boolean };
  };
  assert.deepEqual(
    { code: body.error.code, message: body.error.message, retryable: body.error.retryable },
    {
      code: "RECOGNITION_UNAVAILABLE",
      message: "RECOGNITION_UNAVAILABLE",
      retryable: false,
    },
  );
  assert.match(body.error.requestId, /^[0-9a-f-]{36}$/);
  assert.equal(fake.calls.reserved.length, 0);
});

Deno.test("new authorized work carries only server-resolved reservation data", async () => {
  const fake = dependencies();
  const result = await createRecognitionHandler(fake.value)(request({
    photoId: photoId.toUpperCase(),
    requestId: requestId.toUpperCase(),
  }));
  assert.equal(result.status, 200);
  assert.deepEqual(await json(result), {
    status: "SUGGESTED",
    analysisId,
    photoId,
    suggestion: { name: "Kettle", description: null, brand: null, model: null },
  });
  assert.deepEqual(fake.calls.reserved, [{
    photoId,
    requestId,
    requesterUserId: userId,
    estimatedCostMicrousd: 7,
  }]);
  assert.deepEqual(fake.calls.executed, [reservation]);
});

Deno.test("in-flight, expired, and completed request IDs follow replay semantics", async () => {
  for (
    const [reserved, status, code, retryable] of [
      [{ status: "IN_FLIGHT", analysisId, photoId }, 409, "RECOGNITION_IN_PROGRESS", true],
      [{ status: "RETRY_REQUIRED", analysisId, photoId }, 409, "RECOGNITION_RETRY_REQUIRED", false],
    ] as const
  ) {
    const fake = dependencies({ reserve: () => Promise.resolve(reserved) });
    const result = await createRecognitionHandler(fake.value)(request());
    assert.equal(result.status, status);
    const body = await json(result) as { error: { code: string; retryable: boolean } };
    assert.equal(body.error.code, code);
    assert.equal(body.error.retryable, retryable);
    assert.equal(fake.calls.executed.length, 0);
  }

  const completed = {
    status: "UNRECOGNIZED",
    analysisId,
    photoId,
    suggestion: null,
    reason: "NO_PRODUCT",
  };
  const fake = dependencies({ reserve: () => Promise.resolve(completed) });
  const result = await createRecognitionHandler(fake.value)(request());
  assert.equal(result.status, 200);
  assert.deepEqual(await json(result), completed);
  assert.equal(fake.calls.executed.length, 0);
});

Deno.test("foreign photos, revocation, conflicts, and quota failures stay sanitized", async () => {
  const cases = [
    [new RecognitionBackendError("PT404", "foreign photo details"), 404, "NOT_FOUND"],
    [new RecognitionBackendError("PT404", "revoked membership details"), 404, "NOT_FOUND"],
    [new RecognitionBackendError("PT409", "REQUEST_CONFLICT"), 409, "CONFLICT"],
    [new RecognitionBackendError("PT409", "PHOTO_NOT_READY"), 409, "PHOTO_NOT_READY"],
    [new RecognitionBackendError("PT422", "database details"), 422, "VALIDATION_ERROR"],
  ] as const;
  for (const [error, status, code] of cases) {
    const fake = dependencies({ reserve: () => Promise.reject(error) });
    const result = await createRecognitionHandler(fake.value)(request());
    assert.equal(result.status, status);
    const body = await json(result) as { error: { code: string; message: string } };
    assert.equal(body.error.code, code);
    assert.equal(body.error.message, code);
    if (error.message !== code) assert(!JSON.stringify(body).includes(error.message));
  }

  const fake = dependencies({
    now: () => new Date("2026-09-13T12:00:00Z"),
    reserve: () => Promise.reject(new RecognitionBackendError("PT429", "QUOTA_EXCEEDED")),
  });
  const limited = await createRecognitionHandler(fake.value)(request());
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("Retry-After"), "43200");
  const body = await json(limited) as { error: { code: string; retryable: boolean } };
  assert.equal(body.error.code, "QUOTA_EXCEEDED");
  assert.equal(body.error.retryable, false);
});

Deno.test("malformed internal results and dependency failures become retry-safe errors", async () => {
  for (const reserved of [{ status: "RESERVED" }, { ...reservation, checksum: "secret" }]) {
    const fake = dependencies({ reserve: () => Promise.resolve(reserved) });
    const result = await createRecognitionHandler(fake.value)(request());
    assert.equal(result.status, 500);
    const body = await json(result) as { error: { code: string; retryable: boolean } };
    assert.deepEqual(
      { code: body.error.code, retryable: body.error.retryable },
      { code: "INTERNAL_ERROR", retryable: true },
    );
  }
});

function providerResponse(
  output: unknown,
  options: { contentType?: "output_text" | "refusal"; status?: string; usage?: unknown } = {},
) {
  const content = options.contentType === "refusal"
    ? { type: "refusal", refusal: "synthetic refusal detail" }
    : { type: "output_text", text: typeof output === "string" ? output : JSON.stringify(output) };
  return new Response(
    JSON.stringify({
      id: "resp_synthetic",
      status: options.status ?? "completed",
      output: [{ type: "message", content: [content] }],
      usage: options.usage ?? { input_tokens: 10, output_tokens: 5, total_tokens: 15 },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

async function providerError(response: Response, code: string) {
  await assert.rejects(
    () => recognizeProduct(new Uint8Array([1, 2, 3]), provider, () => Promise.resolve(response)),
    (error: unknown) => error instanceof ProviderError && error.code === code,
  );
}

Deno.test("provider configuration requires an explicit provider, model, key, and cost estimate", () => {
  const values = new Map([
    ["RECOGNITION_PROVIDER", "openai"],
    ["OPENAI_API_KEY", "synthetic-secret"],
    ["OPENAI_MODEL", "synthetic-vision-model"],
    ["RECOGNITION_ESTIMATED_COST_MICROUSD", "7"],
  ]);
  assert.deepEqual(providerConfiguration({ get: (key) => values.get(key) }), {
    ...provider,
    timeoutMs: 25_000,
  });
  for (const key of values.keys()) {
    const incomplete = new Map(values);
    incomplete.delete(key);
    assert.equal(providerConfiguration({ get: (name) => incomplete.get(name) }), null);
  }
  values.set("RECOGNITION_PROVIDER", "arbitrary-url");
  assert.equal(providerConfiguration({ get: (key) => values.get(key) }), null);
});

Deno.test("OpenAI request uses private image input and strict structured output", async () => {
  let capturedURL = "";
  let captured: RequestInit | undefined;
  const fetcher: typeof fetch = (input, init) => {
    capturedURL = String(input);
    captured = init;
    return Promise.resolve(providerResponse({
      outcome: "SUGGESTED",
      name: "  Electric kettle  ",
      description: "Black countertop kettle",
      brand: null,
      model: null,
      reason: null,
    }));
  };
  const result = await recognizeProduct(new Uint8Array([1, 2, 3]), provider, fetcher);
  assert.equal(capturedURL, "https://api.openai.com/v1/responses");
  assert.equal(new Headers(captured!.headers).get("Authorization"), "Bearer synthetic-secret");
  const body = JSON.parse(String(captured!.body));
  assert.equal(body.model, "synthetic-vision-model");
  assert.equal(body.store, false);
  assert.equal(body.input[0].content[1].type, "input_image");
  assert.equal(body.input[0].content[1].detail, "high");
  assert.match(body.input[0].content[1].image_url, /^data:image\/jpeg;base64,/);
  assert.equal(body.text.format.type, "json_schema");
  assert.equal(body.text.format.strict, true);
  assert(!String(captured!.body).includes("synthetic-secret"));
  assert.deepEqual(result, {
    result: {
      outcome: "SUGGESTED",
      name: "Electric kettle",
      description: "Black countertop kettle",
      brand: null,
      model: null,
      reason: null,
    },
    usage: {
      inputTokens: 10,
      outputTokens: 5,
      totalTokens: 15,
      providerResponseId: "resp_synthetic",
    },
    providerId: "openai-responses",
    modelId: "synthetic-vision-model",
    promptVersion: "product-v1",
  });
});

Deno.test("multiple products become an unrecognized result with no partial suggestion", async () => {
  const result = await recognizeProduct(
    new Uint8Array([1]),
    provider,
    () =>
      Promise.resolve(providerResponse({
        outcome: "UNRECOGNIZED",
        name: null,
        description: null,
        brand: null,
        model: null,
        reason: "MULTIPLE_PRODUCTS",
      })),
  );
  assert.deepEqual(result.result, {
    outcome: "UNRECOGNIZED",
    name: null,
    description: null,
    brand: null,
    model: null,
    reason: "MULTIPLE_PRODUCTS",
  });
});

Deno.test("refusals and malformed or incomplete outputs fail closed", async () => {
  await providerError(providerResponse({}, { contentType: "refusal" }), "PROVIDER_REFUSAL");
  const malformed = [
    providerResponse("not-json"),
    providerResponse({
      outcome: "SUGGESTED",
      name: "Kettle",
      description: null,
      model: null,
      reason: null,
    }),
    providerResponse({
      outcome: "SUGGESTED",
      name: "Kettle",
      description: null,
      brand: "Invented",
      model: null,
      reason: "NO_PRODUCT",
    }),
    providerResponse({}, { status: "incomplete" }),
    providerResponse({
      outcome: "UNRECOGNIZED",
      name: null,
      description: null,
      brand: null,
      model: null,
      reason: "NO_PRODUCT",
    }, { usage: { input_tokens: 10, output_tokens: 5, total_tokens: 99 } }),
  ];
  for (const response of malformed) await providerError(response, "INVALID_PROVIDER_RESPONSE");
  assert.throws(
    () =>
      parseProductRecognition({
        outcome: "SUGGESTED",
        name: "Kettle",
        description: null,
        brand: null,
        model: null,
        reason: null,
        extra: "untrusted",
      }),
    /INVALID_PROVIDER_RESPONSE/,
  );
});

Deno.test("provider timeout aborts bounded work without starting an automatic retry", async () => {
  const timed: ProviderConfiguration = { ...provider, timeoutMs: 5 };
  const fetcher: typeof fetch = (_input, init) =>
    new Promise((_resolve, reject) => {
      init!.signal!.addEventListener("abort", () => {
        reject(new DOMException("synthetic timeout", "AbortError"));
      });
    });
  await assert.rejects(
    () => recognizeProduct(new Uint8Array([1]), timed, fetcher),
    (error: unknown) => error instanceof ProviderError && error.code === "PROVIDER_TIMEOUT",
  );

  let executionCount = 0;
  const first = dependencies({
    execute() {
      executionCount += 1;
      return Promise.reject(new RecognitionExecutionError(504, "PROVIDER_TIMEOUT"));
    },
  });
  assert.equal((await createRecognitionHandler(first.value)(request())).status, 504);
  const replay = dependencies({
    reserve: () => Promise.resolve({ status: "IN_FLIGHT", analysisId, photoId }),
    execute() {
      executionCount += 1;
      return Promise.resolve(null);
    },
  });
  assert.equal((await createRecognitionHandler(replay.value)(request())).status, 409);
  assert.equal(executionCount, 1);
});

Deno.test("recognition cancels oversized chunked bodies before reading the remaining stream", async () => {
  let pulls = 0;
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) { pulls++; controller.enqueue(new Uint8Array(1024)); },
    cancel() { cancelled = true; },
  }, { highWaterMark: 0 });
  const fake = dependencies();
  const result = await createRecognitionHandler(fake.value)(new Request("http://localhost/recognitions", {
    method: "POST", headers: { Authorization: "Bearer synthetic", "Content-Type": "application/json" }, body,
  }));
  assert.equal(result.status, 422);
  assert.equal(pulls, 5);
  assert.equal(cancelled, true);
  assert.equal(fake.calls.reserved.length, 0);
});

Deno.test("recognition accepts valid JSON split across small body chunks", async () => {
  const bytes = new TextEncoder().encode(JSON.stringify({ photoId, requestId }));
  const body = new ReadableStream<Uint8Array>({
    start(controller) { for (const byte of bytes) controller.enqueue(new Uint8Array([byte])); controller.close(); },
  });
  const result = await createRecognitionHandler(dependencies().value)(new Request("http://localhost/recognitions", {
    method: "POST", headers: { Authorization: "Bearer synthetic", "Content-Type": "application/json" }, body,
  }));
  assert.equal(result.status, 200);
});
