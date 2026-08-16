require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "owns hosted games" do
    user = users(:primary)

    assert_includes user.hosted_games, games(:one)
    assert_not_includes user.hosted_games, games(:two)
  end
end
