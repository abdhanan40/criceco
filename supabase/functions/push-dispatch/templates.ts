// CricEco · push-dispatch · the lock-screen text of a push (M3 P5).
//
// Written from the notification's type and parameters, like the app's inbox
// rows (lib/features/notifications/server_notification_adapter.dart): the
// same titles and lines, so a push and its inbox row read the same. Never any
// free text except an announcement's title (no reasons, no messages); a
// person who deleted their account is "Deleted player". A missing parameter
// gets a neutral word, never "undefined".
//
// Plain TypeScript with erasable types only: Deno runs it deployed, Node runs
// its tests (templates_test.ts).

/** One row of public.push_claim (migration 27). */
export type PushRow = {
  notification_id: string;
  inbox: "player" | "club_owner";
  type: string;
  params: Record<string, unknown>;
  club_id: string | null;
  match_id: string | null;
  subject_id: string | null;
  created_at: string;
  attempts: number;
  tokens: string[];
};

export type PushText = { title: string; body: string };

/** What an unknown (newer) type shows: nothing wrong, nothing invented. */
export const GENERIC: PushText = { title: "CricEco", body: "You have a new notification" };

const DELETED_PERSON = "Deleted player";

const FORMATS: Record<string, string> = { test: "Test", t20: "T20", odi: "ODI", t10: "T10" };

function text(p: Record<string, unknown>, key: string): string | null {
  const v = p[key];
  return typeof v === "string" && v.trim() !== "" ? v.trim() : null;
}

function join(parts: Array<string | null>): string {
  return parts.filter((s): s is string => s !== null && s !== "").join(" · ");
}

/** "Tue 10:00 am, 2 Dec" in Pakistan time (the app shows local time). */
function when(p: Record<string, unknown>, key: string): string | null {
  const s = text(p, key);
  if (s === null) return null;
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return null;
  const tz = { timeZone: "Asia/Karachi" } as const;
  const day = new Intl.DateTimeFormat("en-GB", { ...tz, weekday: "short" }).format(d);
  const time = new Intl.DateTimeFormat("en-GB", { ...tz, hour: "numeric", minute: "2-digit", hour12: true }).format(d);
  const date = new Intl.DateTimeFormat("en-GB", { ...tz, day: "numeric", month: "short" }).format(d);
  return `${day} ${time}, ${date}`;
}

function answerBy(p: Record<string, unknown>): string | null {
  const w = when(p, "expires_at");
  return w === null ? null : `Answer by ${w}`;
}

/** "2 Dec" from a calendar date (YYYY-MM-DD). */
function calendarDate(p: Record<string, unknown>, key: string): string | null {
  const s = text(p, key);
  if (s === null || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const d = new Date(`${s}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) return null;
  return new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short" }).format(d);
}

function format(p: Record<string, unknown>): string | null {
  const f = text(p, "format");
  if (f === null) return null;
  if (f === "custom") {
    const overs = p["custom_overs"];
    return typeof overs === "number" ? `Custom · ${overs} overs` : "Custom Overs";
  }
  return FORMATS[f] ?? null;
}

function result(r: string | null, club: string, opponent: string): string {
  switch (r) {
    case "won":
      return `${club} won against ${opponent}`;
    case "lost":
      return `${club} lost to ${opponent}`;
    case "tied":
      return `${club} tied with ${opponent}`;
    case "abandoned":
      return `Abandoned: ${club} vs ${opponent}`;
    default:
      return `No result: ${club} vs ${opponent}`;
  }
}

function role(code: string | null): string {
  switch (code) {
    case "player":
      return "a player";
    case "coach":
      return "a coach";
    case "manager":
      return "a manager";
    default:
      return "a member";
  }
}

/** The push's title and line for [row]. */
export function render(row: Pick<PushRow, "type" | "params" | "inbox">): PushText {
  const p = row.params ?? {};
  const club = text(p, "club_name") ?? "your club";
  const opponent = text(p, "opponent_name") ?? "the other club";
  const person = p["person_deleted"] === true ? DELETED_PERSON : (text(p, "person_name") ?? "A club member");
  const reschedule = p["reschedule"] === true;
  const fixture = join([`${club} vs ${opponent}`, when(p, "starts_at")]);
  const terms = join([format(p), calendarDate(p, "proposed_date"), text(p, "venue_name")]);
  const schedule = join([when(p, "starts_at"), text(p, "venue_name"), text(p, "city")]);

  switch (row.type) {
    case "join_request_received":
      return { title: `Join request from ${person}`, body: club };
    case "join_request_approved":
      return { title: "Join request approved", body: `You are now ${role(text(p, "role"))} at ${club}` };
    case "join_request_declined":
      return { title: "Join request not accepted", body: `${club} didn’t accept your request` };
    case "removed_from_club":
      return { title: "Club membership ended", body: `You are no longer a member of ${club}` };
    case "ownership_offered":
      return { title: "Club ownership offer", body: `${person} offered you ownership of ${club}` };
    case "ownership_withdrawn":
      return { title: "Ownership offer withdrawn", body: `${person} withdrew the offer for ${club}` };
    case "ownership_rejected":
      return { title: "Ownership offer declined", body: `${person} declined ownership of ${club}` };
    case "ownership_accepted":
      return { title: "Club ownership transferred", body: `${person} is now the owner of ${club}` };
    case "challenge_received":
      return { title: `Challenge from ${opponent}`, body: terms || "Open My Challenges to answer" };
    case "challenge_accepted":
      return { title: `${opponent} accepted your challenge`, body: join([terms, "Agree the schedule next"]) };
    case "challenge_declined":
      return { title: `${opponent} declined your challenge`, body: terms || "Open My Challenges" };
    case "schedule_proposed":
      return {
        title: reschedule ? `${opponent} proposed a new match time` : `${opponent} proposed a match time`,
        body: schedule || "Open Match Management to answer",
      };
    case "schedule_accepted":
      return {
        title: reschedule ? `${opponent} accepted the new match time` : `${opponent} confirmed the match`,
        body: schedule || "See Match Management",
      };
    case "schedule_declined":
      return { title: `${opponent} declined your proposed time`, body: schedule || "See Match Management" };
    case "match_rescheduled":
      return { title: "Match rescheduled", body: join([fixture, text(p, "venue_name")]) };
    case "match_cancelled": {
      const ownerView = row.inbox === "club_owner" && !("selection" in p);
      return {
        title: "Match cancelled",
        body: ownerView ? join([`vs ${opponent}`, when(p, "starts_at")]) : fixture,
      };
    }
    case "lineup_selected": {
      const sel = text(p, "selection");
      const leader = text(p, "leader");
      const title = sel !== "playing"
        ? "You’re a substitute"
        : leader === "captain"
        ? "You’re captain of the Playing XI"
        : leader === "vice_captain"
        ? "You’re vice-captain of the Playing XI"
        : "You’re in the Playing XI";
      return { title, body: fixture };
    }
    case "lineup_changed":
      return {
        title: text(p, "selection") === "playing" ? "You’re now in the Playing XI" : "You’re now a substitute",
        body: fixture,
      };
    case "lineup_dropped":
      return { title: "You’re no longer in the line-up", body: fixture };
    case "result_published":
      return { title: result(text(p, "result"), club, opponent), body: "Official result" };
    case "result_corrected":
      return { title: result(text(p, "result"), club, opponent), body: "The official result was corrected" };
    case "player_of_match":
      return { title: "You’re the Player of the Match", body: `${club} vs ${opponent}` };
    case "announcement":
      return { title: "Club Announcement", body: join([club, text(p, "title")]) };
    // Reminders (migration 28, M3 P6).
    case "match_reminder":
      return { title: "Your match is coming up", body: join([fixture, text(p, "venue_name")]) };
    case "challenge_expiring":
      return {
        title: `Challenge from ${opponent} expires soon`,
        body: join([answerBy(p), terms]) || "Open My Challenges to answer",
      };
    case "ownership_expiring":
      return {
        title: "Ownership offer expires soon",
        body: join([`${person} offered you ${club}`, answerBy(p)]),
      };
    default:
      return GENERIC;
  }
}
