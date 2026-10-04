raise "Synthetic local development only" unless Rails.env.development? && ENV["TALK_CHANNELS_ENABLED"] == "true" && ENV["TALK_PILOT_SYNTHETIC"] == "true"
raise "Use an empty local database" if User.where.not(email_address: [ "pilot-admin@example.invalid", "pilot-member@example.invalid" ]).exists?

Account.find_or_create_by!(singleton_guard: 0) do |account|
  account.name = "Synthetic talk pilot"
  account.join_code = SecureRandom.hex(16)
end

admin = User.find_or_create_by!(email_address: "pilot-admin@example.invalid") do |user|
  user.name = "Synthetic moderator"
  user.role = :administrator
  user.password = "local-pilot-demo-only"
end
member = User.find_or_create_by!(email_address: "pilot-member@example.invalid") do |user|
  user.name = "Synthetic member"
  user.password = "local-pilot-demo-only"
end
Current.user = admin

%w[ one two ].each_with_index do |suffix, index|
  room = Rooms::Closed.find_or_create_by!(name: "Synthetic talk #{suffix}", creator_id: admin.id)
  room.memberships.grant_to([ admin, member ])
  talk = TalkSlot.find_or_create_by!(uid: "talk-pilot-#{suffix}@deccanqueenonrails.com") do |slot|
    slot.room = room
    slot.title = index == 0 ? "From Ruby source to a running chat" : "Keeping questions open during Q&A"
    slot.speaker = "Synthetic speaker #{index + 1}"
    slot.starts_at = Time.current + index.hours
    slot.ends_at = Time.current + (index + 1).hours
  end
  if room.messages.empty?
    room.messages.create!(body: "Welcome to the synthetic live talk channel.", client_message_id: "welcome-#{suffix}")
    talk.transaction do
      message = room.messages.create!(body: "/ask How does the executable keep the original chat behavior?", client_message_id: "question-#{suffix}")
      talk.capture_question!(message)
    end
  end
  puts "Synthetic #{suffix}: /rooms/#{room.id}; queue: /rooms/#{room.id}/talk; stage: /rooms/#{room.id}/talk/stage"
end
Current.reset
