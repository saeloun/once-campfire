require "test_helper"

class TalkSlotTest < ActiveSupport::TestCase
  setup do
    @talk = TalkSlot.create!(room: rooms(:watercooler), uid: "talk-pilot@deccanqueenonrails.com", title: "Synthetic talk", speaker: "Speaker", starts_at: Time.current, ends_at: 1.hour.from_now)
    Current.user = users(:david)
  end

  teardown { Current.reset }

  test "direct rooms and nonpositive slots cannot be mapped" do
    @talk.room = rooms(:david_and_jason)
    assert_not @talk.valid?
    @talk.room = rooms(:watercooler)
    @talk.ends_at = @talk.starts_at
    assert_not @talk.valid?
  end

  test "database uniquely enforces UID room capture and votes" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      TalkSlot.create!(@talk.attributes.except("id", "created_at", "updated_at"))
    end
    message = capture_message(body: "/ask Test question", client_message_id: "unique")
    question = @talk.talk_questions.first
    assert_raises(ActiveRecord::RecordNotUnique) do
      @talk.talk_questions.create!(message: message, body: "Duplicate", client_message_id: "unique")
    end
    question.vote!(users(:david))
    question.vote!(users(:david))
    assert_equal 1, question.talk_votes.count
    assert_raises(ActiveRecord::RecordNotUnique) { question.talk_votes.create!(user: users(:david)) }
  end

  test "retries cannot claim another author's question" do
    capture_message(body: "/ask Original question", client_message_id: "shared")
    Current.user = users(:jason)
    assert_raises(ActiveRecord::RecordNotFound) { @talk.retry_message!("shared", Current.user) }
    assert_equal 1, @talk.talk_questions.count
    assert_equal 1, @talk.room.messages.where(client_message_id: "shared").count
  end

  test "rank changes never dislodge the active question and rescheduling keeps UID" do
    2.times { |i| capture_message(body: "/ask Question #{i}", client_message_id: "rank-#{i}") }
    first, second = @talk.talk_questions.order(:id).to_a
    @talk.update!(active_question_id: first.id, starts_at: 2.hours.from_now, ends_at: 3.hours.from_now)
    second.vote!(users(:david))
    assert_equal first.id, @talk.snapshot(users(:david))[:questions].first[:id]
    assert_equal "talk-pilot@deccanqueenonrails.com", @talk.reload.uid
    first.update!(answered: true)
    assert @talk.snapshot(users(:david))[:questions].first[:answered]
  end
  test "deleting original messages rooms and voters retains existing lifecycle behavior" do
    message = capture_message(body: "/ask Lifecycle question", client_message_id: "lifecycle")
    question = @talk.talk_questions.first
    question.vote!(users(:jz))
    @talk.talk_hidden_messages.create!(message: message)
    message.destroy!
    assert_not TalkQuestion.exists?(question.id)
    assert_equal 0, TalkVote.where(talk_question_id: question.id).count
    assert_equal 0, @talk.talk_hidden_messages.count
    next_message = capture_message(body: "/ask Voter removal", client_message_id: "voter")
    next_question = @talk.talk_questions.first
    next_question.vote!(users(:jz))
    users(:jz).destroy!
    assert_equal 0, next_question.talk_votes.count
    @talk.room.destroy!
    assert_not TalkSlot.exists?(@talk.id)
    assert_not Message.exists?(next_message.id)
  end

  private
    def capture_message(attributes)
      @talk.transaction do
        message = @talk.room.messages.create!(attributes)
        @talk.capture_question!(message)
        message
      end
    end
end
