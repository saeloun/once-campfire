class TalksController < ApplicationController
  layout false, only: :stage

  before_action :require_pilot
  before_action :set_talk
  before_action :require_moderator, only: %i[ stage moderate ]

  def show
    @available_talks = TalkSlot.where(room_id: Current.user.rooms.pluck(:id)).order(:starts_at).limit(40)
  end

  def stage
  end

  def snapshot
    if params[:stage] == "true" && !Current.user.administrator?
      head :forbidden
    else
      response.headers["Cache-Control"] = "no-store"
      render plain: @talk.snapshot(Current.user, stage: params[:stage] == "true").to_json, content_type: "application/json"
    end
  end

  def vote
    completed = with_talk_write do
      @talk.talk_questions.find_by!(id: params[:question_id], hidden: false).vote!(Current.user)
    end
    head :no_content if completed
  end

  def moderate
    unless %w[ chat questions live paused blank advance select answer hide hide_message ].include?(params[:command])
      head :unprocessable_entity
      return
    end
    completed = with_talk_write do
      case params[:command]
      when "chat", "questions"
        @talk.update!(mode: params[:command])
      when "live", "paused", "blank"
        @talk.update!(projection: params[:command])
      when "advance"
        next_question = @talk.snapshot(Current.user)[:questions].find { |entry| !entry[:answered] && entry[:id] != @talk.active_question_id }
        @talk.update!(active_question_id: next_question && next_question[:id])
      when "select", "answer", "hide"
        question = @talk.talk_questions.find_by!(id: params[:question_id], hidden: false)
        case params[:command]
        when "select"
          @talk.update!(active_question_id: question.id)
        when "answer"
          question.update!(answered: true)
        when "hide"
          question.update!(hidden: true)
          @talk.update!(active_question_id: nil) if @talk.active_question_id == question.id
        end
      when "hide_message"
        message = @talk.room.messages.find(params[:message_id])
        TalkHiddenMessage.create!(talk_slot_id: @talk.id, message: message)
      end
    end
    head :no_content if completed
  rescue ActiveRecord::RecordNotUnique
    head :no_content
  end

  private
    def acquire_talk_write_lock
      TalkSlot.where(id: @talk.id).update_all(updated_at: Time.current)
    end

    def with_talk_write
      lock_retries = 0
      begin
        acquired_talk_lock = false
        TalkSlot.transaction do
          acquire_talk_write_lock
          acquired_talk_lock = true
          @talk = TalkSlot.find(@talk.id)
          yield
        end
        true
      rescue RuntimeError => error
        raise unless !acquired_talk_lock && error.message.include?("Db.exec failed (5): database is locked")

        lock_retries += 1
        if lock_retries <= 2
          sleep(0.05 * lock_retries)
          retry
        end
        response.headers["Retry-After"] = "1"
        head :service_unavailable
        false
      end
    end

    def require_pilot
      head :not_found unless TalkSlot.enabled?
    end

    def set_talk
      head :forbidden and return unless Current.user.active? && !Current.user.bot?
      @membership = Current.user.memberships.find_by!(room_id: params[:room_id])
      @room = Room.find(@membership.room_id)
      head :not_found and return if @room.direct?
      @talk = TalkSlot.find_by!(room_id: @room.id)
    end

    def require_moderator
      head :forbidden unless Current.user.administrator?
    end
end
