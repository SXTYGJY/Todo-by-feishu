# Desktop OAuth Implementation Plan

> **For agentic workers:** Execute in order; do not expose application secrets in source, logs, UI bridge payloads, or distributable binaries.

**Goal:** Add a native Feishu OAuth flow to the macOS Todo client, persist each user's own Feishu app credentials and user tokens in Keychain, and make the client ready for authorization in the user's own Feishu organization.

**Architecture:** AppKit owns credential entry and the OAuth flow, opens the system browser, receives the loopback callback, validates state, exchanges/refreshes tokens directly with Feishu using the user's App ID/App Secret, fetches the authenticated identity, and stores credentials in separate Keychain items. The app does not deploy a token relay; App Secret stays out of the WebView, files, and logs.

**Tech Stack:** Swift 5.9, AppKit, Foundation URLSession, Security Keychain Services, WKWebView bridge.

**Spec:** `SPEC.md` sections 7, 9, 14–16, and 20.

## Global Constraints

- Never embed or commit the developer's Feishu App Secret in the app, source, resources, or build configuration. User-provided App Secret is stored locally in Keychain and only passed to the native token client at runtime.
- Never send access or refresh tokens to WKWebView JavaScript.
- Store access/refresh tokens in Keychain; persist workspace data separately by Feishu identity.
- Store user App ID/App Secret in a separate Keychain item; do not send either value through WKWebView bridge.
- Test only with the development Feishu application and designated test Base.
- Do not claim external-tenant authorization based on a custom-app test.
- Do not add tests in this implementation pass unless requested; build and inspect the changes.

---

## File Map

- `macOS/Sources/TodoDesktop/Auth/FeishuOAuthConfiguration.swift`: app id, scopes, callback URL and redirect construction.
- `macOS/Sources/TodoDesktop/Auth/LoopbackOAuthCallbackServer.swift`: temporary loopback listener and one-shot callback/state validation.
- `macOS/Sources/TodoDesktop/Auth/FeishuTokenClient.swift`: authorization-code exchange, refresh, and profile lookup using runtime credentials loaded from Keychain.
- `macOS/Sources/TodoDesktop/Auth/KeychainTokenStore.swift`: secure account-scoped credential storage and deletion.
- `macOS/Sources/TodoDesktop/Auth/KeychainAppCredentialsStore.swift`: local App ID/App Secret storage, separate from user tokens.
- `macOS/Sources/TodoDesktop/Auth/AuthCoordinator.swift`: orchestrates browser, callback, token lifecycle, identity and workspace selection.
- `macOS/Sources/TodoDesktop/Bridge/TodoBridgeHandler.swift`: expose `auth.start`, `auth.status`, and `auth.signOut` without tokens.
- `macOS/Sources/TodoDesktop/TodoDesktopApp.swift`: wire coordinator, URL callback and app lifecycle.
- `macOS/Package.swift`: include new Auth source directory if target layout needs explicit resources/paths.
- `SPEC.md`: record direct user-owned app credentials, Keychain boundaries, and remaining live validation.

## Tasks

1. Add OAuth config and validated callback URL/state/PKCE primitives.
2. Implement loopback callback lifecycle with one pending authorization, timeout, cancellation, and strict state matching.
3. Implement native credential entry and Keychain storage, then use those credentials for Feishu token/profile requests.
4. Implement Keychain store for access token, refresh token, expiry, app identity, and identity-scoped lookup; avoid defaults/files/logs.
5. Add AuthCoordinator and bridge methods; bootstrap reports current identity and pending view URL without token data.
6. Wire authorization result into identity-keyed workspace loading and resume pending view binding state.
7. Update SPEC with actual implemented behavior, development credential setup steps, and explicitly unverified requirements.
8. Build the macOS target and inspect the diff. Stop before configuring developer-console values or attempting real OAuth if required local credentials/callback registration are absent.

## Configuration / External Setup Needed for Live Validation

- Feishu development app ID (already known to the user; safe to configure as client identifier).
- Exact registered loopback redirect URL supported by the developer console and OAuth flow.
- User access scopes for read-only Bitable access and the minimal record-update scope, including refresh/offline access if required.
- Each user creates/configures their own Feishu app and enters App ID/App Secret in the native Todo credentials panel; Todo stores them in local Keychain.
- Development app published/installed and permission approval active in the test tenant.

## Validation

- Build with `swift build`.
- Source audit for secret/token leakage and callback state validation.
- Live authorization, identity retrieval, Keychain persistence/reuse, Bitable read, token refresh, and status update remain unverified until observed on the ad-hoc Release build in a clean Mac environment. The release package has no Developer ID signature and is not notarized.
