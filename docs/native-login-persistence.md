# Native login persistence

The pinned native runtime treats `cookies.signed.permanent` as an identity operation. Without an explicit expiry, `session_token` is a browser-session cookie even though Campfire's existing Rails policy is a renewable 20-year cookie. Synthetic HTTPS testing of source `cd463624` retained login through 20 page refreshes and a server restart, but closing and reopening Chromium with the same persistent profile removed the authentication cookie and returned to sign-in.

The shared authentication cookie writer now supplies `expires: 20.years.from_now` explicitly. The runtime already supports this option in both the browser `Expires` attribute and signed envelope. Existing HttpOnly, SameSite=Lax, request-dependent Secure, session lookup and sign-out behavior are preserved. Password login, first-run signup and Google callback use this shared writer; no production account was used to reproduce the defect.

The controller test pins the existing lifetime and renewal policy. Rails already implemented `.permanent`, so this test is policy coverage rather than reproduction of the native defect.

The native regression requires an isolated compiled server with the synthetic fixture `synthetic-refresh@example.com` / `synthetic-refresh-password`, an HTTPS loopback proxy forwarding `X-Forwarded-Proto: https`, and an installed Playwright package. Run it against both the original and rebuilt binaries:

```sh
NODE_PATH=/path/to/installed/node_modules node test/native/login_persistence.cjs https://localhost:4318 chromium desktop
NODE_PATH=/path/to/installed/node_modules node test/native/login_persistence.cjs https://localhost:4318 chromium mobile
NODE_PATH=/path/to/installed/node_modules node test/native/login_persistence.cjs https://localhost:4318 webkit mobile
```

The engine argument accepts only `chromium` or `webkit`; the mode accepts only `desktop` or `mobile`. Defaults are desktop Chromium. Mobile mode uses a 390×844 viewport, touch input, a device scale factor of 3, and Playwright's Pixel 7 Chromium or iPhone 13 WebKit user agent. These are mobile browser emulations, not tests on a physical Android phone or iPhone Safari. Each run uses the selected engine's actual persistent browser profile without importing cookies or storage state.

The driver refuses non-loopback URLs, uses only the fixed synthetic credentials, and creates and removes its own temporary browser profile. It performs 20 real page refreshes, closes the selected browser, reopens the same profile without importing cookies or storage state, verifies persistence and cookie attributes, and checks the authenticated UI. It then signs out using that page's CSRF token, verifies cookie removal, and confirms the next root request redirects to sign-in. The original binary must fail at browser reopen; the rebuilt binary must pass. Browser lifetime caps can shorten the stored expiry to approximately 400 days, so the driver requires more than 300 days rather than asserting a 20-year browser timestamp. It never prints cookie values.

This defect does not establish a cause for losing login on a normal refresh while the browser remains open. That flow passed in the original native reproduction and needs separate evidence if it still fails for a user. Production deployment remains a separate decision after native verification and review.
