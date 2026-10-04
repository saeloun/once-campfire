class TalkQuestion < ApplicationRecord
  belongs_to :talk_slot
  belongs_to :message
  has_many :talk_votes, dependent: :destroy

  validates :body, length: { in: 1..500 }
  validates :client_message_id, length: { in: 1..100 }

  def vote!(user)
    talk_votes.create!(user: user)
  rescue ActiveRecord::RecordNotUnique
    talk_votes.find_by!(user_id: user.id)
  end
end
