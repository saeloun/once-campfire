class TalkVote < ApplicationRecord
  belongs_to :talk_question
  belongs_to :user
end
