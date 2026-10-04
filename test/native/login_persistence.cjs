const assert = require("node:assert/strict")
const { mkdtempSync, rmSync } = require("node:fs")
const { tmpdir } = require("node:os")
const { join } = require("node:path")
const { chromium, webkit, devices } = require("playwright")

const base = new URL(process.argv[2] || "https://localhost:4318")
assert.equal(base.protocol, "https:")
assert.ok(["localhost", "127.0.0.1", "[::1]"].includes(base.hostname), "Use a synthetic loopback server")
assert.equal(base.username, "")
assert.equal(base.password, "")

const engine = process.argv[3] || "chromium"
const mode = process.argv[4] || "desktop"
assert.ok(["chromium", "webkit"].includes(engine), "Choose chromium or webkit")
assert.ok(["desktop", "mobile"].includes(mode), "Choose desktop or mobile")
const browser = { chromium, webkit }[engine]
const options = { headless: true, ignoreHTTPSErrors: true }
if (mode === "mobile") {
  Object.assign(options, {
    viewport: { width: 390, height: 844 },
    hasTouch: true,
    isMobile: true,
    deviceScaleFactor: 3,
    userAgent: devices[engine === "webkit" ? "iPhone 13" : "Pixel 7"].userAgent
  })
}
const profile = mkdtempSync(join(tmpdir(), "campfire-login-persistence-"))
let context

function authenticationCookie(cookies) {
  return cookies.find(cookie => cookie.name === "session_token")
}

async function assertSignedIn(page) {
  await page.locator("#user_sidebar").waitFor({ state: "attached" })
  assert.ok(!new URL(page.url()).pathname.startsWith("/session"))
}

async function run() {
  try {
    context = await browser.launchPersistentContext(profile, options)
    let page = await context.newPage()
    await page.goto(new URL("/session/new", base).href, { waitUntil: "domcontentloaded" })
    await page.locator("#email_address").fill("synthetic-refresh@example.com")
    await page.locator("#password").fill("synthetic-refresh-password")
    await page.locator('button[name="log_in"]').click()
    await assertSignedIn(page)

    for (let iteration = 0; iteration < 20; iteration++) {
      const response = await page.reload({ waitUntil: "domcontentloaded" })
      assert.equal(response.status(), 200)
      await assertSignedIn(page)
    }

    const beforeClose = authenticationCookie(await context.cookies())
    assert.ok(beforeClose, "Login must issue its authentication cookie")
    assert.equal(beforeClose.httpOnly, true)
    assert.equal(beforeClose.secure, true)
    assert.equal(beforeClose.sameSite, "Lax")
    assert.equal(beforeClose.path, "/")
    assert.equal(beforeClose.domain, base.hostname.replace(/^\[|\]$/g, ""))

    await context.close()
    context = await browser.launchPersistentContext(profile, options)
    const afterReopen = authenticationCookie(await context.cookies())
    assert.ok(afterReopen, "Authentication cookie must survive browser close/reopen")
    assert.ok(afterReopen.expires > Date.now() / 1000 + 300 * 24 * 60 * 60)

    page = await context.newPage()
    const response = await page.goto(new URL("/", base).href, { waitUntil: "domcontentloaded" })
    assert.equal(response.status(), 200)
    await assertSignedIn(page)
    const csrfToken = await page.locator('meta[name="csrf-token"]').getAttribute("content")
    assert.ok(csrfToken, "Authenticated page must supply its CSRF token")
    const signedOut = await context.request.delete(new URL("/session", base).href, {
      headers: { "X-CSRF-Token": csrfToken },
      maxRedirects: 0
    })
    assert.equal(signedOut.status(), 302)
    assert.equal(authenticationCookie(await context.cookies()), undefined)

    const anonymous = await context.request.get(new URL("/", base).href, { maxRedirects: 0 })
    assert.equal(anonymous.status(), 302)
    assert.equal(new URL(anonymous.headers().location, base).pathname, "/session/new")
    console.log(`PASS (${engine}, ${mode}): 20 authenticated refreshes, browser close/reopen and sign-out; HTTPS cookie attributes preserved`)
  } finally {
    await context?.close()
    rmSync(profile, { recursive: true, force: true })
  }
}

run().catch(error => {
  console.error(error.message)
  process.exitCode = 1
})
