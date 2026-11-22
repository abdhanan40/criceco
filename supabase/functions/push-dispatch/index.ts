// CricEco · Edge Function `push-dispatch` — NOT DEPLOYED (M3 P5).
//
// Sends queued in-app notifications as Android pushes through Firebase Cloud
// Messaging (docs/NOTIFICATIONS_BACKEND.md, "P5"). Requires migration 27.
//
// Called ONLY by the database (migration 27's wake-up, through pg_net), with
// the shared secret in the x-push-secret header — not by the app. Deploy
// without JWT verification, as the caller sends no user session:
//   supabase functions deploy push-dispatch --no-verify-jwt
//
// Secrets (set by the project owner, never in code or logs):
//   PUSH_DISPATCH_SECRET   the same value as Vault's 'push_dispatch_secret'
//   FCM_SERVICE_ACCOUNT    the Firebase service account JSON
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   built in
// The service-role key is used only to call push_claim / push_report (the
// tables themselves are closed even to service_role).

import { createClient } from "jsr:@supabase/supabase-js@2";
import { AccessTokens, buildMessage, parseServiceAccount, sendOne } from "./fcm.ts";
import { type Deps, handle, type Report } from "./dispatch.ts";
import type { PushRow } from "./templates.ts";

const noSession = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };

const url = Deno.env.get("SUPABASE_URL");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const secret = Deno.env.get("PUSH_DISPATCH_SECRET");
const account = parseServiceAccount(Deno.env.get("FCM_SERVICE_ACCOUNT"));
const tokens = account ? new AccessTokens(account, fetch) : null;

Deno.serve(async (req: Request): Promise<Response> => {
  if (!url || !serviceKey || !account || !tokens) {
    return new Response(JSON.stringify({ error: "not_configured" }), {
      status: 500,
      headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  }
  const db = createClient(url, serviceKey, noSession);
  const deps: Deps = {
    secret,
    claim: async (limit) => {
      const { data, error } = await db.rpc("push_claim", { p_limit: limit });
      if (error) throw new Error("claim_failed");
      return (data ?? []) as PushRow[];
    },
    report: async (results: Report[]) => {
      const { data, error } = await db.rpc("push_report", { p_results: results });
      if (error) throw new Error("report_failed");
      return typeof data === "number" ? data : 0;
    },
    send: async (token, row, text) => {
      const access = await tokens.get();
      const outcome = await sendOne(fetch, account.project_id, access, buildMessage(token, row, text));
      if (outcome.kind === "retry" && outcome.error === "AUTH") tokens.reset();
      return outcome;
    },
  };
  return handle(req, deps);
});
