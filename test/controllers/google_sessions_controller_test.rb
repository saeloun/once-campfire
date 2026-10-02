require "test_helper"

class GoogleSessionsControllerTest < ActionDispatch::IntegrationTest
  LOGIN_CODE = "a" * 43
  ISSUER_URL = "https://deccanqueenonrails.com/chat/login"

  setup do
    @environment = %w[GOOGLE_LOGIN_ENABLED GOOGLE_LOGIN_ISSUER_URL CAMPFIRE_ADMIN_EMAILS CAMPFIRE_SPEAKER_EMAILS CAMPFIRE_SPEAKER_ROOM_ID].to_h { |key| [ key, ENV[key] ] }
    ENV["GOOGLE_LOGIN_ENABLED"] = "true"
    ENV.delete("GOOGLE_LOGIN_ISSUER_URL")
    ENV.delete("CAMPFIRE_ADMIN_EMAILS")
    ENV.delete("CAMPFIRE_SPEAKER_EMAILS")
    ENV.delete("CAMPFIRE_SPEAKER_ROOM_ID")
  end

  teardown do
    @environment.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "disabled login hides both buttons and rejects endpoints" do
    ENV["GOOGLE_LOGIN_ENABLED"] = "false"
    get new_session_url
    assert_select "form[action='#{google_session_path}']", count: 0
    get join_url(accounts(:signal).join_code)
    assert_select "form[action='#{google_session_path}']", count: 0
    post google_session_url
    assert_response :not_found
    get google_session_callback_url
    assert_response :not_found
  end

  test "buttons submit outside Turbo and invite carries join code" do
    get new_session_url
    assert_select "form[action='#{google_session_path}'][method='post'][data-turbo='false']"
    get join_url(accounts(:signal).join_code)
    assert_select "form[action='#{google_session_path}'][data-turbo='false'] input[name='join_code'][value='#{accounts(:signal).join_code}']"
  end

  test "beginning login stores signed httponly state before fixed issuer redirect" do
    state = begin_login
    assert_match(/\A[A-Za-z0-9]{32}\z/, state)
    assert_equal state, parsed_cookies.signed[:google_login_state]
    assert_includes response.headers["set-cookie"].to_s, "httponly"
    assert_redirected_to "#{ISSUER_URL}?state=#{state}"
  end

  test "invalid invite cannot begin login" do
    post google_session_url, params: { join_code: "invalid" }
    assert_response :not_found
    assert_nil parsed_cookies.signed[:google_login_state]
  end

  test "beginning login requires CSRF protection" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    assert_raises(ActionController::InvalidAuthenticityToken) { post google_session_url }
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "production ignores issuer overrides and browser supplied hosts" do
    Rails.env.stubs(:production?).returns(true)
    ENV["GOOGLE_LOGIN_ISSUER_URL"] = "https://attacker.example/chat/login"
    post google_session_url, params: { issuer_url: "https://attacker.example", return_to: "https://attacker.example" }
    assert_equal URI.parse(ISSUER_URL).host, URI.parse(response.location).host
  end

  test "existing human signs in case insensitively without changing role" do
    state = begin_login
    redemption = redeem_identity(state, email: "JZ@37SIGNALS.COM")
    assert_difference -> { Session.count }, 1 do
      callback(state, email: users(:david).email_address)
    end
    assert_redirected_to root_url
    assert_equal users(:jz), authenticated_user
    assert users(:jz).reload.member?
    assert_requested redemption, times: 1
  end

  test "signed state is consumed before redemption and cannot be replayed" do
    state = begin_login
    redemption = redeem_identity(state)
    callback(state)
    assert_redirected_to root_url
    assert_no_difference -> { Session.count } do
      callback(state)
    end
    assert_redirected_to new_session_url
    assert_requested redemption, times: 1
  end

  test "Google login returns to the requested private dashboard" do
    get runtime_url
    assert_redirected_to new_session_url
    state = begin_login
    redeem_identity(state)
    callback(state)

    assert_redirected_to runtime_url
  end

  test "wrong missing and unsigned state never reaches redemption" do
    state = begin_login
    redemption = redeem_identity(state)
    callback("wrong")
    assert_redirected_to new_session_url
    callback(state)
    assert_redirected_to new_session_url
    cookies[:google_login_state] = state
    callback(state)
    assert_redirected_to new_session_url
    assert_not_requested redemption
    assert_nil authenticated_user
  end

  test "malformed grant never reaches redemption" do
    state = begin_login
    get google_session_callback_url, params: { state: state, login_code: "invalid" }
    assert_redirected_to new_session_url
    assert_nil authenticated_user
  end

  test "new verified identity requires invitation and never creates an account from browser email" do
    state = begin_login
    redeem_identity(state, email: "new@example.com")
    assert_no_difference -> { User.count } do
      callback(state, email: "attacker@example.com", join_code: accounts(:signal).join_code)
    end
    assert_redirected_to new_session_url
    assert_equal "Use the conference invite link to create your chat account.", flash[:alert]
  end

  test "valid stored invite creates Google only member with open room memberships" do
    state = begin_login(join_code: accounts(:signal).join_code)
    redeem_identity(state, email: "new@example.com", name: "New Member")
    assert_difference -> { User.count }, 1 do
      callback(state)
    end
    user = authenticated_user
    assert_equal "new@example.com", user.email_address
    assert_equal "New Member", user.name
    assert_nil user.password_digest
    assert user.member?
    assert_equal Rooms::Open.all, user.rooms
  end

  test "rotating join code invalidates a pending new member login" do
    state = begin_login(join_code: accounts(:signal).join_code)
    accounts(:signal).reset_join_code
    redeem_identity(state, email: "new@example.com")
    assert_no_difference -> { User.count } do
      callback(state)
    end
    assert_redirected_to new_session_url
  end

  test "banned deactivated and bot accounts cannot sign in" do
    [ :banned, :deactivated, :bot ].each do |restriction|
      user = users(:jz)
      user.update!(status: :active, role: :member)
      user.update!(restriction == :bot ? { role: :bot } : { status: restriction })
      state = begin_login
      redeem_identity(state, email: user.email_address)
      assert_no_difference -> { Session.count } do
        callback(state)
      end
      assert_redirected_to new_session_url
    end
  end

  test "unverified issuer identity is rejected" do
    state = begin_login
    redeem_identity(state, verified: false)
    callback(state)
    assert_redirected_to new_session_url
    assert_nil authenticated_user
  end

  test "redemption timeout is rejected and nonce cannot be retried" do
    state = begin_login
    redemption = stub_request(:post, "#{ISSUER_URL}/redeem").to_timeout
    callback(state)
    assert_redirected_to new_session_url
    callback(state)
    assert_requested redemption, times: 1
  end

  test "expired signed state is rejected before redemption" do
    state = begin_login
    redemption = redeem_identity(state)
    travel 11.minutes do
      callback(state)
    end
    assert_redirected_to new_session_url
    assert_not_requested redemption
  end

  test "malformed issuer response is rejected without authenticating" do
    state = begin_login
    stub_request(:post, "#{ISSUER_URL}/redeem").to_return(status: 200, body: "invalid json")
    callback(state)
    assert_redirected_to new_session_url
    assert_nil authenticated_user
  end

  test "explicit administrator emails promote only verified Google identities" do
    ENV["CAMPFIRE_ADMIN_EMAILS"] = " JZ@37SIGNALS.COM "
    post session_url, params: { email_address: users(:jz).email_address, password: "secret123456" }
    assert users(:jz).reload.member?
    delete session_url
    state = begin_login
    redeem_identity(state, email: users(:jz).email_address)
    callback(state)
    assert users(:jz).reload.administrator?
  end

  test "speaker lounge access is granted only after verified allowlisted login" do
    room = Rooms::Closed.create!(name: "Speaker lounge", creator: users(:david))
    ENV["CAMPFIRE_SPEAKER_ROOM_ID"] = room.id.to_s
    ENV["CAMPFIRE_SPEAKER_EMAILS"] = " JZ@37SIGNALS.COM "
    ENV["CAMPFIRE_ADMIN_EMAILS"] = "organizer@example.com"
    post session_url, params: { email_address: users(:jz).email_address, password: "secret123456" }
    assert_not users(:jz).rooms.include?(room)
    delete session_url

    state = begin_login
    redeem_identity(state, email: users(:jz).email_address)
    callback(state)
    assert users(:jz).rooms.include?(room)
    assert users(:jz).reload.member?

    state = begin_login
    redeem_identity(state, email: users(:kevin).email_address)
    callback(state)
    assert_not users(:kevin).rooms.include?(room)
    assert users(:kevin).reload.member?
  end

  test "speaker room configuration cannot add membership to an open room" do
    room = Rooms::Open.create!(name: "Another room", creator: users(:david))
    users(:jz).memberships.where(room: room).delete_all
    ENV["CAMPFIRE_SPEAKER_ROOM_ID"] = room.id.to_s
    ENV["CAMPFIRE_SPEAKER_EMAILS"] = users(:jz).email_address
    state = begin_login
    redeem_identity(state, email: users(:jz).email_address)
    callback(state)
    assert_not users(:jz).rooms.include?(room)
  end

  private
    def begin_login(join_code: nil)
      post google_session_url, params: { join_code: join_code }.compact
      assert_response :see_other
      URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("state")
    end

    def redeem_identity(state, email: users(:david).email_address, name: "Verified Person", verified: true)
      stub_request(:post, "#{ISSUER_URL}/redeem")
        .with(body: { login_code: LOGIN_CODE, state: state })
        .to_return(status: 200, body: { verified: verified, email: email, name: name }.to_json, headers: { "Content-Type" => "application/json" })
    end

    def callback(state, **params)
      get google_session_callback_url, params: { state: state, login_code: LOGIN_CODE }.merge(params)
    end

    def authenticated_user
      Session.find_by(token: parsed_cookies.signed[:session_token])&.user
    end
end
