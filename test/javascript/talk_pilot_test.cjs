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
  await page.setContent('<meta name="csrf-token" content="synthetic"><section><p id="status"></p><ol id="questions"></ol><ol id="messages"></ol><p id="empty"></p></section>')
  await page.addScriptTag({ content: source })
  await page.evaluate(() => {
    window.pilot = new Pilot()
    Object.assign(pilot, { element: document.querySelector("section"), statusTarget: document.querySelector("#status"), questionsTarget: document.querySelector("#questions"), messagesTarget: document.querySelector("#messages"), emptyTarget: document.querySelector("#empty"), hasMessagesTarget: true, stageValue: false, moderatorValue: true, snapshotValue: "/synthetic", connected: true, generation: 0 })
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

test("16:9 stage fits a full 500-character active question, previews and join footer", async () => {
  await pilotBrowser(async page => {
    await page.setViewportSize({ width: 1920, height: 1080 })
    await page.setContent('<body class="talk-stage"><main><section class="talk-pilot"><header><p class="talk-eyebrow">Deccan Queen on Rails · Live talk channel</p><h1>A synthetic title that deliberately occupies two stage header lines for the maximum question boundary test</h1><p>Synthetic speaker</p></header><p data-talk-pilot-target="status">Q&A is live · /ask stays open</p><ol class="talk-stage-messages"></ol><ol class="talk-questions"><li class="talk-question" data-active="true"><p id="full-question"></p><span class="talk-badge">On the mic · 0 votes</span></li><li class="talk-question" data-active="false"><p id="preview-one"></p><span class="talk-badge">2 votes</span></li><li class="talk-question" data-active="false"><p id="preview-two"></p><span class="talk-badge">1 vote</span></li></ol><footer><p>Join this talk · https://localhost:4348/rooms/1</p><p>Questions stay open during Q&A · /ask your question</p></footer></section></main></body>')
    await page.addStyleTag({ content: fs.readFileSync("app/assets/stylesheets/talk_pilot.css", "utf8") })
    await page.addStyleTag({ content: "body { font-family: system-ui, sans-serif; }" })
    for (const question of ["Synthetic readable question ".repeat(20).slice(0, 500), "W".repeat(500), "a\n".repeat(250)]) {
      await page.evaluate(question => {
        document.querySelector("#full-question").textContent = question
        for (const id of ["preview-one", "preview-two"]) document.querySelector(`#${id}`).textContent = "W".repeat(100)
      }, question)
      const bounds = await page.evaluate(() => ({ height: document.documentElement.scrollHeight, footer: document.querySelector("footer").getBoundingClientRect().bottom, question: document.querySelector("#full-question").textContent.length }))
      assert.equal(bounds.question, 500)
      assert.ok(bounds.height <= 1080, JSON.stringify(bounds))
      assert.ok(bounds.footer <= 1080, JSON.stringify(bounds))
    }
  })
})
