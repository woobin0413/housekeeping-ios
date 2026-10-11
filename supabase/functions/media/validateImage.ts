import { decode } from "jpeg-js";

export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export const MAX_IMAGE_EDGE = 2048;
export const MAX_IMAGE_PIXELS = MAX_IMAGE_EDGE * MAX_IMAGE_EDGE;
export const MAX_VALIDATION_MS = 1_500;

export type ImageValidationCode =
  | "IMAGE_TOO_LARGE"
  | "IMAGE_DIMENSIONS_EXCEEDED"
  | "INVALID_IMAGE"
  | "VALIDATION_TIMEOUT";

export class ImageValidationError extends Error {
  constructor(readonly code: ImageValidationCode) {
    super(code);
    this.name = "ImageValidationError";
  }
}

export interface ValidatedImage {
  byteSize: number;
  checksum: string;
  height: number;
  mimeType: "image/jpeg";
  width: number;
}

interface Dimensions {
  height: number;
  width: number;
}

interface DecodeResult extends Dimensions {
  data: Uint8Array;
}

interface ValidationOptions {
  decodeImage?: (bytes: Uint8Array) => DecodeResult;
  now?: () => number;
}

function invalid(): never {
  throw new ImageValidationError("INVALID_IMAGE");
}

function jpegDimensions(bytes: Uint8Array): Dimensions {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) invalid();
  let offset = 2;
  while (offset < bytes.length) {
    if (bytes[offset] !== 0xff) invalid();
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
    if (offset >= bytes.length) invalid();
    const marker = bytes[offset++];
    if (marker === 0xd9 || marker === 0xda) invalid();
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) invalid();
    const length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) invalid();
    const isStartOfFrame = marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker);
    if (isStartOfFrame) {
      if (length < 8) invalid();
      const height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      const width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      if (width < 1 || height < 1) invalid();
      return { height, width };
    }
    offset += length;
  }
  return invalid();
}

function defaultDecode(bytes: Uint8Array): DecodeResult {
  return decode(bytes, {
    formatAsRGBA: false,
    maxMemoryUsageInMB: 96,
    maxResolutionInMP: MAX_IMAGE_PIXELS / 1_000_000,
    tolerantDecoding: false,
    useTArray: true,
  });
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function validateImage(
  bytes: Uint8Array,
  options: ValidationOptions = {},
): Promise<ValidatedImage> {
  const now = options.now ?? performance.now.bind(performance);
  const startedAt = now();
  if (bytes.byteLength > MAX_IMAGE_BYTES) throw new ImageValidationError("IMAGE_TOO_LARGE");
  if (bytes.byteLength < 4 || bytes.at(-2) !== 0xff || bytes.at(-1) !== 0xd9) invalid();

  const dimensions = jpegDimensions(bytes);
  if (
    dimensions.width > MAX_IMAGE_EDGE || dimensions.height > MAX_IMAGE_EDGE ||
    dimensions.width * dimensions.height > MAX_IMAGE_PIXELS
  ) throw new ImageValidationError("IMAGE_DIMENSIONS_EXCEEDED");

  let decoded: DecodeResult;
  try {
    decoded = (options.decodeImage ?? defaultDecode)(bytes);
  } catch {
    return invalid();
  }
  if (now() - startedAt > MAX_VALIDATION_MS) {
    throw new ImageValidationError("VALIDATION_TIMEOUT");
  }
  if (
    decoded.width !== dimensions.width || decoded.height !== dimensions.height ||
    decoded.data.byteLength !== dimensions.width * dimensions.height * 3
  ) invalid();

  const digestInput = new Uint8Array(bytes.byteLength);
  digestInput.set(bytes);
  const checksum = hex(await crypto.subtle.digest("SHA-256", digestInput));
  if (now() - startedAt > MAX_VALIDATION_MS) {
    throw new ImageValidationError("VALIDATION_TIMEOUT");
  }

  return {
    byteSize: bytes.byteLength,
    checksum,
    height: decoded.height,
    mimeType: "image/jpeg",
    width: decoded.width,
  };
}
