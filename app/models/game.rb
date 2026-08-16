class Game < ApplicationRecord
  belongs_to :host, class_name: "User", inverse_of: :hosted_games
  has_secure_token :join_token

  validates :name, presence: true
  validates :join_token, presence: true, uniqueness: true
end
