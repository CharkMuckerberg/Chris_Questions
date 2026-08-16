require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "track a user for one execution context" do
    Current.set(user: users(:primary)) do
      assert_equal users(:primary), Current.user
    end

    assert_nil Current.user
  end
end
