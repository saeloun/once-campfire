import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["questions", "messages", "status", "empty", "mode", "count", "draft", "send", "askFeedback"]
  static values = { snapshot: String, vote: String, moderate: String, stage: Boolean, moderator: Boolean }

  connect() {
    this.connected = true
    this.generation = (this.generation || 0) + 1
    if (this.hasDraftTarget && location.hash === "#ask") requestAnimationFrame(() => this.draftTarget.focus())
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
    const limit = questions[0]?.id === active && questions[0].body.length > 350 ? 1 : 3
    const visible = this.stageValue ? (state.mode === "questions" ? questions.slice(0, limit) : []) : questions
    this.renderList(this.questionsTarget, visible, question => this.questionNode(question, active))
    if (this.hasMessagesTarget) this.renderList(this.messagesTarget, state.messages.slice(this.stageValue ? -3 : -4), message => this.messageNode(message))
    if (this.hasModeTarget) this.modeTarget.textContent = state.mode === "questions" ? "Live Q&A" : "Live chat"
    if (this.hasCountTarget) this.countTarget.textContent = `(${state.pending_total || questions.filter(question => !question.answered).length})`
    for (const button of this.element.querySelectorAll("[aria-pressed]")) button.setAttribute("aria-pressed", String(button.dataset.command === state.mode || button.dataset.command === state.projection))
    this.element.dataset.mode = state.mode
    this.emptyTarget.hidden = visible.length > 0 || (this.stageValue && state.messages.length > 0) || state.projection !== "live"
    this.statusTarget.textContent = state.projection === "live" ? (this.stageValue ? "" : (this.thanks || "")) : (state.projection === "paused" ? "Projection paused · questions remain open" : "")
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
    item.dataset.answered = String(question.answered)
    if (this.stageValue && question.id === active) item.dataset.length = question.body.length > 160 ? "long" : question.body.length > 110 ? "medium" : "short"
    const text = document.createElement("p")
    text.textContent = this.stageValue && question.id !== active ? question.body.slice(0, 100) : question.body
    const badge = document.createElement("span")
    badge.className = "talk-badge"
    badge.textContent = question.answered ? "Answered" : question.id === active ? "Now answering" : (this.stageValue ? "Up next" : "Waiting")
    const votes = document.createElement("span")
    votes.className = "talk-votes"
    votes.textContent = `${question.votes} ${question.votes === 1 ? "vote" : "votes"}`
    const metadata = document.createElement("div")
    metadata.className = "talk-question-meta"
    metadata.append(badge, votes)
    item.append(metadata, text)
    if (!this.stageValue) {
      const actions = document.createElement("div")
      actions.className = "talk-question-actions"
      actions.append(this.button(question.voted ? "↑ Voted" : "↑ Vote", "vote", question.id, question.voted))
      if (this.moderatorValue) {
        actions.append(this.button("Show on stage", "select", question.id), this.button("Answered", "answer", question.id), this.button("Hide", "hide", question.id))
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
    const label = document.createElement("span")
    label.className = "talk-badge"
    label.textContent = message.body.trim().startsWith("/ask ") ? "Question submitted" : "Message"
    item.append(label, text)
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

  focusAsk(event) {
    event.preventDefault()
    this.draftTarget.scrollIntoView({ block: "center" })
    this.draftTarget.focus({ preventScroll: true })
  }

  saveDraft() {
    if (!this.sending && this.hasAskFeedbackTarget) this.askFeedbackTarget.hidden = true
    this.askClientId = undefined
  }

  async ask(event) {
    event.preventDefault()
    if (this.sending || !this.draftTarget.value.trim()) return
    this.sending = true
    this.sendTarget.disabled = true
    this.sendTarget.textContent = "Sending…"
    this.setAskFeedback("Sending your question…")
    this.askClientId ||= crypto.randomUUID()
    const question = this.draftTarget.value.trim()
    const container = document.createElement("div")
    container.textContent = `/ask ${question}`
    const body = new URLSearchParams()
    body.set("message[body]", container.outerHTML)
    body.set("message[client_message_id]", this.askClientId)
    try {
      const response = await fetch(event.currentTarget.action, { method: "POST", credentials: "same-origin", headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content, Accept: "text/vnd.turbo-stream.html" }, body })
      if (response.status !== 200 || response.redirected || !response.headers.get("content-type")?.includes("text/vnd.turbo-stream.html")) throw new Error("Question failed")
      await response.text()
      if (this.draftTarget.value.trim() === question) {
        this.draftTarget.value = ""
      }
      this.askClientId = undefined
      this.setAskFeedback("Question sent. Vote for the questions you would like answered.")
      clearTimeout(this.timer)
      this.abort?.abort()
      if (this.connected) this.poll()
    } catch {
      this.setAskFeedback("Not confirmed — your draft is kept. Try sending again.")
    } finally {
      this.sending = false
      this.sendTarget.disabled = false
      this.sendTarget.textContent = "Send question"
    }
  }

  setAskFeedback(message) {
    if (this.hasAskFeedbackTarget) {
      this.askFeedbackTarget.hidden = false
      this.askFeedbackTarget.textContent = message
    }
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
