class User < ApplicationRecord
  has_many :hosted_games,
    class_name: "Game",
    foreign_key: :host_id,
    inverse_of: :host,
    dependent: :restrict_with_exception
end
