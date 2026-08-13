require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "shows the home page" do
    get root_url

    assert_response :success
    assert_select "h1", "Chris Questions"
  end
end
