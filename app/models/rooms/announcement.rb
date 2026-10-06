class Rooms::Announcement < Room
  after_create_commit :backfill_memberships

  def self.backfill_memberships(room)
    raise ActiveRecord::RecordNotFound unless room
    raise ActiveRecord::RecordNotFound unless room.announcement?

    last_user_id = 0
    loop do
      users = User.active.without_bots.where("id > ?", last_user_id).order(:id).limit(250).to_a
      break if users.empty?
      room.memberships.grant_to(users)
      last_user_id = users.last.id
    end
  end

  def backfill_memberships
    Rooms::Announcement.backfill_memberships(self)
  end

  def default_involvement
    "everything"
  end
end
