require "test_helper"

class TalksControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    @previous_flag = ENV["TALK_CHANNELS_ENABLED"]
    ENV["TALK_CHANNELS_ENABLED"] = "true"
    sign_in :david
    @room = rooms(:watercooler)
    @talk = TalkSlot.create!(room: @room, uid: "talk-pilot@deccanqueenonrails.com", title: "Synthetic talk", speaker: "Demo speaker", starts_at: Time.current, ends_at: 1.hour.from_now)
  end

  teardown do
    ENV["TALK_CHANNELS_ENABLED"] = @previous_flag
  end

  test "default off hides pilot and leaves ask as ordinary chat" do
    ENV.delete("TALK_CHANNELS_ENABLED")
    get room_talk_path(@room)
    assert_response :not_found
    post_message "/ask Ordinary message", "off"
    assert_response :success
    assert_equal 0, @talk.talk_questions.count
    assert_equal "/ask Ordinary message", Message.last.plain_text_body
  end

  test "actual composer captures one question and one message across retries" do
    2.times { post_message "/ask How does this work?", "retry" }
    assert_response :success
    assert_equal 1, @talk.talk_questions.count
    assert_equal 1, @room.messages.where(client_message_id: "retry").count
    assert_equal "How does this work?", @talk.talk_questions.first.body
    assert_equal @room.id, @talk.talk_questions.first.message.room_id
  end

  test "invalid ask rolls back chat and capture" do
    before = @room.messages.count
    assert_no_enqueued_jobs only: Room::PushMessageJob do
      post_message "/ask ", "empty"
    end
    assert_response :unprocessable_entity
    assert_equal before, @room.messages.count
    post_message "/ask #{'a' * 501}", "long"
    assert_response :unprocessable_entity
    assert_equal before, @room.messages.count
  end

  test "member can vote once but cannot moderate or read stage" do
    sign_in :jz
    room = rooms(:designers)
    talk = TalkSlot.create!(room: room, uid: "talk-other@deccanqueenonrails.com", title: "Other talk", speaker: "Speaker", starts_at: Time.current, ends_at: 1.hour.from_now)
    post room_messages_path(room, format: :turbo_stream), params: { message: { body: "/ask Another question", client_message_id: "other" } }
    question = talk.talk_questions.first
    2.times { post room_talk_vote_path(room), params: { question_id: question.id } }
    assert_response :no_content
    assert_equal 1, question.talk_votes.count
    post room_talk_moderate_path(room), params: { command: "blank" }
    assert_response :forbidden
    get room_talk_stage_path(room)
    assert_response :forbidden
    get room_talk_snapshot_path(room, stage: true)
    assert_response :forbidden
  end

  test "room membership and slot scope guard all question actions" do
    post_message "/ask Scoped question", "scope"
    question = @talk.talk_questions.first
    sign_in :jz
    assert_raises(ActiveRecord::RecordNotFound) { get room_talk_snapshot_path(@room) }
    assert_raises(ActiveRecord::RecordNotFound) { post room_talk_vote_path(@room), params: { question_id: question.id } }
    room = rooms(:designers)
    TalkSlot.create!(room: room, uid: "talk-boundary@deccanqueenonrails.com", title: "Boundary", speaker: "Speaker", starts_at: Time.current, ends_at: 1.hour.from_now)
    assert_raises(ActiveRecord::RecordNotFound) { post room_talk_vote_path(room), params: { question_id: question.id } }
    assert_equal 0, question.talk_votes.count
  end

  test "question intake stays open during Q&A pause and blank with stable active question" do
    post_message "/ask First question", "first"
    first = @talk.talk_questions.first
    post room_talk_moderate_path(@room), params: { command: "select", question_id: first.id }
    assert_response :no_content
    %w[ questions paused blank ].each do |command|
      post room_talk_moderate_path(@room), params: { command: command }
      post_message "/ask During #{command}", command
      assert_response :success
      assert_equal first.id, @talk.reload.active_question_id
    end
    assert_equal 4, @talk.talk_questions.count
    get room_talk_snapshot_path(@room, stage: true)
    assert_equal [], response.parsed_body["questions"]
    post room_talk_moderate_path(@room), params: { command: "live" }
    get room_talk_snapshot_path(@room, stage: true)
    assert_equal first.id, response.parsed_body["questions"].first["id"]
  end

  test "stage is plaintext and hide never deletes chat history" do
    post_message "<div>/ask &lt;script&gt;alert(1)&lt;/script&gt; https://example.invalid</div>", "safe"
    question = @talk.talk_questions.first
    get room_talk_snapshot_path(@room, stage: true)
    data = response.parsed_body
    assert_equal [ "body", "id" ], data["messages"].last.keys.sort
    assert_no_match(/email|creator_id|user_id|author/, response.body)
    assert_match "<script>alert(1)</script>", question.body
    post room_talk_moderate_path(@room), params: { command: "hide_message", message_id: question.message_id }
    assert_response :no_content
    assert Message.exists?(question.message_id)
    get room_talk_snapshot_path(@room, stage: true)
    assert_not_includes response.parsed_body["messages"].map { |message| message["id"] }, question.message_id
    post room_talk_moderate_path(@room), params: { command: "hide", question_id: question.id }
    assert_response :no_content
    get room_talk_snapshot_path(@room)
    assert_equal [], response.parsed_body["questions"]
  end

  test "views include new tab navigation and operational controls" do
    get room_path(@room)
    assert_select "a[target='_blank'][href='#{room_talk_path(@room)}']", count: 1
    get room_talk_path(@room)
    assert_response :success
    assert_select "button[data-command='blank']", count: 1
    get room_talk_stage_path(@room)
    assert_response :success
    assert_select "body.talk-stage", count: 1
    assert_select "[data-talk-pilot-snapshot-value]", count: 1
  end

  test "every pilot endpoint is unavailable while flag is off" do
    ENV.delete("TALK_CHANNELS_ENABLED")
    [ room_talk_path(@room), room_talk_stage_path(@room), room_talk_snapshot_path(@room) ].each do |url|
      get url
      assert_response :not_found
    end
    [ room_talk_vote_path(@room), room_talk_moderate_path(@room) ].each do |url|
      post url
      assert_response :not_found
    end
    get room_path(@room)
    assert_select "a[href='#{room_talk_path(@room)}']", count: 0
    assert_no_match "This talk channel may appear on stage", response.body
  end

  test "inactive and bot users cannot read or write pilot endpoints" do
    users(:david).update!(status: :deactivated)
    get room_talk_snapshot_path(@room)
    assert_response :forbidden
    post room_talk_vote_path(@room), params: { question_id: 0 }
    assert_response :forbidden
    users(:david).update!(status: :active, role: :bot)
    get room_talk_snapshot_path(@room)
    assert_response :forbidden
    post room_talk_moderate_path(@room), params: { command: "blank" }
    assert_response :forbidden
  end

  test "administrator cannot select answer hide or project another slot's records" do
    post_message "/ask Local question", "local"
    question = @talk.talk_questions.first
    other_room = rooms(:designers)
    TalkSlot.create!(room: other_room, uid: "talk-isolated@deccanqueenonrails.com", title: "Isolated", speaker: "Speaker", starts_at: Time.current, ends_at: 1.hour.from_now)
    %w[ select answer hide ].each do |command|
      assert_raises(ActiveRecord::RecordNotFound) do
        post room_talk_moderate_path(other_room), params: { command: command, question_id: question.id }
      end
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      post room_talk_moderate_path(other_room), params: { command: "hide_message", message_id: question.message_id }
    end
    assert_not question.reload.hidden
    assert_not question.answered
  end

  test "retry suppresses duplicate broadcasts and cannot claim another author" do
    post_message "/ask Idempotent question", "effects"
    assert_no_broadcasts Turbo::StreamsChannel.send(:stream_name_from, [ @room, :messages ]) do
      assert_no_enqueued_jobs only: Room::PushMessageJob do
        post_message "/ask Idempotent question", "effects"
      end
      assert_response :success
    end
    sign_in :jason
    post_message "/ask Forged question", "effects"
    assert_response :not_found
    assert_equal 1, @talk.talk_questions.count
    assert_equal 1, @room.messages.where(client_message_id: "effects").count
    assert_equal users(:david).id, @talk.talk_questions.first.message.creator_id
  end

  test "native initial lock contention retries before message side effects" do
    MessagesController.any_instance.expects(:acquire_talk_write_lock).raises(RuntimeError, "Db.exec failed (5): database is locked").then.returns(1).twice
    assert_enqueued_jobs 1, only: Room::PushMessageJob do
      post_message "/ask Retried first write", "locked-retry"
    end
    assert_response :success
    assert_equal 1, @talk.talk_questions.count
    assert_equal 1, @room.messages.where(client_message_id: "locked-retry").count
  end

  test "exhausted native lock contention returns retryable failure without side effects" do
    MessagesController.any_instance.expects(:acquire_talk_write_lock).raises(RuntimeError, "Db.exec failed (5): database is locked").times(3)
    assert_no_enqueued_jobs only: Room::PushMessageJob do
      post_message "/ask Busy first write", "locked-exhausted"
    end
    assert_response :service_unavailable
    assert_equal "1", response.headers["Retry-After"]
    assert_equal 0, @talk.talk_questions.count
    assert_equal 0, @room.messages.where(client_message_id: "locked-exhausted").count
  end

  test "unrelated and post-lock failures are never retried" do
    MessagesController.any_instance.expects(:acquire_talk_write_lock).raises(RuntimeError, "unrelated failure").once
    assert_raises(RuntimeError) { post_message "/ask Unrelated failure", "unrelated" }
    MessagesController.any_instance.unstub(:acquire_talk_write_lock)
    TalkSlot.any_instance.expects(:question_body!).raises(RuntimeError, "Db.exec failed (5): database is locked").once
    assert_raises(RuntimeError) { post_message "/ask Already locked", "after-lock" }
    assert_equal 0, @talk.talk_questions.count
  end

  private
    def post_message(body, id)
      post room_messages_path(@room, format: :turbo_stream), params: { message: { body: body, client_message_id: id } }
    end
end
