class CreateTalkPilot < ActiveRecord::Migration[8.2]
  def change
    create_table :talk_slots do |t|
      t.references :room, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :uid, null: false
      t.string :title, null: false
      t.string :speaker, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :time_zone, null: false, default: "Asia/Kolkata"
      t.string :mode, null: false, default: "chat"
      t.string :projection, null: false, default: "live"
      t.bigint :active_question_id
      t.timestamps
    end
    add_index :talk_slots, :uid, unique: true

    create_table :talk_questions do |t|
      t.references :talk_slot, null: false, foreign_key: { on_delete: :cascade }
      t.references :message, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :client_message_id, null: false
      t.text :body, null: false
      t.boolean :answered, null: false, default: false
      t.boolean :hidden, null: false, default: false
      t.timestamps
    end
    add_index :talk_questions, [ :talk_slot_id, :client_message_id ], unique: true

    create_table :talk_votes do |t|
      t.references :talk_question, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :talk_votes, [ :talk_question_id, :user_id ], unique: true

    create_table :talk_hidden_messages do |t|
      t.references :talk_slot, null: false, foreign_key: { on_delete: :cascade }
      t.references :message, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :talk_hidden_messages, [ :talk_slot_id, :message_id ], unique: true
  end
end
