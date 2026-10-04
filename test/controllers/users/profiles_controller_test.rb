require "test_helper"

class Users::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show" do
    get user_profile_url

    assert_response :success
  end

  test "update" do
    put user_profile_url, params: { user: { name: "John Doe", bio: "Acrobat" } }

    assert_redirected_to user_profile_url
    assert_equal "John Doe", users(:david).reload.name
    assert_equal "Acrobat", users(:david).bio
    assert_equal "david@37signals.com", users(:david).email_address
  end

  test "DQOR owns email and credentials while chat profile details remain editable" do
    previous = ENV["GOOGLE_LOGIN_ENABLED"]
    ENV["GOOGLE_LOGIN_ENABLED"] = "true"
    original_password = users(:david).password_digest

    put user_profile_url, params: { user: { name: "John Doe", bio: "Acrobat", email_address: "unverified@example.com", password: "another-password" } }

    assert_equal "John Doe", users(:david).reload.name
    assert_equal "Acrobat", users(:david).bio
    assert_equal "david@37signals.com", users(:david).email_address
    assert_equal original_password, users(:david).password_digest
    get user_profile_url
    assert_select "input[type='email']", count: 0
    assert_select "input[type='password']", count: 0
    assert_select "a[href='https://deccanqueenonrails.com/account']", count: 1
  ensure
    previous ? ENV["GOOGLE_LOGIN_ENABLED"] = previous : ENV.delete("GOOGLE_LOGIN_ENABLED")
  end

  test "updates are limited to the current user" do
    put user_profile_url(users(:jason)), params: { user: { name: "John Doe" } }

    assert_equal "Jason", users(:jason).reload.name
  end
end
