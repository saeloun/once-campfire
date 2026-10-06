require "test_helper"
require "minitest/mock"

class AnnouncementTest < ActiveSupport::TestCase
  setup do
    Current.reset
    @room = Rooms::Announcement.create!(name: "Synthetic Announcements", creator: users(:david))
  end

  teardown { Current.reset }

  test "active humans join and duplicate backfills preserve existing membership settings" do
    assert_equal User.active.without_bots.pluck(:id).sort, @room.users.pluck(:id).sort
    membership = @room.memberships.find_by!(user: users(:jz))
    membership.update!(involvement: "mentions")
    2.times { @room.backfill_memberships }
    assert_equal User.active.without_bots.count, @room.memberships.count
    assert_equal "mentions", membership.reload.involvement
    assert_not @room.users.include?(users(:bender))
  end

  test "backfill accepts an exact concurrent membership without replacing its preferences" do
    user = users(:jz)
    @room.memberships.find_by!(user: user).destroy!
    grant = @room.memberships.method(:grant_to)
    raced = false
    competing_grant = lambda do |people|
      if people == [ user ] && !raced
        raced = true
        @room.memberships.create!(user: user, involvement: "mentions")
        raise ActiveRecord::RecordNotUnique, "synthetic competing membership"
      else
        grant.call(people)
      end
    end

    @room.memberships.stub(:grant_to, competing_grant) { @room.backfill_memberships }

    assert raced
    assert_equal 1, @room.memberships.where(user: user).count
    assert_equal "mentions", @room.memberships.find_by!(user: user).involvement
    assert_equal User.active.without_bots.count, @room.memberships.count
  end

  test "membership collisions without the exact room and user are not swallowed" do
    user = users(:jz)
    @room.memberships.find_by!(user: user).destroy!
    assert Membership.exists?(room_id: rooms(:designers).id, user_id: user.id)
    assert @room.memberships.exists?(user_id: users(:david).id)
    error = ActiveRecord::RecordNotUnique.new("synthetic unrelated unique failure")

    @room.memberships.stub(:grant_to, ->(_people) { raise error }) do
      raised = assert_raises(ActiveRecord::RecordNotUnique) do
        Rooms::Announcement.grant_membership_to(@room, user)
      end
      assert_same error, raised
    end

    assert_not @room.memberships.exists?(user_id: user.id)
  end

  test "new human signup accepts an exact concurrent announcement membership" do
    insert = Membership.method(:insert_all)
    raced = false
    competing_insert = lambda do |attributes, **options|
      if attributes.size == 1 && attributes.first[:room_id] == @room.id
        raced = true
        Membership.create!(attributes.first.merge(involvement: "mentions"))
        raise ActiveRecord::RecordNotUnique, "synthetic signup membership collision"
      else
        insert.call(attributes, **options)
      end
    end
    person = nil

    Membership.stub(:insert_all, competing_insert) do
      person = User.create!(name: "Synthetic Concurrent Person", email_address: "concurrent-person@announcement.invalid", password: "synthetic-secret")
    end

    assert raced
    assert person.active?
    assert person.member?
    assert_equal 1, @room.memberships.where(user: person).count
    assert_equal "mentions", @room.memberships.find_by!(user: person).involvement
    assert person.rooms.exists?(id: rooms(:pets).id)
    assert_not person.rooms.exists?(id: rooms(:watercooler).id)
  end

  test "membership backfill handles more than one bounded batch without duplicates" do
    users = 260.times.map do |index|
      { name: "Synthetic batch #{index}", email_address: "batch-#{index}@announcement.invalid", role: 0, status: 0, password_digest: "" }
    end
    User.insert_all(users)
    2.times { @room.backfill_memberships }
    assert_equal User.active.without_bots.count, @room.memberships.count
    assert_equal 0, @room.memberships.group(:user_id).having("count(*) > 1").count.size
    assert_equal 260, @room.users.where("email_address like ?", "%@announcement.invalid").count
  end

  test "new active humans join but bots inactive and banned accounts do not" do
    person = User.create!(name: "Synthetic Person", email_address: "person@announcement.invalid", password: "synthetic-secret")
    assert @room.users.include?(person)
    %w[ deactivated banned ].each do |status|
      user = User.create!(name: "Synthetic #{status}", email_address: "#{status}@announcement.invalid", status: status)
      assert_not @room.users.include?(user)
    end
    bot = User.create_bot!(name: "Synthetic Bot", role: :administrator)
    assert bot.bot?
    assert_not @room.users.include?(bot)
  end

  test "backfill skips inactive humans without reactivating them" do
    @room.memberships.find_by!(user: users(:kevin)).destroy!
    users(:kevin).update!(status: :deactivated)
    @room.backfill_memberships
    assert_not @room.users.include?(users(:kevin))
    assert users(:kevin).reload.deactivated?
    assert users(:kevin).member?
  end

  test "publishing requires active existing administrator and current membership" do
    assert @room.postable_by?(users(:david))
    assert @room.postable_by?(users(:jason))
    assert_not @room.postable_by?(users(:jz))
    assert_not @room.postable_by?(users(:bender))
    assert_not @room.postable_by?(nil)
    users(:david).update!(status: :deactivated)
    assert_not @room.postable_by?(users(:david))
    @room.memberships.find_by!(user: users(:jason)).destroy!
    assert_not @room.postable_by?(users(:jason))
    assert rooms(:watercooler).postable_by?(users(:jz))
  end

  test "model creation rejects members and bots without message rich text or attachment side effects" do
    [ users(:jz), users(:bender) ].each do |writer|
      Current.user = writer
      assert_no_difference [ -> { Message.count }, -> { ActionText::RichText.count }, -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ] do
        assert_raises(ActiveRecord::RecordInvalid) { @room.messages.create!(body: "Denied synthetic notice", creator: writer) }
      end
    end
  end

  test "in process attachments are rejected before blob persistence and processing" do
    Current.user = users(:jz)
    Message.any_instance.expects(:process_attachment).never
    assert_no_difference [ -> { Message.count }, -> { ActionText::RichText.count }, -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        @room.messages.create_with_attachment!(creator: users(:jz), body: "Denied attachment",
          attachment: { io: StringIO.new("synthetic denied payload"), filename: "denied.txt", content_type: "text/plain" })
      end
    end
  end

  test "model creation cannot disguise a nonadmin creator with administrator current context" do
    Current.user = users(:david)
    assert_raises(ActiveRecord::RecordInvalid) { @room.messages.create!(body: "Denied creator", creator: users(:jz)) }
  end

  test "model updates by members cannot alter historical administrator messages" do
    message = @room.messages.create!(body: "Original synthetic notice", creator: users(:david))
    Current.user = users(:jz)
    assert_raises(ActiveRecord::RecordInvalid) { message.update!(body: "Denied model edit") }
    assert_equal "Original synthetic notice", message.reload.plain_text_body
  end

  test "all reactions are rejected even from administrators" do
    message = @room.messages.create!(body: "Synthetic notice", creator: users(:david))
    assert_raises(ActiveRecord::RecordInvalid) { message.boosts.create!(content: "Free text", booster: users(:david)) }
    assert_equal 0, message.boosts.count
  end

  test "announcement type is immutable and closed history cannot be widened" do
    announcement = @room.becomes!(Rooms::Open)
    assert_not announcement.valid?
    closed = rooms(:designers).becomes!(Rooms::Announcement)
    assert_not closed.valid?
    direct = rooms(:david_and_jason).becomes!(Rooms::Announcement)
    assert_not direct.valid?
  end

  test "database singleton index prevents a second announcement room" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      Rooms::Announcement.create!(name: "Duplicate", creator: users(:david))
    end
    assert_equal 1, Rooms::Announcement.count
    index = Room.connection.indexes(:rooms).find { |entry| entry.name == "index_rooms_on_single_announcement" }
    assert index.unique
    assert_match "Rooms::Announcement", index.where
  end

  test "webhooks and webhook jobs return before network requests or attachment extraction" do
    message = @room.messages.create!(body: "Synthetic notice", creator: users(:david))
    hook = users(:bender).create_webhook!(url: "https://announcement.invalid/hook")
    hook.expects(:post).never
    hook.expects(:extract_attachment_from).never
    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_nil hook.deliver(message)
    end
    assert_no_enqueued_jobs only: Bot::WebhookJob do
      users(:bender).deliver_webhook_later(message)
    end
  end
end
