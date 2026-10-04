class MessagesController < ApplicationController
  include ActiveStorage::SetCurrent, RoomScoped

  before_action :set_room, except: :create
  before_action :set_message, only: %i[ show edit update destroy ]
  before_action :ensure_can_administer, only: %i[ edit update destroy ]

  layout false, only: :index

  def index
    @messages = find_paged_messages

    if @messages.any?
      fresh_when @messages
    else
      head :no_content
    end
  end

  def create
    set_room
    if TalkSlot.enabled? && @room.nil?
      head :not_found
      return
    end
    talk = TalkSlot.find_by(room_id: @room.id) if TalkSlot.enabled? && Current.user.active? && !Current.user.bot? && !@room.direct?
    if talk
      lock_retries = 0
      begin
        acquired_talk_lock = false
        TalkSlot.transaction do
          acquire_talk_write_lock(talk)
          acquired_talk_lock = true
          preview = Message.new(message_params)
          question_body = talk.question_body!(preview)
          existing = talk.talk_questions.find_by(client_message_id: preview.client_message_id) if question_body
          if existing
            @replayed_talk_message = true
            @message = talk.retry_message!(preview.client_message_id, Current.user)
          else
            @message = @room.messages.create_with_attachment!(message_params)
            talk.capture_question!(@message) if question_body
          end
        end
      rescue RuntimeError => error
        raise unless !acquired_talk_lock && error.message.include?("Db.exec failed (5): database is locked")

        lock_retries += 1
        if lock_retries <= 2
          sleep(0.05 * lock_retries)
          retry
        end
        response.headers["Retry-After"] = "1"
        head :service_unavailable
        return
      rescue ArgumentError => error
        render plain: error.message, status: :unprocessable_entity
        return
      rescue ActiveRecord::RecordNotUnique
        @replayed_talk_message = true
        @message = talk.retry_message!(message_params[:client_message_id], Current.user)
      end
    else
      @message = @room.messages.create_with_attachment!(message_params)
    end

    unless @replayed_talk_message
      @message.broadcast_create
      deliver_webhooks_to_bots
    end
  rescue ActiveRecord::RecordNotFound
    if talk
      head :not_found
    else
      render action: :room_not_found
    end
  end

  def show
  end

  def edit
  end

  def update
    @message.update!(message_params)

    @message.broadcast_replace_to @room, :messages, target: [ @message, :presentation ], partial: "messages/presentation", attributes: { maintain_scroll: true }

    respond_to do |format|
      format.html { redirect_to room_message_url(@room, @message) }
      format.json { render :show }
    end
  end

  def destroy
    @message.destroy
    @message.broadcast_remove
  end

  private
    def acquire_talk_write_lock(talk)
      TalkSlot.where(id: talk.id).update_all(updated_at: Time.current)
    end

    def set_message
      @message = @room.messages.find(params[:id])
    end

    def ensure_can_administer
      head :forbidden unless Current.user.can_administer?(@message)
    end


    def find_paged_messages
      case
      when params[:before].present?
        @room.messages.with_creator.page_before(@room.messages.find(params[:before]))
      when params[:after].present?
        @room.messages.with_creator.page_after(@room.messages.find(params[:after]))
      else
        @room.messages.with_creator.last_page
      end
    end


    def message_params
      params.require(:message).permit(:body, :attachment, :client_message_id)
    end


    def deliver_webhooks_to_bots
      bots_eligible_for_webhook.excluding(@message.creator).each { |bot| bot.deliver_webhook_later(@message) }
    end

    def bots_eligible_for_webhook
      @room.direct? ? @room.users.active_bots : @message.mentionees.active_bots
    end
end
