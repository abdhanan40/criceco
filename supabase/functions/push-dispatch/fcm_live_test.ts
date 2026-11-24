// push-dispatch · LIVE Firebase check (C3 Fix A) — opt-in, local only, sends nothing.
//
// Skipped unless FCM_LIVE_SERVICE_ACCOUNT_FILE names the service account JSON
// file (kept outside the repository). With it, the function's own code gets an
// access token and calls FCM HTTP v1 with `validate_only: true`: Firebase
// checks the request and delivers nothing. The targets are made-up FIDs, never
// a real device. Nothing secret or identifying is printed.
//
//   FCM_LIVE_SERVICE_ACCOUNT_FILE=/path/key.json \
//     node --test supabase/functions/push-dispatch/fcm_live_test.ts
//
// Optional: FCM_LIVE_FID=<a real FID> also dry-runs to that device (still
// validate_only: nothing is shown on it) and expects FCM to accept it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { AccessTokens, buildMessage, classify, parseServiceAccount } from "./fcm.ts";
import type { PushRow } from "./templates.ts";

const file = process.env.FCM_LIVE_SERVICE_ACCOUNT_FILE;
const skip = file ? false : "set FCM_LIVE_SERVICE_ACCOUNT_FILE to run the live validate_only check";

const row: PushRow = {
  notification_id: "00000000-0000-4000-8000-0000000000c3",
  inbox: "player",
  type: "announcement",
  params: { club_name: "CricEco", title: "validate only" },
  club_id: null,
  match_id: null,
  subject_id: "00000000-0000-4000-8000-0000000000c3",
  created_at: "2026-11-24T00:00:00Z",
  attempts: 1,
  tokens: [],
};
const text = { title: "CricEco validate-only check", body: "Not delivered (validate_only)" };

async function dryRun(fid: string): Promise<Response> {
  const sa = parseServiceAccount(readFileSync(file!, "utf8"));
  assert.ok(sa, "the service account file is well formed");
  const access = await new AccessTokens(sa, fetch).get();
  const message = buildMessage(fid, row, text);
  return fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${access}`, "Content-Type": "application/json" },
    // validate_only: Firebase validates the request and sends NOTHING.
    body: JSON.stringify({ validate_only: true, ...message }),
  });
}

test("live, validate_only: FCM accepts the fid target; an unknown FID is UNREGISTERED (removed)", { skip }, async () => {
  for (const fid of ["fQ7xZ2kLm9pRt4vWy8bNc3", "not-a-real-installation-id"]) {
    const res = await dryRun(fid);
    // Never 400 "Unknown name fid": the field is supported.
    assert.equal(res.status, 404, `HTTP ${res.status}`);
    assert.deepEqual(await classify(res), { kind: "invalid_token", error: "UNREGISTERED" });
  }
});

test("live, validate_only: a real FID (FCM_LIVE_FID) is accepted, nothing delivered", {
  skip: skip || (process.env.FCM_LIVE_FID ? false : "set FCM_LIVE_FID to dry-run to a real device"),
}, async () => {
  const res = await dryRun(process.env.FCM_LIVE_FID!);
  const body = await res.clone().json() as { name?: string };
  assert.equal(res.status, 200, `HTTP ${res.status}`);
  assert.match(body.name ?? "", /\/messages\/fake_message_id$|\/messages\//);
  assert.deepEqual(await classify(res), { kind: "sent" });
});
