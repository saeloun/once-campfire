class Rooms::Announcement < Room
  after_create_commit :backfill_memberships

  def backfill_memberships
    last_user_id = 0
    loop do
      users = User.active.without_bots.where("id > ?", last_user_id).order(:id).limit(250).to_a
      break if users.empty?
      memberships.grant_to(users)
      last_user_id = users.last.id
    end
  end

  def default_involvement
    "everything"
  end
end
