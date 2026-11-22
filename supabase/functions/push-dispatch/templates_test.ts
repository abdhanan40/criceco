// push-dispatch · the lock-screen text (M3 P5). Runs on Node (no Deno needed):
//   node --test supabase/functions/push-dispatch/*_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { GENERIC, render } from "./templates.ts";

/** The 23 types of migration 25's notifications_type_check. */
function migrationTypes(): string[] {
  const sql = readFileSync(
    new URL("../../migrations/20261122090000_create_notifications.sql", import.meta.url),
    "utf8",
  );
  const list = /notifications_type_check check \(type in \(([^)]*)\)\)/.exec(sql)![1];
  return [...list.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
}

const full = {
  club_name: "Note Lions",
  opponent_name: "Note Kings",
  person_name: "Ali Khan",
  role: "coach",
  format: "t20",
  proposed_date: "2026-12-02",
  venue_name: "Note Ground",
  starts_at: "2026-12-02T05:00:00+00:00",
  selection: "playing",
  result: "won",
  title: "Nets on Friday",
};

test("every type of migration 25 has its own text, in both inboxes", () => {
  const types = migrationTypes();
  assert.equal(types.length, 23);
  for (const type of types) {
    for (const inbox of ["player", "club_owner"] as const) {
      const t = render({ type, inbox, params: full });
      assert.notDeepEqual(t, GENERIC, type);
      assert.ok(t.title.trim() && t.body.trim(), type);
      assert.ok(!/undefined|null|NaN/.test(t.title + t.body), `${type}: ${t.title} / ${t.body}`);
    }
  }
});

test("missing parameters get neutral words, never undefined", () => {
  for (const type of migrationTypes()) {
    const t = render({ type, inbox: "player", params: {} });
    assert.ok(t.title.trim() && t.body.trim(), type);
    assert.ok(!/undefined|null|NaN/.test(t.title + t.body), `${type}: ${t.title} / ${t.body}`);
  }
});

test("the same wording as the app's inbox rows", () => {
  assert.deepEqual(render({ type: "join_request_received", inbox: "club_owner", params: full }), {
    title: "Join request from Ali Khan",
    body: "Note Lions",
  });
  assert.deepEqual(render({ type: "join_request_approved", inbox: "player", params: full }), {
    title: "Join request approved",
    body: "You are now a coach at Note Lions",
  });
  assert.equal(render({ type: "result_published", inbox: "club_owner", params: full }).title,
    "Note Lions won against Note Kings");
  assert.equal(render({ type: "result_published", inbox: "player", params: { ...full, result: "lost" } }).title,
    "Note Lions lost to Note Kings");
  assert.equal(render({ type: "lineup_selected", inbox: "player", params: { ...full, leader: "captain" } }).title,
    "You’re captain of the Playing XI");
  assert.deepEqual(render({ type: "announcement", inbox: "player", params: full }), {
    title: "Club Announcement",
    body: "Note Lions · Nets on Friday",
  });
  assert.equal(render({ type: "challenge_received", inbox: "club_owner", params: full }).body,
    "T20 · 2 Dec · Note Ground");
});

test("a deleted account is \"Deleted player\"; no free text ever appears", () => {
  assert.equal(
    render({ type: "join_request_received", inbox: "club_owner", params: { person_deleted: true, club_name: "X" } }).title,
    "Join request from Deleted player",
  );
  // Parameters the server never sends but must never show if they did.
  const t = render({ type: "match_cancelled", inbox: "club_owner", params: { ...full, reason: "SECRET REASON" } });
  assert.ok(!t.body.includes("SECRET"));
});

test("times are Pakistan time", () => {
  const t = render({ type: "match_rescheduled", inbox: "player", params: full });
  // 05:00 UTC = 10:00 in Karachi.
  assert.match(t.body, /Wed 10:00 am, 2 Dec/i);
});

test("an unknown (newer) type gets the generic text", () => {
  assert.deepEqual(render({ type: "tournament_reminder", inbox: "player", params: full }), GENERIC);
});
