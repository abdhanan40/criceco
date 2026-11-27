// push-dispatch · the lock-screen text (M3 P5). Runs on Node (no Deno needed):
//   node --test supabase/functions/push-dispatch/*_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { GENERIC, render } from "./templates.ts";

/** The database's types now: the LAST notifications_type_check across the
 * migrations (25, then 28, 33 …). */
function migrationTypes(): string[] {
  const dir = new URL("../../migrations/", import.meta.url);
  let list = "";
  for (const name of readdirSync(dir).filter((n) => n.endsWith(".sql")).sort()) {
    const sql = readFileSync(new URL(name, dir), "utf8");
    for (const m of sql.matchAll(/notifications_type_check check \(type in \(([^)]*)\)\)/g)) list = m[1];
  }
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

test("every database type (migrations 25, 28, 33 and 35) has its own text, in both inboxes", () => {
  const types = migrationTypes();
  assert.equal(types.length, 34);
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

test("the reminders (migration 28)", () => {
  assert.deepEqual(render({ type: "match_reminder", inbox: "player", params: full }), {
    title: "Your match is coming up",
    body: "Note Lions vs Note Kings · Wed 10:00 am, 2 Dec · Note Ground",
  });
  const expires = { ...full, expires_at: "2026-12-01T07:30:00+00:00" };
  assert.equal(render({ type: "challenge_expiring", inbox: "club_owner", params: expires }).title,
    "Challenge from Note Kings expires soon");
  assert.match(render({ type: "challenge_expiring", inbox: "club_owner", params: expires }).body,
    /^Answer by Tue 12:30 pm, 1 Dec · T20 · 2 Dec · Note Ground$/i);
  assert.match(render({ type: "ownership_expiring", inbox: "player", params: expires }).body,
    /^Ali Khan offered you Note Lions · Answer by Tue 12:30 pm, 1 Dec$/i);
});

test("Player Hunt (migration 33)", () => {
  const hunt = { ...full, hunt_role: "wicket_keeper", format: "t20", match_date: "2026-12-02" };
  assert.deepEqual(render({ type: "hunt_invite_received", inbox: "player", params: hunt }), {
    title: "Playing invite from Note Lions",
    body: "Wicket-Keeper · T20 · 2 Dec",
  });
  assert.deepEqual(render({ type: "hunt_invite_received", inbox: "player", params: { club_name: "Note Lions" } }), {
    title: "Playing invite from Note Lions",
    body: "Open Playing Opportunities to answer",
  });
  assert.deepEqual(render({ type: "hunt_interest_received", inbox: "club_owner", params: hunt }), {
    title: "Ali Khan is interested in playing",
    body: "Wicket-Keeper · T20 · 2 Dec",
  });
  assert.equal(
    render({ type: "hunt_interest_received", inbox: "club_owner", params: { person_deleted: true, club_name: "X" } })
      .title,
    "Deleted player is interested in playing",
  );
  assert.deepEqual(render({ type: "hunt_invite_accepted", inbox: "club_owner", params: hunt }), {
    title: "Ali Khan accepted your invite",
    body: "Note Lions · See Player Hunt",
  });
});

test("Tournaments (migration 35)", () => {
  const entry = { tournament_name: "Spring Cup", applicant_name: "Note Kings", organizer_name: "Note Lions",
                  team_name: "Kings XI", start_date: "2026-12-02", round_name: "Semifinal" };
  assert.deepEqual(render({ type: "tournament_registration_received", inbox: "club_owner", params: entry }), {
    title: "Tournament entry from Note Kings",
    body: "Spring Cup · Kings XI",
  });
  assert.deepEqual(render({ type: "tournament_registration_received", inbox: "club_owner", params: {} }), {
    title: "Tournament entry from a club",
    body: "Open Team Requests to answer",
  });
  assert.deepEqual(render({ type: "tournament_registration_approved", inbox: "club_owner", params: entry }), {
    title: "Tournament entry approved",
    body: "Spring Cup · Kings XI",
  });
  assert.deepEqual(render({ type: "tournament_registration_rejected", inbox: "club_owner", params: entry }), {
    title: "Tournament entry not accepted",
    body: "Spring Cup · Kings XI",
  });
  assert.deepEqual(render({ type: "tournament_team_removed", inbox: "club_owner", params: entry }), {
    title: "Team removed from tournament",
    body: "Spring Cup · Kings XI",
  });
  assert.deepEqual(render({ type: "tournament_fixtures_published", inbox: "club_owner", params: entry }), {
    title: "Tournament fixtures published",
    body: "Spring Cup · Semifinal · Starts 2 Dec",
  });
  assert.equal(render({ type: "tournament_fixtures_published", inbox: "club_owner", params: {} }).body,
    "See the tournament's fixtures");
});
