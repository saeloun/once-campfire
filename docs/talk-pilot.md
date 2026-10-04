# Local talk-channel pilot

This is default off. `TALK_CHANNELS_ENABLED=true` enables the pilot UI and endpoints for an existing non-direct room mapped to a `TalkSlot`. It does not create conference channels or change room membership, roles, authentication, Google identity brokerage, session policy, or message-stream authorization.

Use a disposable empty local development database:

```sh
bin/rails db:prepare
TALK_CHANNELS_ENABLED=true TALK_PILOT_SYNTHETIC=true bin/rails runner script/dev/seed-talk-pilot.rb
TALK_CHANNELS_ENABLED=true bin/rails server -b 127.0.0.1
```

The seed creates two synthetic closed rooms for scope-boundary testing, reserved `.invalid` accounts, and synthetic messages. Demo accounts use the local-only password `local-pilot-demo-only`. It refuses databases containing other users. Never use the seed on production or with real conference data.

Each published schedule UID (`talk-<Talk.id>@deccanqueenonrails.com`) maps uniquely to one existing room. The pilot UID examples are synthetic. Title, speaker, start/end, and Asia/Kolkata metadata can change on rescheduling while UID and room identity persist. Importing the final schedule and creating actual channels before conference day remain separate activation decisions. No schedule import or production provisioning is implemented.

The real room composer accepts `/ask your question`. The original message is still sent to chat; its plain-text question is stored transactionally for that room's server-selected slot. The pilot transaction acquires the SQLite write lock through an update of only the slot timestamp, validates a new unsaved message, and checks an existing scoped capture before creating the real message. Invalid questions and retries therefore avoid normal message side effects; concurrent retries serialize before this check. Native SQLite contention at this first write rolls back the complete attempt and retries twice, with 50/100 ms scheduler sleeps. Exhaustion returns HTTP 503 with `Retry-After: 1`; failures after the write lock or unrelated errors are never retried. Each SQLite busy wait itself may last up to five seconds, so high-contention latency still needs measurement in the actual binary. A unique slot/client-message identifier also guards repeated capture and chat duplication. Captured text is 1–500 characters and remains the original submitted question if the ordinary chat message is later edited. Moderators can hide that capture from projection; chat edits do not silently change the question queue. A retry cannot claim another author's capture. Database constraints enforce one vote per user/question, including concurrent retries.

Existing active non-bot room members can read `/rooms/:room_id/talk`, its JSON `/snapshot`, and vote via POST `/vote`. Every request checks current membership. Stage view and POST `/moderate` additionally require an existing administrator. Cross-slot question/message IDs are rejected. The pilot has no public display token or audience-access mechanism.

The snapshot polls every two seconds, contains at most the 50 earliest unanswered questions, ten recently answered questions, plus the pinned active question, and exposes no author IDs/names/emails. Votes are batch-counted, waiting questions rank deterministically, and the active question remains first as votes/new questions arrive. A visible backlog count explains when more than 50 questions are waiting. The bounded window does not replace durable full question history in the database; full historical paging is outside this pilot. Browser reconnect replaces the snapshot without duplicate entries. Interrupted stage connections clear displayed content and show a visible stale-state warning.

The charcoal 16:9 stage view shows four recent live chat lines during the talk, then three queue entries during Q&A. The active question remains fully readable; waiting questions and chat lines have shortened previews. Content is inserted with `textContent`, including code and URLs; nothing auto-opens, links are inert, attachments and private identity fields are absent. A fixed same-app room URL is displayed. QR rendering is deliberately deferred until the native QR facility is verified; no new dependency is added.

Moderator controls choose chat/Q&A, select or advance the pinned question, mark it answered, hide questions/messages from projection, pause, blank, and resume. Hiding preserves original chat history. Pause/blank/Q&A do not stop `/ask` intake. Votes have one-vote server enforcement and subtle thank-you feedback; no volume scoring, leaderboard, or confetti. The answered badge is moderator-applied after the speaker answers. No automatic talk boundary change is implemented: the moderator switches the single track deliberately, and every room retains its own slot/questions.

Known native baseline limitation: the pinned compiler emits cleanup for the new pilot descendants, but it does not lower the existing room-membership `dependent: :delete_all` association. Native room deletion can therefore leave membership rows. This behavior is inherited from the pinned compiler and base application; the pilot does not change authentication, membership, or revocation semantics. Final schedule channel provisioning and deletion need a separate review before activation.

Before activation decide: final schedule/UID mapping and channel creation timing; existing membership and stage-display operator policy; posting notice/consent; moderator staffing and escalation; TV browser/device readability and overscan; room switch timing and stale-display policy; question retention; and whether the audience can access any stage route. Do not activate projection or expand access with this prototype.

Focused checks:

```sh
PARALLEL_WORKERS=1 bin/rails test test/controllers/talks_controller_test.rb test/models/talk_slot_test.rb test/controllers/messages_controller_test.rb
node --input-type=module --check < app/javascript/controllers/talk_pilot_controller.js
RAILS_ENV=test bin/rails assets:precompile
NODE_PATH=/tmp/campfire-dq-browser/node_modules node --test test/javascript/talk_pilot_test.cjs
```

The browser snapshot tests resolve `playwright` normally. Set `NODE_PATH` to an existing installation when it is outside the checkout; the example uses the preinstalled local browser tooling and adds no application dependency. The pinned Roundhouse/Spinel pipeline and actual Linux binary must pass separately before any release. Inverse dependent associations preserve room/message/voter deletion even when the native schema emitter omits foreign-key clauses; Rails additionally retains database cascades. The real composer creation call remains in its original flat shape for native association lowering; snapshot uses JSON text rendering rather than an unsupported dynamic JSON render helper. No compiler refusal may be disabled for this pilot.
