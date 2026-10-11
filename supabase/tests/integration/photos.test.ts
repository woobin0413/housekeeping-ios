import test from "node:test";
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { localHarness, localSQL, uuid } from "./local-harness.mjs";

const malformedJpeg = new Uint8Array([
  0xff,
  0xd8,
  0xff,
  0xdb,
  0x00,
  0x43,
  0xff,
  0xd9,
]);
const truncatedMetadataJpeg = new Uint8Array(Buffer.from(
  "/9j/4AAQSkZJRgABAQAASABIAAD/4QCORXhpZgAATU0AKgAAAAgAAwEOAAIAAAALAAAAMgESAAMAAAABAAEAAIdpAAQAAAABAAAAPgAAAABTY3JlZW5zaG90AAAABJKGAAcAAAASAAAAdKABAAMAAAABAAEAAKACAAQAAAABAAAAAaADAAQAAAABAAAAAgAAAABBU0NJSQAAAFNjcmVlbnNob3T/7QBWUGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAB4cAVoAAxslRxwCAAACAAIcAngAClNjcmVlbnNob3Q4QklNBCUAAAAAABA0BzMgsAuY2Ut8pfM/gFnx/8AAEQgAAgABAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A/aXzpv77fmaPOm/vt+ZqKiucD//Z",
  "base64",
));
const validJpeg = new Uint8Array(Buffer.from(
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSgBBwcHCggKEwoKEygaFhooKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKP/AABEIAAEAAQMBEQACEQEDEQH/xAGiAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+gEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoLEQACAQIEBAMEBwUEBAABAncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/2gAMAwEAAhEDEQA/APOqyPIP/9k=",
  "base64",
));

test("private photo reservation and Storage HTTP boundary", async (t) => {
  const h = localHarness();
  t.after(() => h.cleanup());
  const a = await h.createUser();
  const b = await h.createUser();
  const outsider = await h.createUser();
  const outsiderSpouse = await h.createUser();
  const household = h.provision(a, b);
  h.provision(outsider, outsiderSpouse);
  const [sa, sb, so] = await Promise.all(
    [a, b, outsider].map((user) => h.signIn(user)),
  );
  for (const session of [sa, sb, so]) assert.equal(session.status, 200);

  const reserve = (body: unknown, token?: string) =>
    h.request("/functions/v1/media/photos", { method: "POST", body, token });
  const requestId = randomUUID();
  const reserved = await reserve(
    { householdId: household, requestId },
    sa.data.access_token,
  );
  assert.equal(reserved.status, 201);
  uuid(reserved.data.photoId);
  assert.match(
    reserved.data.objectKey,
    new RegExp(`^${household}/${a.id}/[0-9a-f-]{36}\\.jpg$`, "i"),
  );
  assert(
    Date.parse(reserved.data.expiresAt) > Date.now() + 23 * 60 * 60 * 1000,
  );

  await t.test("reservation is retry-safe and validates its boundary", async () => {
    const retry = await reserve(
      { householdId: household, requestId },
      sa.data.access_token,
    );
    assert.equal(retry.status, 201);
    assert.equal(retry.data.photoId, reserved.data.photoId);
    assert.equal(
      (await reserve(
        { householdId: household, requestId, objectKey: "forged" },
        sa.data.access_token,
      )).status,
      422,
    );
    assert.equal(
      (await reserve(
        { householdId: randomUUID(), requestId: randomUUID() },
        sa.data.access_token,
      ))
        .status,
      404,
    );
    assert.equal(
      (await reserve(
        { householdId: household, requestId: randomUUID() },
        so.data.access_token,
      ))
        .status,
      404,
    );
    assert.equal(
      (await reserve({ householdId: household, requestId: randomUUID() }))
        .status,
      401,
    );
    assert.equal(
      (await h.request("/functions/v1/media/photos", {
        token: sa.data.access_token,
      })).status,
      405,
    );
    assert.equal(
      (await reserve(
        { householdId: household, requestId: randomUUID() },
        "invalid.token.value",
      ))
        .status,
      401,
    );
    assert.equal(
      (await h.bytesRequest("/functions/v1/media/photos", {
        method: "POST",
        body: new Uint8Array(4097),
        token: sa.data.access_token,
        headers: { "Content-Type": "application/json" },
      })).status,
      422,
    );
  });

  const objectPath = `/storage/v1/object/purchase-photos/${reserved.data.objectKey}`;
  const upload = (
    token: string,
    bytes = validJpeg,
    upsert = "false",
    path = objectPath,
  ) =>
    h.bytesRequest(path, {
      method: "POST",
      body: bytes,
      token,
      headers: { "Content-Type": "image/jpeg", "x-upsert": upsert },
    });
  const download = (token: string, path = objectPath) => h.bytesRequest(path, { token });

  await t.test("only the uploader can use the live reserved path", async () => {
    assert((await upload(sb.data.access_token)).status >= 400);
    assert(
      (await h.bytesRequest(objectPath, {
        method: "POST",
        body: validJpeg,
        token: sa.data.access_token,
        headers: { "Content-Type": "image/png", "x-upsert": "false" },
      })).status >= 400,
    );
    const stored = await upload(sa.data.access_token);
    assert.equal(stored.status, 200);
    const ownerDownload = await download(sa.data.access_token);
    assert.equal(ownerDownload.status, 200);
    assert.deepEqual(ownerDownload.data, validJpeg);
    assert((await download(sb.data.access_token)).status >= 400);
    assert(
      (await upload(sa.data.access_token, new Uint8Array([1, 2, 3]), "true"))
        .status >= 400,
    );
    const forged = `/storage/v1/object/purchase-photos/${household}/${a.id}/${randomUUID()}.jpg`;
    assert(
      (await h.bytesRequest(forged, {
        method: "POST",
        body: validJpeg,
        token: sa.data.access_token,
        headers: { "Content-Type": "image/jpeg" },
      })).status >= 400,
    );
    const deletion = await h.request("/storage/v1/object/purchase-photos", {
      method: "DELETE",
      body: { prefixes: [reserved.data.objectKey] },
      token: sa.data.access_token,
    });
    assert.equal(deletion.status, 200);
    assert.deepEqual(deletion.data, []);
    assert.equal((await download(sa.data.access_token)).status, 200);
  });

  const complete = (photoId: string, token: string, body: unknown = {}) =>
    h.request(`/functions/v1/media/photos/${photoId}/completion`, {
      method: "POST",
      body,
      token,
    });
  const reserveUpload = async (bytes?: Uint8Array) => {
    const result = await reserve(
      { householdId: household, requestId: randomUUID() },
      sa.data.access_token,
    );
    assert.equal(result.status, 201);
    if (bytes) {
      const path = `/storage/v1/object/purchase-photos/${result.data.objectKey}`;
      assert.equal(
        (await upload(sa.data.access_token, bytes, "false", path)).status,
        200,
      );
    }
    return result.data;
  };

  await t.test("completion decodes bytes, stores metadata, and is idempotent", async () => {
    assert.equal(
      (await complete(reserved.data.photoId, sb.data.access_token)).status,
      404,
    );
    assert.equal(
      (await complete(reserved.data.photoId, so.data.access_token)).status,
      404,
    );
    assert.equal(
      (await complete(reserved.data.photoId, sa.data.access_token, {
        forged: true,
      })).status,
      422,
    );
    assert.equal(
      (await h.rpc("finalize_photo", {
        photoId: reserved.data.photoId,
        uploaderUserId: a.id,
        byteSize: validJpeg.byteLength,
        mimeType: "image/jpeg",
        checksum: "0".repeat(64),
      }, sa.data.access_token)).status,
      403,
    );
    const completions = await Promise.all([
      // Swift UUID paths use uppercase by default; both spellings identify the same photo.
      complete(reserved.data.photoId.toUpperCase(), sa.data.access_token),
      complete(reserved.data.photoId, sa.data.access_token),
    ]);
    for (const completed of completions) {
      assert.equal(completed.status, 200);
      assert.deepEqual(completed.data, {
        photoId: reserved.data.photoId,
        state: "READY",
      });
    }
    assert.equal(
      (await complete(reserved.data.photoId, sa.data.access_token)).status,
      200,
    );
    const metadata = localSQL(
      `select state || '|' || byte_size || '|' || checksum
      from public.photos where id='${uuid(reserved.data.photoId)}';`,
    );
    const checksum = createHash("sha256").update(validJpeg).digest("hex");
    assert.equal(metadata, `READY|${validJpeg.byteLength}|${checksum}`);
  });

  await t.test("completion rejects malformed, truncated, missing, oversized, and expired uploads", async () => {
    for (
      const bytes of [
        malformedJpeg,
        validJpeg.slice(0, -12),
        truncatedMetadataJpeg,
      ]
    ) {
      const candidate = await reserveUpload(bytes);
      const result = await complete(candidate.photoId, sa.data.access_token);
      assert.equal(result.status, 422);
      assert.equal(result.data.code, "INVALID_IMAGE");
      assert.equal(
        localSQL(
          `select state from public.photos where id='${uuid(candidate.photoId)}';`,
        ),
        "RESERVED",
      );
    }

    const missing = await reserveUpload();
    const missingResult = await complete(missing.photoId, sa.data.access_token);
    assert.equal(missingResult.status, 409);
    assert.equal(missingResult.data.code, "UPLOAD_INCOMPLETE");

    const oversized = await reserveUpload();
    const oversizedPath = `/storage/v1/object/purchase-photos/${oversized.objectKey}`;
    assert(
      (await upload(
        sa.data.access_token,
        new Uint8Array(5 * 1024 * 1024 + 1),
        "false",
        oversizedPath,
      )).status >= 400,
    );
    assert.equal(
      (await complete(oversized.photoId, sa.data.access_token)).data.code,
      "UPLOAD_INCOMPLETE",
    );

    const expired = await reserveUpload(validJpeg);
    localSQL(`update public.photos set expires_at=now()-interval '1 second'
      where id='${uuid(expired.photoId)}';`);
    const expiredResult = await complete(expired.photoId, sa.data.access_token);
    assert.equal(expiredResult.status, 409);
    assert.equal(expiredResult.data.code, "RESERVATION_EXPIRED");
  });

  const created = await h.rpc("create_item", {
    householdId: household,
    requestId: randomUUID(),
    name: "HTTP photo kettle",
    photoId: reserved.data.photoId,
  }, sa.data.access_token);
  assert.equal(created.status, 200);
  assert.equal(created.data.photoId, reserved.data.photoId);

  await t.test("attachment widens reads to the household but not outsiders", async () => {
    const spouseDownload = await download(sb.data.access_token);
    assert.equal(spouseDownload.status, 200);
    assert.deepEqual(spouseDownload.data, validJpeg);
    assert((await download(so.data.access_token)).status >= 400);
    const listing = await h.request("/storage/v1/object/list/purchase-photos", {
      method: "POST",
      body: { prefix: "", limit: 100 },
      token: sb.data.access_token,
    });
    assert.equal(listing.status, 200);
    assert.deepEqual(listing.data, []);
  });

  const runCleanup = (limit = 25) =>
    h.serviceRequest("/functions/v1/cleanup", { method: "POST", body: { limit } });

  await t.test("spouse removal queues deletion and worker purges object before metadata", async () => {
    assert.equal(
      (await h.request("/functions/v1/cleanup", {
        method: "POST",
        body: { limit: 1 },
        token: sa.data.access_token,
      })).status,
      401,
    );
    assert.equal((await runCleanup(26)).status, 422);
    const removed = await h.rpc("remove_item_photo", {
      itemId: created.data.id,
      expectedVersion: created.data.version,
    }, sb.data.access_token);
    assert.equal(removed.status, 200);
    assert.equal(removed.data.photoId, null);
    assert.equal((await download(sa.data.access_token)).status, 400);
    const cleaned = await runCleanup();
    assert.equal(cleaned.status, 200);
    assert(cleaned.data.succeeded >= 1);
    assert.equal(
      localSQL(`select count(*) from public.photos where id='${uuid(reserved.data.photoId)}';`),
      "0",
    );
  });

  await t.test("missing object discard is idempotent and completes cleanup", async () => {
    const missing = await reserveUpload();
    const path = `/functions/v1/media/photos/${missing.photoId}`;
    assert.equal(
      (await h.request(path, { method: "DELETE", token: sb.data.access_token })).status,
      404,
    );
    assert.equal(
      (await h.request(path, {
        method: "DELETE",
        body: {},
        token: sa.data.access_token,
      })).status,
      422,
    );
    assert.equal(
      (await h.request(path, { method: "DELETE", token: sa.data.access_token })).status,
      204,
    );
    assert.equal(
      (await h.request(path, { method: "DELETE", token: sa.data.access_token })).status,
      204,
    );
    assert.equal((await runCleanup()).status, 200);
    assert.equal(
      localSQL(`select count(*) from public.photos where id='${uuid(missing.photoId)}';`),
      "0",
    );
  });

  await t.test("attachment and discard serialize to one lifecycle winner", async () => {
    const candidate = await reserveUpload(validJpeg);
    assert.equal((await complete(candidate.photoId, sa.data.access_token)).status, 200);
    const [attached, discarded] = await Promise.all([
      h.rpc("create_item", {
        householdId: household,
        requestId: randomUUID(),
        name: "Racing photo",
        photoId: candidate.photoId,
      }, sa.data.access_token),
      h.request(`/functions/v1/media/photos/${candidate.photoId}`, {
        method: "DELETE",
        token: sa.data.access_token,
      }),
    ]);
    assert(
      (attached.status === 200 && discarded.status === 409) ||
        (attached.status === 409 && discarded.status === 204),
    );
    const state = localSQL(
      `select state from public.photos where id='${uuid(candidate.photoId)}';`,
    );
    assert(["ATTACHED", "DELETE_PENDING"].includes(state));
  });

  await t.test("spouse purchase deletion queues and completes attached-photo cleanup", async () => {
    const candidate = await reserveUpload(validJpeg);
    assert.equal((await complete(candidate.photoId, sa.data.access_token)).status, 200);
    const item = await h.rpc("create_item", {
      householdId: household,
      requestId: randomUUID(),
      name: "Deleted photo purchase",
      photoId: candidate.photoId,
    }, sa.data.access_token);
    assert.equal(item.status, 200);
    assert.equal(
      (await h.rpc("delete_item", {
        id: item.data.id,
        expectedVersion: item.data.version,
      }, sb.data.access_token)).status,
      204,
    );
    assert.equal((await runCleanup()).status, 200);
    assert.equal(
      localSQL(`select count(*) from public.photos where id='${uuid(candidate.photoId)}';`),
      "0",
    );
    const candidatePath = `/storage/v1/object/purchase-photos/${candidate.objectKey}`;
    assert((await download(sa.data.access_token, candidatePath)).status >= 400);
  });

  await t.test("revocation immediately removes attached-photo access", async () => {
    const candidate = await reserveUpload(validJpeg);
    assert.equal((await complete(candidate.photoId, sa.data.access_token)).status, 200);
    const item = await h.rpc("create_item", {
      householdId: household,
      requestId: randomUUID(),
      name: "Revocation photo",
      photoId: candidate.photoId,
    }, sa.data.access_token);
    assert.equal(item.status, 200);
    const candidatePath = `/storage/v1/object/purchase-photos/${candidate.objectKey}`;
    assert.equal((await download(sb.data.access_token, candidatePath)).status, 200);
    localSQL(
      `delete from public.household_members where user_id='${uuid(b.id)}';`,
    );
    assert((await download(sb.data.access_token, candidatePath)).status >= 400);
  });
});
