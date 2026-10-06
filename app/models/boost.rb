class Boost < ApplicationRecord
  belongs_to :message, touch: true
  belongs_to :booster, class_name: "User", default: -> { Current.user }

  validate :no_announcements_reactions

  scope :ordered, -> { order(:created_at) }
  private
    def no_announcements_reactions
      errors.add :message, "announcements do not accept reactions" if message&.room&.announcement?
    end
end
