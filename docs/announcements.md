# Announcements

A separate `Rooms::Announcement` room is visible to its members. Creating it automatically joins existing active human users in batches of 250; new active human accounts join after creation. Bots, banned users and deactivated users are excluded. Backfill is idempotent through the existing unique room/user membership index. No account is reactivated and no role is granted.

Publishing and management use the existing administrator role, active status and current room membership. Speakers and ordinary members receive no publishing rights. Attendees have a read-only notice; administrators have the ordinary composer. All replies and reactions are disabled, including arbitrary-text boosts. HTTP, bot, model, webhook and typing-action policies enforce this on the server. Webhooks return before requests, replies or attachment extraction; global attachment upload endpoints and ordinary rooms keep their existing behavior.

Open/Closed namespace conversion cannot reach Announcements or direct rooms. The model also prevents conversion to or from Announcements. Message actions remain safe for shared caches: reaction/reply decisions depend only on room type, while the edit link uses a per-request publisher body class computed once from the same active administrator/membership policy outside cached fragments. Controllers enforce its policy independently of CSS. No session, SSO, authentication or membership-revocation mechanism is changed.

## Activation gates

This source does not create a production channel. Before activation, complete five expert reviews, focused Rails tests, desktop/mobile cache and permission checks, and actual Roundhouse/Spinel Linux binary tests. Verify ordinary room writes and missing-room responses still work. Test administrator publishing, attendee/bot denials with zero message/blob/job/broadcast side effects, human join/backfill and concurrent singleton creation. Verify existing session invalidation behavior without altering it.

The partial unique index `index_rooms_on_single_announcement` permits exactly one Announcements room. Rails installs it through the migration. Existing native databases do not run Rails migrations automatically: inspect and install/verify the compatible index explicitly as part of an approved activation procedure before creating the room. Do not run creation against a native database missing this index.

Retain a verified Announcements-aware rollback artifact before production creation. The previous binary does not recognize the new STI type or enforce its posting policy. A blind rollback to the old artifact is unsafe once an Announcements row exists. A complete preactivation database restore loses subsequent messages and is not a substitute for an Announcements-aware rollback binary. Confirm backup and rollback behavior separately with the owner before cutover.

Room creation/settings are accessible through Announcements settings for an existing active administrator. Creation is idempotent and preserves the established room. This feature does not grant organizer privileges or infer them from conference speaker status.

## Focused source checks

```sh
RAILS_ENV=test mise exec ruby@3.4.10 -- bin/rails db:prepare
PARALLEL_WORKERS=1 mise exec ruby@3.4.10 -- bin/rails test test/models/announcement_test.rb test/controllers/announcements_test.rb test/channels/announcement_typing_test.rb test/controllers/messages_controller_test.rb test/controllers/messages/by_bots_controller_test.rb test/controllers/messages/boosts_controller_test.rb test/controllers/messages/boosts/by_bots_controller_test.rb test/models/room_test.rb test/controllers/rooms_controller_test.rb test/models/user_test.rb test/channels/room_messages_channel_test.rb test/controllers/sessions_controller_test.rb
RAILS_ENV=test mise exec ruby@3.4.10 -- bin/rails assets:precompile
```

The concurrent creation test uses two independently signed-in synthetic fixture administrators and actual concurrent HTTP controller requests against the isolated Rails test database. It verifies one room and duplicate-free memberships. This is source/Rails evidence; it does not establish native runtime or browser behavior. Those gates remain required before activation.
