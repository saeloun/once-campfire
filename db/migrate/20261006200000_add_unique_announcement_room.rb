class AddUniqueAnnouncementRoom < ActiveRecord::Migration[8.2]
  def change
    add_index :rooms, :type, unique: true, where: "type = 'Rooms::Announcement'", name: "index_rooms_on_single_announcement"
  end
end
