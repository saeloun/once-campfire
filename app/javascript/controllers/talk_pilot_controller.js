import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["questions", "messages", "status", "empty"]
  static values = { snapshot: String, vote: String, moderate: String, stage: Boolean, moderator: Boolean }

  connect() {
    this.connected = true
    this.generation = (this.generation || 0) + 1
    this.poll()
  }

  disconnect() {
    this.connected = false
    this.generation += 1
    clearTimeout(this.timer)
    this.abort?.abort()
  }

  async poll() {
    const generation = ++this.generation
    this.abort = new AbortController()
    try {
      const response = await fetch(this.snapshotValue, { credentials: "same-origin", cache: "no-store", signal: this.abort.signal, headers: { Accept: "application/json" } })
      if (!response.ok || !response.headers.get("content-type")?.includes("application/json")) throw new Error("Could not refresh")
      const state = await response.json()
      if (!this.connected || generation !== this.generation) return
      this.render(state)
    } catch (error) {
      if (this.connected && generation === this.generation && error.name !== "AbortError") {
        this.statusTarget.textContent = "Connection interrupted. Retrying…"
        if (this.stageValue) {
          this.questionsTarget.replaceChildren()
          if (this.hasMessagesTarget) this.messagesTarget.replaceChildren()
        }
      }
    } finally {
      if (this.connected && generation === this.generation) this.timer = setTimeout(() => this.poll(), 2000)
    }
  }

  render(state) {
    const active = state.active_question_id
    this.activeQuestion = active
    const questions = state.questions.slice().sort((a, b) => Number(b.id === active) - Number(a.id === active) || Number(a.answered) - Number(b.answered) || b.votes - a.votes || a.id - b.id)
    const visible = this.stageValue ? (state.mode === "questions" ? questions.slice(0, 3) : []) : questions
    this.renderList(this.questionsTarget, visible, question => this.questionNode(question, active))
    if (this.hasMessagesTarget) this.renderList(this.messagesTarget, state.messages.slice(-4), message => this.messageNode(message))
    this.emptyTarget.hidden = visible.length > 0 || state.messages.length > 0 || state.projection !== "live"
    this.statusTarget.textContent = state.projection === "live" ? (this.thanks || (state.mode === "questions" ? "Q&A is live · /ask stays open" : "Talk chat is live · /ask stays open")) : (state.projection === "paused" ? "Projection paused · questions remain open" : "")
    if (!this.stageValue && state.projection === "live" && state.pending_total > 50) this.statusTarget.textContent += ` · ${state.pending_total} waiting; showing the earliest 50`
    this.element.dataset.projection = state.projection
  }

  renderList(target, entries, build) {
    const focus = document.activeElement
    const focusedId = focus?.closest("[data-entry-id]")?.dataset.entryId
    const focusedCommand = focus?.dataset.command
    const keys = new Set(entries.map(entry => String(entry.id)))
    for (const child of [...target.children]) if (!keys.has(child.dataset.entryId)) child.remove()
    for (const entry of entries) {
      let node = Array.from(target.children).find(child => child.dataset.entryId === String(entry.id))
      const signature = JSON.stringify(entry) + String(this.activeQuestion)
      if (!node || node.dataset.signature !== signature) {
        const replacement = build(entry)
        replacement.dataset.entryId = String(entry.id)
        replacement.dataset.signature = signature
        if (node) node.replaceWith(replacement)
        node = replacement
      }
      target.append(node)
    }
    if (focusedId && focusedCommand) target.querySelector(`[data-entry-id="${focusedId}"] [data-command="${focusedCommand}"]`)?.focus({ preventScroll: true })
  }

  questionNode(question, active) {
    this.activeQuestion = active
    const item = document.createElement("li")
    item.className = "talk-question"
    item.dataset.active = String(question.id === active)
    const text = document.createElement("p")
    text.textContent = this.stageValue && question.id !== active ? question.body.slice(0, 100) : question.body
    const badge = document.createElement("span")
    badge.className = "talk-badge"
    badge.textContent = `${question.id === active ? "On the mic · " : ""}${question.answered ? "Answered by speaker · " : ""}${question.votes} votes`
    item.append(text, badge)
    if (!this.stageValue) {
      const actions = document.createElement("div")
      actions.className = "talk-question-actions"
      actions.append(this.button(question.voted ? "Thanks — voted" : "Vote", "vote", question.id, question.voted))
      if (this.moderatorValue) {
        actions.append(this.button("On the mic", "select", question.id), this.button("Answered", "answer", question.id), this.button("Hide", "hide", question.id))
      }
      item.append(actions)
    }
    return item
  }

  messageNode(message) {
    const item = document.createElement("li")
    item.className = "talk-stage-message"
    const text = document.createElement("p")
    text.textContent = message.body.slice(0, 180)
    item.append(text)
    if (!this.stageValue && this.moderatorValue) {
      const hide = this.button("Hide from stage", "hide_message", "")
      hide.dataset.messageId = message.id
      item.append(hide)
    }
    return item
  }

  button(label, command, id, disabled = false) {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = label
    button.dataset.command = command
    button.dataset.questionId = id
    button.dataset.action = command === "vote" ? "talk-pilot#vote" : "talk-pilot#moderate"
    button.disabled = disabled
    return button
  }

  vote(event) {
    this.submit(this.voteValue, { question_id: event.currentTarget.dataset.questionId }, "Thanks for helping the speaker find useful questions.")
  }

  moderate(event) {
    this.submit(this.moderateValue, { command: event.currentTarget.dataset.command, question_id: event.currentTarget.dataset.questionId, message_id: event.currentTarget.dataset.messageId })
  }

  async submit(url, body, thanks) {
    try {
      const response = await fetch(url, { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content, Accept: "application/json" }, body: JSON.stringify(body) })
      if (response.status !== 204 || response.redirected) throw new Error("Action failed")
      this.thanks = thanks
      clearTimeout(this.timer)
      this.abort?.abort()
      if (this.connected) this.poll()
    } catch {
      if (this.connected) this.statusTarget.textContent = "Action failed. Check your connection and try again."
    }
  }
}
