require "test_helper"

class GameTest < ActiveSupport::TestCase
  test "starts in the lobby with a join token" do
    game = Game.new(name: "First Game")

    assert game.valid?
    assert game.join_token.present?
  end

  test "requires a name" do
    game = Game.new

    assert_not game.valid?
    assert_includes game.errors[:name], "can't be blank"
  end

  test "generates different join tokens despite same name" do
    first_game = Game.new(name: "First Game")
    second_game = Game.new(name: "First Game")

    assert_equal first_game.name, second_game.name
    assert_not_equal first_game.join_token, second_game.join_token
  end

end
