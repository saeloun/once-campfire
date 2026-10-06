require "test_helper"

class AnnouncementsTest < ActionDispatch::IntegrationTest
  setup do
    Current.reset
    @room = Rooms::Announcement.create!(name: "Synthetic Announcements", creator: users(:david))
    @message = @room.messages.create!(body: "Synthetic administrator notice", creator: users(:david))
  end

  test "member attachment and text posts fail before all persistence jobs and broadcasts" do
    sign_in :jz
    stream = Turbo::StreamsChannel.send(:stream_name_from, [ @room, :messages ])
    assert_no_broadcasts stream do
      assert_no_enqueued_jobs do
        assert_no_difference [ -> { Message.count }, -> { ActionText::RichText.count }, -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ] do
          post room_messages_path(@room, format: :turbo_stream), params: { message: { body: "Denied", attachment: fixture_file_upload("moon.jpg", "image/jpeg") } }
          assert_response :forbidden
        end
      end
    end
  end

  test "signed existing blobs and forged fields cannot bypass JSON create policy" do
    sign_in :jz
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("synthetic announcement blob"), filename: "existing.txt", content_type: "text/plain")
    checksum = Digest::SHA256.hexdigest(blob.download)
    assert_no_difference [ -> { Message.count }, -> { ActionText::RichText.count }, -> { ActiveStorage::Attachment.count }, -> { ActiveStorage::VariantRecord.count }, -> { ActiveStorage::Blob.count } ] do
      post room_messages_path(@room, format: :json), params: { message: { body: "Denied JSON notice", attachment: blob.signed_id,
        creator_id: users(:david).id, room_id: rooms(:watercooler).id } }
      assert_response :forbidden
    end
    assert_equal checksum, Digest::SHA256.hexdigest(blob.download)
    assert_difference -> { Message.count }, 1 do
      post room_messages_path(rooms(:designers), format: :turbo_stream), params: { message: { body: "Ordinary synthetic chat", room_id: @room.id, creator_id: users(:david).id } }
      assert_response :success
    end
    assert_equal rooms(:designers).id, Message.last.room_id
    assert_equal users(:jz).id, Message.last.creator_id
  end

  test "PUT and PATCH JSON edit policies deny members before attachments" do
    sign_in :jz
    [ :put, :patch ].each do |method|
      assert_no_difference [ -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ] do
        public_send(method, room_message_path(@room, @message, format: :json), params: { message: { body: "Denied JSON edit", attachment: fixture_file_upload("moon.jpg", "image/jpeg") } })
        assert_response :forbidden
      end
    end
    assert_equal "Synthetic administrator notice", @message.reload.plain_text_body
  end

  test "mocked verified Google signup joins announcements without changing role" do
    keys = %w[ GOOGLE_LOGIN_ENABLED CAMPFIRE_ADMIN_EMAILS CAMPFIRE_SPEAKER_EMAILS CAMPFIRE_SPEAKER_ROOM_ID ]
    previous = keys.to_h { |key| [ key, ENV[key] ] }
    ENV["GOOGLE_LOGIN_ENABLED"] = "true"
    keys.drop(1).each { |key| ENV.delete(key) }
    post google_session_url, params: { join_code: accounts(:signal).join_code }
    state = parsed_cookies.signed[:google_login_state]
    code = "a" * 43
    GoogleSessionsController.any_instance.expects(:redeem).with(code, state).returns({ "verified" => true, "email" => "new-google@announcement.invalid", "name" => "Synthetic Google Person" })
    get google_session_callback_url, params: { state: state, login_code: code }
    assert_response :redirect
    user = User.find_by!(email_address: "new-google@announcement.invalid")
    assert user.member?
    assert @room.users.include?(user)
    assert_not @room.postable_by?(user)
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "member edits updates and deletes are denied including a demoted original creator" do
    sign_in :jz
    get edit_room_message_path(@room, @message)
    assert_response :forbidden
    patch room_message_path(@room, @message), params: { message: { body: "Denied edit" } }
    assert_response :forbidden
    delete room_message_path(@room, @message, format: :turbo_stream)
    assert_response :forbidden
    assert_equal "Synthetic administrator notice", @message.reload.plain_text_body
    users(:david).update!(role: :member)
    sign_in :david
    delete room_message_path(@room, @message, format: :turbo_stream)
    assert_response :forbidden
    assert Message.exists?(@message.id)
  end

  test "another existing administrator can publish edit and delete announcements" do
    sign_in :jason
    assert_difference -> { Message.count }, 1 do
      post room_messages_path(@room, format: :turbo_stream), params: { message: { body: "New synthetic notice", client_message_id: "announcement-admin" } }
      assert_response :success
    end
    patch room_message_path(@room, @message), params: { message: { body: "Edited synthetic notice" } }
    assert_response :redirect
    assert_equal "Edited synthetic notice", @message.reload.plain_text_body
    delete room_message_path(@room, @message, format: :turbo_stream)
    assert_response :success
    assert_not Message.exists?(@message.id)
  end

  test "inactive administrator and administrator without membership cannot publish" do
    sign_in :david
    users(:david).update!(status: :deactivated)
    assert_no_difference -> { Message.count } do
      post room_messages_path(@room, format: :turbo_stream), params: { message: { body: "Denied inactive" } }
      assert_response :forbidden
    end
    users(:david).update!(status: :active)
    @room.memberships.find_by!(user: users(:david)).destroy!
    assert_no_difference -> { Message.count } do
      post room_messages_path(@room, format: :turbo_stream), params: { message: { body: "Denied nonmember" } }
    end
    assert_response :success
    assert_match "This room was deleted", response.body
  end

  test "bot posts and updates are denied even with an artificially existing membership" do
    @room.memberships.grant_to(users(:bender))
    assert_no_difference [ -> { Message.count }, -> { ActionText::RichText.count }, -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ] do
      post room_bot_messages_url(@room, users(:bender).bot_key), params: "Denied raw bot text"
      assert_response :forbidden
      post room_bot_messages_url(@room, users(:bender).bot_key), params: { attachment: fixture_file_upload("moon.jpg", "image/jpeg") }
      assert_response :forbidden
      patch room_bot_message_url(@room, users(:bender).bot_key, @message), params: "Denied bot edit"
      assert_response :forbidden
      delete room_bot_message_url(@room, users(:bender).bot_key, @message)
      assert_response :forbidden
    end
  end

  test "boost creation deletion and interface are blocked for every role" do
    [ :jz, :david ].each do |writer|
      sign_in writer
      get new_message_boost_path(@message)
      assert_response :forbidden
      get message_boosts_path(@message)
      assert_response :forbidden
      post message_boosts_path(@message), params: { boost: { content: "Free text" } }
      assert_response :forbidden
      delete message_boost_path(@message, 123)
      assert_response :forbidden
    end
    @room.memberships.grant_to(users(:bender))
    post room_bot_message_boosts_url(@room, users(:bender).bot_key, @message), params: "Bot text"
    assert_response :forbidden
    assert_equal 0, @message.boosts.count
  end

  test "member UI is read only while cached actions contain no replies or boosts" do
    sign_in :jz
    get room_path(@room)
    assert_response :success
    assert_select "form#composer", count: 0
    assert_select "[role=status]", text: /Announcements are read only/
    assert_select "[data-action='reply#reply']", count: 0
    assert_select ".quick-boosts", count: 0
    assert_select "a[href='#{edit_rooms_announcement_path(@room)}']", count: 0
    sign_in :jason
    get room_path(@room)
    assert_select "form#composer", count: 1
    assert_select "body.admin.announcement-publisher", count: 1
    assert_select ".announcement__edit-btn", count: 1
  end

  test "inactive administrators and demoted authors have no publisher UI class" do
    sign_in :david
    users(:david).update!(status: :deactivated)
    get room_path(@room)
    assert_response :success
    assert_select "body.announcement-publisher", count: 0
    assert_select "form#composer", count: 0
    users(:david).update!(status: :active, role: :member)
    get room_path(@room)
    assert_select "body.announcement-publisher", count: 0
    assert_select "form#composer", count: 0
  end

  test "administrator creation is idempotent and members cannot manage or convert announcements" do
    sign_in :david
    2.times do
      assert_no_difference [ -> { Rooms::Announcement.count }, -> { @room.memberships.count } ] do
        post rooms_announcements_path, params: { room: { name: "Another room" } }
        assert_redirected_to room_path(@room)
      end
    end
    get edit_rooms_announcement_path(@room)
    assert_response :success
    patch rooms_announcement_path(@room), params: { room: { name: "Renamed notices" } }
    assert_redirected_to room_path(@room)
    assert_equal "Renamed notices", @room.reload.name
    [ edit_rooms_open_path(@room), edit_rooms_closed_path(@room) ].each do |path|
      get path
      assert_response :redirect
    end
    sign_in :jz
    get new_rooms_announcement_path
    assert_response :forbidden
    patch rooms_announcement_path(@room), params: { room: { name: "Denied settings" } }
    assert_response :forbidden
    delete room_path(@room)
    assert_response :forbidden
    assert_equal "Rooms::Announcement", @room.reload.type
  end
end

class AnnouncementCreationConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test "concurrent administrator requests establish one room and one membership per person" do
    clients = [ :david, :jason ].map do |name|
      client = open_session
      user = users(name)
      client.post session_url, params: { email_address: user.email_address, password: "secret123456" }
      assert client.cookies[:session_token].present?
      client
    end
    gate = Queue.new
    outcomes = Queue.new
    threads = clients.map do |client|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          client.post rooms_announcements_path, params: { room: { name: "Concurrent synthetic notices" } }
          outcomes << client.response.status
        end
      rescue StandardError => error
        outcomes << error
      end
    end
    2.times { gate << true }
    threads.each(&:join)
    2.times { assert_equal 302, outcomes.pop }
    assert_equal 1, Rooms::Announcement.count
    room = Rooms::Announcement.first!
    assert_equal User.active.without_bots.count, room.memberships.count
    assert_equal 0, room.memberships.group(:user_id).having("count(*) > 1").count.size
  ensure
    Rooms::Announcement.destroy_all
  end
end
