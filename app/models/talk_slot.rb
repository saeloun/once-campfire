class TalkSlot < ApplicationRecord
  belongs_to :room
  has_many :talk_questions, dependent: :destroy
  has_many :talk_hidden_messages, dependent: :destroy

  validates :uid, :title, :speaker, :starts_at, :ends_at, presence: true
  validates :uid, format: { with: /\Atalk-[a-zA-Z0-9-]+@deccanqueenonrails\.com\z/ }
  validates :mode, inclusion: { in: %w[ chat questions ] }
  validates :projection, inclusion: { in: %w[ live paused blank ] }
  validates :time_zone, inclusion: { in: [ "Asia/Kolkata" ] }
  validate :non_direct_room
  validate :positive_duration

  def self.enabled?
    ENV["TALK_CHANNELS_ENABLED"] == "true"
  end

  def question_body!(message)
    text = message.plain_text_body.strip
    return unless text.match?(/\A\/ask(?:\s|\z)/)

    body = text.sub(/\A\/ask\s*/, "").strip
    raise ArgumentError, "Questions must contain 1 to 500 characters" unless body.length >= 1 && body.length <= 500
    raise ArgumentError, "A question needs a message identifier" unless message.client_message_id.to_s.length >= 1 && message.client_message_id.to_s.length <= 100
    body
  end

  def capture_question!(message)
    body = question_body!(message)
    talk_questions.create!(message: message, client_message_id: message.client_message_id, body: body) if body
  end

  def retry_message!(client_message_id, user)
    question = talk_questions.find_by!(client_message_id: client_message_id)
    raise ActiveRecord::RecordNotFound unless question.message.creator_id == user.id
    question.message
  end

  def snapshot(user, stage: false)
    waiting = talk_questions.where(hidden: false, answered: false)
    questions = waiting.order(id: :asc).limit(50).to_a
    questions += talk_questions.where(hidden: false, answered: true).order(id: :desc).limit(10).to_a
    active = talk_questions.find_by(id: active_question_id, hidden: false)
    questions << active if active && !questions.include?(active)
    question_ids = questions.map(&:id)
    vote_counts = TalkVote.where(talk_question_id: question_ids).group(:talk_question_id).count
    voted_ids = stage ? [] : TalkVote.where(talk_question_id: question_ids, user_id: user.id).pluck(:talk_question_id)
    entries = questions.map do |question|
      { id: question.id, body: question.body, answered: question.answered, votes: vote_counts[question.id] || 0,
        voted: !stage && voted_ids.include?(question.id) }
    end
    entries.sort_by! { |entry| [ entry[:id] == active_question_id ? 0 : 1, entry[:answered] ? 1 : 0, -entry[:votes], entry[:id] ] }
    messages = []
    if (stage || user.administrator?) && mode == "chat" && projection == "live"
      candidates = room.messages.with_rich_text_body_and_embeds.order(id: :desc).limit(16).to_a
      candidate_ids = candidates.map(&:id)
      hidden_ids = []
      talk_hidden_messages.where(message_id: candidate_ids).each { |hidden| hidden_ids << hidden.message_id }
      visible = candidates.reject { |message| hidden_ids.include?(message.id) || message.body.to_plain_text.blank? }
      messages = visible.first(8).reverse.map do |message|
        { id: message.id, body: message.body.to_plain_text[0, 360] }
      end
    end
    entries = [] if stage && projection != "live"
    { uid: uid, title: title, speaker: speaker, mode: mode, projection: projection,
      active_question_id: active_question_id, pending_total: waiting.count, questions: entries, messages: messages }
  end

  private
    def non_direct_room
      errors.add(:room, "must be a talk channel") if room&.direct?
    end

    def positive_duration
      errors.add(:ends_at, "must follow the start") if starts_at && ends_at && ends_at <= starts_at
    end
end
