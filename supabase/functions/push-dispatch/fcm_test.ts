// push-dispatch · FCM HTTP v1 (M3 P5): the OAuth assertion, token caching,
// the message and FCM's answers. No network, no real key: a throwaway RSA key
// is generated for the test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { AccessTokens, buildMessage, classify, parseServiceAccount, sendOne, signedAssertion } from "./fcm.ts";
import { dispatch } from "./dispatch.ts";
import type { PushRow } from "./templates.ts";

async function throwawayAccount() {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let bin = "";
  for (const b of der) bin += String.fromCharCode(b);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(bin).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----\n`;
  return {
    account: { project_id: "criceco-test", client_email: "push@criceco-test.iam.gserviceaccount.com", private_key: pem },
    publicKey: pair.publicKey,
  };
}

function b64urlDecode(s: string): Uint8Array {
  const raw = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

const row: PushRow = {
  notification_id: "11111111-1111-4111-8111-111111111111",
  inbox: "player",
  type: "lineup_selected",
  params: { club_name: "Note Lions", selection: "playing" },
  club_id: "22222222-2222-4222-8222-222222222222",
  match_id: "33333333-3333-4333-8333-333333333333",
  subject_id: null,
  created_at: "2026-11-22T10:00:00Z",
  attempts: 1,
  tokens: ["tok-a"],
};

test("the service account secret: only a well-formed one is accepted", async () => {
  const { account } = await throwawayAccount();
  assert.deepEqual(parseServiceAccount(JSON.stringify({ ...account, extra: "ignored" })), account);
  for (const bad of [undefined, "", "not json", JSON.stringify({ ...account, project_id: "Bad Id!" }),
                     JSON.stringify({ ...account, private_key: "nope" }), JSON.stringify({ project_id: "x" })]) {
    assert.equal(parseServiceAccount(bad), null, String(bad));
  }
});

test("the OAuth assertion is an RS256 JWT for FCM, signed with the account's key", async () => {
  const { account, publicKey } = await throwawayAccount();
  const jwt = await signedAssertion(account, 1_000_000);
  const [h, c, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(new TextDecoder().decode(b64urlDecode(h))), { alg: "RS256", typ: "JWT" });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(b64urlDecode(c))), {
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: 1_000_000,
    exp: 1_003_600,
  });
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", publicKey, b64urlDecode(s),
    new TextEncoder().encode(`${h}.${c}`));
  assert.ok(ok);
});

test("the access token is fetched once and reused until a minute before it expires", async () => {
  const { account } = await throwawayAccount();
  let now = 1_000_000;
  const calls: string[] = [];
  const fake = async (url: string, init?: RequestInit) => {
    calls.push(url);
    assert.match(String(init?.body), /^grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=/);
    return new Response(JSON.stringify({ access_token: `at-${calls.length}`, expires_in: 3600 }), { status: 200 });
  };
  const tokens = new AccessTokens(account, fake, () => now);
  assert.equal(await tokens.get(), "at-1");
  now += 3500;
  assert.equal(await tokens.get(), "at-1");
  now += 60;
  assert.equal(await tokens.get(), "at-2");
  tokens.reset();
  assert.equal(await tokens.get(), "at-3");
  assert.deepEqual(new Set(calls), new Set(["https://oauth2.googleapis.com/token"]));
});

test("a refused OAuth exchange is an error (no token is invented)", async () => {
  const { account } = await throwawayAccount();
  const tokens = new AccessTokens(account, async () => new Response("no", { status: 400 }), () => 1);
  await assert.rejects(tokens.get(), /oauth_400/);
});

test("the message: addressed by FID, the text, ids to open the right screen, one per inbox row", () => {
  const m = buildMessage("fid-a", row, { title: "You’re in the Playing XI", body: "Note Lions vs Note Kings" });
  // deepEqual is exact: `fid` is the only target (FCM refuses a second one, `token`).
  assert.deepEqual(m, {
    message: {
      fid: "fid-a",
      notification: { title: "You’re in the Playing XI", body: "Note Lions vs Note Kings" },
      data: {
        notification_id: row.notification_id,
        type: "lineup_selected",
        inbox: "player",
        match_id: row.match_id!,
        club_id: row.club_id!,
      },
      android: { priority: "HIGH", notification: { tag: row.notification_id } },
    },
  });
});

function fcmError(status: number, code: string, errorCode?: string): Response {
  return new Response(JSON.stringify({
    error: {
      code: status,
      status: code,
      message: "details",
      details: errorCode ? [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode }] : [],
    },
  }), { status });
}

test("FCM's answers: sent, token gone, try later, failed", async () => {
  assert.deepEqual(await classify(new Response("{}", { status: 200 })), { kind: "sent" });
  assert.deepEqual(await classify(fcmError(404, "NOT_FOUND", "UNREGISTERED")), { kind: "invalid_token", error: "UNREGISTERED" });
  assert.deepEqual(await classify(fcmError(403, "PERMISSION_DENIED", "SENDER_ID_MISMATCH")),
    { kind: "invalid_token", error: "SENDER_ID_MISMATCH" });
  assert.deepEqual(await classify(fcmError(503, "UNAVAILABLE", "UNAVAILABLE")), { kind: "retry", error: "UNAVAILABLE" });
  assert.deepEqual(await classify(fcmError(429, "RESOURCE_EXHAUSTED", "QUOTA_EXCEEDED")),
    { kind: "retry", error: "QUOTA_EXCEEDED" });
  assert.deepEqual(await classify(new Response("down", { status: 500 })), { kind: "retry", error: "HTTP_500" });
  assert.deepEqual(await classify(fcmError(401, "UNAUTHENTICATED")), { kind: "retry", error: "AUTH" });
  // A bad message is NOT a reason to delete the token.
  assert.deepEqual(await classify(fcmError(400, "INVALID_ARGUMENT", "INVALID_ARGUMENT")),
    { kind: "failed", error: "INVALID_ARGUMENT" });
});

/** FCM's answers as recorded live (C3 Fix A, validate_only, made-up targets; ids left out). */
function recorded(status: number, error: Record<string, unknown>): Response {
  return new Response(JSON.stringify({ error: { code: status, ...error } }), { status });
}
const FCM_ERROR = "type.googleapis.com/google.firebase.fcm.v1.FcmError";
const BAD_REQUEST = "type.googleapis.com/google.rpc.BadRequest";

test("an FID FCM doesn't know (made up, malformed, signed out) is gone: removed", async () => {
  const notRegistered = recorded(404, {
    status: "NOT_FOUND",
    message: "NotRegistered",
    details: [{ "@type": FCM_ERROR, errorCode: "UNREGISTERED" }],
  });
  assert.deepEqual(await classify(notRegistered), { kind: "invalid_token", error: "UNREGISTERED" });
});

test("a wrong payload is never blamed on the device (nothing removed, no retry)", async () => {
  // Each of these names the target, yet the device is fine: the message is wrong.
  for (const message of [
    "Recipient of the message is not set.",
    "Invalid JSON payload received. Unknown name \"fid\" at 'message': Cannot find field.",
    "Invalid value at 'message' (oneof), oneof field 'target' is already set. Cannot set 'token'",
  ]) {
    const res = recorded(400, {
      status: "INVALID_ARGUMENT",
      message,
      details: [
        { "@type": BAD_REQUEST, fieldViolations: [{ field: "message", description: message }] },
        { "@type": FCM_ERROR, errorCode: "INVALID_ARGUMENT" },
      ],
    });
    assert.deepEqual(await classify(res), { kind: "failed", error: "INVALID_ARGUMENT" }, message);
  }
  // Without FCM's own error code (only BadRequest), still a plain failure.
  const plain = recorded(400, {
    status: "INVALID_ARGUMENT",
    message: "Invalid JSON payload received.",
    details: [{ "@type": BAD_REQUEST, fieldViolations: [{ field: "message" }] }],
  });
  assert.deepEqual(await classify(plain), { kind: "failed", error: "INVALID_ARGUMENT" });
});

test("FCM's internal error is tried again later", async () => {
  const internal = recorded(500, {
    status: "INTERNAL",
    message: "Unknown internal error occurred.",
    details: [{ "@type": FCM_ERROR, errorCode: "INTERNAL" }],
  });
  assert.deepEqual(await classify(internal), { kind: "retry", error: "INTERNAL" });
});

test("FID delivery end to end: dispatch → message.fid → FCM's answer → the report", async () => {
  const bodies: Array<Record<string, any>> = [];
  const fetchFn = async (_url: string, init?: RequestInit) => {
    const body = JSON.parse(String(init!.body));
    bodies.push(body);
    const fid = body.message.fid as string;
    if (fid === "fid-live-aaaaaaaaaaaaaa") return new Response("{\"name\":\"projects/p/messages/1\"}", { status: 200 });
    if (fid === "fid-gone-bbbbbbbbbbbbbb") {
      return recorded(404, { status: "NOT_FOUND", message: "NotRegistered", details: [{ "@type": FCM_ERROR, errorCode: "UNREGISTERED" }] });
    }
    return recorded(503, { status: "UNAVAILABLE", message: "busy", details: [{ "@type": FCM_ERROR, errorCode: "UNAVAILABLE" }] });
  };
  const send = (fid: string, r: PushRow, text: { title: string; body: string }) =>
    sendOne(fetchFn, "criceco-test", "at-1", buildMessage(fid, r, text));
  const reports: unknown[] = [];
  const rows: PushRow[] = [
    { ...row, notification_id: "00000000-0000-4000-8000-000000000001", tokens: ["fid-live-aaaaaaaaaaaaaa", "fid-gone-bbbbbbbbbbbbbb"] },
    { ...row, notification_id: "00000000-0000-4000-8000-000000000002", tokens: ["fid-busy-cccccccccccccc"] },
    { ...row, notification_id: "00000000-0000-4000-8000-000000000003", tokens: ["fid-gone-bbbbbbbbbbbbbb"] },
  ];
  let batches = [rows];
  const s = await dispatch({
    secret: "s",
    batch: 10,
    claim: async () => batches.shift() ?? [],
    report: async (r) => { reports.push(...r); return r.length; },
    send,
  });
  assert.deepEqual(s, { claimed: 3, sent: 1, retried: 1, failed: 1 });
  for (const b of bodies) {
    assert.equal(typeof b.message.fid, "string");
    assert.equal("token" in b.message, false);
  }
  assert.deepEqual(reports, [
    { notification_id: rows[0].notification_id, outcome: "sent", invalid_tokens: ["fid-gone-bbbbbbbbbbbbbb"] },
    { notification_id: rows[1].notification_id, outcome: "retry", error: "UNAVAILABLE" },
    { notification_id: rows[2].notification_id, outcome: "failed", error: "UNREGISTERED", invalid_tokens: ["fid-gone-bbbbbbbbbbbbbb"] },
  ]);
  batches = [];
});

test("sending: the v1 endpoint with the access token; a network failure is a retry", async () => {
  let seen: { url: string; init?: RequestInit } | null = null;
  const ok = await sendOne(async (url, init) => {
    seen = { url, init };
    return new Response("{}", { status: 200 });
  }, "criceco-test", "at-1", { message: {} });
  assert.deepEqual(ok, { kind: "sent" });
  assert.equal(seen!.url, "https://fcm.googleapis.com/v1/projects/criceco-test/messages:send");
  assert.equal((seen!.init!.headers as Record<string, string>)["Authorization"], "Bearer at-1");
  assert.deepEqual(await sendOne(async () => { throw new Error("reset"); }, "p", "t", {}), { kind: "retry", error: "NETWORK" });
});
