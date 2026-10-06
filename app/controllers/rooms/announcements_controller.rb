class Rooms::AnnouncementsController < RoomsController
  before_action :require_active_administrator
  before_action :set_room, only: %i[ edit update ]

  def new
    @room = Rooms::Announcement.first || Rooms::Announcement.new(name: "Announcements")
  end

  def create
    if room = Rooms::Announcement.first
      Rooms::Announcement.backfill_memberships(room)
    else
      room = Rooms::Announcement.create!(room_params)
    end
    broadcast_prepend_to :rooms, target: :shared_rooms, partial: "users/sidebars/rooms/shared", locals: { room: room }
    redirect_to room_url(room)
  rescue ActiveRecord::RecordNotUnique
    room = Rooms::Announcement.first
    raise ActiveRecord::RecordNotFound unless room
    Rooms::Announcement.backfill_memberships(room)
    redirect_to room_url(room)
  end

  def edit
  end

  def update
    @room.update!(room_params)
    broadcast_replace_to :rooms, target: [ @room, :list ], partial: "users/sidebars/rooms/shared", locals: { room: @room }
    redirect_to room_url(@room)
  end

  private
    def require_active_administrator
      head :forbidden unless Current.user.active? && Current.user.administrator?
    end

    def room_scope
      Current.user.rooms.where(type: "Rooms::Announcement")
    end
end
