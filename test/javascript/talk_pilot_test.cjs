const { test } = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const { chromium } = require("playwright")

const source = fs.readFileSync("app/javascript/controllers/talk_pilot_controller.js", "utf8")
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
  .replace("export default class", "window.Pilot = class")

async function pilotBrowser(run) {
  const browser = await chromium.launch({ headless: true })
  const page = await browser.newPage()
  await page.setContent('<meta name="csrf-token" content="synthetic"><section><p id="status"></p><ol id="questions"></ol><ol id="messages"></ol><p id="empty"></p><p id="ask-feedback" hidden></p></section>')
  await page.addScriptTag({ content: source })
  await page.evaluate(() => {
    window.pilot = new Pilot()
    Object.assign(pilot, { element: document.querySelector("section"), statusTarget: document.querySelector("#status"), questionsTarget: document.querySelector("#questions"), messagesTarget: document.querySelector("#messages"), emptyTarget: document.querySelector("#empty"), hasMessagesTarget: true, askFeedbackTarget: document.querySelector("#ask-feedback"), hasAskFeedbackTarget: true, stageValue: false, moderatorValue: true, snapshotValue: "/synthetic", connected: true, generation: 0 })
  })
  try { await run(page) } finally { await browser.close() }
}

const state = { active_question_id: 2, mode: "questions", projection: "live", messages: [], questions: [{ id: 1, body: '<script>alert(1)</script> https://example.invalid', votes: 10, voted: false, answered: false }, { id: 2, body: "Pinned question", votes: 0, voted: false, answered: false }] }

test("snapshot text is inert, pinned, deduplicated and vote focus survives updates", async () => {
  await pilotBrowser(async page => {
    await page.evaluate(state => { pilot.render(state); pilot.render(state) }, state)
    assert.equal(await page.locator("#questions > li").count(), 2)
    assert.equal(await page.locator("#questions > li").first().getAttribute("data-entry-id"), "2")
    assert.equal(await page.locator("#questions script, #questions a").count(), 0)
    assert.match(await page.locator("#questions").textContent(), /<script>alert/)
    await page.locator('[data-entry-id="1"] [data-command="vote"]').focus()
    await page.evaluate(state => { state.questions[0].votes = 20; pilot.render(state) }, state)
    assert.equal(await page.evaluate(() => document.activeElement.dataset.command), "vote")
    assert.equal(await page.locator("#questions > li").first().getAttribute("data-entry-id"), "2")
    await page.evaluate(state => { state.active_question_id = 1; pilot.render(state) }, state)
    assert.equal(await page.locator("#questions > li").first().getAttribute("data-active"), "true")
  })
})

test("stage removes controls and stale content, blanks safely and reconnects without duplicates", async () => {
  await pilotBrowser(async page => {
    await page.evaluate(state => { pilot.stageValue = true; pilot.render(state) }, state)
    assert.equal(await page.locator("#questions button").count(), 0)
    await page.evaluate(() => { window.fetch = async () => { throw Error("offline") }; pilot.poll() })
    await page.waitForFunction(() => document.querySelector("#status").textContent.includes("interrupted"))
    assert.equal(await page.locator("#questions > li").count(), 0)
    await page.evaluate(state => { clearTimeout(pilot.timer); window.fetch = async () => ({ ok: true, headers: new Headers({ "content-type": "application/json" }), json: async () => state }); pilot.poll() }, state)
    await page.waitForFunction(() => document.querySelectorAll("#questions > li").length === 2)
    await page.evaluate(state => { state.projection = "blank"; state.questions = []; pilot.render(state); pilot.disconnect() }, state)
    assert.equal(await page.locator("#questions > li").count(), 0)
    assert.equal(await page.locator("section").getAttribute("data-projection"), "blank")
  })
})

test("a late response after disconnect cannot restore stale projection", async () => {
  await pilotBrowser(async page => {
    await page.evaluate(state => {
      window.fetch = () => new Promise(resolve => { window.resolveFetch = () => resolve({ ok: true, headers: new Headers({ "content-type": "application/json" }), json: async () => state }) })
      pilot.poll()
      pilot.disconnect()
      resolveFetch()
    }, state)
    await page.waitForTimeout(50)
    assert.equal(await page.locator("#questions > li").count(), 0)
  })
})

test("late old JSON cannot overwrite a newer snapshot after reconnect", async () => {
  await pilotBrowser(async page => {
    await page.evaluate(state => {
      const nextState = { ...state, active_question_id: 9, questions: [{ id: 9, body: "New snapshot after reconnect", votes: 0, voted: false, answered: false }] }
      let fetchCount = 0
      window.fetch = async () => ({ ok: true, headers: new Headers({ "content-type": "application/json" }), json: () => ++fetchCount === 1 ? new Promise(resolve => { window.resolveOldJson = () => resolve(state) }) : Promise.resolve(nextState) })
      pilot.stageValue = true
      pilot.poll()
    }, state)
    await page.waitForFunction(() => typeof resolveOldJson === "function")
    await page.evaluate(() => { pilot.disconnect(); pilot.connect() })
    await page.waitForFunction(() => document.querySelector('[data-entry-id="9"]'))
    await page.evaluate(() => resolveOldJson())
    await page.waitForTimeout(50)
    assert.equal(await page.locator("#questions > li").count(), 1)
    assert.equal(await page.locator("#questions > li").first().getAttribute("data-entry-id"), "9")
    await page.evaluate(() => pilot.disconnect())
  })
})

test("16:9 stage fits a full 500-character active question and join footer", async () => {
  await pilotBrowser(async page => {
    await page.setViewportSize({ width: 1920, height: 1080 })
    await page.setContent('<body class="talk-stage"><main><section class="talk-pilot"><header class="talk-stage-header"><img width="64" height="64"><div><p class="talk-eyebrow">Deccan Queen on Rails · Live talk channel</p><h1>A synthetic title that deliberately occupies two stage header lines for the maximum question boundary test</h1><p class="talk-speaker">Synthetic speaker</p></div><span class="talk-mode">Live Q&A</span></header><p class="talk-status" data-talk-pilot-target="status">Questions stay open during Q&A.</p><ol class="talk-stage-messages"></ol><ol class="talk-questions"><li class="talk-question" data-active="true" data-length="long"><div class="talk-question-meta"><span class="talk-badge">Now answering</span><span class="talk-votes">0 votes</span></div><p id="full-question"></p></li><li class="talk-question" data-active="false"><p id="preview-one"></p><span class="talk-badge">2 votes</span></li><li class="talk-question" data-active="false"><p id="preview-two"></p><span class="talk-badge">1 vote</span></li></ol><footer><strong>Ask the speaker · Open Questions in the talk channel</strong><span>Demo · local preview</span></footer></section></main></body>')
    await page.addStyleTag({ content: fs.readFileSync("app/assets/stylesheets/talk_pilot.css", "utf8") })
    await page.addStyleTag({ content: `@font-face { font-family: "Instrument Sans"; src: url(data:font/ttf;base64,${fs.readFileSync("app/assets/fonts/instrument-sans-variable.ttf").toString("base64")}); font-weight: 400 700; }` })
    await page.evaluate(() => document.fonts.load('42px "Instrument Sans"'))
    for (const question of ["Synthetic readable question ".repeat(20).slice(0, 500), "W".repeat(500), "a\n".repeat(250)]) {
      await page.evaluate(question => {
        document.querySelector("#full-question").textContent = question
        for (const id of ["preview-one", "preview-two"]) document.querySelector(`#${id}`)?.closest("li").remove()
      }, question)
      const bounds = await page.evaluate(() => ({ height: document.documentElement.scrollHeight, footer: document.querySelector("footer").getBoundingClientRect().bottom, question: document.querySelector("#full-question").textContent.length, glyph: document.querySelector("#full-question").textContent[0], regions: [...document.querySelector("section").children].map(node => [node.tagName, node.getBoundingClientRect().height]), font: getComputedStyle(document.querySelector("#full-question")).font }))
      assert.equal(bounds.question, 500)
      assert.ok(bounds.height <= 1080, JSON.stringify(bounds))
      assert.ok(bounds.footer <= 1080, JSON.stringify(bounds))
    }
  })
})


test("question form escapes plaintext, retains an unconfirmed draft and reuses its retry ID", async () => {
  await pilotBrowser(async page => {
    await page.evaluate(() => {
      const textarea = document.createElement("textarea")
      const button = document.createElement("button")
      document.querySelector("section").append(textarea, button)
      Object.assign(pilot, { draftTarget: textarea, sendTarget: button, hasDraftTarget: true })
      textarea.value = '<script>hello</script> https://example.invalid'
      Object.defineProperty(crypto, "randomUUID", { value: () => "synthetic-stable-ask-id" })
      window.requests = []
      window.fetch = async (url, options) => {
        requests.push(Object.fromEntries(options.body))
        return { status: requests.length === 1 ? 503 : 200, redirected: false, headers: new Headers({ "content-type": "text/vnd.turbo-stream.html" }), text: async () => "<turbo-stream></turbo-stream>" }
      }
      window.sendAsk = () => pilot.ask({ preventDefault() {}, currentTarget: { action: "/rooms/1/messages" } })
      pilot.connected = false
    })
    await page.evaluate(() => sendAsk())
    assert.match(await page.locator("textarea").inputValue(), /<script>/)
    await page.evaluate(() => sendAsk())
    assert.equal(await page.locator("textarea").inputValue(), "")
    const requests = await page.evaluate(() => requests)
    assert.equal(requests[0]["message[client_message_id]"], requests[1]["message[client_message_id]"])
    assert.equal(requests[0]["message[body]"], '<div>/ask &lt;script&gt;hello&lt;/script&gt; https://example.invalid</div>')
  })
})

test("question form keeps edits made during submission and rejects redirected sign-in HTML", async () => {
  await pilotBrowser(async page => {
    await page.evaluate(() => {
      const textarea = document.createElement("textarea")
      const button = document.createElement("button")
      document.querySelector("section").append(textarea, button)
      Object.assign(pilot, { draftTarget: textarea, sendTarget: button, hasDraftTarget: true, connected: false })
      textarea.value = "First question"
      Object.defineProperty(crypto, "randomUUID", { value: () => "synthetic-edit-ask-id" })
      window.fetch = () => new Promise(resolve => { window.finishAsk = () => resolve({ status: 200, redirected: false, headers: new Headers({ "content-type": "text/vnd.turbo-stream.html" }), text: async () => "<turbo-stream></turbo-stream>" }) })
      window.pendingAsk = pilot.ask({ preventDefault() {}, currentTarget: { action: "/rooms/1/messages" } })
      textarea.value = "A different question"
      pilot.saveDraft()
      finishAsk()
    })
    await page.evaluate(() => pendingAsk)
    assert.equal(await page.locator("textarea").inputValue(), "A different question")
    await page.evaluate(async () => {
      window.fetch = async () => ({ status: 200, redirected: true, headers: new Headers({ "content-type": "text/html" }) })
      await pilot.ask({ preventDefault() {}, currentTarget: { action: "/rooms/1/messages" } })
    })
    assert.equal(await page.locator("textarea").inputValue(), "A different question")
  })
})


test("snapshot polling preserves an unconfirmed question warning instead of showing an old success", async () => {
  await pilotBrowser(async page => {
    await page.evaluate(state => {
      const textarea = document.createElement("textarea")
      const button = document.createElement("button")
      document.querySelector("section").append(textarea, button)
      Object.assign(pilot, { draftTarget: textarea, sendTarget: button, hasDraftTarget: true, connected: false, thanks: "Old vote success" })
      textarea.value = "Question awaiting confirmation"
      Object.defineProperty(crypto, "randomUUID", { value: () => "synthetic-feedback-ask-id" })
      window.fetch = async (url, options) => options?.method === "POST" ? { status: 503, redirected: false, headers: new Headers() } : { ok: true, headers: new Headers({ "content-type": "application/json" }), json: async () => state }
    }, state)
    await page.evaluate(() => pilot.ask({ preventDefault() {}, currentTarget: { action: "/rooms/1/messages" } }))
    assert.match(await page.locator("#ask-feedback").textContent(), /Not confirmed/)
    await page.evaluate(() => { pilot.connected = true; pilot.poll() })
    await page.waitForFunction(() => document.querySelector("#questions li"))
    assert.match(await page.locator("#ask-feedback").textContent(), /Not confirmed/)
    assert.equal(await page.locator("textarea").inputValue(), "Question awaiting confirmation")
    await page.evaluate(() => pilot.disconnect())
  })
})

test("TV text-size boundaries fit wide glyphs, two previews and a two-line title", async () => {
  await pilotBrowser(async page => {
    await page.setViewportSize({ width: 1920, height: 1080 })
    await page.setContent('<body class="talk-stage"><main><section class="talk-pilot"><header class="talk-stage-header"><img width="64" height="64"><div><p class="talk-eyebrow">Deccan Queen on Rails · Demo</p><h1>A synthetic title that deliberately occupies two stage header lines for the maximum question boundary test</h1><p class="talk-speaker">Synthetic speaker</p></div><span class="talk-mode" id="mode">Live Q&A</span></header><p class="talk-status" id="status"></p><ol class="talk-stage-messages" id="messages"></ol><ol class="talk-questions" id="questions"></ol><div id="empty" hidden></div><footer><strong>Ask the speaker · Open Questions in the talk channel</strong><span>Demo · local preview</span></footer></section></main></body>')
    await page.addStyleTag({ content: fs.readFileSync("app/assets/stylesheets/talk_pilot.css", "utf8") })
    await page.addStyleTag({ content: fs.readFileSync("app/assets/stylesheets/instrument_sans.css", "utf8") })
    await page.evaluate(async () => {
      await document.fonts.load('42px "Instrument Sans"')
      window.pilot = new Pilot()
      Object.assign(pilot, { element: document.querySelector("section"), statusTarget: document.querySelector("#status"), questionsTarget: document.querySelector("#questions"), messagesTarget: document.querySelector("#messages"), emptyTarget: document.querySelector("#empty"), hasMessagesTarget: true, stageValue: true })
    })
    const layouts = []
    for (const length of [110, 111, 160, 161, 350, 351]) {
      layouts.push(await page.evaluate(length => {
        pilot.render({ active_question_id: 1, mode: "questions", projection: "live", messages: [], questions: [1, 2, 3].map(id => ({ id, body: "W".repeat(id === 1 ? length : 100), answered: false, votes: 0 })) })
        return { length, height: document.documentElement.scrollHeight, footer: document.querySelector("footer").getBoundingClientRect().bottom, font: getComputedStyle(document.querySelector(".talk-question p")).fontSize, items: document.querySelectorAll(".talk-question").length }
      }, length))
    }
    assert.ok(layouts.every(layout => layout.height <= 1080 && layout.footer <= 1080), JSON.stringify(layouts))
  })
})
