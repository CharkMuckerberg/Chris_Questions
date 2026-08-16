class AddHostToGames < ActiveRecord::Migration[8.1]
  def change
    add_reference :games, :host, null: false, type: :uuid, foreign_key: { to_table: :users }
  end
end
