require "test_helper"

class WelcomeControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "shows the welcome screen when the signed-in user has no rooms" do
    users(:david).memberships.destroy_all

    get root_url

    assert_response :success
    assert_select ".dq-empty h1", text: "Welcome aboard"
    assert_select ".dq-empty p", text: "Choose a room from the menu to start a conversation."
  end

  test "redirects to the first created visible room the user has access to" do
    get root_url

    assert_redirected_to room_url(users(:david).rooms.original)
  end

  test "redirects to the last room visited, if we have one" do
    cookies[:last_room] = rooms(:watercooler).id

    get root_url

    assert_redirected_to room_url(rooms(:watercooler))
  end
end
