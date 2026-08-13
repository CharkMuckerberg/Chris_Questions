class Game < ApplicationRecord
  has_secure_token :join_token

  validates :name, presence: true
  validates :join_token, presence: true, uniqueness: true
end
