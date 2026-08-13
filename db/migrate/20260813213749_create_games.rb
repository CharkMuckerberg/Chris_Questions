class CreateGames < ActiveRecord::Migration[8.1]
  def change
    create_table :games, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.string :join_token, null: false

      t.timestamps
    end

    add_index :games, :join_token, unique: true
  end
end
