export const PROMPT_VERSION = "product-v1";

export const productRecognitionSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    outcome: { type: "string", enum: ["SUGGESTED", "UNRECOGNIZED"] },
    name: { type: ["string", "null"] },
    description: { type: ["string", "null"] },
    brand: { type: ["string", "null"] },
    model: { type: ["string", "null"] },
    reason: {
      type: ["string", "null"],
      enum: ["UNCLEAR_IMAGE", "MULTIPLE_PRODUCTS", "NO_PRODUCT", null],
    },
  },
  required: ["outcome", "name", "description", "brand", "model", "reason"],
} as const;

export interface SuggestedProduct {
  outcome: "SUGGESTED";
  name: string;
  description: string | null;
  brand: string | null;
  model: string | null;
  reason: null;
}

export interface UnrecognizedProduct {
  outcome: "UNRECOGNIZED";
  name: null;
  description: null;
  brand: null;
  model: null;
  reason: "UNCLEAR_IMAGE" | "MULTIPLE_PRODUCTS" | "NO_PRODUCT";
}

export type ProductRecognition = SuggestedProduct | UnrecognizedProduct;

export class RecognitionSchemaError extends Error {
  constructor() {
    super("INVALID_PROVIDER_RESPONSE");
  }
}

function exactObject(value: unknown, keys: string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new RecognitionSchemaError();
  }
  const object = value as Record<string, unknown>;
  const actual = Object.keys(object);
  if (actual.length !== keys.length || !keys.every((key) => key in object)) {
    throw new RecognitionSchemaError();
  }
  return object;
}

function nullableText(value: unknown, maximumLength: number): string | null {
  if (value === null) return null;
  if (typeof value !== "string") throw new RecognitionSchemaError();
  const normalized = value.trim();
  if (normalized.length === 0 || normalized.length > maximumLength) {
    throw new RecognitionSchemaError();
  }
  return normalized;
}

export function parseProductRecognition(value: unknown): ProductRecognition {
  const object = exactObject(value, [
    "outcome",
    "name",
    "description",
    "brand",
    "model",
    "reason",
  ]);
  if (object.outcome === "SUGGESTED") {
    const name = nullableText(object.name, 200);
    if (name === null || object.reason !== null) throw new RecognitionSchemaError();
    return {
      outcome: "SUGGESTED",
      name,
      description: nullableText(object.description, 2_000),
      brand: nullableText(object.brand, 100),
      model: nullableText(object.model, 100),
      reason: null,
    };
  }
  if (
    object.outcome === "UNRECOGNIZED" && object.name === null && object.description === null &&
    object.brand === null && object.model === null &&
    ["UNCLEAR_IMAGE", "MULTIPLE_PRODUCTS", "NO_PRODUCT"].includes(String(object.reason))
  ) {
    return object as unknown as UnrecognizedProduct;
  }
  throw new RecognitionSchemaError();
}
