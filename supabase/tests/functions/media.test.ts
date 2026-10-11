import assert from "node:assert/strict";
import { encode } from "jpeg-js";
import {
  ImageValidationError,
  MAX_IMAGE_BYTES,
  MAX_VALIDATION_MS,
  validateImage,
} from "../../functions/media/validateImage.ts";

function jpeg(width: number, height: number): Uint8Array {
  const pixels = new Uint8Array(width * height * 4);
  for (let offset = 0; offset < pixels.length; offset += 4) {
    pixels[offset] = 48;
    pixels[offset + 1] = 92;
    pixels[offset + 2] = 70;
    pixels[offset + 3] = 255;
  }
  return new Uint8Array(encode({ data: pixels, width, height }, 80).data);
}

async function rejectsWith(bytes: Uint8Array, code: string): Promise<void> {
  await assert.rejects(
    () => validateImage(bytes),
    (error: unknown) => error instanceof ImageValidationError && error.code === code,
  );
}

Deno.test("decodes a real JPEG and computes trusted metadata", async () => {
  const bytes = jpeg(3, 2);
  const image = await validateImage(bytes);
  assert.deepEqual(
    {
      byteSize: image.byteSize,
      height: image.height,
      mimeType: image.mimeType,
      width: image.width,
    },
    { byteSize: bytes.byteLength, height: 2, mimeType: "image/jpeg", width: 3 },
  );
  const digestInput = new Uint8Array(bytes.byteLength);
  digestInput.set(bytes);
  const expected = Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", digestInput)),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  assert.equal(image.checksum, expected);
});

Deno.test("rejects marker-only, truncated, trailing, and random payloads", async () => {
  await rejectsWith(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), "INVALID_IMAGE");
  const valid = jpeg(2, 2);
  await rejectsWith(valid.slice(0, -12), "INVALID_IMAGE");
  await rejectsWith(new Uint8Array([...valid, 0]), "INVALID_IMAGE");
  await rejectsWith(new Uint8Array([1, 2, 3, 4]), "INVALID_IMAGE");
});

Deno.test("rejects byte and long-edge limits before decoding", async () => {
  await rejectsWith(new Uint8Array(MAX_IMAGE_BYTES + 1), "IMAGE_TOO_LARGE");
  await rejectsWith(jpeg(2049, 1), "IMAGE_DIMENSIONS_EXCEEDED");
});

Deno.test("rejects inconsistent decoder output and elapsed validation budgets", async () => {
  const bytes = jpeg(2, 2);
  await assert.rejects(
    () =>
      validateImage(bytes, {
        decodeImage: () => ({ data: new Uint8Array(3), height: 1, width: 1 }),
      }),
    (error: unknown) => error instanceof ImageValidationError && error.code === "INVALID_IMAGE",
  );
  const times = [10, 10 + MAX_VALIDATION_MS + 1];
  await assert.rejects(
    () =>
      validateImage(bytes, {
        decodeImage: () => ({ data: new Uint8Array(12), height: 2, width: 2 }),
        now: () => times.shift()!,
      }),
    (error: unknown) =>
      error instanceof ImageValidationError && error.code === "VALIDATION_TIMEOUT",
  );
  const checksumTimes = [10, 10, 10 + MAX_VALIDATION_MS + 1];
  await assert.rejects(
    () =>
      validateImage(bytes, {
        decodeImage: () => ({ data: new Uint8Array(12), height: 2, width: 2 }),
        now: () => checksumTimes.shift()!,
      }),
    (error: unknown) =>
      error instanceof ImageValidationError && error.code === "VALIDATION_TIMEOUT",
  );
});

Deno.test("decodes the maximum normalized dimensions within the time budget", async () => {
  const bytes = jpeg(2048, 2048);
  const startedAt = performance.now();
  const image = await validateImage(bytes);
  assert.equal(image.width, 2048);
  assert.equal(image.height, 2048);
  assert(performance.now() - startedAt <= MAX_VALIDATION_MS);
});
