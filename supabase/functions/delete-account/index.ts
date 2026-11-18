// CricEco · Edge Function `delete-account` — NOT DEPLOYED.
//
// Deletes the CALLER's account (docs/ACCOUNT_PRIVACY_AND_DELETION.md).
// Requires migrations 14 and 15 on the database; never deploy it before 15
// (without 15 the data step would delete the clubs an owner owns).
//
//   1. The session (Authorization: Bearer <user JWT>) names the user — never a
//      request parameter, so nobody can delete someone else.
//   2. Club owners are refused (409 CLUB_OWNERSHIP_TRANSFER_REQUIRED): the
//      approved policy is "transfer ownership first". The database refuses
//      them too (migration 15) — this early check only gives a clear answer
//      before any password is asked for.
//   3. At most 5 wrong passwords per user per 15 minutes (429), counted by
//      the database (account_deletion_throttled / account_deletion_failed).
//   4. The password typed in the app is checked again on the server, with a
//      throwaway sign-in; its session is ended at once (scope "local": the
//      user's other sessions are untouched).
//   5. public.delete_account_data(user id): the app data, all-or-nothing and
//      idempotent; refuses owners under a row lock (no race).
//   6. auth.admin.deleteUser(user id) — only after step 5 succeeded. If it
//      fails, the user retries the same request: step 5 then does nothing.
//
// Secrets: only the platform's built-in SUPABASE_URL, SUPABASE_ANON_KEY and
// SUPABASE_SERVICE_ROLE_KEY. The service-role key never leaves this function,
// is never logged and never returned. Responses carry an error code only.

import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

const noSession = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
const OWNERSHIP = "CLUB_OWNERSHIP_TRANSFER_REQUIRED";
const MAX_PASSWORD_LENGTH = 72;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return reply(500, { error: "not_configured" });

  // 1. Who is asking: the user of the session, as Supabase Auth sees it.
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return reply(401, { error: "not_authenticated" });
  const admin = createClient(url, serviceKey, noSession);
  const { data: who, error: whoError } = await admin.auth.getUser(jwt);
  const user = who?.user;
  if (whoError || !user) return reply(401, { error: "not_authenticated" });

  // The request: the password again, and the word DELETE. Nothing else is read
  // (an id in the body is ignored — the session decides who is deleted).
  let body: { password?: unknown; confirm?: unknown };
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "invalid_request" });
  }
  if (body === null || typeof body !== "object" || body.confirm !== "DELETE" ||
      typeof body.password !== "string" || body.password.length === 0 ||
      body.password.length > MAX_PASSWORD_LENGTH) {
    return reply(400, { error: "invalid_request" });
  }
  if (!user.email) return reply(400, { error: "no_email_password_account" });

  // 2. Club owners: transfer first (no password asked, nothing counted).
  const { count: owned, error: ownedError } = await admin
    .from("clubs").select("id", { count: "exact", head: true }).eq("owner_id", user.id);
  if (ownedError) return reply(500, { error: "check_failed" });
  if ((owned ?? 0) > 0) return reply(409, { error: OWNERSHIP, clubs: owned });

  // 3. Throttle wrong passwords.
  const { data: throttled, error: throttleError } = await admin.rpc("account_deletion_throttled", { p_user_id: user.id });
  if (throttleError) return reply(500, { error: "check_failed" });
  if (throttled === true) return reply(429, { error: "rate_limited" });

  // 4. The password, checked by signing in on a throwaway client.
  const checker = createClient(url, anonKey, noSession);
  const { data: signedIn, error: signInError } = await checker.auth.signInWithPassword({
    email: user.email,
    password: body.password,
  });
  if (signInError || signedIn?.user?.id !== user.id) {
    if (signInError?.status === 429) return reply(429, { error: "rate_limited" });
    await admin.rpc("account_deletion_failed", { p_user_id: user.id });
    return reply(403, { error: "invalid_password" });
  }
  await checker.auth.signOut({ scope: "local" }).catch(() => {});

  // 5. The app data (refuses owners again, under a lock; idempotent).
  const { error: dataError } = await admin.rpc("delete_account_data", { p_user_id: user.id });
  if (dataError) {
    const owner = `${dataError.message ?? ""}`.includes(OWNERSHIP);
    return owner ? reply(409, { error: OWNERSHIP }) : reply(500, { error: "delete_failed" });
  }

  // 6. The Auth user (its sessions end with it).
  const { error: authError } = await admin.auth.admin.deleteUser(user.id);
  if (authError) return reply(500, { error: "auth_delete_failed" });

  return reply(200, { deleted: true });
});
