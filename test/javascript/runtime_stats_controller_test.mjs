import assert from "node:assert/strict"
import fs from "node:fs/promises"
import vm from "node:vm"

const source = await fs.readFile(new URL("../../app/javascript/controllers/runtime_stats_controller.js", import.meta.url), "utf8")
const RuntimeStats = vm.runInNewContext(source.replace(/^import .*$/m, "class Controller {}").replace("export default class", "class RuntimeStats") + "; RuntimeStats", {
  AbortController, setTimeout, clearTimeout,
  fetch: async () => { throw new Error("Collector unavailable") },
  document: { createElementNS: () => ({ setAttribute() {} }) }
})
const controller = new RuntimeStats()
const fields = new Map()
const group = { replaceChildren() {}, append() {} }
const svg = { dataset: { chart: "rss_bytes" }, querySelector: () => group, setAttribute: (name, value) => fields.set(name, value) }
controller.element = {
  dataset: {},
  querySelectorAll: () => [svg],
  querySelector: selector => ({ set textContent(value) { fields.set(selector, value) } })
}
controller.field = (key, value) => fields.set(key, value)
controller.rows = () => {}
controller.render({ sampled_at: new Date().toISOString(), history: [{ rss_bytes: 2 * 1024 ** 2 }, { rss_bytes: 4 * 1024 ** 2 }] })
assert.equal(controller.element.dataset.state, "live")
assert.equal(fields.get('[data-chart-peak="rss_bytes"]'), "4 MiB")
assert.match(fields.get("aria-label"), /chart peak 4 MiB/)
controller.render({ sampled_at: new Date().toISOString(), history: [{ rss_bytes: 0 }] })
assert.equal(fields.get('[data-chart-peak="rss_bytes"]'), "0 MiB")
controller.render({ sampled_at: new Date(0).toISOString() })
assert.equal(controller.element.dataset.state, "stale")
assert.equal(fields.get('[data-chart-peak="rss_bytes"]'), "—")
controller.active = true
await controller.refresh()
assert.equal(controller.element.dataset.state, "unavailable")
assert.equal(fields.get("live"), "Data unavailable")
controller.disconnect()
console.log("Runtime status states and chart peak units verified")
