# Modeling State the Fizzy Way

This is a practical companion to [The Fizzy Guide to Ruby on Rails](./fizzy_ruby_rails_guide.md), especially [Part III §9: State transitions as records](./fizzy_ruby_rails_guide.md#iii9-state-transitions-as-records).

Use it when deciding whether a piece of state belongs:

- in a column on an existing table,
- in a row in another table, or
- outside the database entirely.

## The core distinction

A **column** describes a property of a record.

A **transition record** says that something meaningful happened to a record.

Compare:

```text
players.play_mode = "local"
```

with:

```text
game_launches contains a row for game 123
```

`play_mode` classifies a player. There is normally no need to know who made the player local, exactly when it happened, or how to undo that choice independently.

A launch is an action. Someone launched the game at a particular time, and the rest of the system may need to react to it. The row is evidence that the action happened.

The shortest useful rule is:

> Use a column for a property. Use a record for an important event or relationship.

## The decision test

Ask these questions in order.

### 1. Is this just descriptive data?

If the value simply describes the object, use a column.

Examples:

- `Game#name`
- `Player#name`
- `Player#play_mode` (`local` or `remote`)
- `Question#kind` (`multiple_choice` or `free_text`)
- `Question#time_limit_seconds`

An enum is still a column. It is useful when a property has a small, known vocabulary:

```ruby
class Player < ApplicationRecord
  enum :play_mode, {
    local: "local",
    remote: "remote"
  }, validate: true
end
```

### 2. Did something happen?

If the state is the result of a domain action, consider a separate record.

Examples:

- A host launched a game.
- A host closed a question.
- A host revealed an answer.
- A host completed a game.
- A player submitted a response.

The action-oriented wording is a clue: **launched**, **closed**, **revealed**, **completed**, **submitted**.

### 3. Will anyone ask “who?”, “when?”, or “why?”

If any answer is yes, prefer a record.

A record naturally has room for:

```text
game_id
initiated_by_id
created_at
reason
```

Putting all of that on `games` tends to produce a growing collection of coupled columns:

```text
status
started_at
started_by_id
finished_at
finished_by_id
```

Separate records keep each fact together.

### 4. Does the action trigger other work?

Prefer a record when the transition drives:

- a Turbo or Action Cable broadcast,
- an activity event,
- a notification,
- a webhook,
- cache invalidation,
- a background job, or
- authorization rules.

The transition row gives that work a concrete domain object to reference.

### 5. Must it be independently reversible?

A transition record can often be undone by deleting it:

```ruby
game.completion.destroy!
```

The game is no longer complete, and there are no stale `finished_at` or `finished_by_id` columns to clear.

This does not mean every transition must be reversible. It means a record makes reversal explicit and keeps related data together.

### 6. Can it happen more than once?

Cardinality helps determine the association:

- At most one current fact: `has_one`
- A repeating history or collection: `has_many`
- A relationship between two records: a join table

Examples:

```ruby
has_one  :completion
has_many :responses
has_many :players
```

If there can be only one transition record per parent, enforce that in PostgreSQL with a unique index. Do not rely only on application code.

## A quick decision tree

```text
Does it belong in the database at all?
│
├── No → Keep it in memory, a cache, or the connection layer.
│
└── Yes
    │
    ├── Is it a simple property or classification?
    │   └── Yes → Column, possibly a string-backed enum.
    │
    └── Is it an action or relationship?
        │
        ├── Does it have an actor, timestamp, metadata, side effects,
        │   independent undo, or audit value?
        │   └── Yes → Separate record/table.
        │
        └── No → A column may be enough. Choose the simpler model.
```

## What Fizzy itself does

Fizzy uses both approaches. It does not turn every state into a table.

| State | Representation | Reason |
| --- | --- | --- |
| Draft versus published | Enum column | A simple distinction with no extra transition data |
| Closed | `Closure` record | Can carry actor and time; can be undone |
| Postponed | `Card::NotNow` record | A meaningful, reversible action |
| Assigned | `Assignment` records | A card-to-user relationship, possibly many |
| Tagged | `Tagging` records | A card-to-tag relationship, possibly many |
| Watched | `Watch` record with a boolean | The row means the user has an opinion; the boolean stores which opinion |

The `Watch` example is an important nuance. A separate record and a column can work together:

- The record represents the meaningful relationship between a user and a card.
- The boolean represents a small property of that relationship.

The rule is not “columns bad, tables good.” The rule is to give each fact the right shape.

## Applying this to the trivia app

### Clear column candidates

| Data | Suggested shape | Why |
| --- | --- | --- |
| Game name | `games.name` | Descriptive property |
| Reusable join token | `games.join_token` | Credential-like property of one game |
| Player name | `players.name` | Descriptive property |
| Local or remote player | `players.play_mode` enum | Stable classification with no useful transition history |
| Question type | `questions.kind` enum | Classification |
| Choice text | `choices.text` | Descriptive data |

### Clear record candidates

| Domain fact | Suggested record | Why |
| --- | --- | --- |
| Host starts a game | `Game::Launch` | Actor, timestamp, broadcast, authorization |
| Host finishes a game | `Game::Completion` | Actor, timestamp, final results, possible correction |
| Player joins a game | `Player` | A real participant relationship with its own identity and behavior |
| Player answers a question | `Response` | Relationship among player, round, and selected choice |
| Host closes submissions | `Round::Closure` | Actor, timestamp, blocks later submissions |
| Host reveals the answer | `Round::Reveal` | Actor, timestamp, controls what remote clients may see |
| A score is awarded or adjusted | Possibly `ScoreAward` | Use a record if rescoring, actor, reason, or audit history matters |

### State that may not belong in PostgreSQL

“This browser currently has an open WebSocket” is transient connection state. It may disappear without a clean disconnect and usually belongs in Action Cable’s connection/presence layer rather than a permanent `players.connected` column.

Persist a value only when the domain needs it after the connection is gone. For example, `last_seen_at` could be a legitimate column if the product displays it.

## Worked example: launching a game

### The tempting column design

```ruby
create_table :games do |t|
  t.string :status, null: false, default: "lobby"
  t.datetime :started_at
  t.uuid :started_by_id
end
```

This works, but one game row now contains both the game and details of a separate action. More transitions will add more groups of columns.

### The Fizzy-shaped record design

```ruby
create_table :game_launches, id: :uuid, default: -> { "uuidv7()" } do |t|
  t.references :game, type: :uuid, null: false, foreign_key: true,
    index: { unique: true }
  t.references :initiated_by, type: :uuid, null: false, foreign_key: { to_table: :users }

  t.timestamps
end
```

The unique index says a game can have at most one launch. That is a domain invariant enforced even if two requests arrive simultaneously.

The transition record can stay small:

```ruby
class Game::Launch < ApplicationRecord
  belongs_to :game, touch: true
  belongs_to :initiated_by, class_name: "User"
end
```

`touch: true` updates the parent game’s `updated_at` when the launch changes. Fizzy relies on this for cache invalidation, freshness checks, and real-time refreshes.

The parent owns the behavior:

```ruby
class Game < ApplicationRecord
  has_one :launch, dependent: :destroy

  def lobby?
    launch.blank?
  end

  def started?
    launch.present?
  end

  def start(initiated_by:)
    transaction do
      create_launch!(initiated_by: initiated_by)
      # Create an event here when the application has events.
    end
  end
end
```

The transition row is intentionally simple. Business behavior remains on `Game`, next to the data it changes. There is no `StartGameService`.

The HTTP action should also be a resource:

```ruby
resources :games do
  scope module: :games do
    resource :launch, only: :create
  end
end
```

That produces a create operation on a noun, rather than a custom verb such as:

```ruby
# Avoid
post :start, on: :member
```

## Deriving state instead of storing it twice

Once transitions are records, avoid also maintaining a `games.status` column unless performance evidence proves it is necessary.

Two sources of truth can disagree:

```text
games.status = "lobby"
game_launches contains a row
```

Instead, derive the predicates:

```ruby
def lobby?
  launch.blank?
end

def playing?
  launch.present? && completion.blank?
end

def finished?
  completion.present?
end
```

If a derived status is eventually needed for sorting or performance, add a cache deliberately and define which source is authoritative. Do not introduce duplication speculatively.

## State records are not automatically event logs

A transition record usually represents a **current fact**:

```text
A closure row exists → the card is closed.
```

Destroying that row reopens the card. If the product must remember that it was once closed and later reopened, that historical fact belongs in an event or activity log.

Keep the distinction clear:

- Transition record: what is true now
- Event record: what happened over time

Some domains combine the two through append-only event sourcing. Fizzy does not require that architecture; it uses ordinary Active Record models plus events where history matters.

## Database constraints still matter

Rails associations and validations make errors friendly. PostgreSQL constraints protect the data under concurrency and from non-Rails writes.

For transition tables, normally consider:

- `null: false` on required foreign keys,
- foreign-key constraints,
- a unique index for a `has_one` transition,
- a composite unique index for “one per parent and participant,” and
- check constraints for scalar values with strict rules.

For example, one response per player per round:

```ruby
add_index :responses, [ :round_id, :player_id ], unique: true
```

A model validation can accompany it, but it cannot replace the unique index when requests race.

## Testing the transition

Fizzy tests behavior through the model and real HTTP requests.

A model test should assert the state change:

```ruby
test "starting launches the game" do
  game = games(:friday_trivia)

  assert_changes -> { game.reload.started? }, from: false, to: true do
    assert_difference -> { Game::Launch.count }, +1 do
      game.start initiated_by: users(:host)
    end
  end
end
```

An integration test should hit the resource route and verify authorization. When one transition begins driving HTML, Turbo Stream, or JSON responses, test each supported format.

Do not mock `Game` or `Game::Launch`. They are your own inexpensive domain objects and should use the transactional test database.

## Warning signs that a column wants to become a record

Reconsider a column when you notice any of these:

- New columns appear in a cluster: `*_at`, `*_by_id`, `*_reason`.
- A controller directly flips the value and performs several side effects.
- Undo requires remembering which related columns to clear.
- Multiple requests can race to perform the transition.
- You need a dedicated authorization rule for changing it.
- Product questions begin with “Who changed…?” or “When did…?”
- Notifications or webhooks need to refer to the change.
- Tests care more about the transition than the stored value.

## Warning signs that a table may be over-modeling

A column is probably enough when:

- no actor or timestamp matters,
- no metadata belongs to the change,
- no independent undo exists,
- no other records refer to it,
- the value is simply a classification,
- the extra table would contain only a foreign key forever, and
- deriving the value through an association makes ordinary queries needlessly difficult.

“Could this someday need more data?” is not sufficient justification. Almost anything could. Add the table when the domain meaning is present, not merely imaginable.

## Changing a column into a transition record later

It is safe to begin with a column when the domain is genuinely simple. If the feature grows:

1. Create the transition table.
2. Backfill a transition row for records where the old state is active.
3. Change model predicates and scopes to use the association.
4. Change write paths to create or destroy the transition record.
5. Deploy and verify the new path.
6. Remove the old column in a later migration.

For a production system, do not combine a risky backfill and immediate column deletion without considering deployments that run old and new code concurrently.

## Review checklist

Before choosing a column, ask:

- [ ] Is this a property or classification rather than an action?
- [ ] Is there truly no useful actor, timestamp, reason, or metadata?
- [ ] Is independent undo irrelevant?
- [ ] Is an enum vocabulary small and stable enough to be useful?

Before choosing a transition record, ask:

- [ ] What domain action does the row represent?
- [ ] Is it `has_one`, `has_many`, or a join relationship?
- [ ] Which actor performed it?
- [ ] Should the parent use `touch: true`?
- [ ] Which unique index enforces its cardinality?
- [ ] Should creation and its event share a transaction?
- [ ] Can the state predicate be derived from the association?
- [ ] What does undo mean: destroy the row, create an inverse record, or forbid it?
- [ ] Should the HTTP interface be a nested REST resource?

## Practice scenarios

Decide on a column, separate record, or no database persistence before opening the answers.

1. A question is multiple-choice or free-text.
2. A host closes answer submission for a round.
3. A remote player currently has a WebSocket connected.
4. A player is participating locally or remotely.
5. A host changes an awarded score after reviewing an ambiguous answer.
6. A game has a reusable public join link.

<details>
<summary>Suggested answers</summary>

1. **Column/enum.** This is a classification of the question.
2. **Transition record.** Actor, timestamp, authorization, broadcast, and submission rules all matter.
3. **Usually no database persistence.** Connection state is transient. Persist `last_seen_at` only if the product needs historical presence information.
4. **Column/enum.** It describes how that player participates.
5. **Likely a record.** If adjustments need actor, reason, timestamp, or audit history, model an award or adjustment. A simple immutable automatic score could remain a column on the response.
6. **Column on `Game`.** The token is a property of the game. A separate invitation record is unnecessary unless invitations acquire individual recipients, expiration, acceptance, or revocation behavior.

</details>

## The sentence to remember

> A column tells you what an object is like; a transition row proves that something meaningful happened to it.

When the answer is still unclear, choose the smallest model that preserves the facts your product already cares about. Fizzy favors rich domain records, but it also favors not adding structure before the domain earns it.
