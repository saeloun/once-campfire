require "test_helper"

class AnnouncementTypingTest < ActionCable::Channel::TestCase
  tests TypingNotificationsChannel

  setup do
    @room = Rooms::Announcement.create!(name: "Synthetic Announcements", creator: users(:david))
  end

  test "attendees can subscribe for presence but cannot send typing events" do
    stub_connection(current_user: users(:jz))
    subscribe room_id: @room.id
    assert subscription.confirmed?
    assert_has_stream TypingNotificationsChannel.broadcasting_for(@room)
    assert_no_broadcasts TypingNotificationsChannel.broadcasting_for(@room) do
      perform :start
      perform :stop
    end
  end

  test "administrator typing remains available and role changes are checked per action" do
    stub_connection(current_user: users(:david))
    subscribe room_id: @room.id
    assert_broadcasts TypingNotificationsChannel.broadcasting_for(@room), 1 do
      perform :start
    end
    users(:david).update!(role: :member)
    assert users(:david).reload.member?
    assert_not @room.postable_by?(users(:david))
    assert_not subscription.instance_variable_get(:@room).postable_by?(subscription.current_user)
    assert_no_broadcasts TypingNotificationsChannel.broadcasting_for(@room) do
      perform :stop
    end
  end
end
