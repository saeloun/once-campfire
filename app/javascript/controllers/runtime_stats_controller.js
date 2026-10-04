import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "statuses", "recent" ]
  static values = { url: String }

  connect() {
    this.active = true
    this.refresh()
  }

  disconnect() {
    this.active = false
    clearTimeout(this.timer)
    this.abort?.abort()
  }

  async refresh() {
    this.abort = new AbortController()
    try {
      const response = await fetch(this.urlValue, { credentials: "same-origin", cache: "no-store", signal: this.abort.signal, headers: { Accept: "application/json" } })
      if (response.redirected) throw new Error("Sign in again to view runtime data")
      const data = await response.json()
      if (!response.ok || !data.available) throw new Error(data.error || "Collector unavailable")
      if (this.active) this.render(data)
    } catch (error) {
      if (this.active) {
        this.element.dataset.state = "unavailable"
        this.field("live", "Data unavailable")
        this.field("updated", error.message)
      }
    } finally {
      if (this.active) this.timer = setTimeout(() => this.refresh(), 5000)
    }
  }

  field(name, value) {
    this.element.querySelectorAll(`[data-field="${name}"]`).forEach(element => { element.textContent = value })
  }

  number(value, digits = 0) {
    return Number.isFinite(value) ? value.toLocaleString(undefined, { maximumFractionDigits: digits }) : "—"
  }

  bytes(value) {
    return Number.isFinite(value) ? `${this.number(value / 1024 / 1024, 1)} MiB` : "—"
  }

  time(value) {
    return value ? new Date(value).toLocaleTimeString() : "—"
  }

  render(data) {
    const system = data.system || {}, native = data.native || {}, requests = data.requests || {}, database = data.database || {}
    const age = (Date.now() - Date.parse(data.sampled_at)) / 1000
    this.element.dataset.state = age > 20 ? "stale" : "live"
    this.field("live", age > 20 ? "Sample stale" : "Live · 5s")
    this.field("updated", `${age > 20 ? "Stale sample" : "Last sampled"} ${new Date(data.sampled_at).toLocaleString()}`)
    this.field("proof", native.elf === true ? "ELF native executable" : native.elf === false ? "Executable is not ELF" : "Executable unavailable")
    this.field("executable", native.executable || "Unavailable")
    this.field("ruby", native.ruby_runtime_present === false ? "No Ruby interpreter / libruby found" : native.ruby_runtime_present === true ? "Ruby runtime detected" : "Inspection unavailable")
    this.field("container", `Container ${(native.container_id || "unavailable").slice(0, 12)} · ${this.number(native.processes_inspected)} processes inspected`)
    this.field("image", native.image_ref || "Unavailable")
    this.field("revision", `Roundhouse ${native.image_revision || "unavailable"} · Campfire ${native.campfire_revision || "unavailable"} · Spinel ${native.spinel_revision || "unavailable"}`)
    this.field("digest", native.image_id || "Digest unavailable")
    this.field("total", this.number(requests.total))
    this.field("observed", `Since ${requests.observed_since ? new Date(requests.observed_since).toLocaleString() : "unavailable"}`)
    this.field("rate", this.number(requests.rate_per_second, 2))
    this.field("p95", `${this.number(requests.p95_ms, 1)} ms`)
    this.field("errors", this.number(requests.errors))
    this.field("errorRate", `HTTP 5xx · ${requests.total ? this.number(requests.errors / requests.total * 100, 2) : "0"}% of requests`)
    this.field("uptime", Number.isFinite(system.uptime_seconds) ? `${this.number(system.uptime_seconds / 3600, 1)} hours` : "—")
    this.field("restarts", this.number(system.restarts))
    this.field("workers", `${this.number(system.workers)} / ${this.number(system.threads)}`)
    this.field("fds", this.number(system.open_fds))
    this.field("connections", this.number(system.tcp_connections))
    this.field("memory", `${this.bytes(system.memory_bytes)} / ${this.bytes(system.memory_limit_bytes)}`)
    this.field("cpuLimit", Number.isFinite(system.cpu_limit) ? `${this.number(system.cpu_limit, 1)} cores` : "Unavailable")
    this.field("hostCPU", `${this.number(system.host_cpu_percent, 1)}% of ${this.number(system.host_cpu_count)} cores`)
    this.field("hostLoad", [system.load_1m, system.load_5m, system.load_15m].map(value => this.number(value, 2)).join(" / "))
    this.field("hostMemory", `${this.bytes(Number.isFinite(system.host_memory_available_bytes) ? system.host_memory_total_bytes - system.host_memory_available_bytes : null)} / ${this.bytes(system.host_memory_total_bytes)}`)
    this.field("database", database.error || this.bytes(database.bytes))
    this.field("records", [ "users", "rooms", "messages" ].map(table => this.number(database.counts?.[table])).join(" / "))
    this.field("historyStart", data.history?.length ? this.time(data.history[0].at) : "Waiting for samples")
    this.charts(data.history || [])
    this.rows(this.statusesTarget, Object.entries(requests.statuses || {}).sort(([a], [b]) => a.localeCompare(b)).map(([status, count]) => [status, ({ "1": "Informational", "2": "Success", "3": "Redirect", "4": "Client error", "5": "Server error" })[status[0]], this.number(count), `${this.number(count / Math.max(1, requests.total) * 100, 1)}%`]))
    this.rows(this.recentTarget, (requests.recent || []).map(request => [this.time(request.at), `${request.method} ${request.path}`, request.status, `${this.number(request.duration_ms, 1)} ms`, this.number(request.bytes)]), 1)
  }

  rows(target, values, routeColumn = -1) {
    target.replaceChildren()
    if (!values.length) values = [ ["No completed requests recorded"] ]
    values.forEach(columns => {
      const row = document.createElement("tr")
      columns.forEach((value, index) => {
        const cell = document.createElement("td")
        cell.textContent = value
        if (index === routeColumn) cell.className = "rt-route"
        if (String(value).match(/^5\d\d$/)) cell.classList.add("rt-error")
        row.append(cell)
      })
      target.append(row)
    })
  }

  charts(history) {
    const ns = "http://www.w3.org/2000/svg"
    this.element.querySelectorAll("[data-chart]").forEach(svg => {
      const key = svg.dataset.chart
      const values = history.map(sample => sample[key])
      const finite = values.filter(Number.isFinite)
      const peak = finite.length ? Math.max(...finite) : null
      const maximum = Math.max(1, peak || 0)
      const group = svg.querySelector("g")
      group.replaceChildren()
      let points = []
      const flush = () => {
        if (points.length) {
          const line = document.createElementNS(ns, "polyline")
          line.setAttribute("points", points.join(" "))
          group.append(line)
          points = []
        }
      }
      values.forEach((value, index) => {
        if (Number.isFinite(value)) points.push(`${index / Math.max(1, values.length - 1) * 600},${140 - value / maximum * 125}`)
        else flush()
      })
      flush()
      const format = value => key === "rss_bytes" ? this.bytes(value) : `${this.number(value, key === "rate_per_second" ? 2 : 1)}${key === "cpu_percent" ? "%" : key === "p95_ms" ? " ms" : " req/s"}`
      const formatted = format(values.at(-1))
      this.element.querySelector(`[data-chart-value="${key}"]`).textContent = formatted
      this.element.querySelector(`[data-chart-peak="${key}"]`).textContent = format(peak)
      svg.setAttribute("aria-label", `${key.replaceAll("_", " ")}: current ${formatted}; chart peak ${format(peak)}`)
    })
  }
}
