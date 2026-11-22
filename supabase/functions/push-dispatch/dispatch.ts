// CricEco · push-dispatch · the dispatch loop and the request handler (M3 P5).
//
// Woken by the database (migration 27, pg_net) with the shared secret in
// x-push-secret. Claims queued deliveries (public.push_claim), sends each to
// the recipient's devices, and reports what happened (public.push_report):
//   * sent to at least one device → "sent";
//   * otherwise a retryable failure (FCM busy, network) → "retry" (the
//     database tries at most 3 times);
//   * otherwise → "failed";
//   * tokens FCM says no longer exist are removed.
// Several rounds per wake while full batches keep coming. Responses carry
// counts only — never a token, a text or an error detail.
//
// Plain TypeScript with erasable types only (Deno deployed, Node in tests).

import type { SendOutcome } from "./fcm.ts";
import { type PushRow, type PushText, render } from "./templates.ts";

export type Report = {
  notification_id: string;
  outcome: "sent" | "retry" | "failed";
  error?: string;
  invalid_tokens?: string[];
};

export type Deps = {
  /** The shared secret the database sends (PUSH_DISPATCH_SECRET). */
  secret: string | undefined;
  claim: (limit: number) => Promise<PushRow[]>;
  report: (results: Report[]) => Promise<number>;
  send: (token: string, row: PushRow, text: PushText) => Promise<SendOutcome>;
  batch?: number;
  maxRounds?: number;
};

export type Summary = { claimed: number; sent: number; retried: number; failed: number };

/** Constant-time string comparison (the secret check). */
export function sameSecret(given: string, expected: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

/** One delivery's report from its devices' outcomes. */
export function summarize(row: PushRow, outcomes: SendOutcome[]): Report {
  const invalid = row.tokens.filter((_, i) => outcomes[i]?.kind === "invalid_token");
  const base: Report = { notification_id: row.notification_id, outcome: "failed" };
  if (invalid.length > 0) base.invalid_tokens = invalid;
  if (outcomes.some((o) => o.kind === "sent")) return { ...base, outcome: "sent" };
  const retry = outcomes.find((o) => o.kind === "retry");
  if (retry && retry.kind === "retry") return { ...base, outcome: "retry", error: retry.error };
  const first = outcomes.find((o) => o.kind !== "sent");
  return { ...base, outcome: "failed", error: first && first.kind !== "sent" ? first.error : "NO_DEVICE" };
}

export async function dispatch(deps: Deps): Promise<Summary> {
  const batch = deps.batch ?? 100;
  const maxRounds = deps.maxRounds ?? 5;
  const summary: Summary = { claimed: 0, sent: 0, retried: 0, failed: 0 };
  for (let round = 0; round < maxRounds; round++) {
    const rows = await deps.claim(batch);
    summary.claimed += rows.length;
    const reports: Report[] = [];
    for (const row of rows) {
      // No device any more: the database already marked it skipped.
      if (row.tokens.length === 0) continue;
      const text = render(row);
      const outcomes = await Promise.all(row.tokens.map((t) => deps.send(t, row, text)));
      const r = summarize(row, outcomes);
      reports.push(r);
      if (r.outcome === "sent") summary.sent++;
      else if (r.outcome === "retry") summary.retried++;
      else summary.failed++;
    }
    if (reports.length > 0) await deps.report(reports);
    if (rows.length < batch) break;
  }
  return summary;
}

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  if (!deps.secret) return json(500, { error: "not_configured" });
  if (!sameSecret(req.headers.get("x-push-secret") ?? "", deps.secret)) {
    return json(401, { error: "not_allowed" });
  }
  try {
    return json(200, await dispatch(deps));
  } catch {
    // Claimed deliveries stay "sending" and are claimed again after 5 minutes.
    return json(500, { error: "dispatch_failed" });
  }
}
