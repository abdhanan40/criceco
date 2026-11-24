// CricEco · push-dispatch · Firebase Cloud Messaging HTTP v1 (M3 P5).
//
// An OAuth access token from the Firebase service account (a JWT signed with
// its private key, RS256, exchanged at Google), then one request per device,
// addressed by its Firebase Installation ID (`message.fid`). The service
// account comes only from the function's secret FCM_SERVICE_ACCOUNT — never
// logged, never returned.
//
// Plain TypeScript with erasable types only (Deno deployed, Node in tests).

import type { PushRow, PushText } from "./templates.ts";

export type ServiceAccount = { project_id: string; client_email: string; private_key: string };

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

/** What one token's send came to. */
export type SendOutcome =
  | { kind: "sent" }
  | { kind: "invalid_token"; error: string }
  | { kind: "retry"; error: string }
  | { kind: "failed"; error: string };

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const TOKEN_URL = "https://oauth2.googleapis.com/token";

/** The secret's JSON → the three fields used; anything else is refused. */
export function parseServiceAccount(json: string | undefined): ServiceAccount | null {
  if (!json) return null;
  try {
    const v = JSON.parse(json) as Record<string, unknown>;
    const { project_id, client_email, private_key } = v;
    if (typeof project_id !== "string" || !/^[a-z0-9-]{4,40}$/.test(project_id)) return null;
    if (typeof client_email !== "string" || !client_email.includes("@")) return null;
    if (typeof private_key !== "string" || !private_key.includes("PRIVATE KEY")) return null;
    return { project_id, client_email, private_key };
  } catch {
    return null;
  }
}

function base64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): ArrayBuffer {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const raw = atob(body);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out.buffer;
}

/** The signed JWT Google exchanges for an access token. */
export async function signedAssertion(sa: ServiceAccount, nowSeconds: number): Promise<string> {
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: SCOPE,
    aud: TOKEN_URL,
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  }));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  return `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
}

/** Caches the access token until a minute before it expires. */
export class AccessTokens {
  private token: string | null = null;
  private expiresAt = 0;
  private readonly sa: ServiceAccount;
  private readonly fetchFn: Fetch;
  private readonly now: () => number;

  constructor(sa: ServiceAccount, fetchFn: Fetch, now: () => number = () => Math.floor(Date.now() / 1000)) {
    this.sa = sa;
    this.fetchFn = fetchFn;
    this.now = now;
  }

  async get(): Promise<string> {
    const now = this.now();
    if (this.token !== null && now < this.expiresAt - 60) return this.token;
    const assertion = await signedAssertion(this.sa, now);
    const res = await this.fetchFn(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: `grant_type=${encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer")}&assertion=${assertion}`,
    });
    if (!res.ok) throw new Error(`oauth_${res.status}`);
    const body = await res.json() as { access_token?: unknown; expires_in?: unknown };
    if (typeof body.access_token !== "string") throw new Error("oauth_no_token");
    this.token = body.access_token;
    this.expiresAt = now + (typeof body.expires_in === "number" ? body.expires_in : 3600);
    return this.token;
  }

  /** Forget the token (Google refused it). */
  reset(): void {
    this.token = null;
    this.expiresAt = 0;
  }
}

/** The FCM v1 message for one device: the text, and the ids the app needs
 * to open the right screen when it is tapped (no content in the data).
 *
 * The device is addressed by its Firebase Installation ID (`message.fid`,
 * C3 Fix A): the app registers with firebase_messaging's register() /
 * onRegistered, which give an FID, not a classic registration token. The
 * column that stores it is still called `token` (device_tokens). */
export function buildMessage(fid: string, row: PushRow, text: PushText): Record<string, unknown> {
  const data: Record<string, string> = {
    notification_id: row.notification_id,
    type: row.type,
    inbox: row.inbox,
  };
  if (row.match_id) data.match_id = row.match_id;
  if (row.subject_id) data.subject_id = row.subject_id;
  if (row.club_id) data.club_id = row.club_id;
  return {
    message: {
      fid,
      notification: { title: text.title, body: text.body },
      data,
      // One notification per inbox row: a re-send replaces, never doubles.
      android: { priority: "HIGH", notification: { tag: row.notification_id } },
    },
  };
}

/** FCM's answer → what to do. A device is dropped only when FCM says its
 * registration no longer exists (UNREGISTERED, 404) or belongs to another
 * sender.
 *
 * INVALID_ARGUMENT (400) is never a reason to drop a device: FCM answers it
 * for a wrong payload too ("Recipient of the message is not set", an
 * unknown field, two targets), so treating it as a bad device would let one
 * payload bug delete every registration. Firebase drops on it only "if the
 * payload is valid", which this function can't tell; it is a plain failure
 * (no retry, nothing deleted). Checked live with validate_only (C3 Fix A):
 * an unknown or malformed FID is answered 404 UNREGISTERED. */
export async function classify(res: Response): Promise<SendOutcome> {
  if (res.ok) return { kind: "sent" };
  let status = "";
  let code = "";
  try {
    const body = await res.json() as {
      error?: { status?: string; details?: Array<{ errorCode?: string }> };
    };
    status = body.error?.status ?? "";
    code = body.error?.details?.find((d) => typeof d.errorCode === "string")?.errorCode ?? "";
  } catch {
    // Not JSON: decide by the status code alone.
  }
  // Our access token was refused: get a new one and try again later.
  if (res.status === 401) return { kind: "retry", error: "AUTH" };
  const error = (code || status || `HTTP_${res.status}`).replace(/[^A-Za-z0-9_.:-]/g, "").slice(0, 60);
  if (code === "UNREGISTERED" || code === "SENDER_ID_MISMATCH" || res.status === 404) {
    return { kind: "invalid_token", error: error || "UNREGISTERED" };
  }
  if (res.status === 429 || res.status >= 500 || code === "UNAVAILABLE" || code === "INTERNAL" ||
      code === "QUOTA_EXCEEDED") {
    return { kind: "retry", error };
  }
  return { kind: "failed", error };
}

/** Sends one message; a network failure is a retry. */
export async function sendOne(
  fetchFn: Fetch,
  projectId: string,
  accessToken: string,
  message: Record<string, unknown>,
): Promise<SendOutcome> {
  try {
    const res = await fetchFn(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
      method: "POST",
      headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify(message),
    });
    return await classify(res);
  } catch {
    return { kind: "retry", error: "NETWORK" };
  }
}
