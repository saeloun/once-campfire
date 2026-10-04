class TalksController < ApplicationController
  layout false, only: :stage

  before_action :require_pilot
  before_action :set_talk
  before_action :require_moderator, only: %i[ stage moderate ]

  def show
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
    @talk.talk_questions.find_by!(id: params[:question_id], hidden: false).vote!(Current.user)
    head :no_content
  end

  def moderate
    TalkSlot.transaction do
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
      else
        head :unprocessable_entity
        return
      end
    end
    head :no_content
  rescue ActiveRecord::RecordNotUnique
    head :no_content
  end

  private
    def require_pilot
      head :not_found unless TalkSlot.enabled?
    end

    def set_talk
      head :forbidden and return unless Current.user.active? && !Current.user.bot?
      @membership = Current.user.memberships.find_by!(room_id: params[:room_id])
      @room = @membership.room
      head :not_found and return if @room.direct?
      @talk = TalkSlot.find_by!(room_id: @room.id)
    end

    def require_moderator
      head :forbidden unless Current.user.administrator?
    end
end
