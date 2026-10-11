import assert from "node:assert/strict";

import {
  type EvaluationManifest,
  type EvaluationRecord,
  type EvaluationRun,
  parseEvaluationManifest,
  scoreEvaluation,
} from "../../../scripts/evaluate-recognition.ts";

const categories = [
  "labeled-packaging",
  "unbranded-object",
  "poor-lighting",
  "small-label",
  "multiple-products",
] as const;

function manifest(
  models: string[] = ["gpt-5.6-luna"],
  budget = 200_000,
): unknown {
  return {
    schemaVersion: 1,
    evaluationId: "hk-recognition-synthetic-20260913",
    models,
    maximumBudgetMicrousd: budget,
    cases: categories.flatMap((category) =>
      Array.from({ length: 8 }, (_, index) => ({
        id: `${category}-${index + 1}`,
        file: `images/${category}-${index + 1}.jpg`,
        category,
        expectedOutcome: category === "multiple-products" ? "UNRECOGNIZED" : "SUGGESTED",
        authorization: {
          kind: "synthetic",
          source: "Generated test fixture",
          containsPersonalData: false,
        },
      }))
    ),
  };
}

Deno.test("evaluation manifest requires the representative authorized set and bounded models", () => {
  const parsed = parseEvaluationManifest(manifest()) as EvaluationManifest;
  assert.equal(parsed.cases.length, 40);
  assert.deepEqual(parsed.models, ["gpt-5.6-luna"]);

  const insufficient = manifest() as Record<string, unknown>;
  insufficient.cases = (insufficient.cases as unknown[]).slice(0, 39);
  assert.throws(() => parseEvaluationManifest(insufficient), /40 to 100/);

  const personal = manifest() as {
    cases: Array<{ authorization: { containsPersonalData: boolean } }>;
  };
  personal.cases[0].authorization.containsPersonalData = true;
  assert.throws(() => parseEvaluationManifest(personal), /authorization/);

  assert.throws(
    () =>
      parseEvaluationManifest(
        manifest(["gpt-5.6-luna", "gpt-5.6-terra"], 799_999),
      ),
    /reservations exceed/,
  );
  assert.throws(
    () => parseEvaluationManifest(manifest(["unapproved-model"])),
    /candidate model/,
  );
});

function record(index: number): EvaluationRecord {
  const multiple = index >= 32;
  return {
    caseId: `case-${index}`,
    category: categories[Math.floor(index / 8)],
    expectedOutcome: multiple ? "UNRECOGNIZED" : "SUGGESTED",
    model: "gpt-5.6-luna",
    durationMs: index === 39 ? 14_000 : 1_000 + index,
    costMicrousd: 1_000,
    inputTokens: 1_000,
    outputTokens: 100,
    result: multiple
      ? {
        outcome: "UNRECOGNIZED",
        name: null,
        description: null,
        brand: null,
        model: null,
        reason: "MULTIPLE_PRODUCTS",
      }
      : {
        outcome: "SUGGESTED",
        name: "Kettle",
        description: null,
        brand: null,
        model: null,
        reason: null,
      },
    errorCode: null,
    review: {
      usefulNameAndDescription: index < 29,
      unsupportedBrandClaim: false,
      unsupportedModelClaim: false,
      notes: "",
    },
  };
}

Deno.test("evaluation scoring applies AC-10 and AC-11 without rounding away failures", () => {
  const run: EvaluationRun = {
    schemaVersion: 1,
    evaluationId: "hk-recognition-synthetic-20260913",
    createdAt: "2026-09-13T00:00:00.000Z",
    maximumBudgetMicrousd: 200_000,
    reservedBudgetMicrousd: 200_000,
    calculatedUsageCostMicrousd: 40_000,
    records: Array.from({ length: 40 }, (_, index) => record(index)),
  };
  const score = scoreEvaluation(run);
  assert.deepEqual(score.summaries[0], {
    model: "gpt-5.6-luna",
    cases: 40,
    p95LatencyMs: 1_037,
    usefulSingleProductRate: 29 / 32,
    expectedOutcomeRate: 1,
    multipleProductOutcomeRate: 1,
    unsupportedClaimCases: 0,
    providerErrors: 0,
    calculatedUsageCostMicrousd: 40_000,
    passesAC10: true,
    passesAC11: true,
    eligibleToPin: true,
  });

  run.records[0].review.unsupportedBrandClaim = true;
  assert.equal(scoreEvaluation(run).summaries[0].passesAC11, false);
  run.records[0].review.unsupportedBrandClaim = null;
  assert.throws(() => scoreEvaluation(run), /Manual review is incomplete/);
  run.records[0].review.unsupportedBrandClaim = false;
  run.calculatedUsageCostMicrousd -= 1;
  assert.throws(() => scoreEvaluation(run), /Incomplete results/);
});
