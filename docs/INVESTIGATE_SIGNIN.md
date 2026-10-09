# ByteStream: investigate the "Spotify returned an error while signing in" failure

You are a local agent on the Windows PC where ByteStream runs. The author of ByteStream cannot see this machine,
so your job is to **collect facts and report them**. Do not guess, and do not "fix" things unless a step below
says so. A short, accurate report is worth more than a long theory.

## 1. What ByteStream is

A native Windows Spotify player written in x86-64 assembly (NASM). It signs in with Spotify's official OAuth flow
(Authorization Code with PKCE, no client secret), and plays audio through Spotify's Web Playback SDK inside a
hidden Microsoft Edge window. Source: this repository. `README.md` has the setup steps; `src/auth.asm` is the
sign-in code.

The app has only ever been tested against a fake Spotify server (Wine on Linux, plus a Windows CI that does not use
the real Spotify). This is its **first run against the real Spotify**, so a failure here is expected and useful.

## 2. The symptom

1. The window opens and looks right (dark theme, "Welcome to ByteStream", three setup steps).
2. In step 3 a Client ID is pasted, the port shows `8888` (the default is 8989, so someone changed it), and the
   redirect address shows `http://127.0.0.1:8888/callback`.
3. **Sign in with Spotify** was pressed. After that a red banner appears at the top:
   *"Spotify returned an error while signing in. Details are in the log (Settings > Diagnostics)."*
4. There is no Settings button on this screen, so read the log file directly (below).

That banner is the app's catch-all. It is shown when any of these happens (see `src/auth.asm`):

| Code | Case | What the log should show |
| --- | --- | --- |
| A | Spotify redirected back with `?error=<something other than access_denied>` | no `sign-in: redirect received` line |
| B | Token exchange answered non-200 with an error that is not `invalid_client`, and not `invalid_grant` mentioning a redirect | `http POST https://accounts.spotify.com/api/token -> 4xx` then `sign-in: failed, token endpoint status N` |
| C | Token exchange answered 200 but the JSON could not be used | token `-> 200`, but no `sign-in: tokens installed` |
| D | Sign-in worked but `GET /v1/me` answered something other than 200, 401 or 403 (for example 429, 400, 5xx) | `sign-in: tokens installed`, then `http GET https://api.spotify.com/v1/me -> N` |

Important: **the log records the HTTP status, but not Spotify's error name or message.** That is a known gap and
will be fixed once we know the cause. To get the missing text, use step 4.3 below.

## 3. Ground rules

- **Never** print, copy or paste: access tokens, refresh tokens, the `code=` value of the callback URL, the
  `code_verifier`, or the contents of `auth.bin` (it is encrypted with Windows DPAPI; do not try to decrypt it).
- Do **not** change anything in the user's Spotify dashboard or account. Describe what you see; the user changes it.
- Do not delete `%APPDATA%\ByteStream`. If you need a clean run, rename the folder, and say so in the report.
- Do not kill processes you did not start. Closing ByteStream and the hidden Edge window it starts is fine.
- The Client ID is **not** a secret (it appears in every sign-in URL), but leave it out of the report anyway.

## 4. What to do

### 4.1 Read the evidence that already exists (read-only)

```powershell
Get-ChildItem "$env:APPDATA\ByteStream"
Get-Content "$env:APPDATA\ByteStream\bytestream.log" -Tail 80
Get-Content "$env:APPDATA\ByteStream\bytestream.old.log" -Tail 40 -ErrorAction SilentlyContinue
Get-Content "$env:APPDATA\ByteStream\settings.ini"
```

Find the last attempt: it starts at the line `sign-in: browser opened`. Copy that line and everything after it
(the log has no secrets). Work out which row of the table in section 2 matches (A, B, C or D, or something else).
Also note any `server: rejected request: ...` lines, and any `CRASH` or exception lines (these mean a bug).

### 4.2 Environment checks

```powershell
(Get-CimInstance Win32_OperatingSystem).Caption, (Get-CimInstance Win32_OperatingSystem).Version
Get-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe" -ErrorAction SilentlyContinue
netstat -ano | findstr ":8888"
Get-Process bytestream -ErrorAction SilentlyContinue | Select-Object Id, Path
```

Report the Windows version, whether Edge is installed, and whether **anything other than ByteStream** is listening
on the port (ByteStream listens on `127.0.0.1` only while it is waiting for the browser). Also note any antivirus
or firewall prompt the user saw.

### 4.3 Reproduce once, and capture the part the log is missing

1. Close ByteStream, then start it again (find the exe with `Get-Process`, or ask the user).
2. Press **Sign in with Spotify**. Your browser opens Spotify's page. Before the user clicks anything, **read the
   address bar** and note: `redirect_uri` (must be exactly the address shown in step 2 of the app, URL-encoded),
   `scope`, `response_type=code`, and `code_challenge_method=S256`. Ignore the Client ID.
3. If Spotify shows its **own error page** (for example `INVALID_CLIENT: Invalid redirect URI` or
   `INVALID_CLIENT: Invalid client`), copy that text. That is the answer.
4. Otherwise let the user approve. The browser then lands on `http://127.0.0.1:8888/callback?...`. Read that final
   address from the address bar. Report **only** the parameter names and, if present, the value of `error=`
   (and `error_description=`). **Do not report `code=` or `state=` values.** A leftover `?error=...` here is the
   exact reason for case A.
5. Note what the page in the browser says, and what the app shows afterwards.
6. Re-read the log tail (section 4.1) and say which table row it matches now.

Optional sanity check while the app is waiting for the browser, to prove the local sign-in server is up:
`curl.exe -i http://127.0.0.1:8888/`. A `403` or `404` is fine; "connection refused" means the server is not listening.

### 4.4 Things only the user can check (ask, do not do)

- The Spotify dashboard (https://developer.spotify.com/dashboard) app lists **exactly**
  `http://127.0.0.1:8888/callback` under Redirect URIs, and **Save** was clicked. The port in the app and the one in
  the dashboard must match (the app's default is 8989).
- Under *User management* the user's own Spotify account (the email they sign in with) is listed.
- The Spotify account has Premium, and the account that owns the dashboard app has Premium too (development mode).
- The app in the dashboard says it uses the **Web API** and **Web Playback SDK**.

## 5. Report back

Reply with a short markdown report, in this shape:

```
## ByteStream sign-in report
- Windows: <version>; Edge installed: yes/no; port 8888 used by another program: yes/no
- Matching case: A / B / C / D / other
- Browser showed (own Spotify error page?): <text or "approved normally">
- Final callback URL parameter names: <e.g. code, state>   error=<value if any>
- Log excerpt (from "sign-in: browser opened" to the end):
  <paste>
- Anything else odd (antivirus prompts, crashes, extra windows):
- Things the user must check in the Spotify dashboard (4.4): <list what you could not verify>
```

Stop after reporting. Do not edit the source code or rebuild unless the user explicitly asks you to.

## 6. For whoever fixes it afterwards

Likely follow-up changes in `src/auth.asm`: log Spotify's `error` and `error_description` for cases A and B, log the
`/v1/me` status explicitly for D, and change the banner so it does not point to Settings (not reachable before
sign-in) but shows the actual reason. The Windows build runs in GitHub Actions on every push and uploads a
`bytestream-windows` artifact.
