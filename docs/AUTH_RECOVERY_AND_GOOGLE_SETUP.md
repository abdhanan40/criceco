# Password recovery (AUTH-04) and Google sign-in (AUTH-05): setup

What the app does, and what must be configured outside the code before
either feature is switched on in a real build. Nothing here contains a
secret; the Google client secret lives only in the Supabase Dashboard.

## 1. How the app works

### AUTH-04: Forgot password

1. Login → **Forgot password?** → the email (email only in Supabase builds)
   → `resetPasswordForEmail`. The answer is the same whether or not the
   address has an account.
2. The email carries **a 6-digit code and a link**:
   - **Code** (any device): entered in the sheet → `verifyOTP(type: recovery)`.
   - **Link** (only the browser or phone that asked for it, because the PKCE
     verifier is stored there) → back to the app's callback → the SDK
     exchanges it.
3. Either path opens a **recovery session**. The router guard then shows
   only **Reset Password** (`/reset-password`).
4. New password + confirm (the shared strong-password rules) → `updateUser`
   → **sign-out on every device** (`signOut(scope: global)`) → Login says
   "Password updated".
5. Cancel, an app restart, or an expired recovery ends the recovery session
   without a change.
6. Errors handled: wrong / expired / used code; expired or used link; a link
   opened elsewhere; rate limits (429); offline; the same password again;
   weak passwords.

### AUTH-05: Google

1. Login or Sign Up → **Continue with Google** → `signInWithOAuth(google)`
   in the browser.
2. **Web:** Google → Supabase → back to the app's address. `Supabase.initialize`
   exchanges the code before the app starts, and the router sends a new
   account to User Profile Setup and a returning one to their role.
3. **Android:** a browser tab, then back through
   `com.criceco.criceco://login-callback` (intent filter in
   `AndroidManifest.xml`). The account arrives as an event while Login or
   Sign Up is open.
4. A new Google user gets their `profiles` row from the existing sign-up
   trigger, once (`ON CONFLICT DO NOTHING`). An existing user with the same
   *confirmed* email is linked by Supabase to the same user id, so there is
   no duplicate.
5. Cancel / deny / provider errors come back as a message on Login. Closing
   the Android tab without finishing returns to the app with no change.

### Build switches (both OFF by default)

| Switch | Turns on |
|---|---|
| `CRICECO_EMAIL_CODES=true` | Sign-up codes (AUTH-02) **and** Forgot password in Supabase builds (AUTH-04). |
| `CRICECO_GOOGLE_SIGN_IN=true` | "Continue with Google" in Supabase builds (AUTH-05). |

The demo (memory) build keeps its simulated Forgot password and Google sign-in.

## 2. Supabase Dashboard (production or a dev project): you make these

1. **Authentication → URL Configuration**
   - **Site URL:** the web app's real address.
   - **Redirect URLs:** add
     - `com.criceco.criceco://login-callback` (Android)
     - the web app's address, with and without a trailing `/`, e.g.
       `https://app.example.com` and `https://app.example.com/`
       (placeholder; use the real one)
     - for local web testing only: `http://localhost:60550` and
       `http://localhost:60550/`
2. **Authentication → Email Templates → Reset Password**: show the code
   **and** the link, for example:
   ```html
   <p>Your CricEco password reset code:</p>
   <p style="font-size:28px;font-weight:bold;letter-spacing:6px">{{ .Token }}</p>
   <p>Valid for 15 minutes. Or, on the device where you asked for it:
     <a href="{{ .ConfirmationURL }}">Reset my password</a></p>
   ```
3. **Authentication → Providers → Email:** OTP length 6, expiry 900 s (as for
   AUTH-02).
4. **Rate limits:** keep the per-user email interval at 60 s (the app's
   resend wording assumes it). Check the token-verification limit too: it
   protects the 6-digit codes from guessing.
5. **Custom SMTP** must be live first (see AUTH-01). Supabase's built-in
   sender can't deliver reset emails to ordinary users.
6. **Authentication → Providers → Google:**
   - Enable it.
   - Enter the **Web client ID** and **client secret** from Google Cloud
     (below). The secret goes here only, never into the app.
7. **Identity linking (verify before release):** Supabase's automatic
   linking joins a Google sign-in to an existing account with the same
   email only when that email is confirmed. Check what happens to an
   *unconfirmed* email/password account on your project before enabling
   Google there.

## 3. Google Cloud Console: you make these

1. Create (or pick) a project → **APIs & Services → OAuth consent screen**:
   - app name, support email, the authorised domain of the web app, scopes
     `email`, `profile`, `openid`;
   - publish it, or add test users while in Testing.
2. **Credentials → Create credentials → OAuth client ID → Web application:**
   - **Authorised JavaScript origins:** the web app's address (and
     `http://localhost:60550` for local testing).
   - **Authorised redirect URIs:** the Supabase callback,
     `https://<project-ref>.supabase.co/auth/v1/callback`.
   - Copy the client ID and secret into the Supabase Google provider (step 2.6).
3. No Android OAuth client is needed for this browser flow. The app never
   calls Google directly; it only opens Supabase's `/authorize` URL.

## 4. Platform status

| | Web | Android |
|---|---|---|
| Recovery by code | Works (local stack, tested live) | Same code path; needs a device test |
| Recovery by link | Works on the same browser (tested live) | Intent filter added; needs a device test with the debug cleartext exception or HTTPS |
| Google | Code done; **not operational** until the provider is configured and tested | Code done; **not operational** until configured and tested on a device |

## 5. Rollback

Turn the switches off (rebuild). No database change is involved.
