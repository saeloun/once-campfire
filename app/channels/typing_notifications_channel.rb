class TypingNotificationsChannel < RoomChannel
  def start(data)
    return unless @room.postable_by?(current_user)
    broadcast_to @room, action: :start, user: current_user_attributes
  end

  def stop(data)
    return unless @room.postable_by?(current_user)
    broadcast_to @room, action: :stop, user: current_user_attributes
  end

  private
    def current_user_attributes
      current_user.slice(:id, :name)
    end
end
