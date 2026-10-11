import { dirname, isAbsolute, relative, resolve } from "node:path";

import {
  type ProviderConfiguration,
  ProviderError,
  recognizeProduct,
} from "../supabase/functions/recognitions/provider.ts";
import { validateImage } from "../supabase/functions/media/validateImage.ts";

const categories = [
  "labeled-packaging",
  "unbranded-object",
  "poor-lighting",
  "small-label",
  "multiple-products",
] as const;
const outcomes = ["SUGGESTED", "UNRECOGNIZED"] as const;
const maximumAuthorizedBudgetMicrousd = 1_000_000;

const candidates = {
  "gpt-5.6-luna": {
    inputPricePerMillionMicrousd: 200_000,
    outputPricePerMillionMicrousd: 1_200_000,
    reservePerRequestMicrousd: 5_000,
  },
  "gpt-5.6-terra": {
    inputPricePerMillionMicrousd: 2_000_000,
    outputPricePerMillionMicrousd: 12_000_000,
    reservePerRequestMicrousd: 15_000,
  },
} as const;

type Category = typeof categories[number];
type ExpectedOutcome = typeof outcomes[number];
type CandidateModel = keyof typeof candidates;

interface FixtureAuthorization {
  kind: "synthetic" | "user-owned-non-personal" | "licensed";
  source: string;
  containsPersonalData: false;
}

interface EvaluationCase {
  id: string;
  file: string;
  category: Category;
  expectedOutcome: ExpectedOutcome;
  authorization: FixtureAuthorization;
}

export interface EvaluationManifest {
  schemaVersion: 1;
  evaluationId: string;
  models: CandidateModel[];
  maximumBudgetMicrousd: number;
  cases: EvaluationCase[];
}

export interface EvaluationReview {
  usefulNameAndDescription: boolean | null;
  unsupportedBrandClaim: boolean | null;
  unsupportedModelClaim: boolean | null;
  notes: string;
}

export interface EvaluationRecord {
  caseId: string;
  category: Category;
  expectedOutcome: ExpectedOutcome;
  model: CandidateModel;
  durationMs: number;
  costMicrousd: number;
  inputTokens: number;
  outputTokens: number;
  result: Awaited<ReturnType<typeof recognizeProduct>>["result"] | null;
  errorCode: string | null;
  review: EvaluationReview;
}

export interface EvaluationRun {
  schemaVersion: 1;
  evaluationId: string;
  createdAt: string;
  maximumBudgetMicrousd: number;
  reservedBudgetMicrousd: number;
  calculatedUsageCostMicrousd: number;
  records: EvaluationRecord[];
}

function exactObject(
  value: unknown,
  keys: string[],
  label: string,
): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Invalid ${label}`);
  }
  const object = value as Record<string, unknown>;
  const actual = Object.keys(object);
  if (actual.length !== keys.length || !keys.every((key) => key in object)) {
    throw new Error(`Invalid ${label}`);
  }
  return object;
}

function oneOf<T extends string>(
  value: unknown,
  allowed: readonly T[],
  label: string,
): T {
  if (typeof value !== "string" || !allowed.includes(value as T)) {
    throw new Error(`Invalid ${label}`);
  }
  return value as T;
}

function fixture(value: unknown): EvaluationCase {
  const object = exactObject(
    value,
    ["id", "file", "category", "expectedOutcome", "authorization"],
    "evaluation case",
  );
  if (
    typeof object.id !== "string" ||
    !/^[a-z0-9][a-z0-9-]{2,79}$/.test(object.id)
  ) {
    throw new Error("Invalid case id");
  }
  if (
    typeof object.file !== "string" || object.file.length > 240 ||
    isAbsolute(object.file) ||
    object.file.split(/[\\/]/).includes("..") || !/\.jpe?g$/i.test(object.file)
  ) throw new Error(`Invalid fixture path for ${object.id}`);
  const authorization = exactObject(
    object.authorization,
    ["kind", "source", "containsPersonalData"],
    `authorization for ${object.id}`,
  );
  if (
    typeof authorization.source !== "string" ||
    authorization.source.trim().length < 3 ||
    authorization.source.length > 500 ||
    authorization.containsPersonalData !== false
  ) throw new Error(`Invalid authorization for ${object.id}`);
  return {
    id: object.id,
    file: object.file,
    category: oneOf(object.category, categories, `category for ${object.id}`),
    expectedOutcome: oneOf(
      object.expectedOutcome,
      outcomes,
      `outcome for ${object.id}`,
    ),
    authorization: {
      kind: oneOf(
        authorization.kind,
        ["synthetic", "user-owned-non-personal", "licensed"],
        `authorization kind for ${object.id}`,
      ),
      source: authorization.source.trim(),
      containsPersonalData: false,
    },
  };
}

export function parseEvaluationManifest(value: unknown): EvaluationManifest {
  const object = exactObject(
    value,
    [
      "schemaVersion",
      "evaluationId",
      "models",
      "maximumBudgetMicrousd",
      "cases",
    ],
    "manifest",
  );
  if (object.schemaVersion !== 1) {
    throw new Error("Unsupported manifest schema");
  }
  if (
    typeof object.evaluationId !== "string" ||
    !/^hk-recognition-[a-z0-9-]{8,80}$/.test(object.evaluationId)
  ) throw new Error("Invalid evaluation id");
  if (
    !Number.isSafeInteger(object.maximumBudgetMicrousd) ||
    Number(object.maximumBudgetMicrousd) < 1 ||
    Number(object.maximumBudgetMicrousd) > maximumAuthorizedBudgetMicrousd
  ) {
    throw new Error(
      "Evaluation budget exceeds the built-in one-dollar ceiling",
    );
  }
  if (
    !Array.isArray(object.models) || object.models.length < 1 ||
    object.models.length > 2
  ) {
    throw new Error("Select one or two candidate models");
  }
  const models = object.models.map((model) =>
    oneOf(model, Object.keys(candidates) as CandidateModel[], "candidate model")
  );
  if (new Set(models).size !== models.length) {
    throw new Error("Candidate models must be unique");
  }
  if (
    !Array.isArray(object.cases) || object.cases.length < 40 ||
    object.cases.length > 100
  ) {
    throw new Error("Evaluation requires 40 to 100 cases");
  }
  const cases = object.cases.map(fixture);
  if (new Set(cases.map((entry) => entry.id)).size !== cases.length) {
    throw new Error("Case ids must be unique");
  }
  for (const category of categories) {
    if (cases.filter((entry) => entry.category === category).length < 8) {
      throw new Error(`Evaluation requires at least eight ${category} cases`);
    }
  }
  for (const entry of cases) {
    const required = entry.category === "multiple-products" ? "UNRECOGNIZED" : "SUGGESTED";
    if (entry.expectedOutcome !== required) {
      throw new Error(`Unexpected outcome for ${entry.id}`);
    }
  }
  const reserved = models.reduce(
    (total, model) => total + candidates[model].reservePerRequestMicrousd * cases.length,
    0,
  );
  if (reserved > Number(object.maximumBudgetMicrousd)) {
    throw new Error("Model request reservations exceed the manifest budget");
  }
  return {
    schemaVersion: 1,
    evaluationId: object.evaluationId,
    models,
    maximumBudgetMicrousd: Number(object.maximumBudgetMicrousd),
    cases,
  };
}

async function loadManifest(path: string): Promise<EvaluationManifest> {
  return parseEvaluationManifest(JSON.parse(await Deno.readTextFile(path)));
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes).buffer),
  );
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function approvalDigest(
  path: string,
  manifest: EvaluationManifest,
): Promise<string> {
  const manifestHash = await sha256(await Deno.readFile(path));
  const fixtureHashes = [];
  for (const entry of manifest.cases) {
    fixtureHashes.push(
      `${entry.id}:${await sha256(await fixtureBytes(path, entry))}`,
    );
  }
  const binding = new TextEncoder().encode(
    [manifestHash, ...fixtureHashes].join("\n"),
  );
  const digest = await sha256(binding);
  return `sha256:${digest}`;
}

async function fixtureBytes(
  manifestPath: string,
  entry: EvaluationCase,
): Promise<Uint8Array> {
  const base = await Deno.realPath(dirname(resolve(manifestPath)));
  const requested = resolve(base, entry.file);
  const actual = await Deno.realPath(requested);
  const within = relative(base, actual);
  if (within.startsWith("..") || isAbsolute(within)) {
    throw new Error(`Fixture escapes dataset: ${entry.id}`);
  }
  const bytes = await Deno.readFile(actual);
  try {
    await validateImage(bytes);
  } catch {
    throw new Error(`Fixture is not a bounded decoded JPEG: ${entry.id}`);
  }
  return bytes;
}

export async function validateEvaluationFixtures(
  manifestPath: string,
  manifest: EvaluationManifest,
): Promise<void> {
  for (const entry of manifest.cases) await fixtureBytes(manifestPath, entry);
}

function cost(
  model: CandidateModel,
  inputTokens: number,
  outputTokens: number,
): number {
  const pricing = candidates[model];
  return Math.ceil(
    (inputTokens * pricing.inputPricePerMillionMicrousd +
      outputTokens * pricing.outputPricePerMillionMicrousd) / 1_000_000,
  );
}

async function runEvaluation(
  manifestPath: string,
  outputPath: string,
): Promise<EvaluationRun> {
  const manifest = await loadManifest(manifestPath);
  if (
    Deno.env.get("HK_RECOGNITION_EVALUATION_APPROVAL") !==
      await approvalDigest(manifestPath, manifest)
  ) {
    throw new Error(
      "Paid evaluation approval is absent or does not match the manifest",
    );
  }
  const apiKey = Deno.env.get("OPENAI_API_KEY")?.trim();
  if (!apiKey) throw new Error("OPENAI_API_KEY is required");
  const output = resolve(outputPath);
  if (!output.startsWith("/tmp/") && !output.startsWith("/private/tmp/")) {
    throw new Error(
      "Write evaluation results under /tmp so they cannot be committed accidentally",
    );
  }
  await Deno.writeTextFile(output, "", { createNew: true });

  const records: EvaluationRecord[] = [];
  let reservedBudgetMicrousd = 0;
  let calculatedUsageCostMicrousd = 0;
  for (const model of manifest.models) {
    const settings = candidates[model];
    const configuration: ProviderConfiguration = {
      provider: "openai",
      apiKey,
      model,
      estimatedCostMicrousd: settings.reservePerRequestMicrousd,
      timeoutMs: 25_000,
    };
    for (const entry of manifest.cases) {
      reservedBudgetMicrousd += settings.reservePerRequestMicrousd;
      if (reservedBudgetMicrousd > manifest.maximumBudgetMicrousd) {
        throw new Error(
          "Evaluation stopped before exceeding its reserved budget",
        );
      }
      const bytes = await fixtureBytes(manifestPath, entry);
      const started = performance.now();
      let result: EvaluationRecord["result"] = null;
      let errorCode: string | null = null;
      let inputTokens = 0;
      let outputTokens = 0;
      try {
        const response = await recognizeProduct(bytes, configuration);
        result = response.result;
        inputTokens = response.usage.inputTokens;
        outputTokens = response.usage.outputTokens;
      } catch (error) {
        errorCode = error instanceof ProviderError ? error.code : "UNEXPECTED_PROVIDER_ERROR";
      }
      const recordCost = cost(model, inputTokens, outputTokens);
      calculatedUsageCostMicrousd += recordCost;
      records.push({
        caseId: entry.id,
        category: entry.category,
        expectedOutcome: entry.expectedOutcome,
        model,
        durationMs: Math.round(performance.now() - started),
        costMicrousd: recordCost,
        inputTokens,
        outputTokens,
        result,
        errorCode,
        review: {
          usefulNameAndDescription: null,
          unsupportedBrandClaim: null,
          unsupportedModelClaim: null,
          notes: "",
        },
      });
      const partial: EvaluationRun = {
        schemaVersion: 1,
        evaluationId: manifest.evaluationId,
        createdAt: new Date().toISOString(),
        maximumBudgetMicrousd: manifest.maximumBudgetMicrousd,
        reservedBudgetMicrousd,
        calculatedUsageCostMicrousd,
        records,
      };
      await Deno.writeTextFile(output, `${JSON.stringify(partial, null, 2)}\n`);
    }
  }
  return JSON.parse(await Deno.readTextFile(output)) as EvaluationRun;
}

function percentile95(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * 0.95) - 1)];
}

export function scoreEvaluation(run: EvaluationRun) {
  if (
    run.schemaVersion !== 1 || !Array.isArray(run.records) || run.records.length < 40 ||
    !Number.isSafeInteger(run.calculatedUsageCostMicrousd) ||
    run.calculatedUsageCostMicrousd < 0 ||
    !Number.isSafeInteger(run.reservedBudgetMicrousd) || run.reservedBudgetMicrousd < 0 ||
    run.reservedBudgetMicrousd > run.maximumBudgetMicrousd ||
    run.maximumBudgetMicrousd > maximumAuthorizedBudgetMicrousd ||
    run.records.reduce((total, record) => total + record.costMicrousd, 0) !==
      run.calculatedUsageCostMicrousd
  ) {
    throw new Error("Incomplete results");
  }
  const summaries = [];
  for (const model of new Set(run.records.map((record) => record.model))) {
    if (!Object.hasOwn(candidates, model)) throw new Error(`Unapproved model in results: ${model}`);
    const records = run.records.filter((record) => record.model === model);
    if (
      records.length < 40 || new Set(records.map((record) => record.caseId)).size !== records.length
    ) throw new Error(`Incomplete or duplicate results for ${model}`);
    for (const record of records) {
      if (
        !categories.includes(record.category) || !outcomes.includes(record.expectedOutcome) ||
        (record.category === "multiple-products") !==
          (record.expectedOutcome === "UNRECOGNIZED") ||
        !Number.isSafeInteger(record.durationMs) || record.durationMs < 0 ||
        !Number.isSafeInteger(record.costMicrousd) || record.costMicrousd < 0 ||
        !Number.isSafeInteger(record.inputTokens) || record.inputTokens < 0 ||
        !Number.isSafeInteger(record.outputTokens) || record.outputTokens < 0
      ) throw new Error(`Invalid result metrics for ${model}/${record.caseId}`);
    }
    for (const category of categories) {
      if (records.filter((record) => record.category === category).length < 8) {
        throw new Error(`Incomplete ${category} results for ${model}`);
      }
    }
    const singles = records.filter((record) => record.expectedOutcome === "SUGGESTED");
    for (const record of records) {
      if (
        typeof record.review?.usefulNameAndDescription !== "boolean" ||
        typeof record.review?.unsupportedBrandClaim !== "boolean" ||
        typeof record.review?.unsupportedModelClaim !== "boolean"
      ) {
        throw new Error(
          `Manual review is incomplete for ${model}/${record.caseId}`,
        );
      }
    }
    const useful = singles.filter((record) => record.review.usefulNameAndDescription).length;
    const unsupported = records.filter((record) =>
      record.review.unsupportedBrandClaim || record.review.unsupportedModelClaim
    ).length;
    const providerErrors = records.filter((record) =>
      record.errorCode !== null
    ).length;
    const p95LatencyMs = percentile95(
      records.map((record) => record.durationMs),
    );
    const usefulRate = singles.length === 0 ? 0 : useful / singles.length;
    const outcomeMatches =
      records.filter((record) => record.result?.outcome === record.expectedOutcome).length;
    const multipleProducts = records.filter((record) => record.category === "multiple-products");
    const multipleProductOutcomeRate =
      multipleProducts.filter((record) => record.result?.outcome === "UNRECOGNIZED").length /
      multipleProducts.length;
    summaries.push({
      model,
      cases: records.length,
      p95LatencyMs,
      usefulSingleProductRate: usefulRate,
      expectedOutcomeRate: outcomeMatches / records.length,
      multipleProductOutcomeRate,
      unsupportedClaimCases: unsupported,
      providerErrors,
      calculatedUsageCostMicrousd: records.reduce(
        (total, record) => total + record.costMicrousd,
        0,
      ),
      passesAC10: p95LatencyMs <= 15_000,
      passesAC11: usefulRate >= 0.9 && unsupported === 0,
      eligibleToPin: p95LatencyMs <= 15_000 && usefulRate >= 0.9 &&
        multipleProductOutcomeRate === 1 && unsupported === 0 &&
        providerErrors === 0,
    });
  }
  return {
    evaluationId: run.evaluationId,
    calculatedUsageCostMicrousd: run.calculatedUsageCostMicrousd,
    summaries,
  };
}

async function main(args: string[]) {
  const [command, input, output] = args;
  if (command === "validate" && input && !output) {
    const manifest = await loadManifest(input);
    console.log(
      `Validated ${manifest.cases.length} authorized fixtures; no provider call made. Approval digest: ${await approvalDigest(
        input,
        manifest,
      )}`,
    );
    return;
  }
  if (command === "run" && input && output) {
    const run = await runEvaluation(input, output);
    console.log(
      `Completed ${run.records.length} bounded calls; results: ${
        resolve(output)
      }; calculated usage cost: ${run.calculatedUsageCostMicrousd} micro-USD.`,
    );
    return;
  }
  if (command === "score" && input && output) {
    const run = JSON.parse(await Deno.readTextFile(input)) as EvaluationRun;
    await Deno.writeTextFile(
      output,
      `${JSON.stringify(scoreEvaluation(run), null, 2)}\n`,
    );
    console.log(`Wrote aggregate score: ${resolve(output)}`);
    return;
  }
  throw new Error(
    "Usage: evaluate-recognition.ts validate MANIFEST | run MANIFEST /tmp/RESULTS | score RESULTS SUMMARY",
  );
}

if (import.meta.main) {
  try {
    await main(Deno.args);
  } catch (error) {
    console.error(error instanceof Error ? error.message : "Evaluation failed");
    Deno.exit(1);
  }
}
