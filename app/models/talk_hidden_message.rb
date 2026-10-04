class TalkHiddenMessage < ApplicationRecord
  belongs_to :talk_slot
  belongs_to :message
end
