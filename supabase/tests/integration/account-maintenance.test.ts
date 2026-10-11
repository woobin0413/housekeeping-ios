import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import test from "node:test";
import { localHarness, localSQL, uuid } from "./local-harness.mjs";

const jpeg = new Uint8Array(Buffer.from(
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSgBBwcHCggKEwoKEygaFhooKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKP/AABEIAAEAAQMBEQACEQEDEQH/xAGiAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+gEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoLEQACAQIEBAMEBwUEBAABAncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/2gAMAwEAAhEDEQA/APOqyPIP/9k=",
  "base64",
));

test("operator removal and closure preserve or purge actual Storage bytes", async (t) => {
  const h = localHarness();
  const operationIds: string[] = [];
  t.after(async () => {
    await h.cleanup();
    for (const operationId of operationIds) {
      localSQL(`delete from private.account_operations where id='${uuid(operationId)}';`);
    }
  });

  async function attachedPhoto() {
    const a = await h.createUser();
    const b = await h.createUser();
    const householdId = h.provision(a, b);
    const [sessionA, sessionB] = await Promise.all([h.signIn(a), h.signIn(b)]);
    assert.equal(sessionA.status, 200);
    assert.equal(sessionB.status, 200);
    const reserved = await h.request("/functions/v1/media/photos", {
      method: "POST",
      body: { householdId, requestId: randomUUID() },
      token: sessionA.data.access_token,
    });
    assert.equal(reserved.status, 201);
    const objectPath = `/storage/v1/object/purchase-photos/${reserved.data.objectKey}`;
    assert.equal(
      (await h.bytesRequest(objectPath, {
        method: "POST",
        body: jpeg,
        token: sessionA.data.access_token,
        headers: { "Content-Type": "image/jpeg", "x-upsert": "false" },
      })).status,
      200,
    );
    const checksum = createHash("sha256").update(jpeg).digest("hex");
    localSQL(
      `update public.photos set state='READY',byte_size=${jpeg.byteLength},
      mime_type='image/jpeg',checksum='${checksum}'
      where id='${uuid(reserved.data.photoId)}';`,
    );
    const item = await h.rpc("create_item", {
      householdId,
      requestId: randomUUID(),
      name: "Account operation fixture",
      photoId: reserved.data.photoId,
    }, sessionA.data.access_token);
    assert.equal(item.status, 200);
    return {
      a,
      b,
      householdId,
      item,
      objectPath,
      reserved,
      sessionA,
      sessionB,
    };
  }

  await t.test("member removal revokes immediately and retains spouse photo access", async () => {
    const fixture = await attachedPhoto();
    const operationId = randomUUID();
    operationIds.push(operationId);
    const body = {
      action: "removeMember",
      confirmation: "REMOVE MEMBER",
      operationId,
      householdId: fixture.householdId,
      userId: fixture.a.id,
    };
    assert.equal(
      (await h.request("/functions/v1/account-maintenance", {
        method: "POST",
        body,
        token: fixture.sessionA.data.access_token,
      })).status,
      401,
    );
    const removed = await h.serviceRequest(
      "/functions/v1/account-maintenance",
      {
        method: "POST",
        body,
      },
    );
    assert.equal(removed.status, 200);
    assert.equal(removed.data.status, "COMPLETED");
    assert.equal(
      (await h.serviceRequest("/functions/v1/account-maintenance", {
        method: "POST",
        body,
      })).status,
      200,
    );
    assert.equal(
      (await h.rpc("get_household", {}, fixture.sessionA.data.access_token))
        .status,
      404,
    );
    const spousePhoto = await h.bytesRequest(fixture.objectPath, {
      token: fixture.sessionB.data.access_token,
    });
    assert.equal(spousePhoto.status, 200);
    assert.deepEqual(spousePhoto.data, jpeg);
    assert.equal(
      localSQL(
        `select count(*) from auth.users where id='${uuid(fixture.a.id)}';`,
      ),
      "0",
    );
    assert.equal(
      localSQL(`select owner_id is null from storage.objects
      where bucket_id='purchase-photos' and name='${fixture.reserved.data.objectKey}';`),
      "t",
    );
    assert.equal(
      localSQL(`select count(*) from public.items
      where id='${uuid(fixture.item.data.id)}' and photo_id='${
        uuid(fixture.reserved.data.photoId)
      }';`),
      "1",
    );
  });

  await t.test("household closure deletes bytes before records and identities", async () => {
    const fixture = await attachedPhoto();
    const operationId = randomUUID();
    operationIds.push(operationId);
    const closed = await h.serviceRequest("/functions/v1/account-maintenance", {
      method: "POST",
      body: {
        action: "closeHousehold",
        confirmation: "CLOSE HOUSEHOLD",
        operationId,
        householdId: fixture.householdId,
      },
    });
    assert.equal(closed.status, 200);
    assert.equal(closed.data.status, "COMPLETED");
    assert(
      (await h.bytesRequest(fixture.objectPath, {
        token: fixture.sessionA.data.access_token,
      })).status >= 400,
    );
    assert.equal(
      localSQL(`select count(*) from storage.objects
      where bucket_id='purchase-photos' and name='${fixture.reserved.data.objectKey}';`),
      "0",
    );
    assert.equal(
      localSQL(`select count(*) from public.households
      where id='${uuid(fixture.householdId)}';`),
      "0",
    );
    assert.equal(
      localSQL(`select count(*) from public.items
      where id='${uuid(fixture.item.data.id)}';`),
      "0",
    );
    assert.equal(
      localSQL(`select count(*) from auth.users where id in
      ('${uuid(fixture.a.id)}','${uuid(fixture.b.id)}');`),
      "0",
    );
    assert.equal(
      localSQL(`select state from private.account_operations
      where id='${uuid(operationId)}';`),
      "COMPLETED",
    );
  });
});
