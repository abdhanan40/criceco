// push-dispatch · the request handler and the dispatch loop (M3 P5), with
// fake claim / report / send — the database side is covered by
// supabase/tests/local/22 and 22b.
import { test } from "node:test";
import assert from "node:assert/strict";
import { type Deps, dispatch, handle, type Report, sameSecret, summarize } from "./dispatch.ts";
import type { SendOutcome } from "./fcm.ts";
import type { PushRow } from "./templates.ts";

let seq = 0;
function row(tokens: string[], type = "announcement"): PushRow {
  seq++;
  return {
    notification_id: `00000000-0000-4000-8000-${String(seq).padStart(12, "0")}`,
    inbox: "player",
    type,
    params: { club_name: "Note Lions", title: "Nets" },
    club_id: null,
    match_id: null,
    subject_id: null,
    created_at: "2026-11-22T10:00:00Z",
    attempts: 1,
    tokens,
  };
}

/** A fake world: queued batches, each token's outcome, and what was reported. */
function world(batches: PushRow[][], outcome: (token: string) => SendOutcome = () => ({ kind: "sent" })) {
  const reports: Report[][] = [];
  const sent: Array<{ token: string; title: string }> = [];
  let claims = 0;
  const deps: Deps = {
    secret: "s3cret",
    batch: 2,
    claim: async (limit) => {
      assert.equal(limit, 2);
      claims++;
      return batches.shift() ?? [];
    },
    report: async (r) => {
      reports.push(r);
      return r.length;
    },
    send: async (token, _row, text) => {
      sent.push({ token, title: text.title });
      return outcome(token);
    },
  };
  return { deps, reports, sent, claims: () => claims };
}

function post(secret?: string): Request {
  return new Request("https://example.local/functions/v1/push-dispatch", {
    method: "POST",
    headers: secret === undefined ? {} : { "x-push-secret": secret },
    body: "{}",
  });
}

test("only the database may call it: the shared secret, POST only", async () => {
  const { deps } = world([]);
  assert.equal((await handle(new Request("https://x/", { method: "GET" }), deps)).status, 405);
  assert.equal((await handle(post(), deps)).status, 401);
  assert.equal((await handle(post("wrong"), deps)).status, 401);
  assert.equal((await handle(post("s3cret"), { ...deps, secret: undefined })).status, 500);
  const ok = await handle(post("s3cret"), deps);
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), { claimed: 0, sent: 0, retried: 0, failed: 0 });
});

test("the secret check is exact", () => {
  assert.ok(sameSecret("abc", "abc"));
  assert.ok(!sameSecret("abc", "abd"));
  assert.ok(!sameSecret("abc", "abcd"));
  assert.ok(!sameSecret("", "abc"));
});

test("each delivery goes to all its devices; one success is \"sent\"", async () => {
  const a = row(["t1", "t2"]);
  const { deps, reports, sent } = world([[a]], (t) => (t === "t1" ? { kind: "retry", error: "UNAVAILABLE" } : { kind: "sent" }));
  const s = await dispatch(deps);
  assert.deepEqual(s, { claimed: 1, sent: 1, retried: 0, failed: 0 });
  assert.deepEqual(sent.map((x) => x.token), ["t1", "t2"]);
  assert.equal(sent[0].title, "Club Announcement");
  assert.deepEqual(reports, [[{ notification_id: a.notification_id, outcome: "sent" }]]);
});

test("gone tokens are reported for removal; busy FCM is a retry; otherwise failed", () => {
  const r = row(["gone", "busy"]);
  assert.deepEqual(summarize(r, [{ kind: "invalid_token", error: "UNREGISTERED" }, { kind: "retry", error: "UNAVAILABLE" }]), {
    notification_id: r.notification_id,
    outcome: "retry",
    error: "UNAVAILABLE",
    invalid_tokens: ["gone"],
  });
  const f = row(["gone"]);
  assert.deepEqual(summarize(f, [{ kind: "invalid_token", error: "UNREGISTERED" }]), {
    notification_id: f.notification_id,
    outcome: "failed",
    error: "UNREGISTERED",
    invalid_tokens: ["gone"],
  });
});

test("full batches keep coming → more rounds; a short batch ends the wake", async () => {
  const { deps, reports, claims } = world([[row(["a"]), row(["b"])], [row(["c"]), row(["d"])], [row(["e"])], [row(["never"])]]);
  const s = await dispatch(deps);
  assert.equal(s.claimed, 5);
  assert.equal(claims(), 3);
  assert.equal(reports.length, 3);
});

test("at most maxRounds per wake (the rest waits for the next)", async () => {
  const batches = Array.from({ length: 10 }, () => [row(["x"]), row(["y"])]);
  const { deps, claims } = world(batches);
  await dispatch({ ...deps, maxRounds: 3 });
  assert.equal(claims(), 3);
});

test("a delivery whose recipient has no device any more is not sent nor reported", async () => {
  const { deps, reports, sent } = world([[row([])]]);
  const s = await dispatch(deps);
  assert.equal(s.claimed, 1);
  assert.equal(sent.length, 0);
  assert.equal(reports.length, 0);
});

test("a database failure answers 500 with no detail", async () => {
  const { deps } = world([]);
  const res = await handle(post("s3cret"), { ...deps, claim: async () => { throw new Error("connection details here"); } });
  assert.equal(res.status, 500);
  assert.deepEqual(await res.json(), { error: "dispatch_failed" });
});

test("the response never carries a token or a text", async () => {
  const { deps } = world([[row(["secret-token-123"])]]);
  const body = await (await handle(post("s3cret"), deps)).text();
  assert.ok(!body.includes("secret-token-123") && !body.includes("Club Announcement") && !body.includes("Nets"));
});
