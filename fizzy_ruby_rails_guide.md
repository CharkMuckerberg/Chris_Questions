# The Fizzy Guide to Ruby on Rails

**For experienced programmers who have never written Ruby or Rails.**

This guide teaches you two things at once: the Ruby language and the Rails framework, and the specific way this codebase — [Fizzy](https://fizzy.do/), the kanban tool by 37signals — uses them. Every code example is real code from this repository, quoted verbatim with its file path. Nothing here is invented Rails written to look like Fizzy.

By the end you should be able to open a pull request against this codebase and have it look like it belongs.

---

## Who this is for

You already know how to program. You've shipped software. You understand HTTP, relational databases, MVC, dependency injection, testing, and deployment. What you don't have is:

- Ruby syntax and idiom
- Rails' conventions and where its magic comes from
- 37signals' particular, opinionated house style

You are probably arriving from Java, C#, Go, TypeScript, Python, Rust, or PHP. Some of what you know transfers directly. Some of it will actively work against you here, and this guide will tell you which is which.

### What transfers

Your instincts about data modelling, transactions, indexing, HTTP semantics, caching, and testing are all correct and useful. Rails is a normal web framework doing normal web things. Nothing in it is conceptually novel.

### What to unlearn

Most of the architecture you have been taught to add on top of a web framework, this codebase deliberately does not have:

| You may expect | Fizzy has instead |
|---|---|
| A service layer (`CardService`, `CloseCardCommand`) | Methods on the model: `card.close` |
| Repositories / DAOs | Active Record models are the persistence layer |
| DTOs between layers | The model object goes all the way to the view |
| A policy/authorization framework (Pundit, CanCan) | Scoped associations: `Current.user.accessible_cards.find_by!(...)` |
| Presenters / view models / decorators | Helper methods and small POROs |
| An SPA front end + JSON API | Server-rendered HTML with Hotwire; JSON as a parallel interface |
| Redis for jobs/cache/websockets | The database, via Solid Queue / Solid Cache / Solid Cable |
| Interfaces and dependency injection for testability | Real objects, real database, fixtures |

None of these omissions are oversights. Each one is a decision, and this guide gives you the reasoning behind each. You are free to disagree; you are not free to quietly reintroduce them into this codebase.

---

## How to read this guide

Read Parts I and II linearly — they're the language and the framework, and everything later assumes them. From Part III onward, each chapter follows the same four-beat structure:

1. **The idea** — what problem this layer solves.
2. **How Fizzy does it** — real code, quoted, with the file path.
3. **The rule** — the house style, stated as a rule.
4. **Your turn** — build the same thing in your own app.

The "Your turn" steps assume you're building a small app alongside. Pick a domain you care about; the examples below use a hypothetical `Recipe` app so the parallels to `Card` are obvious. If you'd rather just read, skip them — the guide still works.

---

## Orientation: what Fizzy is

Fizzy is a kanban issue tracker. Teams create **cards** on **boards**, move them through **columns**, and comment on them. Cards that go untouched are automatically postponed — the "entropy" feature — so backlogs don't grow forever.

It is a Rails monolith. Some numbers, so you know what scale of codebase you're looking at:

| | |
|---|---|
| Ruby in `app/` + `lib/` | ~13,600 lines |
| Models | 174 files |
| Controllers | 115 files |
| Views | 379 files |
| Stimulus controllers | 70 files |
| Tests | 299 files |
| Ruby | 3.4.7 |
| Rails | 8.2.0.alpha (tracks `rails/rails` `main`) |

Thirteen thousand lines is small. A single person can read the entire application in a few days. That is not an accident — it is the point of every decision in this guide. Every abstraction you don't add is code someone doesn't have to read.

Fizzy runs on edge Rails, which means recent framework features (`params.expect`, `normalizes`, `generates_token_for`, `allow_browser`, `ActiveSupport::ContinuousIntegration`) are not just available, they're expected.

### The doctrine, in one paragraph

Build a Rails monolith. Keep the server in charge of state and HTML. Use Hotwire, not a JavaScript SPA. Put business behavior on domain models, not in a service layer. Keep controllers thin and RESTful, modelling every action as a resource. Use jobs for timing and external work, not as your business layer. Model important state transitions as records, not boolean columns. Extend the framework where it pays off instead of building infrastructure beside it.

---

## The spine: closing a card

Here is the entire vertical slice for one feature — clicking "Close" on a card. Seven files. Read them now without understanding them; by the end of Part III you will understand every line.

**1. The route** — `config/routes.rb`

```ruby
resources :cards do
  scope module: :cards do
    resource :closure
    ...
  end
end
```

**2. The controller** — `app/controllers/cards/closures_controller.rb`

```ruby
class Cards::ClosuresController < ApplicationController
  include CardScoped

  def create
    capture_card_location
    @card.close
    refresh_stream_if_needed

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end
end
```

**3. The controller concern that loads and authorizes the record** — `app/controllers/concerns/card_scoped.rb`

```ruby
module CardScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_card, :set_board
  end

  private
    def set_card
      @card = Current.user.accessible_cards.find_by!(number: params[:card_id])
    end
end
```

**4. The domain behavior** — `app/models/card/closeable.rb`

```ruby
def close(user: Current.user)
  unless closed?
    transaction do
      not_now&.destroy
      create_closure! user: user
      track_event :closed, creator: user
    end
  end
end
```

**5. The state transition, as a record** — `app/models/closure.rb`

```ruby
class Closure < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :card, touch: true
  belongs_to :user, optional: true
end
```

**6. The response** — `app/views/cards/closures/create.turbo_stream.erb`

```erb
<%= turbo_stream.replace("closed-cards", partial: "boards/show/closed", method: :morph, locals: { board: @card.board }) %>

<% if @source_column %>
  <%= turbo_stream.replace(dom_id(@source_column), partial: "boards/show/column", method: :morph, locals: { column: @source_column }) %>
<% end %>

<%= turbo_stream.replace([ @card, :card_container ], partial: "cards/container", method: :morph, locals: { card: @card.reload }) %>
```

**7. The test** — `test/controllers/cards/closures_controller_test.rb`

```ruby
test "create" do
  card = cards(:logo)

  assert_changes -> { card.reload.closed? }, from: false, to: true do
    post card_closure_path(card), as: :turbo_stream
    assert_card_container_rerendered(card)
  end
end
```

Note what is *not* there: no service object, no command handler, no DTO, no authorization policy, no mapper, no interface. Seven small files, each doing one job, each in the place Rails expects to find it.

---

## Table of contents

**Part I — [Ruby for people who already program](#part-i--ruby-for-people-who-already-program)**
1. [Five things that will surprise you](#1-five-things-that-will-surprise-you)
2. [Syntax speedrun](#2-syntax-speedrun)
3. [Blocks](#3-blocks)
4. [Symbols, hashes, and keyword arguments](#4-symbols-hashes-and-keyword-arguments)
5. [nil, truthiness, and the safe operators](#5-nil-truthiness-and-the-safe-operators)
6. [Modules, mixins, and concerns](#6-modules-mixins-and-concerns)
7. [Classes](#7-classes)
8. [Enumerable](#8-enumerable)
9. [Small idioms you'll see constantly](#9-small-idioms-youll-see-constantly)
10. [The mental unlock: class-level DSLs](#10-the-mental-unlock-class-level-dsls)
11. [Active Support: the Ruby that Rails adds](#11-active-support-the-ruby-that-rails-adds)
12. [Gems, Bundler, and the console](#12-gems-bundler-and-the-console)

**Part II — [Rails' mental model](#part-ii--rails-mental-model)**
1. [Convention over configuration, concretely](#1-convention-over-configuration-concretely)
2. [Zeitwerk: the file path is the constant name](#2-zeitwerk-the-file-path-is-the-constant-name)
3. [The request lifecycle](#3-the-request-lifecycle)
4. [The parts of Rails](#4-the-parts-of-rails)
5. [The command line](#5-the-command-line)
6. [What not to rebuild](#6-what-not-to-rebuild)

**Part III — [Building a Fizzy-style app](#part-iii--building-a-fizzy-style-app)**
1. [Start with the domain](#iii1-start-with-the-domain)
2. [Bootstrapping and the directory map](#iii2-bootstrapping-and-the-directory-map)
3. [Schema and data design](#iii3-schema-and-data-design)
4. [Request context: Current](#iii4-request-context-current)
5. [Multi-tenancy](#iii5-multi-tenancy)
6. [Identity, membership, authentication](#iii6-identity-membership-authentication)
7. [Rich Active Record models](#iii7-rich-active-record-models)
8. [Concerns as capability slices](#iii8-concerns-as-capability-slices)
9. [State transitions as records](#iii9-state-transitions-as-records)
10. [Events, notifications, webhooks](#iii10-events-notifications-webhooks)
11. [Routes as resources](#iii11-routes-as-resources)
12. [Thin controllers](#iii12-thin-controllers)
13. [Views and ERB](#iii13-views-and-erb)
14. [Hotwire: Turbo](#iii14-hotwire-turbo)
15. [Stimulus](#iii15-stimulus)
16. [CSS and assets](#iii16-css-and-assets)
17. [Background jobs](#iii17-background-jobs)
18. [Mailers](#iii18-mailers)
19. [JSON alongside HTML](#iii19-json-alongside-html)
20. [Search, filters, pagination, caching](#iii20-search-filters-pagination-caching)
21. [Files and rich text](#iii21-files-and-rich-text)
22. [Advanced subsystems](#iii22-advanced-subsystems)
23. [Callbacks, transactions, and side effects](#iii23-callbacks-transactions-and-side-effects)

**Part IV — [Testing](#part-iv--testing)**
**Part V — [Operations](#part-v--operations)**
**Part VI — [House style](#part-vi--house-style)**
**Part VII — [Appendices](#part-vii--appendices)**

---
# Part I — Ruby for people who already program

This is not a complete Ruby reference. It is the subset of Ruby that Fizzy actually uses, ordered so that each idea is introduced before the first Fizzy snippet that depends on it. Every example is real code from this repository.

## 1. Five things that will surprise you

**Everything is an object, including classes and `nil`.** `5.times`, `"hello".upcase`, `nil.to_a`, `Card.count` — there are no primitives. Operators are methods: `1 + 2` is `1.+(2)`.

**Methods return their last expression.** `return` exists but is rare, and using it where the last expression would do is a style smell here:

```ruby
# app/models/card/closeable.rb
def closed?
  closure.present?
end
```

No `return`. The value of `closure.present?` is the value of the method.

**Parentheses are optional.** These are the same call:

```ruby
head :forbidden
head(:forbidden)
```

Fizzy omits them for DSL-ish calls (`belongs_to :board`, `head :forbidden`, `render :show`) and keeps them where they aid reading. You'll develop a feel; when in doubt, match the surrounding code.

**`?` and `!` are legal in method names.** `?` means "this returns a boolean" — `closed?`, `published?`, `admin?`. `!` does *not* mean "dangerous". The house rule is explicit:

> We only use `!` for methods that have a correspondent counterpart without `!`. In particular, we don't use `!` to flag destructive actions.
> — `STYLE.md`

So `Card#destroy` is not `destroy!` because it's destructive; `create!` exists because `create` exists, and the bang version raises instead of returning `false`.

**Classes are open and are executed, not declared.** A class body is ordinary code that runs top to bottom. This one fact explains nearly all of Rails' apparent magic — see [§10](#10-the-mental-unlock-class-level-dsls).

## 2. Syntax speedrun

```ruby
# Local variables — no declaration keyword, snake_case
card = Card.new
old_board = account.boards.find_by(id: board_id_before_last_save)

# Constants — CamelCase or SCREAMING_SNAKE. Assigning twice warns.
PERMITTED_SCHEMES = %w[ http https ].freeze     # app/models/webhook.rb

# Instance variables — @ prefix, no declaration, nil if unset
@card = Current.user.accessible_cards.find_by!(number: params[:card_id])

# Methods
def close(user: Current.user)
  # ...
end

# Conditionals as expressions
title = if published? then "Untitled" else nil end

# Trailing (modifier) conditionals — very common for one-liners
self.title = "Untitled" if title.blank?          # app/models/card.rb
head :forbidden unless Current.user.admin?       # app/controllers/concerns/authorization.rb

# unless == if not. Used freely, but never with an else clause.
```

Array and symbol-array literals use percent syntax. Note the spaces inside the brackets — that is the house style, enforced by rubocop-rails-omakase:

```ruby
PERMITTED_SCHEMES = %w[ http https ].freeze          # ["http", "https"]
enum :role, %i[ owner admin member system ]          # [:owner, :admin, :member, :system]
before_action :set_card, only: %i[ show edit update destroy ]
```

Strings are double-quoted by default here, even without interpolation. Interpolation is `#{}`:

```ruby
# app/models/concerns/eventable.rb
board.events.create!(action: "#{eventable_prefix}_#{action}", ...)
```

## 3. Blocks

A block is a chunk of code passed to a method. This is the single most important piece of Ruby syntax to internalize, because Rails' entire DSL surface is built on it.

Two forms, semantically identical:

```ruby
cards.each { |card| puts card.title }

cards.each do |card|
  puts card.title
end
```

**The convention:** braces for single-expression blocks, `do...end` for multi-line blocks. Fizzy follows this consistently.

```ruby
# Single expression, braces — app/models/notifier.rb
recipients.sort_by(&:id)

# Multi-line, do...end — app/models/card/closeable.rb
transaction do
  not_now&.destroy
  create_closure! user: user
  track_event :closed, creator: user
end
```

A method receives a block implicitly and calls it with `yield`, or takes it explicitly with `&block`. Fizzy uses the Ruby 3.1+ **anonymous block forwarding** where the block is only passed along:

```ruby
# app/models/current.rb
def with_account(value, &)
  with(account: value, &)
end
```

The bare `&` says "take the block and forward it" without naming it.

**`&:symbol` shorthand.** `&` converts a symbol to a block that calls that method:

```ruby
card.assignees.map(&:name)          # same as: card.assignees.map { |a| a.name }
users.find_each(&:deactivate)       # app/models/identity.rb
recipients.sort_by(&:id)            # app/models/notifier.rb
```

**`it` — the implicit block parameter** (Ruby 3.4). When a block takes exactly one argument and you don't want to name it:

```ruby
# app/models/webhook.rb
normalizes :url, with: -> { it.strip }

# app/models/magic_link/code.rb
normalize_code(code)
  .then { apply_substitutions(it) }
  .then { remove_invalid_characters(it) }
```

**Lambdas** are blocks stored as objects, written `-> (args) { ... }` or `->(args) do ... end`. Rails uses them everywhere for deferred evaluation — a scope body isn't run when the class loads, it's run when the scope is called:

```ruby
# app/models/card.rb
scope :latest,                  -> { order last_active_at: :desc, id: :desc }
belongs_to :account, default: -> { board.account }
after_save   -> { board.touch }, if: :published?

# app/models/card/closeable.rb
scope :closed_by, ->(users) { closed.where(closures: { user_id: Array(users) }) }
```

Read `-> { board.account }` as "a piece of code that, when eventually run in the context of this record, evaluates `board.account`."

## 4. Symbols, hashes, and keyword arguments

**Symbols** (`:name`) are interned, immutable identifiers. Use them as names of things — method names, hash keys, option values. Use strings for data.

```ruby
track_event :closed, creator: user       # :closed is a name
card.title = "The logo isn't big enough" # a string is data
```

**Hashes** map keys to values. Modern syntax uses `key: value` for symbol keys:

```ruby
{ user_id: 1, watching: true }
```

When a hash is the last argument to a method, the braces are omitted. This is why Rails calls look like keyword syntax but are often just a trailing hash:

```ruby
has_many :reactions, -> { order(:created_at) }, as: :reactable, dependent: :delete_all
```

**Keyword arguments** are declared with a trailing colon. They can have defaults, and defaults can be arbitrary expressions evaluated at call time:

```ruby
# app/models/concerns/eventable.rb
def track_event(action, creator: Current.user, board: self.board, **particulars)
  if should_track_event?
    board.events.create!(action: "#{eventable_prefix}_#{action}", creator:, board:, eventable: self, particulars:)
  end
end
```

Three things to notice here:

- `action` is positional; `creator:` and `board:` are keywords with defaults.
- `**particulars` collects any other keywords into a hash — the `**` double-splat.
- `creator:, board:, particulars:` in the `create!` call is **hash shorthand** (Ruby 3.1+): `creator:` alone means `creator: creator`. It's punning on the local variable name.
- `self.board` is needed as the default because `board` alone would refer to the parameter being defined.

**Argument forwarding** with `...` passes everything through:

```ruby
# config/initializers/active_job.rb
def initialize(...)
  super
  @account = Current.account
end
```

## 5. nil, truthiness, and the safe operators

Only `false` and `nil` are falsy. `0`, `""`, and `[]` are all truthy. This trips up C and JavaScript programmers constantly.

**`&.` — safe navigation.** Calls the method only if the receiver isn't nil, otherwise returns nil:

```ruby
Current.user&.active?          # app/controllers/concerns/authorization.rb
closure&.user                  # app/models/card/closeable.rb
not_now&.destroy               # app/models/card/closeable.rb
```

**`||=` — assign if nil or false.** Used for defaulting and memoizing:

```ruby
# app/models/card.rb — assign a number only if one wasn't supplied
self.number ||= account.increment!(:cards_count).cards_count

# app/models/event/particulars.rb — memoize an expensive lookup
def assignees
  @assignees ||= User.where id: assignee_ids
end
```

**Assignment inside a conditional** is idiomatic here, not a bug to be linted away:

```ruby
# app/controllers/concerns/authentication.rb
def resume_session
  if session = find_session_by_cookie
    set_current_session session
  end
end
```

Read it as: "if we found a session, bind it and use it."

## 6. Modules, mixins, and concerns

A **module** is a namespace and/or a bag of methods. It cannot be instantiated.

**As a namespace**, `Card::Closeable` lives in `app/models/card/closeable.rb`. The `::` is the scope operator. Fizzy namespaces heavily — `Card::NotNow`, `Board::Publication`, `Webhook::Delivery`, `Notifier::CardEventNotifier`.

**As a mixin**, `include SomeModule` adds its instance methods to a class. Ruby has no multiple inheritance, but it has this, and it's better. Fizzy leans on it hard — 102 files across `app/` and `lib/` define a mixin.

```ruby
# app/models/card.rb — a class composed of 23 capabilities
class Card < ApplicationRecord
  include Accessible, Assignable, Attachments, Broadcastable, Closeable, Colored, Commentable,
    Entropic, Eventable, Exportable, Golden, Mentions, Multistep, Pinnable, Postponable, Promptable,
    Readable, Searchable, Stallable, Statuses, Storage::Tracked, Taggable, Triageable, Watchable
```

One `include` call, many modules, comma-separated. That single statement is the table of contents for `Card`.

**`ActiveSupport::Concern`** is Rails' extension to plain modules. It solves one problem: a mixin that needs to run *class-level* code in the including class. Plain Ruby makes this awkward; `Concern` makes it declarative:

```ruby
# app/models/card/closeable.rb — the canonical shape
module Card::Closeable
  extend ActiveSupport::Concern

  included do
    has_one :closure, dependent: :destroy

    scope :closed, -> { joins(:closure) }
    scope :open, -> { where.missing(:closure) }
  end

  def closed?
    closure.present?
  end

  private
    def some_helper
    end
end
```

Read it as three zones:

| Zone | Runs where | Use for |
|---|---|---|
| `included do ... end` | In the class body of the includer | Associations, scopes, callbacks, validations — anything that's a class-level DSL call |
| Bare `def` | Instance methods | The capability's behavior |
| `class_methods do ... end` | Class methods of the includer | Finders, factories, DSL macros |

`class_methods do` in action, defining a macro other controllers use:

```ruby
# app/controllers/concerns/authentication.rb
class_methods do
  def require_unauthenticated_access(**options)
    allow_unauthenticated_access **options
    before_action :redirect_authenticated_user, **options
  end
end
```

## 7. Classes

```ruby
# app/models/time_window_parser.rb — abridged
class TimeWindowParser
  attr_reader :now

  VALUES = HUMAN_NAMES_BY_VALUE.keys

  class << self
    def parse(string)
      new.parse(string)
    end
  end

  def initialize(now: Time.current)
    @now = now
  end

  def parse(string)
    case normalize(string)
    when "today"
      now.all_day
    when "yesterday"
      (now - 1.day).all_day
    end
  end
end
```

- `attr_reader :now` generates `def now; @now; end`. There's also `attr_writer` and `attr_accessor`.
- `initialize` is the constructor; `TimeWindowParser.new` calls it.
- `class << self ... end` opens the singleton class — everything defined inside is a class method. Fizzy prefers this over `def self.foo` when there are two or more class methods. For exactly one, `def self.foo` is fine:

```ruby
# app/models/identity.rb
def self.find_by_permissable_access_token(token, method:)
```

**Visibility.** `private` is a marker, not a block. Everything after it is private. The house style — this is unusual and you must follow it — indents the private methods one extra level:

```ruby
# STYLE.md
class SomeClass
  def some_method
    # ...
  end

  private
    def some_private_method_1
      # ...
    end

    def some_private_method_2
      # ...
    end
end
```

No blank line after `private`, and the methods under it are indented. If a module is entirely private, `private` goes at the top with a blank line after and **no** extra indentation.

**Value objects.** `Struct` and `Data` build small classes without ceremony:

```ruby
# app/models/color.rb — the entire file starts with one line
Color = Struct.new(:name, :value)

# app/models/passkey/authenticator.rb — Data is immutable
class Passkey::Authenticator < Data.define(:aaguids, :name, :icon)
```

`Struct.new` also takes a block to add methods:

```ruby
# config/initializers/uuid_primary_keys.rb
PendingUuidDefault = Struct.new(:name) do
  def apply_to(attribute_set)
    attribute_set[name] = attribute_set[name].with_user_default(-> { ActiveRecord::Type::Uuid.generate })
  end
end
```

**`self.`** disambiguates a setter from a local variable. Inside a method, `title = "x"` creates a local; `self.title = "x"` calls the setter:

```ruby
# app/models/card.rb
def set_default_title
  self.title = "Untitled" if title.blank?
end
```

Reading doesn't need `self.` — only writing does.

## 8. Enumerable

Ruby's collection protocol. Anything that defines `each` gets all of this for free — including Active Record relations.

```ruby
card.assignees.map(&:name)                        # transform
cards.select(&:closed?)                           # filter
boards.sum { |board| board.storage_bytes }        # app/models/account/storage.rb
limited_events.group_by { it.created_at.hour }    # app/models/user/day_timeline/column.rb
assignments.any? { |a| a.assignee_id == user.id } # app/models/card/assignable.rb
```

`each_with_object` threads an accumulator through:

```ruby
# app/models/concerns/storage/tracked.rb
attachments.each_with_object(Hash.new { |h, k| h[k] = [] }) do |attachment, grouped|
  # ...
end
```

`filter_map` maps and drops nils in one pass. `each_slice` batches.

**`find_each` is the one you must remember.** On an Active Record relation, `each` loads every row into memory. `find_each` batches:

```ruby
# app/models/account/import.rb
account.boards.all_access.find_each do |board|
  # ...
end
```

Use `find_each` any time the collection could be large. In a background job, that's always.

## 9. Small idioms you'll see constantly

**`tap`** — run a block on an object and return the object. For side effects mid-chain:

```ruby
# app/controllers/concerns/authentication.rb
identity.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
  set_current_session session
end
```

**`then`** (a.k.a. `yield_self`) — run a block and return the block's value. For pipelines:

```ruby
# app/models/magic_link/code.rb
normalize_code(code)
  .then { apply_substitutions(it) }
  .then { remove_invalid_characters(it) }
```

**`case`/`when`** — not just equality; `when` uses `===`, so it matches regexes, ranges, and classes. Fizzy also uses the subject-less form as a tidy multi-branch guard:

```ruby
# app/models/application_platform.rb
def bridge_name
  case
  when native? && android? then :android
  when native? && ios?     then :ios
  end
end
```

Note: this codebase does **not** use Ruby's `case/in` pattern matching anywhere. Don't introduce it without a good reason.

**Ranges**, including beginless and endless, used directly as database conditions:

```ruby
# app/models/magic_link.rb
scope :active, -> { where(expires_at: Time.current...) }    # from now, forever
# app/models/export.rb
scope :expired, -> { where(completed_at: ...24.hours.ago) } # from the dawn of time until then
```

**`rescue` inside a method body** — no `begin` needed:

```ruby
# app/models/card/assignable.rb
def assign(user)
  assignment = assignments.create assignee: user, assigner: Current.user

  if assignment.persisted?
    watch_by user
    track_event :assigned, assignee_ids: [ user.id ]
  end
rescue ActiveRecord::RecordNotUnique
  # Already assigned
end
```

**Guard clauses vs expanded conditionals.** This is a house rule with real teeth. The default is an expanded `if/else`, not an early return:

```ruby
# Bad
def todos_for_new_group
  ids = params.require(:todolist)[:todo_ids]
  return [] unless ids
  @bucket.recordings.todos.find(ids.split(","))
end

# Good
def todos_for_new_group
  if ids = params.require(:todolist)[:todo_ids]
    @bucket.recordings.todos.find(ids.split(","))
  else
    []
  end
end
```

The exception, from `STYLE.md`: a guard clause is fine when it's the very first line of the method *and* the main body is non-trivial.

You can see the preference throughout the domain code — `close` wraps its body in `unless closed?` rather than returning early:

```ruby
def close(user: Current.user)
  unless closed?
    transaction do
      # ...
    end
  end
end
```

## 10. The mental unlock: class-level DSLs

Newcomers describe Rails as "magic." Almost all of it is one Ruby fact: **a class body is executable code, and `self` inside it is the class.**

So this:

```ruby
class Card < ApplicationRecord
  belongs_to :board
  scope :latest, -> { order last_active_at: :desc, id: :desc }
  before_save :set_default_title, if: :published?
end
```

is not declarative syntax. It is three method calls on the `Card` class object, executed when the file loads. `belongs_to` is an ordinary class method inherited from `ActiveRecord::Base` that defines `board` and `board=` methods on the fly.

You can build the same thing in fifteen lines:

```ruby
class Model
  def self.scope(name, body)
    define_singleton_method(name) { body.call }
  end
end

class Recipe < Model
  scope :recent, -> { "SELECT * FROM recipes ORDER BY created_at DESC" }
end

Recipe.recent   # => "SELECT * FROM recipes ORDER BY created_at DESC"
```

`scope` is a class method that takes a name and a lambda and defines a new class method. That's the whole trick. `belongs_to`, `validates`, `has_many`, `before_action`, `enum`, `normalizes` — all the same shape, differing only in how much they generate.

Once you see class bodies as running code, three consequences follow:

1. **Order matters.** A `scope` defined after a `before_save` that references it is still fine (the lambda body is lazy), but `include`s and `belongs_to` are evaluated top to bottom, and a concern's `included do` block runs at the point of the `include`.
2. **You can compute definitions.** `enum :status, %w[ drafted published ].index_by(&:itself)` builds the enum mapping with ordinary Ruby before passing it in.
3. **There is no hidden framework layer to find.** If you don't know what `broadcasts_refreshes` does, it's a method — `bin/rails console`, then `Card.method(:broadcasts_refreshes).source_location`.

## 11. Active Support: the Ruby that Rails adds

Rails ships Active Support, a large set of extensions to Ruby's core classes. These are not optional or exotic — they are part of the language as far as this codebase is concerned.

**Time and duration:**

```ruby
1.week.ago
3.days.from_now
30.minutes
expires_in 1.year, public: true
Time.current               # timezone-aware Time.now — always use this one
now.all_day                # a Range covering the day
```

**Blankness.** `nil?` is Ruby. `blank?` and `present?` are Active Support and treat empty strings and collections as blank:

```ruby
closure.present?               # not nil
title.blank?                   # nil, "", "  ", or []
Current.account.present?
card.image.presence && url_for(card.image)   # `presence` returns self or nil
```

**`delegate`** forwards methods to an associated object, replacing a pile of one-line wrappers:

```ruby
# app/models/comment.rb
delegate :publicly_accessible?, :accessible_to?, :board, :watch_by, to: :card

# app/models/user/configurable.rb
delegate :timezone, to: :settings, allow_nil: true
```

**String inflection** — the machinery behind Rails' naming conventions:

```ruby
# app/models/concerns/eventable.rb
self.class.name.demodulize.underscore     # "Card::NotNow" -> "NotNow" -> "not_now"
```

Also `pluralize`, `singularize`, `camelize`, `classify`, `constantize`, `safe_constantize` (which returns nil instead of raising).

**`Array.wrap`** coerces nil/scalar/array to an array. **`inquiry`** turns a string into a query object:

```ruby
# app/models/event.rb
def action
  super.inquiry     # lets callers write event.action.card_closed?
end
```

**`ActiveSupport::CurrentAttributes`** — request-scoped globals, covered in depth in [Part III §4](#iii4-request-context-current).

## 12. Gems, Bundler, and the console

**Gems** are Ruby packages. `Gemfile` declares them, `Gemfile.lock` pins exact versions, `bundle install` installs them, and `bundle exec` runs a command with exactly those versions.

```ruby
# Gemfile
source "https://rubygems.org"

git_source(:bc) { |repo| "https://github.com/basecamp/#{repo}" }

gem "rails", github: "rails/rails", branch: "main"
gem "importmap-rails"
gem "propshaft"
gem "solid_queue", "~> 1.3"
gem "useragent", bc: "useragent"
```

Note `git_source(:bc)` — a custom shorthand so `bc: "useragent"` expands to a Basecamp GitHub repo. And note that `rails` itself comes from a git branch, not a released version: this app runs edge Rails deliberately.

`group :development, :test do ... end` scopes gems to environments. `require: false` means "install it, but don't load it at boot" — used for tools like `kamal` and `brakeman` that are only invoked from the command line.

**The console** is the single best tool you have for learning this codebase:

```bash
bin/rails console
```

```ruby
card = Card.first
card.closed?
card.close
Card.method(:broadcasts_refreshes).source_location   # where is this defined?
card.method(:close).source_location
Card.instance_methods(false).sort                    # what does Card itself define?
Card.ancestors                                       # what's mixed in, in what order?
```

`Card.ancestors` in particular is how you make sense of a 23-concern model: it lists every module in the lookup chain, in precedence order.

---
# Part II — Rails' mental model

## 1. Convention over configuration, concretely

Rails guesses. If you name things the way it expects, you write almost no wiring. The core mapping:

| Concept | Name | Location |
|---|---|---|
| Database table | `cards` (plural, snake_case) | — |
| Model | `Card` | `app/models/card.rb` |
| Controller | `CardsController` | `app/controllers/cards_controller.rb` |
| Views | one per action | `app/views/cards/show.html.erb` |
| Partial | `_comment.html.erb` (leading underscore) | `app/views/cards/comments/_comment.html.erb` |
| Route helper | `card_path(card)`, `cards_path` | generated by `resources :cards` |
| Test | `CardTest`, `CardsControllerTest` | `test/models/card_test.rb`, `test/controllers/cards_controller_test.rb` |
| Fixture | `cards(:logo)` | `test/fixtures/cards.yml` |

Namespaces nest the same way in every layer. `Cards::ClosuresController` lives at `app/controllers/cards/closures_controller.rb`, renders `app/views/cards/closures/create.turbo_stream.erb`, and is tested by `test/controllers/cards/closures_controller_test.rb`.

Columns become attributes automatically. There is no ORM mapping file, no annotations, no schema class. If `cards` has a `title` column, `Card#title` exists. The schema is the single source of truth, dumped to `db/schema.rb`.

## 2. Zeitwerk: the file path is the constant name

Rails autoloads code with Zeitwerk. The rule is absolute:

> `app/models/card/closeable.rb` **must** define `Card::Closeable`.

Directory separators become `::`. `snake_case` filenames become `CamelCase` constants. Acronyms follow the inflector (`api` → `Api` unless configured otherwise).

This is the number one source of confusing errors for newcomers. If you see `NameError: expected app/models/card/closeable.rb to define constant Card::Closeable`, you named the file or the module wrong. There is no import statement to fix — the fix is always the name.

There are no `require` statements in application code. Referencing `Card` loads it. In development, editing a file reloads it on the next request without restarting the server.

`lib/` is a special case here. Fizzy autoloads it, with exceptions:

```ruby
# config/application.rb
config.autoload_lib ignore: %w[ assets tasks rails_ext ]
```

`lib/rails_ext/` is ignored because those files are framework patches that self-register via `ActiveSupport.on_load` rather than being referenced by name.

## 3. The request lifecycle

Trace `POST /897362094/cards/42/closure` from socket to response:

**1. Rack + middleware.** Rails is a Rack app: a stack of middleware wrapping an `env` hash. Fizzy inserts its own tenancy middleware here, which strips the account prefix from the path and stashes the account:

```ruby
# config/initializers/tenanting/account_slug.rb
Rails.application.config.middleware.insert_after Rack::TempfileReaper, AccountSlug::Extractor
```

By the time routing runs, the path is `/cards/42/closure` and `Current.account` is set.

**2. Routing.** `config/routes.rb` maps method + path to a controller action. `resource :closure` nested in `resources :cards` maps `POST /cards/:card_id/closure` to `Cards::ClosuresController#create`.

**3. Controller.** Rails instantiates the controller, runs its `before_action` filters (authentication, authorization, record loading), then the action.

**4. Model.** The action calls domain behavior — `@card.close` — which runs a transaction, writes records, and records an `Event`.

**5. View.** With no explicit `render`, Rails renders the template matching the action and format: `app/views/cards/closures/create.turbo_stream.erb`.

**6. Response.** The rendered Turbo Stream goes back with `Content-Type: text/vnd.turbo-stream.html`, and the browser applies the DOM updates in place.

The same action, requested with `Accept: application/json`, takes the `format.json { head :no_content }` branch instead. One action, two representations.

## 4. The parts of Rails

| Component | What it does | Where you'll meet it in Fizzy |
|---|---|---|
| **Active Record** | ORM: models, associations, validations, callbacks, migrations | Everything in `app/models` |
| **Action Pack** | Routing + controllers (`ActionDispatch`, `ActionController`) | `config/routes.rb`, `app/controllers` |
| **Action View** | ERB templates, partials, helpers, form builders | `app/views`, `app/helpers` |
| **Active Job** | Background job abstraction | `app/jobs`, backed by Solid Queue |
| **Action Mailer** | Email | `app/mailers` |
| **Action Cable** | WebSockets | `app/channels` — only a connection class; Turbo does the rest |
| **Active Storage** | File attachments | `has_one_attached :image` on `Card` |
| **Action Text** | Rich text fields | `has_rich_text :description` on `Card` |
| **Active Support** | Core extensions, `Current`, caching, concerns | Everywhere |

The lesson to draw: Rails is not a minimal core with an ecosystem bolted on. Jobs, email, file uploads, websockets, and rich text are all in the box, and reaching outside the box needs a justification.

## 5. The command line

```bash
bin/setup              # install dependencies, create and seed the database
bin/dev                # run the development server on port 3006
bin/rails console      # interactive REPL with the app loaded
bin/rails test         # run unit/integration tests
bin/rails test test/models/card_test.rb        # one file
bin/rails test test/models/card_test.rb:42     # one test, by line
bin/rails test:system  # browser tests
bin/rails db:migrate   # apply pending migrations
bin/rails routes       # print every route (pipe to grep)
bin/rails generate migration AddColorToColumns color:string
bin/ci                 # the full pipeline: style, security, tests
```

Development runs at `http://fizzy.localhost:3006`. Sign in as `david@example.com`; the verification code appears in the browser console.

The `bin/` scripts are *binstubs* — thin wrappers that guarantee the right gem versions. Always use `bin/rails`, never bare `rails`.

## 6. What not to rebuild

If you're arriving from a Java, C#, or Go codebase, you have muscle memory for layers that Rails deliberately collapses. Here's the argument for each omission, so you can decide whether you believe it before you're asked to follow it.

**No service layer.** In a framework where models are anemic, business logic has nowhere to go but a service. Active Record models aren't anemic — they're persistence *and* behavior. `card.close` reads better than `CardService.new(card).close`, and it puts the logic where the next person will look for it. The style guide is explicit:

> In general, we favor a vanilla Rails approach with thin controllers directly invoking a rich domain model. We don't use services or other artifacts to connect the two.
> — `STYLE.md`

Note the escape hatch in the same document: "When justified, it is fine to use services or form objects, but don't treat those as special artifacts." `Signup` (`app/models/signup.rb`) is exactly that — a plain object that isn't backed by a table because signing up spans two.

**No repositories.** Active Record relations *are* the query layer, and they compose: `Current.user.accessible_cards.active.latest.preloaded`. A repository would wrap that in a less capable API.

**No DTOs.** The model instance goes to the view. The view is server-rendered and trusted. There is no serialization boundary to defend.

**No policy objects.** Authorization happens by scoping: you can only load what you're allowed to load. See [Part III §12](#iii12-thin-controllers).

**No SPA.** Turbo gives you SPA-feeling navigation and partial page updates while the server keeps rendering HTML. You avoid maintaining a second application, a second router, a second set of models, and a serialization layer between them.

**No Redis.** Solid Queue, Solid Cache, and Solid Cable put jobs, cache, and websocket pubsub in the database. One less thing to operate, back up, and monitor.

The through-line: every layer you add is a layer someone reads, tests, and debugs forever. Add one when the pain is real and present, not when the diagram looks tidier.

---
# Part III — Building a Fizzy-style app

## III.1 Start with the domain

**The idea.** Before you scaffold anything, name the nouns, the boundaries, and the state transitions. Rails makes it cheap to generate controllers and views; it does not make it cheap to un-model your domain six months later.

Answer five questions:

1. What is the **tenant boundary** — the thing that owns all the data?
2. Is there a **global identity** that spans tenants?
3. What is the **main aggregate** users spend their day inside?
4. What are the important **state transitions**?
5. Which actions deserve **history, notification, or integration hooks**?

**How Fizzy answers them.**

| Question | Fizzy's answer |
|---|---|
| Tenant | `Account` — every table carries `account_id` |
| Global identity | `Identity` (an email address) — can be a `User` in many accounts |
| Membership | `User` — belongs to one `Account` and one `Identity`, holds a role |
| Main aggregate | `Card` — inside a `Board`, optionally in a `Column` |
| Transitions | closure, postponement, triage, assignment, publication, access |
| Auditable actions | everything, via `Event` |

The whole domain fits in a paragraph:

> An **Account** has **Users**, each linked to a global **Identity**. Users work on **Boards**, which contain **Columns** and **Cards**. A Card moves from triage into a Column, and can be closed, postponed ("not now"), assigned, tagged, pinned, watched, and commented on. Every significant action creates an **Event**, which drives the activity feed, notifications, and webhooks.

**The rule.** Model nouns first. Then model transitions. Then expose them through Rails. If you can't write your domain as one readable paragraph, you don't understand it well enough to build it yet.

**Your turn.** Write your domain paragraph. Name your tenant, your identity boundary, your main aggregate, and at least three state transitions. Keep it — the next several chapters build directly on it.

---

## III.2 Bootstrapping and the directory map

**The idea.** Start from Rails' defaults and stay close to them. Every directory you invent is a directory the next person has to learn.

**Creating the app.** A Fizzy-shaped starting point:

```bash
rails new myapp --database=sqlite3 --javascript=importmap --css=propshaft --skip-jbuilder=false
cd myapp
bin/rails generate stimulus:install
```

You want: server-rendered HTML, importmap (no Node build step), Propshaft (no asset compilation pipeline), Turbo and Stimulus from day one, Minitest, and Solid Queue/Cache/Cable. Rails 8 gives you nearly all of that by default.

SQLite is a legitimate production database for this shape of app, and it's what Fizzy defaults to. MySQL is supported when operational needs justify it.

**The directory map.** Where things go:

```
app/
  assets/stylesheets/   plain CSS, one file per UI concern
  channels/             Action Cable — usually just the connection class
  controllers/          thin HTTP adapters, mirroring routes
    concerns/           reusable request shapes (authentication, record loading)
  helpers/              small presentational methods for views
  javascript/
    controllers/        Stimulus controllers
    helpers/            shared JS functions
    initializers/       code that runs once at boot
  jobs/                 one-line wrappers around domain methods
  mailers/              email delivery adapters
  models/               the domain — this is where behavior lives
    concerns/           genuinely cross-model behavior only
    card/               Card's own concerns and child records
  views/                ERB templates, partials, jbuilder
config/
  routes.rb             the resource map
  initializers/         framework integration points
lib/
  rails_ext/            framework patches
test/                   mirrors app/
```

**What not to create.** No `app/services`, `app/interactors`, `app/commands`, `app/use_cases`, `app/repositories`, `app/policies`, `app/presenters`, `app/serializers`, `app/forms`. If you feel the urge, the answer is almost always a model method, a namespaced concern, or a plain object in `app/models`.

**The one nuance that matters most:** `app/models/` is not just Active Record classes. It's the domain. Plain Ruby objects live there too — `Color`, `TimeWindowParser`, `Notifier`, `Event::Description`, `Card::Entropy` are all in `app/models` and none of them are backed by a table.

**The rule.** Put code where a Rails developer would guess. When behavior belongs to a model, it goes in that model's directory, not a global one.

**Your turn.** Generate your app. Delete nothing, add no top-level directories. Confirm `bin/dev` boots and you get the welcome page.

---

## III.3 Schema and data design

**The idea.** The database schema is the foundation of an Active Record app, and `db/schema.rb` is its source of truth. You change it only through migrations.

```bash
bin/rails generate migration AddColorToColumns color:string
bin/rails db:migrate
```

That writes a timestamped file in `db/migrate/` and regenerates `db/schema.rb`. Never edit `schema.rb` by hand.

**How Fizzy does it.** Two decisions dominate.

**1. UUIDv7 primary keys, base36-encoded.**

```ruby
# db/schema.rb
create_table "cards", id: :uuid, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
  t.uuid "account_id", null: false
  t.uuid "board_id", null: false
  t.uuid "column_id"
  t.datetime "created_at", null: false
  t.uuid "creator_id", null: false
  t.date "due_on"
  t.datetime "last_active_at", null: false
  t.bigint "number", null: false
  t.string "status", default: "drafted", null: false
  t.string "title"
  t.datetime "updated_at", null: false
  t.index ["account_id", "last_active_at", "status"], name: "index_cards_on_account_id_and_last_active_at_and_status"
  t.index ["account_id", "number"], name: "index_cards_on_account_id_and_number", unique: true
  t.index ["board_id"], name: "index_cards_on_board_id"
  t.index ["column_id"], name: "index_cards_on_column_id"
end
```

Sequential integer IDs leak information (how many customers you have, how fast you're growing) and make merging data across databases painful. Random UUIDv4s solve that but destroy index locality. **UUIDv7** is the compromise: the high bits are a timestamp, so IDs sort chronologically and index inserts stay sequential.

Fizzy stores them as 16 raw bytes and presents them as 25-character base36 strings — shorter and URL-friendlier than the hyphenated hex form. A custom Active Record type does the conversion:

```ruby
# lib/rails_ext/active_record_uuid_type.rb
module ActiveRecord
  module Type
    class Uuid < Binary
      BASE36_LENGTH = 25 # 36^25 > 2^128

      class << self
        def generate
          uuid = SecureRandom.uuid_v7
          hex = uuid.delete("-")
          hex_to_base36(hex)
        end
      end

      def serialize(value)
        return unless value
        binary = Uuid.base36_to_hex(value).scan(/../).map(&:hex).pack("C*")
        super(binary)
      end

      def deserialize(value)
        return unless value
        hex = value.to_s.unpack1("H*")
        Uuid.hex_to_base36(hex)
      end
    end
  end
end
```

New tables get UUID keys automatically, because the generator default is set app-wide:

```ruby
# config/application.rb
config.generators do |g|
  g.orm :active_record, primary_key_type: :uuid
end
```

**2. `account_id` on every tenant-owned table.** Look at the `cards` table above: `account_id` is there even though it's derivable through `board_id`. That denormalization is deliberate — it makes every tenant-scoped query a single index lookup, and it makes "delete this account's data" a straightforward operation.

The application-side mechanism is not a `default_scope` or a global callback. Each model declares where its account comes from:

```ruby
# app/models/card.rb
belongs_to :account, default: -> { board.account }

# app/models/comment.rb
belongs_to :account, default: -> { card.account }

# app/models/closure.rb
belongs_to :account, default: -> { card.account }

# app/models/board.rb
belongs_to :account, default: -> { creator.account }

# app/models/tag.rb
belongs_to :account, default: -> { Current.account }
```

Each one walks up to the nearest object that already knows its account. `Tag` is the exception that falls back to `Current.account`, because a tag has no natural parent at creation time.

**Multiple databases.** In production, Fizzy runs four logical databases from one app:

```yaml
# config/database.sqlite.yml
production:
  primary:
    <<: *default
    database: storage/production.sqlite3
    schema_dump: schema_sqlite.rb
  cable:
    <<: *default
    database: storage/production_cable.sqlite3
    migrations_paths: db/cable_migrate
  cache:
    <<: *default
    database: storage/production_cache.sqlite3
    migrations_paths: db/cache_migrate
  queue:
    <<: *default
    database: storage/production_queue.sqlite3
    migrations_paths: db/queue_migrate
```

Domain data in `primary`; jobs, cache, and websocket pubsub each in their own. High-churn infrastructure tables never contend with your domain tables, and each can be backed up or discarded on its own schedule.

`ApplicationRecord` is where the reading/writing split is wired up:

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  configure_replica_connections
end
```

`configure_replica_connections` is a Fizzy extension (`lib/rails_ext/active_record_replica_support.rb`) that calls `connects_to` only when a replica is actually configured — a no-op in development, active in production.

**The rules.**

- UUIDv7 primary keys for new tables.
- Every tenant-owned table gets `account_id`, `null: false`, indexed — usually as the first column of a composite index.
- Every model declares `belongs_to :account, default: -> { ... }` walking up to its parent.
- Index what you query. Note `["account_id", "number"], unique: true` — that's both a performance index and a data integrity constraint.

**Your turn.** Write the migrations for your domain. Use `id: :uuid`. Put your tenant's foreign key on every table and index it first. Run `bin/rails db:migrate` and read the generated `db/schema.rb`.

---

## III.4 Request context: `Current`

**The idea.** Some values are true for the whole request — who's signed in, which tenant this is. Threading them through every method call is noise. Rails offers `ActiveSupport::CurrentAttributes`: a thread-local, request-scoped singleton that Rails resets between requests.

This is a loaded gun. Used narrowly, it's the cleanest solution available. Used broadly, it becomes global mutable state and your test suite becomes a haunted house.

**How Fizzy does it.**

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :identity, :account
  attribute :http_method, :request_id, :user_agent, :ip_address, :referrer

  def session=(value)
    super(value)

    if value.present?
      self.identity = session.identity
    end
  end

  def identity=(identity)
    super(identity)

    if identity.present?
      self.user = identity.users.find_by(account: account)
    end
  end

  def with_account(value, &)
    with(account: value, &)
  end

  def without_account(&)
    with(account: nil, &)
  end
end
```

Nine attributes, total. Two of them cascade: setting the session derives the identity, and setting the identity derives the account-scoped user. So a controller sets one thing and gets three.

The `with_account` / `without_account` helpers wrap `CurrentAttributes#with`, which sets a value for the duration of a block and restores it afterward. That's what makes tenant switching safe in middleware and jobs.

**Who populates it.** Three places, all at the edge:

```ruby
# config/initializers/tenanting/account_slug.rb — middleware sets the account
Current.with_account(account) do
  @app.call env
end

# app/controllers/concerns/authentication.rb — sets the session
def set_current_session(session)
  Current.session = session
  cookies.signed.permanent[:session_token] = { value: session.signed_id, httponly: true, same_site: :lax }
end

# app/controllers/concerns/current_request.rb — request metadata
module CurrentRequest
  extend ActiveSupport::Concern

  included do
    before_action do
      Current.http_method = request.method
      Current.request_id  = request.uuid
      Current.user_agent  = request.user_agent
      Current.ip_address  = request.ip
      Current.referrer    = request.referrer
    end
  end
end
```

**Who reads it.** Models use it for actor defaults, so callers don't have to pass the obvious thing:

```ruby
# app/models/card.rb
belongs_to :creator, class_name: "User", default: -> { Current.user }

# app/models/card/closeable.rb
def close(user: Current.user)
```

Note the shape of that second one: `Current.user` is a *default*, not a hard dependency. You can still call `card.close(user: someone_else)` — from a job, a test, or an import. That's the difference between convenient and untestable.

**The rules.**

- `Current` holds identity, tenancy, and request metadata. Nothing else.
- Never put "state the app needs later" or "a dependency I didn't want to pass" in it.
- When a model uses `Current`, use it as a keyword-argument default so it can be overridden.
- Populate it only at the edges: middleware, controller concerns, job hooks.

**Your turn.** Create `app/models/current.rb` with your tenant and user attributes. Add a `CurrentRequest` concern and include it in `ApplicationController`.

---

## III.5 Multi-tenancy

**The idea.** If your app is multi-tenant, decide how before you build anything else. It affects your URLs, your queries, your jobs, your tests, and your cache keys.

The usual options are subdomains (`acme.app.com`), a database per tenant, or a path prefix (`/12345/boards`). Fizzy uses the path prefix, and the implementation is worth studying because it's clever without being magic.

**How Fizzy does it.** A Rack middleware moves the account prefix out of the path *before routing sees it*:

```ruby
# config/initializers/tenanting/account_slug.rb
module AccountSlug
  PATTERN = /(\d+)/
  PATH_INFO_MATCH = /\A(\/#{AccountSlug::PATTERN})/

  class Extractor
    def initialize(app)
      @app = app
    end

    # We're using account id prefixes in the URL path. Rather than namespace
    # all our routes, we're "mounting" the Rails app at this URL prefix.
    def call(env)
      request = ActionDispatch::Request.new(env)

      # $1, $2, $' == script_name, slug, path_info
      if request.script_name && request.script_name =~ PATH_INFO_MATCH
        env["fizzy.external_account_id"] = AccountSlug.decode($2)
      elsif request.path_info =~ PATH_INFO_MATCH
        # Yanks the prefix off PATH_INFO and move it to SCRIPT_NAME
        request.engine_script_name = request.script_name = $1
        request.path_info   = $'.empty? ? "/" : $'

        env["fizzy.external_account_id"] = AccountSlug.decode($2)
      end

      if env["fizzy.external_account_id"]
        account = Account.find_by(external_account_id: env["fizzy.external_account_id"])
        Current.with_account(account) do
          @app.call env
        end
      else
        Current.without_account do
          @app.call env
        end
      end
    end
  end

  def self.decode(slug) slug.to_i end
  def self.encode(id) id.to_s end
end

Rails.application.config.middleware.insert_after Rack::TempfileReaper, AccountSlug::Extractor
```

Moving the prefix from `PATH_INFO` to `SCRIPT_NAME` makes Rails believe the whole application is *mounted* at `/12345`. The payoff is enormous:

- `config/routes.rb` never mentions accounts. It's a clean resource map.
- Every URL helper automatically emits the prefix, because Rails prepends `SCRIPT_NAME`.
- No controller has to remember to scope by account in its route.

And `Current.with_account(account) { ... }` guarantees the account is set for the entire downstream request and unset afterward.

The reverse direction — building URLs — is one method:

```ruby
# app/models/account.rb
def slug
  "/#{AccountSlug.encode(external_account_id)}"
end
```

**Why not subdomains?** Local development and testing. A path prefix works on `localhost` with no DNS, no wildcard certificates, and no host manipulation in tests. Compare the two test setups — Fizzy's is one line:

```ruby
# test/test_helper.rb
class ActionDispatch::IntegrationTest
  setup do
    integration_session.default_url_options[:script_name] = "/#{ActiveRecord::FixtureSet.identify("37signals")}"
  end
end
```

**Carrying tenancy into jobs.** A background job runs outside the request, so `Current` is empty. Fizzy fixes that once, globally, by prepending a module onto `ActiveJob`:

```ruby
# config/initializers/active_job.rb
module FizzyActiveJobExtensions
  extend ActiveSupport::Concern

  prepended do
    attr_reader :account
    self.enqueue_after_transaction_commit = true
  end

  def initialize(...)
    super
    @account = Current.account
  end

  def serialize
    super.merge({ "account" => @account&.to_gid })
  end

  def deserialize(job_data)
    super
    if _account = job_data.fetch("account", nil)
      @account = GlobalID::Locator.locate(_account)
    end
  end

  def perform_now
    if account.present?
      Current.with_account(account) { super }
    else
      super
    end
  end
end

ActiveSupport.on_load(:active_job) do
  prepend FizzyActiveJobExtensions
end
```

Every job captures `Current.account` when enqueued, serializes it as a GlobalID, and restores it before performing. No job ever has to think about tenancy again.

That `self.enqueue_after_transaction_commit = true` line is doing quiet, important work too: jobs enqueued inside a transaction don't actually dispatch until it commits. Without it, a worker could pick up a job referencing a record that isn't visible yet — or that's about to be rolled back.

**The rules.**

- Pick your tenancy scheme before anything else and implement it at the edge.
- Set tenant context in middleware, not in a `before_action` every controller must remember.
- Restore tenant context in jobs automatically, once, for all jobs.
- Still scope your queries explicitly (`Current.account.tags`, `Current.user.boards`) — the middleware sets context, it does not filter your SQL.

**Your turn.** If your app is multi-tenant, write the middleware and register it in an initializer. Add the job extension. Write a middleware test asserting `Current.account` is set for a prefixed path and nil otherwise (see `test/middleware/account_slug_extractor_test.rb`).

---

## III.6 Identity, membership, authentication

**The idea.** "User" usually means two different things: a person (an email address, a password, a session) and a membership (a role inside one organization). Conflating them makes multi-org support painful later. Fizzy separates them from the start.

**How Fizzy does it.**

```ruby
# app/models/identity.rb
class Identity < ApplicationRecord
  include Joinable, Transferable

  has_passkeys name: :email_address, display_name: -> { Current.user&.name || email_address }

  has_many :access_tokens, dependent: :destroy
  has_many :magic_links, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :users, dependent: :nullify
  has_many :accounts, through: :users

  has_one_attached :avatar

  before_destroy :deactivate_users, prepend: true

  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }
  normalizes :email_address, with: ->(value) { value.strip.downcase.presence }

  def self.find_by_permissable_access_token(token, method:)
    if (access_token = AccessToken.find_by(token: token)) && access_token.allows?(method)
      access_token.identity
    end
  end

  def send_magic_link(**attributes)
    attributes[:purpose] = attributes.delete(:for) if attributes.key?(:for)

    magic_links.create!(attributes).tap do |magic_link|
      MagicLinkMailer.sign_in_instructions(magic_link).deliver_later
    end
  end

  private
    def deactivate_users
      users.find_each(&:deactivate)
    end
end
```

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Accessor, Assignee, Attachable, Avatar, Configurable, EmailAddressChangeable,
    Mentionable, Named, Notifiable, Role, Searcher, Watcher
  include Timelined # Depends on Accessor

  belongs_to :account
  belongs_to :identity, optional: true

  validates :name, presence: true

  has_many :comments, inverse_of: :creator, dependent: :destroy
  has_many :pins, dependent: :destroy
  has_many :pinned_cards, through: :pins, source: :card

  def deactivate
    transaction do
      accesses.destroy_all
      update! active: false, identity: nil
      close_remote_connections
    end
  end
end
```

`Identity` is global and owns credentials. `User` is per-account and owns role, name, avatar, and access. One `Identity` has many `Users`, one per account it belongs to. Note `include Timelined # Depends on Accessor` — when concern order matters, say so in a comment rather than leaving a landmine.

`normalizes` is worth pausing on. It's a Rails attribute-level normalization that runs before validation *and* when querying, so `Identity.find_by(email_address: " DAVID@Example.com ")` finds the record stored as `david@example.com`.

**Authentication.** No passwords. You get a magic link by email, or you use a passkey. The controller-side machinery lives in one concern:

```ruby
# app/controllers/concerns/authentication.rb
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_account # Checking and setting account must happen first
    before_action :require_authentication
    helper_method :authenticated?
    helper_method :email_address_pending_authentication

    etag { Current.identity.id if authenticated? }

    include Authentication::ViaMagicLink, LoginHelper
  end

  class_methods do
    def require_unauthenticated_access(**options)
      allow_unauthenticated_access **options
      before_action :redirect_authenticated_user, **options
    end

    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
      before_action :resume_session, **options
      allow_unauthorized_access **options
    end
  end

  private
    def authenticated?
      Current.identity.present?
    end

    def require_authentication
      resume_session || authenticate_by_bearer_token || request_authentication
    end

    def resume_session
      if session = find_session_by_cookie
        set_current_session session
      end
    end

    def find_session_by_cookie
      Session.find_signed(cookies.signed[:session_token])
    end

    def authenticate_by_bearer_token
      if request.authorization.to_s.include?("Bearer")
        if request.format.json?
          authenticate_or_request_with_http_token do |token|
            if identity = Identity.find_by_permissable_access_token(token, method: request.method)
              Current.identity = identity
            end
          end
        else
          request_http_token_authentication
        end
      end
    end

    def start_new_session_for(identity)
      identity.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        set_current_session session
      end
    end

    def set_current_session(session)
      Current.session = session
      cookies.signed.permanent[:session_token] = { value: session.signed_id, httponly: true, same_site: :lax }
    end
end
```

Several things to learn from this file:

**One gate, several credentials.** `require_authentication` is a single chain: `resume_session || authenticate_by_bearer_token || request_authentication`. Cookie sessions and API tokens converge on the same result — `Current.identity` set — so nothing downstream cares which was used.

**Concerns can define DSL macros.** `allow_unauthenticated_access` and `require_unauthenticated_access` are class methods a controller calls to opt out. Rather than every public controller reproducing three `skip_before_action` lines, they write one:

```ruby
class SessionsController < ApplicationController
  require_unauthenticated_access only: %i[ new create ]
end
```

**Sessions are records, not cookie payloads.** The cookie holds `session.signed_id`; the `Session` row holds the user agent and IP. Revoking a session means deleting a row.

**`Bearer` tokens are restricted to JSON.** A browser request carrying an `Authorization` header hits `request_http_token_authentication` instead — a deliberate fix (commit `13e2c7492`) preventing token auth from being used to drive HTML flows.

**Authorization** is a separate concern and covers only one question: may this identity use this account at all?

```ruby
# app/controllers/concerns/authorization.rb
module Authorization
  extend ActiveSupport::Concern

  included do
    before_action :ensure_can_access_account, if: :authenticated_account_access?
  end

  private
    def ensure_admin
      head :forbidden unless Current.user.admin?
    end

    def authenticated_account_access?
      Current.account.present? && authenticated?
    end

    def ensure_can_access_account
      unless Current.account.active? && Current.user&.active?
        respond_to do |format|
          format.html { redirect_to session_menu_path(script_name: nil) }
          format.json { head :forbidden }
        end
      end
    end
end
```

Per-record authorization is *not* here. That happens by scoping — see [§12](#iii12-thin-controllers).

Roles are an enum on `User`:

```ruby
# app/models/user/role.rb
enum :role, %i[ owner admin member system ].index_by(&:itself), scopes: false
```

`.index_by(&:itself)` builds `{ owner: "owner", admin: "admin", ... }` so the database stores readable strings rather than integers. That's the house pattern for every enum in the app — integers are unreadable in a database console and break when someone reorders the list.

**The rules.**

- Separate global identity from per-tenant membership.
- One authentication gate; multiple credential types converge on it.
- Sessions are database records referenced by a signed cookie.
- Account-level authorization in a concern; record-level authorization by scoping.
- Enums store strings, via `%w[ ... ].index_by(&:itself)`.

**Your turn.** Build `Identity`, `User`, and `Session`. Write an `Authentication` concern with `resume_session`, `start_new_session_for`, and `allow_unauthenticated_access`. Include it in `ApplicationController`. Get sign-in working end to end before building anything else — every later chapter assumes `Current.user`.

---

## III.7 Rich Active Record models

**The idea.** In Rails, the model is the domain layer. It knows how to persist itself *and* what it means. That combination is what lets you delete the service layer.

**How Fizzy does it.** Here's `Card` in full — the most important file in the application:

```ruby
# app/models/card.rb
class Card < ApplicationRecord
  include Accessible, Assignable, Attachments, Broadcastable, Closeable, Colored, Commentable,
    Entropic, Eventable, Exportable, Golden, Mentions, Multistep, Pinnable, Postponable, Promptable,
    Readable, Searchable, Stallable, Statuses, Storage::Tracked, Taggable, Triageable, Watchable

  belongs_to :account, default: -> { board.account }
  belongs_to :board
  belongs_to :creator, class_name: "User", default: -> { Current.user }

  has_many :reactions, -> { order(:created_at) }, as: :reactable, dependent: :delete_all
  has_one_attached :image, dependent: :purge_later

  has_rich_text :description

  before_save :set_default_title, if: :published?
  before_create :assign_number

  after_save   -> { board.touch }, if: :published?
  after_touch  -> { board.touch }, if: :published?
  after_update :handle_board_change, if: :saved_change_to_board_id?

  scope :reverse_chronologically, -> { order created_at:     :desc, id: :desc }
  scope :chronologically,         -> { order created_at:     :asc,  id: :asc  }
  scope :latest,                  -> { order last_active_at: :desc, id: :desc }
  scope :with_users,              -> { preload(creator: [ :avatar_attachment, :account ], assignees: [ :avatar_attachment, :account ]) }
  scope :preloaded,               -> { with_users.preload(:column, :tags, :steps, :closure, :goldness, :activity_spike, :image_attachment, reactions: :reacter, board: [ :entropy, :columns ], not_now: [ :user ]).with_rich_text_description_and_embeds }

  scope :indexed_by, ->(index) do
    case index
    when "stalled" then stalled
    when "postponing_soon" then postponing_soon
    when "closed" then closed
    when "not_now" then postponed.latest
    when "golden" then golden
    when "draft" then drafted
    else all
    end
  end

  scope :sorted_by, ->(sort) do
    case sort
    when "newest" then reverse_chronologically
    when "oldest" then chronologically
    when "latest" then latest
    else latest
    end
  end

  def card
    self
  end

  def to_param
    number.to_s
  end

  def move_to(new_board)
    transaction do
      card.update!(board: new_board)
      card.events.update_all(board_id: new_board.id)
      Event.where(eventable: card.comments).update_all(board_id: new_board.id)
    end
  end

  def filled?
    title.present? || description.present?
  end

  private
    def set_default_title
      self.title = "Untitled" if title.blank?
    end

    def handle_board_change
      old_board = account.boards.find_by(id: board_id_before_last_save)

      transaction do
        update! column: nil
        track_board_change_event(old_board.name)
        grant_access_to_assignees unless board.all_access?
      end

      remove_inaccessible_notifications_later
      clean_inaccessible_data_later
    end

    def track_board_change_event(old_board_name)
      track_event "board_changed", particulars: { old_board: old_board_name, new_board: board.name }
    end

    def assign_number
      self.number ||= account.increment!(:cards_count).cards_count
    end
end
```

Ninety-four lines for the central object of the entire application. Read what's in it:

**Associations with computed defaults.**

```ruby
belongs_to :creator, class_name: "User", default: -> { Current.user }
```

`class_name:` because the association name doesn't match the class. `default:` runs when a new record is built without one — so `Card.new` already knows its creator.

**Scopes are composable query fragments.** Each returns a relation, so they chain:

```ruby
@board.cards.awaiting_triage.latest.with_golden_first.preloaded
```

Two of them deserve special attention. `preloaded` is a named answer to the N+1 problem: instead of scattering `includes` calls through controllers and views, the model declares once what a fully-rendered card needs. `indexed_by` and `sorted_by` take a user-supplied string and dispatch to a real scope — the `case` acts as an allowlist, so no user input reaches SQL.

**`to_param` gives you friendly URLs.**

```ruby
def to_param
  number.to_s
end
```

Rails calls `to_param` when generating URLs, so `card_path(card)` produces `/cards/42` using the per-account sequential number instead of the UUID. The other half is in the controller: `find_by!(number: params[:id])`.

**`assign_number` shows what a business rule looks like.**

```ruby
self.number ||= account.increment!(:cards_count).cards_count
```

`increment!` performs an atomic `UPDATE accounts SET cards_count = cards_count + 1` and returns the account, so concurrent card creation can't produce duplicate numbers. The `||=` means an explicitly supplied number (during an import) is preserved.

**`def card; self; end`** looks odd until you see why: many concerns (`Commentable`, `Eventable`, `Storage::Tracked`) are mixed into both `Card` and `Comment` and call `card` to find the owning card. `Comment#card` is an association; `Card#card` is itself. One method makes a whole family of shared code work on both.

**What isn't here.** No SQL. No HTML. No HTTP concepts. No knowledge of jobs beyond calling `..._later` methods. And no validations — because in this domain, a card with a blank title is valid; it just gets titled "Untitled" (`before_save :set_default_title`). Validation is for what must be true, not for what you'd prefer.

**Validations, where they do appear**, are one rule per line, with custom `validate` methods for cross-field logic:

```ruby
# app/models/assignment.rb
LIMIT = 100
validate :within_limit, on: :create

private
  def within_limit
    if card.assignments.count >= LIMIT
      errors.add(:base, "Card already has the maximum of #{LIMIT} assignees")
    end
  end
```

**The rules.**

- Business behavior belongs on the model, next to the data it operates on.
- Name methods after the domain (`close`, `postpone`, `move_to`, `filled?`), never after mechanics (`update_status_field`).
- Use `default: -> { ... }` on `belongs_to` to remove ceremony from callers.
- Define a `preloaded` scope for anything rendered in a list, and use it.
- Never interpolate user input into a query; dispatch through a `case` to named scopes.
- The model may not know about HTTP, HTML, or params.

**Your turn.** Write your main aggregate model. Associations, a `latest` scope, a `preloaded` scope, and at least one real business method that does something in a transaction. Exercise it from `bin/rails console`.

---

## III.8 Concerns as capability slices

**The idea.** A rich model grows. `Card` has 23 capabilities; a single 2,000-line file would be unreadable. The answer is not to move logic into services — it's to slice the model into named capabilities that live next to it.

**How Fizzy does it.** Compare two directories:

```
app/models/concerns/          # cross-model: mixed into several unrelated classes
  attachments.rb
  eventable.rb
  filterable.rb
  mentions.rb
  notifiable.rb
  searchable.rb
  storage/

app/models/card/              # Card's own: nothing else includes these
  accessible.rb   assignable.rb   broadcastable.rb   closeable.rb
  colored.rb      commentable.rb  entropic.rb        exportable.rb
  golden.rb       mentions.rb     multistep.rb       pinnable.rb
  postponable.rb  promptable.rb   readable.rb        searchable.rb
  stallable.rb    statuses.rb     taggable.rb        triageable.rb
  watchable.rb
  entropy.rb      goldness.rb     not_now.rb         activity_spike.rb
```

The distinction is ownership, and it's the whole rule: **if only `Card` includes it, it goes in `app/models/card/`.** `app/models/concerns/` is reserved for behavior genuinely shared across unrelated models — `Eventable` is included by `Card`, `Comment`, and others, so it's global.

Note that `app/models/card/` holds two kinds of file: capability modules (adjective-ish names — `Closeable`, `Assignable`, `Postponable`) and child record classes (noun names — `Card::NotNow`, `Card::Goldness`, `Card::Entropy`). Same namespace, different kinds of thing, distinguishable at a glance from the name.

Here is a complete concern:

```ruby
# app/models/card/closeable.rb
module Card::Closeable
  extend ActiveSupport::Concern

  included do
    has_one :closure, dependent: :destroy

    scope :closed, -> { joins(:closure) }
    scope :open, -> { where.missing(:closure) }

    scope :recently_closed_first, -> { closed.order(closures: { created_at: :desc }) }
    scope :closed_at_window, ->(window) { closed.where(closures: { created_at: window }) }
    scope :closed_by, ->(users) { closed.where(closures: { user_id: Array(users) }) }
  end

  def closed?
    closure.present?
  end

  def open?
    !closed?
  end

  def closed_by
    closure&.user
  end

  def closed_at
    closure&.created_at
  end

  def close(user: Current.user)
    unless closed?
      transaction do
        not_now&.destroy
        create_closure! user: user
        track_event :closed, creator: user
      end
    end
  end

  def reopen(user: Current.user)
    if closed?
      transaction do
        closure&.destroy
        track_event :reopened, creator: user
      end
    end
  end
end
```

Forty-nine lines that contain *everything* about closing a card: the association, the query scopes, the predicates, the reads, and the two transitions. If you're asked to change how closing works, there is exactly one file to open.

Another, showing a join model and a race-condition guard:

```ruby
# app/models/card/assignable.rb
module Card::Assignable
  extend ActiveSupport::Concern

  included do
    has_many :assignments, dependent: :delete_all
    has_many :assignees, through: :assignments

    scope :unassigned, -> { where.missing :assignments }
    scope :assigned_to, ->(users) { joins(:assignments).where(assignments: { assignee: users }).distinct }
  end

  def toggle_assignment(user)
    assigned_to?(user) ? unassign(user) : assign(user)
  end

  def assigned_to?(user)
    assignments.any? { |a| a.assignee_id == user.id }
  end

  private
    def assign(user)
      assignment = assignments.create assignee: user, assigner: Current.user

      if assignment.persisted?
        watch_by user
        track_event :assigned, assignee_ids: [ user.id ]
      end
    rescue ActiveRecord::RecordNotUnique
      # Already assigned
    end
end
```

`rescue ActiveRecord::RecordNotUnique` with a comment and no re-raise is the correct handling of a benign race: two rapid clicks both try to assign, the database's unique index rejects the second, and "already assigned" is exactly the outcome the user wanted.

**Sizing.** Notice how small these are. A concern that's 300 lines is a sign the capability is actually two capabilities.

**The anti-pattern.** A concern named after a mechanism rather than a capability — `CardHelpers`, `CardUtils`, `CardExtensions` — is a bag, not a slice. If you can't name it after something a user would recognize (`Closeable`, `Postponable`, `Watchable`), you haven't found the seam yet.

**Reading a model composed this way.** In the console:

```ruby
Card.ancestors                       # every module, in lookup order
Card.instance_methods(false)         # what Card itself defines
card.method(:close).source_location  # which file defines this?
```

**The rules.**

- One capability per concern, named after the capability.
- `app/models/<model>/` for behavior only that model has; `app/models/concerns/` only for genuinely shared behavior.
- `included do` holds class-level DSL calls only — associations, scopes, callbacks, validations.
- A concern owns its whole capability: association, scopes, predicates, and transitions together.
- If concern order matters, say so in a comment.

**Your turn.** Take your aggregate and slice one capability out into `app/models/<your_model>/<capability>.rb`. Move its association, its scopes, its predicates, and its transition methods. Include it. The model file should get shorter and the tests should still pass.

---
## III.9 State transitions as records

**The idea.** When something important happens to a record, you have two choices: flip a column, or create a row.

```ruby
# The obvious way
card.update!(closed: true, closed_at: Time.current, closed_by_id: user.id)

# The Fizzy way
card.create_closure!(user: user)
```

The first is fewer tables. The second gives you, for free: who did it, when, the ability to attach more data later, referential integrity, an index you can query, and — critically — a record you can *destroy* to undo the transition without leaving stale columns behind.

**How Fizzy does it.** `Card`'s state is composed entirely of associations. There is one enum in the whole model, and it's for a distinction that carries no extra data:

| State | How it's modelled | Predicate | Scope |
|---|---|---|---|
| Draft vs published | `enum :status` on `cards` | `published?` | `drafted` |
| Closed | `has_one :closure` | `closed?` | `closed` / `open` |
| Postponed ("not now") | `has_one :not_now` | `postponed?` | `postponed` / `active` |
| Golden (starred) | `has_one :goldness` | `golden?` | `golden` |
| Triaged into a column | `belongs_to :column, optional: true` | `triaged?` | `awaiting_triage` |
| Assigned | `has_many :assignments` | `assigned_to?` | `assigned_to` / `unassigned` |
| Watched | `has_many :watches` | `watched_by?` | — |
| Tagged | `has_many :taggings` | `tagged_with?` | `tagged_with` |

And the records themselves are tiny. Here are four side by side:

```ruby
# app/models/closure.rb
class Closure < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :card, touch: true
  belongs_to :user, optional: true
end

# app/models/card/not_now.rb
class Card::NotNow < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :card, class_name: "::Card", touch: true
  belongs_to :user, optional: true
end

# app/models/watch.rb
class Watch < ApplicationRecord
  belongs_to :account, default: -> { user.account }
  belongs_to :user
  belongs_to :card, touch: true

  scope :watching, -> { where(watching: true) }
  scope :not_watching, -> { where(watching: false) }
end

# app/models/tagging.rb
class Tagging < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :tag
  belongs_to :card, touch: true
end
```

Same shape every time: account, the parent (with `touch: true`), and an actor.

**`touch: true` is load-bearing.** When a `Closure` is created, its `card`'s `updated_at` is bumped. That single option cascades through the entire application:

- `<% cache card do %>` fragments invalidate automatically.
- `fresh_when etag: @page.records` produces a new ETag.
- Turbo's `broadcasts_refreshes` fires.
- "Recently active" ordering stays correct.

Sixteen-plus models in this codebase use it. It's the reason there is no manual cache-invalidation code anywhere.

**Querying by absence.** `where.missing` turns "records without an associated X" into readable SQL:

```ruby
scope :open,            -> { where.missing(:closure) }
scope :unassigned,      -> { where.missing :assignments }
scope :awaiting_triage, -> { active.where.missing(:column) }
```

**Transitions live in the concern.** The record is dumb; the transition is behavior:

```ruby
# app/models/card/postponable.rb
def auto_postpone(**args)
  postpone(**args, event_name: :auto_postponed)
end

def postpone(user: Current.user, event_name: :postponed)
  transaction do
    send_back_to_triage(skip_event: true)
    reopen
    activity_spike&.destroy
    create_not_now!(user: user) unless postponed?
    track_event event_name, creator: user
  end
end

def resume
  transaction do
    reopen
    activity_spike&.destroy
    not_now&.destroy
  end
end
```

Three things worth copying here. The transaction wraps *every* write plus the event, so an activity feed can never disagree with reality. `auto_postpone` is a one-line wrapper that changes only the event name — the system-driven and user-driven paths share all their logic but stay distinguishable in the audit trail. And `resume` is the exact inverse: destroy the row, and the state is gone.

**When a boolean column is fine.** When the transition carries no who, no when, and no possibility of ever carrying more. `Watch` has a `watching:` boolean *inside* the record because the record's existence means "this user has an opinion" and the boolean means which opinion. That's a considered distinction, not an inconsistency.

**The rules.**

- If a transition has an actor or a timestamp anyone will ever ask about, model it as a record.
- Transition records are tiny: account, parent with `touch: true`, actor.
- Always `touch: true` on the parent — that's your cache invalidation.
- Predicate methods read the association (`closure.present?`), never a column.
- Wrap the write and its event in one transaction.
- Undo by destroying the record.

**Your turn.** Pick a transition in your domain currently expressed as a boolean. Create the record, its migration with `touch: true`, and a concern with the scopes, the predicates, and the do/undo methods. Delete the column.

---

## III.10 Events, notifications, webhooks

**The idea.** Every significant action should leave a trace. One `Event` table, written by every domain action, becomes the activity feed, the notification source, and the webhook trigger — three features from one abstraction.

**How Fizzy does it.** Writing an event is one shared concern:

```ruby
# app/models/concerns/eventable.rb
module Eventable
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :eventable, dependent: :destroy
  end

  def track_event(action, creator: Current.user, board: self.board, **particulars)
    if should_track_event?
      board.events.create!(action: "#{eventable_prefix}_#{action}", creator:, board:, eventable: self, particulars:)
    end
  end

  def event_was_created(event)
  end

  private
    def should_track_event?
      true
    end

    def eventable_prefix
      self.class.name.demodulize.underscore
    end
end
```

Three design decisions in twenty-five lines:

**Action names are derived, not typed.** `eventable_prefix` turns the class name into a prefix, so `track_event :closed` on a `Card` produces `"card_closed"` and on a `Comment` produces `"comment_closed"`. No magic strings duplicated across the codebase.

**`should_track_event?` is an override point.** `Card::Eventable` overrides it to `published?`, so draft cards don't spam the feed. A subclass changes the policy without touching the mechanism.

**`event_was_created` is an empty hook.** Any eventable model may override it to react. `Card` does:

```ruby
# app/models/card/eventable.rb
def event_was_created(event)
  transaction do
    create_system_comment_for(event)
    touch_last_active_at unless was_just_published?
  end
end
```

**The `Event` model is the fan-out point.**

```ruby
# app/models/event.rb
class Event < ApplicationRecord
  include Notifiable, Particulars, Promptable

  belongs_to :account, default: -> { board.account }
  belongs_to :board
  belongs_to :creator, class_name: "User"
  belongs_to :eventable, polymorphic: true

  has_many :webhook_deliveries, class_name: "Webhook::Delivery", dependent: :delete_all

  scope :chronologically, -> { order created_at: :asc, id: :desc }

  after_create -> { eventable.event_was_created(self) }
  after_create_commit :dispatch_webhooks

  delegate :card, to: :eventable

  def action
    super.inquiry
  end

  def notifiable_target
    eventable
  end

  def description_for(user)
    Event::Description.new(self, user)
  end

  private
    def dispatch_webhooks
      Event::WebhookDispatchJob.perform_later(self)
    end
end
```

`belongs_to :eventable, polymorphic: true` means an event can point at any model — a card, a comment, anything. `super.inquiry` wraps the action string so callers can write `event.action.card_closed?` instead of comparing strings.

Note the callback split, which is the pattern to internalize:

- `after_create` — synchronous, in the same transaction, for local consequences.
- `after_create_commit` — after the transaction commits, for enqueuing jobs and anything touching the outside world.

**`particulars` is a JSON column** for per-action metadata, with named accessors where a field is used often:

```ruby
# app/models/event/particulars.rb
module Event::Particulars
  extend ActiveSupport::Concern

  included do
    store_accessor :particulars, :assignee_ids
  end

  def assignees
    @assignees ||= User.where id: assignee_ids
  end
end
```

Used from a domain method like this:

```ruby
# app/models/card.rb
track_event "board_changed", particulars: { old_board: old_board_name, new_board: board.name }
```

This is the escape valve that keeps the `events` table from growing a column per action type.

**Notifications.** A generic concern enqueues the work; a factory picks the right notifier:

```ruby
# app/models/notifier.rb — abridged
class Notifier
  class << self
    def for(source)
      case source
      when Event
        "Notifier::#{source.eventable.class}EventNotifier".safe_constantize&.new(source)
      when Mention
        MentionNotifier.new(source)
      end
    end
  end

  def notify
    if should_notify?
      # Processing recipients in order avoids deadlocks if notifications overlap.
      recipients.sort_by(&:id).map do |recipient|
        notification = Notification.create_or_find_by(user: recipient, card: source.card) do |n|
          n.source = source
          n.creator = creator
          n.unread_count = 1
        end
        # ...
      end
    end
  end
end
```

`safe_constantize` resolves a class name from a string and returns `nil` rather than raising if it doesn't exist — so adding a notifier for a new eventable type means adding one file, with no registry to update.

Subclasses answer only "who cares about this?" — `Notifier::CardEventNotifier` maps `card_assigned` to the assignees, `comment_created` to the card's watchers minus the mentioners.

**Webhooks** are modelled as records, not inline HTTP calls. Each delivery is auditable, retryable, and inspectable. The dispatch job is resumable, which matters when a single event fans out to many subscribers:

```ruby
# app/jobs/event/webhook_dispatch_job.rb
class Event::WebhookDispatchJob < ApplicationJob
  include ActiveJob::Continuable

  queue_as :webhooks
  discard_on ActiveJob::DeserializationError

  def perform(event)
    step :dispatch do |step|
      Webhook.active.triggered_by(event).find_each(start: step.cursor) do |webhook|
        webhook.trigger(event)
        step.advance! from: webhook.id
      end
    end
  end
end
```

`ActiveJob::Continuable` checkpoints progress, so a deploy mid-fan-out resumes rather than restarting — and doesn't re-deliver to webhooks already notified.

**The rules.**

- One `Event` table, polymorphic, written by domain methods via `track_event`.
- Derive action names from the class; never hand-write `"card_closed"` at a call site.
- Structured extras go in a JSON `particulars` column, promoted to `store_accessor` when frequently used.
- `after_create` for local consequences; `after_create_commit` for jobs and the outside world.
- Model outbound integrations as records with their own state, not as HTTP calls buried in a callback.

**Your turn.** Add `Event` with a polymorphic `eventable`, an `Eventable` concern with `track_event`, and call it from the transitions you built in §9. Render a simple activity feed from `Event.chronologically`.

---

## III.11 Routes as resources

**The idea.** REST, taken literally. Your routes file is a map of *nouns*, and every action a user can take is a create/update/destroy on some noun. When an action doesn't fit CRUD on the existing resource, you introduce a new resource rather than a custom verb.

**How Fizzy does it.**

```ruby
# config/routes.rb
resources :cards do
  scope module: :cards do
    resource :draft, only: :show
    resource :board
    resource :closure
    resource :column
    resource :goldness
    resource :image
    resource :not_now
    resource :pin
    resource :publish
    resource :reading
    resource :triage
    resource :watch

    resources :reactions

    resources :assignments
    resource :self_assignment, only: :create
    resources :steps
    resources :taggings

    resources :comments do
      resources :reactions, module: :comments
    end
  end
end
```

Read that list. It's the entire feature set of a card, expressed as nouns. Closing a card is `POST /cards/42/closure`; reopening is `DELETE /cards/42/closure`. Starring is `POST /cards/42/goldness`. There is no `POST /cards/42/close`.

The style guide states it as a Bad/Good pair:

```ruby
# Bad
resources :cards do
  post :close
  post :reopen
end

# Good
resources :cards do
  resource :closure
end
```

**Why this is worth the discipline:**

1. HTTP verbs already express create/update/delete. A custom verb duplicates that badly.
2. `POST` and `DELETE` on one path collapse `close` and `reopen` into one small controller with `create` and `destroy`.
3. Each controller stays tiny and single-purpose.
4. It forces you to name the transition, and naming it usually reveals it should be a record — which is exactly [§9](#iii9-state-transitions-as-records).

**`resource` vs `resources`.** Singular `resource :closure` means there's at most one per parent, so no `:id` appears in the path. Plural `resources :comments` generates the full seven routes with IDs. A card has one closure and many comments — the route file states that.

**`scope module:` vs `namespace`.** Both nest the controller into a Ruby module; they differ on the URL.

```ruby
# scope module: — nests the CLASS only. URL is /cards/42/closure
resources :cards do
  scope module: :cards do
    resource :closure   # => Cards::ClosuresController
  end
end

# namespace — nests BOTH class and URL. URL is /notifications/settings
namespace :notifications do
  resource :settings    # => Notifications::SettingsController
end
```

Use `scope module:` when the parent resource already supplies the URL segment; use `namespace` when you want a genuine URL prefix.

**Deeper nesting, when the domain earns it.** Dragging a card onto a drop target is genuinely a different operation from clicking Close, so it gets its own controllers:

```ruby
namespace :columns do
  resources :cards do
    scope module: :cards do
      namespace :drops do
        resource :not_now
        resource :stream
        resource :closure
        resource :column
      end
    end
  end
end
```

That yields `Columns::Cards::Drops::ClosuresController` — verbose, but every segment carries meaning, and the controller is four lines long.

**`direct` and `resolve`** teach URL helpers about domain objects, so views can stay dumb:

```ruby
direct :published_board do |board, options|
  route_for :public_board, board.publication.key
end

resolve "Comment" do |comment, options|
  options[:anchor] = ActionView::RecordIdentifier.dom_id(comment)
  route_for :card, comment.card, options
end
```

With that `resolve`, `link_to comment.body, comment` produces a link to the comment's card, anchored at the comment. The view doesn't need to know the rule.

**What's missing from this routes file:** the account. Multi-tenancy is handled by middleware ([§5](#iii5-multi-tenancy)), so routes stay clean. And there are no route `concern`s and essentially no `constraints` blocks — one regex constraint in 257 lines.

**The rules.**

- Every action is CRUD on a resource. No custom verbs.
- Singular `resource` when there's one per parent; plural `resources` otherwise.
- `scope module:` to namespace controllers under an existing URL segment; `namespace` when you want the URL prefix too.
- Use `only:`/`except:` to declare exactly which actions exist.
- Reach for `resolve`/`direct` when views would otherwise need to know routing rules.

**Your turn.** Convert every custom action in your routes to a nested resource. Run `bin/rails routes | grep <your_model>` and check that each row reads as a noun plus an HTTP verb.

---

## III.12 Thin controllers

**The idea.** A controller is an adapter between HTTP and your domain. It authenticates, loads records, calls one domain method, and picks a response. That's the whole job.

**`ApplicationController` is a composition root.** The entire file:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Authentication
  include Authorization
  include BlockSearchEngineIndexing
  include CurrentRequest, CurrentTimezone, SetPlatform
  include RequestForgeryProtection
  include TurboFlash, ViewTransitions
  include RoutingHeaders

  etag { "v1" }
  stale_when_importmap_changes
  allow_browser versions: :modern
end
```

Thirteen lines, no logic. Every cross-cutting behavior is a named concern you can open and read on its own. Compare that with the 400-line `ApplicationController` you've probably met, where nobody dares delete anything.

**A nested action controller** — the whole thing:

```ruby
# app/controllers/cards/closures_controller.rb
class Cards::ClosuresController < ApplicationController
  include CardScoped

  def create
    capture_card_location
    @card.close
    refresh_stream_if_needed

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end

  def destroy
    @card.reopen
    refresh_stream_after_reopen

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end

  private
    def refresh_stream_after_reopen
      if @card.awaiting_triage?
        set_page_and_extract_portion_from @board.cards.awaiting_triage.latest.with_golden_first.preloaded
      end
    end
end
```

The business logic is exactly one line per action: `@card.close`, `@card.reopen`. Everything else is HTTP plumbing.

**A standard CRUD controller:**

```ruby
# app/controllers/cards_controller.rb
class CardsController < ApplicationController
  wrap_parameters :card, include: %i[ title description image created_at last_active_at ]

  include FilterScoped

  before_action :set_board, only: %i[ create ]
  before_action :set_card, only: %i[ show edit update destroy ]
  before_action :redirect_if_drafted, only: :show
  before_action :ensure_permission_to_administer_card, only: %i[ destroy ]

  def index
    set_page_and_extract_portion_from @filter.cards
  end

  def create
    respond_to do |format|
      format.html do
        card = Current.user.draft_new_card_in(@board)
        redirect_to card_draft_path(card)
      end

      format.json do
        @card = @board.cards.create! card_params.merge(creator: Current.user, status: "published")
        render :show, status: :created, location: card_path(@card, format: :json)
      end
    end
  end

  def show
  end

  def edit
  end

  def update
    @card.update! card_params

    respond_to do |format|
      format.turbo_stream
      format.json { render :show }
    end
  end

  def destroy
    @card.destroy!

    respond_to do |format|
      format.html { redirect_to @card.board, notice: "Card deleted" }
      format.json { head :no_content }
    end
  end

  private
    def set_board
      @board = Current.user.boards.find params[:board_id]
    end

    def set_card
      @card = Current.user.accessible_cards.find_by!(number: params[:id])
    end

    def ensure_permission_to_administer_card
      head :forbidden unless Current.user.can_administer_card?(@card)
    end

    def card_params
      params.expect(card: [ :title, :description, :image, :created_at, :last_active_at ])
    end
end
```

`show` and `edit` are empty. They don't need bodies — the `before_action` loaded `@card` and Rails renders the matching template. Empty actions are correct, not lazy.

### Authorization by scoping

This is the most important idea in the chapter, and the biggest departure from what you're probably used to.

```ruby
@card = Current.user.accessible_cards.find_by!(number: params[:id])
```

Not `Card.find(...)` followed by a permission check. The query *starts* from the current user, so a card the user can't reach doesn't exist as far as this request is concerned — `find_by!` raises `RecordNotFound`, Rails returns 404, and no information leaks about whether the record exists.

The pattern is everywhere:

```ruby
Current.user.accessible_cards.find_by!(number: params[:card_id])   # app/controllers/concerns/card_scoped.rb
Current.user.boards.find(params[:board_id])                        # app/controllers/concerns/board_scoped.rb
Current.user.accessible_columns.find(params[:column_id])           # app/controllers/concerns/column_scoped.rb
Current.account.tags.alphabetically                                # app/controllers/tags_controller.rb
Current.account.users.active.find(params[:id])                     # app/controllers/users_controller.rb
```

There is no Pundit, no CanCanCan, no policy directory. Authorization is a property of the association graph, which means it is impossible to forget: if you write `Current.user.accessible_cards`, you cannot accidentally load someone else's card.

Explicit checks remain for *role*-based rules, where scoping can't express it:

```ruby
def ensure_permission_to_administer_card
  head :forbidden unless Current.user.can_administer_card?(@card)
end
```

Note the predicate lives on `User`, not in the controller.

### Controller concerns as reusable request shapes

```ruby
# app/controllers/concerns/card_scoped.rb
module CardScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_card, :set_board
  end

  private
    def set_card
      @card = Current.user.accessible_cards.find_by!(number: params[:card_id])
    end

    def set_board
      @board = @card.board
    end

    def render_card_replacement
      render turbo_stream: turbo_stream.replace([ @card, :card_container ], partial: "cards/container", method: :morph, locals: { card: @card.reload })
    end

    def capture_card_location
      @source_column = @card.column
      @was_in_stream = @card.awaiting_triage?
    end

    def refresh_stream_if_needed
      if @was_in_stream
        set_page_and_extract_portion_from @board.cards.awaiting_triage.latest.with_golden_first.preloaded
      end
    end
end
```

Every one of the ~20 controllers nested under a card includes this and gets a correctly-scoped `@card`, a `@board`, and shared rendering helpers. One line — `include CardScoped` — replaces boilerplate that would otherwise be copied twenty times and drift.

The other concerns are similarly narrow: `CurrentRequest` (request metadata), `CurrentTimezone`, `SetPlatform`, `TurboFlash`, `ViewTransitions`, `RequestForgeryProtection`, `BlockSearchEngineIndexing`. Each does one thing.

### Strong parameters

The house style is `params.expect`, paired with `wrap_parameters`:

```ruby
wrap_parameters :card, include: %i[ title description image created_at last_active_at ]

def card_params
  params.expect(card: [ :title, :description, :image, :created_at, :last_active_at ])
end
```

`params.expect` (Rails 8) is stricter than the older `params.require(:card).permit(...)`: if the structure isn't what you declared — say an attacker sends an array where a hash was expected — it raises a parameter error resulting in a 400, rather than quietly permitting something. Nested arrays are declared explicitly:

```ruby
# app/controllers/webhooks_controller.rb
def webhook_params
  params
    .expect(webhook: [ :name, :url, subscribed_actions: [] ])
    .merge(board_id: @board.id)
end
```

`wrap_parameters` handles JSON clients posting a flat body: it nests permitted top-level keys under `card` so one `card_params` method serves both HTML forms and API requests.

### Bang or no bang

Fizzy uses bang methods (`create!`, `update!`, `destroy!`) by default and lets Rails' exception handling produce the right status page. There is **no `rescue_from` anywhere in the controller tree.**

Non-bang plus an `if`/`else` appears only where a form must be re-rendered with errors:

```ruby
# app/controllers/webhooks_controller.rb
def create
  @webhook = @board.webhooks.new(webhook_params)

  if @webhook.save
    respond_to do |format|
      format.html { redirect_to @webhook }
      format.json { render :show, status: :created, location: board_webhook_url(@webhook.board, @webhook, format: :json) }
    end
  else
    respond_to do |format|
      format.html { render :new, status: :unprocessable_entity }
      format.json { render json: @webhook.errors, status: :unprocessable_entity }
    end
  end
end
```

The heuristic: if there's a form to re-render, use the non-bang form. Otherwise use the bang and let it raise.

**The rules.**

- Controllers authenticate, load, call one domain method, and respond. Nothing else.
- Load records through `Current.user` / `Current.account` associations. Never `Model.find` on a tenant-owned record.
- Extract repeated `before_action` sets into a `*Scoped` concern.
- `params.expect` with `wrap_parameters`.
- Bang methods by default; non-bang only when re-rendering a form.
- Empty actions are fine.
- No `rescue_from`.

**Your turn.** Write the controller for one transition from §9 as a nested resource with `create` and `destroy`. Build a `*Scoped` concern that loads the parent through `Current.user`. Verify a foreign record 404s rather than 403s.

---

## III.13 Views and ERB

**The idea.** The server renders HTML. Views are ERB — HTML with `<% %>` for logic and `<%= %>` for output. Rails composes pages from small partials, and partials are the unit of reuse.

**How Fizzy does it.** A page template:

```erb
<%# app/views/cards/index.html.erb %>
<% @page_title = @user_filtering.selected_boards_label %>
<% turbo_exempts_page_from_cache %>

<%= render "cards/broadcasts", filter: @filter %>

<% content_for :header do %>
  <h1 class="header__title divider divider--fade full-width" data-bridge--title-target="header">
    <span class="overflow-ellipsis txt-capitalize-first-letter"><%= @user_filtering.selected_boards_label %></span>
  </h1>

  <div class="header__actions header__actions--end">
    <% if board = @filter.single_board %>
      <%= link_to_edit_board board %>
    <% end %>
  </div>
<% end %>

<%= render "filters/settings", filter_url: cards_path, user_filtering: @user_filtering, no_filtering_url: cards_path %>

<%= turbo_frame_tag :cards_container do %>
  <section class="cards cards--grid">
    <div class="cards__list hide-scrollbar">
      <%= with_automatic_pagination :cards_paginated_container, @page do %>
        <%= render "cards/display/previews", cards: @page.records, draggable: true %>
      <% end %>
      <div class="blank-slate">No cards match this filter</div>
    </div>
  </section>
<% end %>
```

Note how little markup there is. The page sets a title, yields a header, and renders three partials. Everything substantial lives in a partial that can be re-rendered on its own — which is exactly what Turbo needs.

**Partial conventions.**

- Filenames start with an underscore: `app/views/cards/_container.html.erb`. You render it as `render "cards/container"`.
- A partial named after a resource takes a local of the same name.
- **Pass locals, not instance variables.** A partial that reads `@card` can only be rendered from a controller that set `@card`; one that takes `card:` can be rendered from anywhere, including a Turbo Stream broadcast from a model or a job.

```erb
<%= render "cards/container", card: @card %>
<%= render "boards/show/column", column: @source_column %>
```

**Collection rendering** with `cached: true` gives you Russian-doll caching, where each item's fragment is fetched from cache in a single multi-read:

```erb
<%# app/views/cards/display/_previews.html.erb %>
<%= render partial: "cards/display/preview", collection: cards, as: :card, locals: { draggable: local_assigns.fetch(:draggable, false) }, cached: true %>
```

`local_assigns.fetch(:draggable, false)` is how a partial reads an optional local with a default.

**A resource partial**, with fragment caching and `dom_id`:

```erb
<%# app/views/cards/comments/_comment.html.erb %>
<% cache comment do %>
  <%= turbo_frame_tag comment, :container, class: { "comment-by-system": comment.creator.system? } do %>
    <div id="<%= dom_id(comment) %>" data-creator-id="<%= comment.creator_id %>" class="comment align-start full-width">
      <figure class="comment__avatar flex-item-no-shrink" aria-hidden="true">
        <%= avatar_tag comment.creator, hidden_for_screen_reader: true %>
      </figure>
      <div class="comment__content flex flex-column flex-item-grow full-width">
        ...
        <%= render "reactions/reactions", reactable: comment %>
      </div>
    </div>
  <% end %>
<% end %>
```

`dom_id(comment)` produces `comment_<id>` — the same identifier Turbo Streams target, so a partial and the stream that replaces it agree without any shared constant.

**The layout** is a shell:

```erb
<%# app/views/layouts/application.html.erb — some attributes and renders omitted %>
<body class="<%= @body_class %>"
  data-controller="local-time timezone-cookie turbo-navigation theme bridge--title bridge--text-size bridge--insets"
  data-action="turbo:morph@window->local-time#refreshAll turbo:before-visit@document->turbo-navigation#rememberLocation">
  <div id="global-container" data-controller="bridge--buttons bridge--overflow-menu">
    <header class="header header--mobile-actions-stack <%= @header_class %>" id="header">
      <a href="#main" class="header__skip-navigation btn" data-turbo="false">Skip to main content</a>
      <%= render "my/menu" if Current.user %>
      <%= yield :header %>
    </header>

    <%= render "layouts/shared/flash" %>

    <main id="main">
      <%= yield %>
    </main>
  </div>

  <footer id="footer" class="hide-on-native">
    <%= yield :footer %>

    <% if Current.user && !@hide_footer_frames %>
      <div id="footer_frames" data-turbo-permanent="true">
        <%= render "bar/bar" %>
        <%= render "my/pins/tray" %>
        <%= render "notifications/tray" %>
      </div>
    <% end %>
  </footer>
</body>
```

`yield` places the page; `yield :header` places whatever the page put in `content_for :header`. `data-turbo-permanent` marks elements Turbo should preserve across navigations — that's how the notification tray keeps its state while you move around the app.

**Helpers** are small and presentational:

```ruby
# app/helpers/cards_helper.rb
module CardsHelper
  def card_article_tag(card, id: dom_id(card, :article), data: {}, **options, &block)
    classes = [
      options.delete(:class),
      ("golden-effect" if card.golden?),
      ("card--postponed" if card.postponed?),
      ("card--active" if card.active?)
    ].compact.join(" ")

    data[:drag_and_drop_top] = true if card.golden? && !card.closed? && !card.postponed?

    tag.article \
      id: id,
      style: "--card-color: #{card.color}; view-transition-name: #{id}",
      class: classes,
      data: data,
      **options,
      &block
  end
end
```

Two things to steal: `("golden-effect" if card.golden?)` yields `nil` when false, and `.compact` drops the nils — a clean way to build a conditional class list. And `style: "--card-color: #{card.color}"` passes a server-computed value into CSS as a custom property, which is the house approach to per-record styling ([§16](#iii16-css-and-assets)).

There are no presenters or decorators. Presentation logic is a helper method, or a small PORO in `app/models` (`Event::Description`, `User::Filtering`) when it has enough substance to deserve a name.

**Forms** are plain `form_with`, with thin domain-aware wrappers where a behavior recurs:

```ruby
# app/helpers/forms_helper.rb
def auto_submit_form_with(**attributes, &)
  data = attributes.delete(:data) || {}
  data[:controller] = "auto-submit #{data[:controller]}".strip

  if block_given?
    form_with **attributes, data: data, &
  else
    form_with(**attributes, data: data) { }
  end
end
```

**The rules.**

- Page templates set up and render partials; markup lives in partials.
- Partials take locals, never instance variables.
- Use `dom_id` for element ids so streams and templates agree.
- Wrap cacheable partials in `<% cache record do %>`; use `cached: true` on collections.
- Helpers are small and presentational; no logic that belongs on a model.
- No decorator or presenter layer.

**Your turn.** Build `index` and `show` for your aggregate. Extract a `_<resource>.html.erb` partial that takes a local, render it from a collection with `cached: true`, and wrap it in `<% cache %>`.

---

## III.14 Hotwire: Turbo

**The idea.** Turbo makes a server-rendered app feel like an SPA without you writing one. Three layers, in increasing specificity:

- **Turbo Drive** intercepts link clicks and form submissions, fetches the new page, and swaps the `<body>` — no full reload, no work from you.
- **Turbo Frames** scope navigation to a region of the page. A link inside a frame replaces only that frame.
- **Turbo Streams** send targeted DOM operations (`replace`, `append`, `remove`, `update`) from a response or a broadcast.

**Turbo Frames.**

```erb
<%= turbo_frame_tag :cards_container do %>
  ...
<% end %>
```

Any link or form inside that frame updates only that frame. A frame with a `src:` loads lazily:

```erb
<%# app/views/boards/show/_column.html.erb %>
<%= column_frame_tag dom_id(column, :cards), src: board_column_path(column.board, column) %>
```

That's a board page rendering instantly with empty columns, each of which fetches its own cards. The wrapper helper adds house defaults:

```ruby
# app/helpers/columns_helper.rb
def column_frame_tag(id, src: nil, data: {}, **options, &block)
  data = data.with_defaults \
    drag_and_drop_refresh: true,
    controller: "frame",
    action: "turbo:before-frame-render->frame#morphRender turbo:before-morph-element->frame#morphReload"
  options[:refresh] = :morph if src.present?
  turbo_frame_tag(id, src: src, data: data, **options, &block)
end
```

**Turbo Streams from a response.** Return `format.turbo_stream` and Rails renders `<action>.turbo_stream.erb`:

```erb
<%# app/views/cards/comments/create.turbo_stream.erb %>
<%= turbo_stream.before [ @card, :new_comment ], partial: "cards/comments/comment", locals: { comment: @comment } %>

<%= turbo_stream.update [ @card, :new_comment ], partial: "cards/comments/new", locals: { card: @card } %>
```

```erb
<%# app/views/cards/comments/destroy.turbo_stream.erb %>
<%= turbo_stream.remove [ @comment, :container ] %>
```

The `[ @comment, :container ]` array resolves to the same DOM id as `turbo_frame_tag comment, :container` in the partial. Target ids are derived, never hand-written.

**`method: :morph`** replaces content by diffing rather than wholesale swapping, so scroll position, focus, and open dialogs survive:

```erb
<%# app/views/cards/closures/create.turbo_stream.erb %>
<%= turbo_stream.replace("closed-cards", partial: "boards/show/closed", method: :morph, locals: { board: @card.board }) %>

<% if @source_column %>
  <%= turbo_stream.replace(dom_id(@source_column), partial: "boards/show/column", method: :morph, locals: { column: @source_column }) %>
<% elsif @was_in_stream %>
  <%= turbo_stream.replace("maybe", partial: "boards/show/stream", method: :morph, locals: { board: @card.board, page: @page }) %>
<% end %>

<%= turbo_stream.replace([ @card, :card_container ], partial: "cards/container", method: :morph, locals: { card: @card.reload }) %>
```

Read that file as the answer to "what on this page is now wrong?" Closing a card changes the card itself, the Done column, and wherever the card used to be. Three replacements, conditionally.

Note `@card.reload` — the in-memory card was mutated inside `close`, and `reload` guarantees the partial renders committed state including the new association.

**Turbo Streams from a broadcast.** For *other* people's browsers, the model broadcasts:

```ruby
# app/models/card/broadcastable.rb
module Card::Broadcastable
  extend ActiveSupport::Concern

  included do
    broadcasts_refreshes

    before_update :remember_if_preview_changed
  end
end

# app/models/board/broadcastable.rb
module Board::Broadcastable
  extend ActiveSupport::Concern

  included do
    broadcasts_refreshes
    broadcasts_refreshes_to ->(board) { [ board.account, :all_boards ] }
  end
end
```

`broadcasts_refreshes` sends a lightweight "refresh" signal on every change; subscribed pages re-request and morph themselves. It's dramatically simpler than broadcasting specific HTML for every possible change, and morphing makes it cheap. The view subscribes:

```erb
<%# app/views/cards/show.html.erb %>
<%= turbo_stream_from @card %>
<%= turbo_stream_from @card, :activity %>
```

```erb
<%# app/views/cards/_broadcasts.html.erb — subscribe dynamically based on a filter %>
<% if filter.boards.any? %>
  <% filter.boards.each do |board| %>
    <%= turbo_stream_from board %>
  <% end %>
<% else %>
  <%= turbo_stream_from [ Current.account, :all_boards ] %>
<% end %>
```

Where a specific update is better than a refresh, broadcast it explicitly — with `_later` variants so the rendering happens in a job:

```ruby
# app/models/notification.rb
after_create_commit  -> { broadcast_prepend_later_to user, :notifications, target: "notifications" }
after_update_commit  -> { broadcast_update }
after_destroy_commit -> { broadcast_remove_to user, :notifications }
```

**Choosing a response type:**

| Situation | Response |
|---|---|
| Small in-page change, same user | `format.turbo_stream` |
| Navigation to a different page | `redirect_to` (Turbo Drive handles it) |
| Form failed validation | `render :new, status: :unprocessable_entity` |
| Other users need to see it | broadcast from the model |
| API client | `format.json` |

That `status: :unprocessable_entity` is mandatory, not decorative — Turbo ignores a 200 response to a form submission and only re-renders on a 4xx/5xx.

**The rules.**

- Turbo Drive by default. Reach for frames when a region should navigate independently, streams when a specific element must change.
- Use `method: :morph` for replacements inside pages with state worth preserving.
- Derive stream targets with `dom_id` or the `[ record, :suffix ]` form.
- `broadcasts_refreshes` first; explicit broadcasts only when a refresh is too coarse.
- Broadcast with `_later` variants so rendering happens off the request.
- Failed form submissions must return `:unprocessable_entity`.

**Your turn.** Convert your transition controller to respond with `format.turbo_stream` and write the `.turbo_stream.erb` that updates the affected elements. Then add `broadcasts_refreshes` and `turbo_stream_from` and watch two browser windows stay in sync.

---

## III.15 Stimulus

**The idea.** Some behavior genuinely belongs in the browser: autosave timers, keyboard shortcuts, drag and drop, focus management. Stimulus attaches small JavaScript controllers to server-rendered HTML via `data-` attributes. It never owns state or rendering — the server still does that.

**How Fizzy does it.** Seventy controllers, most of them 10–40 lines.

```javascript
// app/javascript/controllers/reaction_emoji_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "input" ]

  insertEmoji(event) {
    const emojiChar = event.target.getAttribute("data-emoji")
    const value = this.inputTarget.value
    const newValue = `${value}${emojiChar}`

    if (this.inputTarget.maxLength > 0 && newValue.length <= this.inputTarget.maxLength) {
      this.inputTarget.value = newValue
    }

    this.inputTarget.focus()
  }
}
```

Wired up from the view:

```erb
<%# app/views/reactions/new.html.erb — attributes trimmed %>
<%= form_with model: [ *reaction_path_prefix_for(@reactable), Reaction.new ],
      data: { controller: "form reaction-emoji", ... } do |form| %>
  <%= form.text_field :content, ...,
        data: { form_target: "input", reaction_emoji_target: "input", ... } %>
<% end %>

<%# app/views/reactions/_menu.html.erb %>
<% EmojiHelper::REACTIONS.each do |character, title| %>
  <%= tag.button character, title: title, class: "reaction__emoji-btn btn btn--circle borderless hide-focus-ring", type: "button", data: { action: "reaction-emoji#insertEmoji dialog#close", emoji: character } %>
<% end %>
```

The naming rules, which Stimulus enforces:

| File | `data-controller` | Target | Action |
|---|---|---|---|
| `reaction_emoji_controller.js` | `reaction-emoji` | `data-reaction-emoji-target="input"` | `data-action="reaction-emoji#insertEmoji"` |
| `bridge/form_controller.js` | `bridge--form` | `data-bridge--form-target="..."` | `data-action="bridge--form#submit"` |

Underscores become dashes; subdirectories become `--`.

Note `data: { controller: "form reaction-emoji" }` and `data-action="reaction-emoji#insertEmoji dialog#close"` — multiple controllers on one element, multiple actions on one event. Composition instead of one big controller.

A more substantial one, showing lifecycle hooks and private fields:

```javascript
// app/javascript/controllers/auto_save_controller.js
import { Controller } from "@hotwired/stimulus"
import { submitForm } from "helpers/form_helpers"

const AUTOSAVE_INTERVAL = 3000

export default class extends Controller {
  #timer

  // Lifecycle

  disconnect() {
    this.submit()
  }

  // Actions

  async submit() {
    if (this.#dirty) {
      await this.#save()
    }
  }

  change(event) {
    if (event.target.form === this.element && !this.#dirty) {
      this.#scheduleSave()
    }
  }

  // Private

  #scheduleSave() {
    this.#timer = setTimeout(() => this.#save(), AUTOSAVE_INTERVAL)
  }

  async #save() {
    this.#resetTimer()
    await submitForm(this.element)
  }

  #resetTimer() {
    clearTimeout(this.#timer)
    this.#timer = null
  }

  get #dirty() {
    return !!this.#timer
  }
}
```

Used with several actions bound to one form:

```erb
<%# app/views/cards/container/_content.html.erb %>
<%= form_with model: card, id: "card_form", data: { controller: "autoresize auto-save" } do |form| %>
  ... data: { action: "input->autoresize#resize auto-save#change blur->auto-save#submit keydown.enter->auto-save#submit:prevent" } ...
```

Three conventions worth adopting: `// Lifecycle` / `// Actions` / `// Private` section comments mirror the Ruby method-ordering rule; `#private` JavaScript fields mark internals the way `private` does in Ruby; and shared logic (`submitForm`) lives in `app/javascript/helpers/`, not duplicated across controllers.

**No build step.** Importmap maps bare module specifiers to files the browser fetches directly:

```ruby
# config/importmap.rb
pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"

pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/helpers", under: "helpers"
pin_all_from "app/javascript/lib", under: "lib"
pin_all_from "app/javascript/initializers", under: "initializers"
```

```javascript
// app/javascript/application.js
import "@hotwired/turbo-rails"
import "@hotwired/hotwire-native-bridge"
import "initializers"
import "controllers"

import "lexxy"
import "@rails/actiontext"
import "lib/action_pack/passkey"
```

No webpack, no esbuild, no `node_modules`, no build cache to bust in CI. Add a file to `app/javascript/controllers/` and it's live.

**The rules.**

- Stimulus controllers connect HTML to behavior. They don't own application state and don't render templates.
- Keep them small and single-purpose; compose several on one element rather than growing one.
- Name after behavior (`auto-save`, `element-removal`), not after the page.
- Extract shared functions to `app/javascript/helpers/`.
- If you're building a client-side model layer, stop — that work belongs on the server.

**Your turn.** Write one Stimulus controller for a genuine browser-side behavior in your app. Keep it under 40 lines. If it's growing, ask what the server should have rendered instead.

---

## III.16 CSS and assets

**The idea.** Plain CSS, delivered by Propshaft, using the platform directly. No Sass, no Tailwind, no PostCSS, no CSS-in-JS, no bundler. Modern CSS has nesting, custom properties, and cascade layers — the things preprocessors were invented to provide.

**How Fizzy does it.** One entry point in the layout:

```erb
<%# app/views/layouts/shared/_head.html.erb %>
<%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
```

That expands to every `.css` file under `app/assets/`. The codebase is split into ~60 small files by UI concern — `buttons.css`, `cards.css`, `header.css`, `trays.css`, `notifications.css`, `search.css`, `native.css`, `ios.css` — not one giant stylesheet and not one per page.

**Cascade layers set precedence explicitly.**

```css
/* app/assets/stylesheets/_global.css */
@layer reset, base, components, modules, utilities, native, platform;
```

Every file wraps its rules in a layer:

```css
@layer components {
  .btn { ... }
}
```

Layer order beats specificity, so a `utilities` rule wins over a `components` rule regardless of selector complexity. That's what eliminates specificity wars and `!important` from a codebase this size.

**Design tokens live in `_global.css`:**

```css
:root {
  /* Spacing */
  --inline-space: 1ch;
  --inline-space-half: calc(var(--inline-space) / 2);
  --inline-space-double: calc(var(--inline-space) * 2);
  --block-space: 1rem;
  --block-space-half: calc(var(--block-space) / 2);
  --block-space-double: calc(var(--block-space) * 2);

  /* Text */
  --text-small: 0.85rem;
  --text-normal: 1rem;
  --text-large: 1.5rem;

  /* Components */
  --btn-size: 2.65em;
  --tray-size: clamp(12rem, 25dvw, 24rem);

  /* Focus rings for keyboard navigation */
  --focus-ring-color: var(--color-link);
  --focus-ring-offset: 1px;
  --focus-ring-size: 2px;
}
```

Note `--inline-space: 1ch` — spacing derived from the font's character width, so it scales with type. And the media query nested directly inside `:root` that rescales the type ramp on small screens: one block, no component-level breakpoints.

Colors are semantic (`--color-canvas`, `--color-ink`, `--color-link`, `--color-negative`, `--color-positive`), built on OKLCH. Dark mode overrides the variables, not the components:

```css
html[data-theme="dark"] { ... }
@media (prefers-color-scheme: dark) { html:not([data-theme]) { ... } }
```

**Naming is BEM-ish:** `.card` (block), `.card__header` (element), `.btn--link` (modifier).

**Custom properties are the extension mechanism.** Components declare their knobs at the top of the root rule:

```css
.card {
  --card-bg-color: color-mix(in srgb, var(--card-color) 4%, var(--color-canvas));
  --card-content-color: color-mix(in srgb, var(--card-color) 30%, var(--color-ink));
  --card-padding-inline: var(--inline-space-double);
}
```

Then the server sets per-instance values inline:

```ruby
tag.article id: id, style: "--card-color: #{card.color}; view-transition-name: #{id}", ...
```

**This is the one place inline styles are correct here** — setting a custom property from server data. Inline `style="padding: …; border: …"` blocks are not.

**Style from real state, not extra classes.** The codebase selects on the DOM's own semantics:

```css
.btn:has(input:checked) { ... }
.tray:has(.tray__dialog[open]) { ... }
```

Along with `[hidden]`, `[disabled]`, `[aria-selected]`, `[aria-busy]`, `[data-platform~=ios]`. Add a state class only when no semantic attribute exists.

**Logical properties everywhere:** `padding-inline`, `margin-block`, `inline-size`, `border-inline-start` — not `left`, `right`, `width`.

**The house shape for a new component:**

```css
@layer components {
  .example {
    --example-padding: var(--block-space);
    --example-bg: var(--color-canvas);

    background: var(--example-bg);
    color: var(--color-ink);
    padding: var(--example-padding);
  }

  .example__title {
    font-size: var(--text-large);
    font-weight: 900;
  }

  .example--active {
    --example-bg: var(--color-selected);
  }

  .example:has(button:focus-visible) {
    --focus-ring-color: var(--color-link);
  }
}
```

**The rules.**

- Plain CSS with native nesting. No Sass, no Tailwind.
- Every rule inside a `@layer`, usually `components`.
- Consume semantic tokens; add a global token only when it's genuinely shared.
- BEM-ish naming, scoped under a component root.
- Push variation into custom properties, including server-set inline ones.
- Logical properties, modern units, `:has()` over state classes.
- Utilities for generic composition; component classes for the component.
- Keep native/platform overrides in the `native` and `platform` layers.

**Your turn.** Create `_global.css` with a spacing scale, a type ramp, and semantic colors, plus the `@layer` declaration. Build one component following the shape above, and pass one per-record value in through an inline custom property.

---
## III.17 Background jobs

**The idea.** Jobs are for *timing*, not for logic. They answer "do this later, retry it if it fails, and don't make the user wait." What gets done still belongs on the model.

**How Fizzy does it.** `ApplicationJob` is empty — the commented-out lines document the options rather than enabling them:

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
```

Every job is one line of work:

```ruby
# app/jobs/card/clean_inaccessible_data_job.rb
class Card::CleanInaccessibleDataJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(card)
    card.clean_inaccessible_data
  end
end

# app/jobs/webhook/delivery_job.rb
class Webhook::DeliveryJob < ApplicationJob
  queue_as :webhooks
  discard_on ActiveJob::DeserializationError

  def perform(delivery)
    delivery.deliver
  end
end

# app/jobs/mention/create_job.rb
class Mention::CreateJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(record, mentioner:)
    record.create_mentions(mentioner:)
  end
end
```

`discard_on ActiveJob::DeserializationError` says: if the record is gone by the time this runs, that's fine, drop the job. Correct for almost every job whose subject a user can delete.

**The `_later` / `_now` pattern.** The style guide gives the canonical shape:

```ruby
module Event::Relaying
  extend ActiveSupport::Concern

  included do
    after_create_commit :relay_later
  end

  def relay_later
    Event::RelayJob.perform_later(self)
  end

  def relay_now
    # ...
  end
end

class Event::RelayJob < ApplicationJob
  def perform(event)
    event.relay_now
  end
end
```

`_later` always means "this enqueues a job." That's a strict suffix — reading `remove_inaccessible_notifications_later` in a model, you know instantly it's asynchronous without opening anything.

`_now` is used only where the bare name would be ambiguous. In practice most synchronous counterparts are just named for what they do — `deliver`, `notify_recipients`, `clean_inaccessible_data`.

Why this matters: the *caller* stays readable, the *logic* stays testable synchronously, and the job class holds nothing worth testing.

**Where jobs get enqueued.** From `after_*_commit` callbacks, so the transaction has committed and the record really exists:

```ruby
# app/models/concerns/notifiable.rb
after_create_commit :notify_recipients_later

# app/models/concerns/searchable.rb
after_create_commit :create_in_search_index
after_update_commit :update_in_search_index
after_destroy_commit :remove_from_search_index

# app/models/webhook/delivery.rb
after_create_commit :deliver_later
```

There's also a global safety net, from [§5](#iii5-multi-tenancy):

```ruby
self.enqueue_after_transaction_commit = true
```

With that set, even a job enqueued from inside a transaction waits for the commit. It's what makes `handle_board_change` safe:

```ruby
# app/models/card.rb
def handle_board_change
  old_board = account.boards.find_by(id: board_id_before_last_save)

  transaction do
    update! column: nil
    track_board_change_event(old_board.name)
    grant_access_to_assignees unless board.all_access?
  end

  remove_inaccessible_notifications_later
  clean_inaccessible_data_later
end
```

**Solid Queue** stores jobs in a database table, in its own database. No Redis. Monitor it at `/admin/jobs` via Mission Control.

**Recurring tasks** are declared in YAML:

```yaml
# config/recurring.yml
production: &production
  # Application functionality: notifications and summaries
  deliver_bundled_notifications:
    command: "Notification::Bundle.deliver_all_later"
    schedule: every 30 minutes

  # Application cleanup
  auto_postpone_all_due:
    command: "Card.auto_postpone_all_due"
    schedule: every hour at minute 50
  delete_unused_tags:
    class: DeleteUnusedTagsJob
    schedule: every day at 04:02

  # Operations cleanup and backups
  cleanup_webhook_deliveries:
    command: "Webhook::Delivery.cleanup"
    schedule: every 15 minutes
  incineration:
    class: "Account::IncinerateDueJob"
    schedule: every 8 hours at minute 16

beta: &beta
  clear_solid_queue_finished_jobs:
    command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
    schedule: every hour at minute 12

staging: *beta
development: *production
```

`command:` calls a class method directly — no job class needed when the target is already a model method. `class:` names a real job. Both appear here; use `command:` when the domain method already exists and is idempotent.

Notice the staggered minutes (`at minute 50`, `at minute 12`, `at minute 20`, `at minute 25`). That's deliberate: nothing lands on the hour together.

**Long-running work** uses `ActiveJob::Continuable` so a deploy doesn't restart it from zero:

```ruby
# app/jobs/event/webhook_dispatch_job.rb
def perform(event)
  step :dispatch do |step|
    Webhook.active.triggered_by(event).find_each(start: step.cursor) do |webhook|
      webhook.trigger(event)
      step.advance! from: webhook.id
    end
  end
end
```

**The rules.**

- Jobs are one line: `record.domain_method`.
- The `_later` suffix means "enqueues a job," always.
- Enqueue from `after_*_commit`, never `after_create`.
- `discard_on ActiveJob::DeserializationError` when the subject can be deleted.
- Use `queue_as` to separate slow or external work.
- Batch with `find_each`; checkpoint long fan-outs with `ActiveJob::Continuable`.
- Jobs are not your business layer. If a job has an `if`, it's probably in the wrong place.

**Your turn.** Move one slow side effect into a job. Add a `_later` method on the model, an `after_create_commit` that calls it, and a job that calls the synchronous method. Assert the enqueue in a test with `assert_enqueued_with`.

---

## III.18 Mailers

**The idea.** A mailer is a delivery adapter: it gathers what the template needs and hands it to Action Mailer. It is not a place for domain logic.

**How Fizzy does it.**

```ruby
# app/mailers/application_mailer.rb
class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAILER_FROM_ADDRESS", "Fizzy <support@fizzy.do>")

  layout "mailer"
  append_view_path Rails.root.join("app/views/mailers")
  helper AvatarsHelper, HtmlHelper

  private
    def default_url_options
      if Current.account
        super.merge(script_name: Current.account.slug)
      else
        super
      end
    end
end
```

That `default_url_options` override is the piece worth stealing. Mailers render outside a request, so nothing has set the URL prefix — every link would point at the wrong tenant. Overriding it once in the base class means no individual mailer or template has to think about tenancy.

A concrete mailer:

```ruby
# app/mailers/notification/bundle_mailer.rb
class Notification::BundleMailer < ApplicationMailer
  include Mailers::Unsubscribable

  helper NotificationsHelper

  def notification(bundle)
    @user = bundle.user
    @bundle = bundle
    @notifications = bundle.notifications
      .preload(:card, :creator, source: [ :board, :creator ])
      .reject { |n| n.source.nil? || n.card.nil? }
    @unsubscribe_token = @user.generate_token_for(:unsubscribe)

    if @notifications.any?
      mail \
        to: bundle.user.identity.email_address,
        subject: "Fizzy#{ " (#{ Current.account.name })" if @user.identity.accounts.many? }: New notifications"
    end
  end
end
```

Assign ivars, call `mail`. Note the `preload` — mailers hit N+1 problems just like views. And note that calling `mail` conditionally means "send nothing" is expressible without raising.

**Unsubscribe tokens** use `generates_token_for`, which produces a signed, expiring token with no token table:

```ruby
# app/models/user/notifiable.rb
generates_token_for :unsubscribe, expires_in: 1.month
```

The link embeds `@user.generate_token_for(:unsubscribe)`; the controller calls `User.find_by_token_for(:unsubscribe, params[:token])`. The token is invalidated automatically if the underlying record changes in a way you configure.

**Always deliver asynchronously:**

```ruby
# app/models/identity.rb
magic_links.create!(attributes).tap do |magic_link|
  MagicLinkMailer.sign_in_instructions(magic_link).deliver_later
end
```

`deliver_later` enqueues; `deliver_now` blocks the request on your SMTP server.

**In development**, `bin/rails dev:email` toggles `letter_opener`, which pops sent mail into a browser tab instead of sending it. Previews live in `test/mailers/previews/` and render at `/rails/mailers`.

**The rules.**

- Mailers gather data and call `mail`. No domain logic.
- Override `default_url_options` centrally for tenancy.
- `deliver_later`, always.
- Preload associations used by templates.
- `generates_token_for` for unsubscribe and other one-off links.
- Write previews; they're the cheapest way to iterate on email design.

**Your turn.** Add a mailer for one notification in your app. Deliver it with `deliver_later` from an `after_create_commit`. Add a preview and view it at `/rails/mailers`.

---

## III.19 JSON alongside HTML

**The idea.** The JSON API is the same application, seen through a different renderer. Same routes, same controllers, same authorization, same domain methods. Only the view layer differs.

**How Fizzy does it.** There is no `Api::` namespace and no version prefix. Every controller you've already seen handles both:

```ruby
def update
  @card.update! card_params

  respond_to do |format|
    format.turbo_stream
    format.json { render :show }
  end
end
```

Rendering is jbuilder — a Ruby DSL that builds JSON:

```ruby
# app/views/cards/_card.json.jbuilder
json.cache! card do
  json.(card, :id, :number, :title, :status)
  json.description card.description.to_plain_text
  json.description_html card.description.to_s
  json.image_url card.image.presence && url_for(card.image)
  json.has_attachments card.has_attachments?

  json.tags card.tags.pluck(:title).sort

  json.closed card.closed?
  json.postponed card.postponed?
  json.golden card.golden?
  json.last_active_at card.last_active_at.utc
  json.created_at card.created_at.utc

  json.url card_url(card)

  json.board card.board, partial: "boards/board", as: :board
  json.column card.column, partial: "columns/column", as: :column if card.column
  json.creator card.creator, partial: "users/user", as: :user
  json.assignees card.assignees.limit(5), partial: "users/user", as: :user
  json.has_more_assignees card.assignees.size > 5

  json.comments_url card_comments_url(card)
  json.reactions_url card_reactions_url(card)
end
```

- `json.(card, :id, :number, :title, :status)` is shorthand for extracting several attributes.
- Partials compose exactly like ERB partials, and get reused across `show`, `index`, and `create`.
- `json.cache! card do` is fragment caching for JSON — same invalidation, same `touch: true` cascade.
- The payload includes URLs (`json.url`, `json.comments_url`), so clients can navigate instead of constructing paths.

And the two templates that use it are one line each:

```ruby
# app/views/cards/index.json.jbuilder
json.array! @page.records, partial: "cards/card", as: :card

# app/views/cards/show.json.jbuilder
json.partial! "cards/card", card: @card
json.steps @card.steps, partial: "cards/steps/step", as: :step
```

**Authentication** is bearer tokens, restricted to JSON requests — see [§6](#iii6-identity-membership-authentication).

**Errors** use Rails' default serialization, no envelope:

```ruby
format.json { render json: @webhook.errors, status: :unprocessable_entity }
```

**Pagination** is `geared_pagination`, which sets a `Link` header rather than wrapping the payload:

```ruby
def index
  set_page_and_extract_portion_from @filter.cards
end
```

The response body stays a plain array, and the client follows `Link: <...>; rel="next"`. That keeps the JSON shape identical whether or not there's another page.

**Status codes** carry meaning: `201 Created` with a `location:`, `204 No Content` for a successful state change with nothing to return, `403 Forbidden` for role failures, `404` for anything out of scope, `422` for validation errors.

**The rules.**

- Same controllers, same routes, same authorization. `respond_to` branches at the end.
- jbuilder templates; partials for shared shapes.
- No API version prefix until the API becomes a separate product with separate consumers you don't control.
- Pagination in headers, not in the body.
- `json.cache!` for anything expensive.
- Use real HTTP status codes.

**Your turn.** Add `show.json.jbuilder` and `index.json.jbuilder` for your aggregate, plus a `_<resource>.json.jbuilder` partial. Add `format.json` branches. Test with `as: :json`.

---

## III.20 Search, filters, pagination, caching

### Search

**The idea.** Full-text search does not require Elasticsearch. Both MySQL and SQLite have full-text indexes, and using them means one less system to run, secure, and keep in sync.

**How Fizzy does it.** A denormalized `Search::Record` table holds the searchable projection of any model, kept up to date by a concern:

```ruby
# app/models/concerns/searchable.rb
module Searchable
  extend ActiveSupport::Concern

  SEARCH_CONTENT_LIMIT = 32.kilobytes

  included do
    after_create_commit :create_in_search_index
    after_update_commit :update_in_search_index
    after_destroy_commit :remove_from_search_index
  end

  private
    def search_record_attributes
      {
        account_id: account_id,
        searchable_type: self.class.name,
        searchable_id: id,
        card_id: search_card_id,
        board_id: search_board_id,
        title: search_title,
        content: search_record_content,
        created_at: created_at
      }
    end

    def search_record_class
      Search::Record.for(account_id)
    end

  # Models must implement these methods:
  # - account_id: returns the account id
  # - search_title: returns title string or nil
  # - search_content: returns content string
  # - search_card_id: returns the card id (self.id for cards, card_id for comments)
  # - search_board_id: returns the board id
  # - searchable?: returns whether this record should be indexed
end
```

That trailing comment block is the interface. Ruby has no abstract methods, so the convention is to document the contract where the includer will see it. The implementing side is small:

```ruby
# app/models/card/searchable.rb
module Card::Searchable
  extend ActiveSupport::Concern

  included do
    include ::Searchable

    scope :mentioning, ->(query, user:) do
      search_record_class = Search::Record.for(user.account_id)
      joins(search_record_class.card_join).merge(search_record_class.for_query(query, user: user))
    end
  end

  def search_title
    title
  end

  def search_content
    description.to_plain_text
  end

  def searchable?
    published?
  end
end
```

**Sharding.** `Search::Record.for(account_id)` picks one of 16 shard tables by hashing the account id. Full-text indexes are expensive to maintain; splitting them keeps each one small and keeps one enormous tenant from degrading everyone else's searches.

**Authorization survives search**, because it's the same scoping rule as everywhere else:

```ruby
scope :for_query, ->(query, user:) do
  query = Search::Query.wrap(query)

  if query.valid? && user.board_ids.any?
    matching(query.to_s, user.account_id).where(account_id: user.account_id, board_id: user.board_ids)
  else
    none
  end
end
```

`where(account_id: ..., board_id: user.board_ids)` and `none` for an invalid query — a search can never surface a record the user couldn't otherwise reach.

### Filters as domain objects

**The idea.** A filter with a dozen optional criteria will metastasize into a controller method if you let it. Give it a name and a class.

**How Fizzy does it.** `Filter` is a real model — filters are saved and shared — and it builds its query in one readable method:

```ruby
# app/models/filter.rb
def cards
  @cards ||= begin
    result = creator.accessible_cards.preloaded.published
    result = result.indexed_by(indexed_by)
    result = result.sorted_by(sorted_by)
    result = result.where(id: card_ids) if card_ids.present?
    result = result.where.missing(:not_now) unless include_not_now_cards?
    result = result.open unless include_closed_cards?
    result = result.unassigned if assignment_status.unassigned?
    result = result.assigned_to(assignees.ids) if assignees.present?
    result = result.where(creator_id: creators.ids) if creators.present?
    result = result.where(board: boards.ids) if boards.present?
    result = result.tagged_with(tags.ids) if tags.present?
    result = result.where(cards: { created_at: creation_window }) if creation_window
    result = result.closed_at_window(closure_window) if closure_window
    result = result.closed_by(closers) if closers.present?
    result = terms.reduce(result) do |result, term|
      result.mentioning(term, user: creator)
    end

    result.distinct
  end
end
```

Fourteen optional criteria, one method, and it reads like a spec. Two things make that possible: it starts from `creator.accessible_cards` (authorization first, so no criterion can widen the scope), and every clause is a named scope defined in the concern that owns it. The complexity lives in one place and is testable without a controller.

The controller's whole involvement:

```ruby
# app/controllers/concerns/filter_scoped.rb
def set_filter
  if params[:filter_id].present?
    @filter = Current.user.filters.find(params[:filter_id])
  else
    @filter = Current.user.filters.from_params filter_params
  end
end

def filter_params
  params.with_defaults(**Filter.default_values).permit(*Filter::PERMITTED_PARAMS)
end
```

And then `set_page_and_extract_portion_from @filter.cards`.

### Pagination

`geared_pagination` — a 37signals gem that ramps page size (small first page for fast first paint, larger later pages). One call in the controller:

```ruby
set_page_and_extract_portion_from @filter.cards
```

Then `@page.records` in the view and a `Link` header for API clients.

### Caching

Three layers, all keyed on the same thing: `updated_at`, kept correct by `touch: true`.

**HTTP caching / ETags.** `ApplicationController` composes global etag components, and concerns add their own:

```ruby
# app/controllers/application_controller.rb
etag { "v1" }
stale_when_importmap_changes

# app/controllers/concerns/authentication.rb
etag { Current.identity.id if authenticated? }

# app/controllers/concerns/current_timezone.rb
etag { timezone_from_cookie }
```

Actions add the data that varies:

```ruby
# app/controllers/boards/columns_controller.rb
def index
  @columns = @board.columns.sorted
  fresh_when etag: @columns
end

def show
  set_page_and_extract_portion_from @column.cards.active.latest.with_golden_first.preloaded
  fresh_when etag: @page.records
end
```

`fresh_when` computes the ETag and returns `304 Not Modified` when the client already has it — no rendering at all. Use `stale?` when the branch is conditional:

```ruby
# app/controllers/users/avatars_controller.rb
elsif stale? @user, cache_control: cache_control
  render_initials
end

private
  def cache_control
    if @user == Current.user
      {}
    else
      { max_age: 30.minutes, stale_while_revalidate: 1.week }
    end
  end
```

**Fragment caching:**

```erb
<% cache card do %> ... <% end %>
<% cache [ Current.identity, accounts, Current.account ] do %> ... <% end %>
```

**Cache keys on POROs.** Objects that aren't Active Record can still participate:

```ruby
# app/models/filter.rb
def cache_key
  ActiveSupport::Cache.expand_cache_key params_digest, "filter"
end

# app/models/user/filtering.rb
def cache_key
  ActiveSupport::Cache.expand_cache_key([ user, filter, expanded?, boards, tags, users, filters ], "user-filtering")
end
```

**The rules.**

- Use the database's full-text search before adding a search cluster.
- Denormalize search content into its own table, maintained by `after_*_commit` callbacks.
- Search results are scoped by the same authorization rules as everything else.
- Complex filtering becomes an object, not a controller method.
- Start every query from an authorized scope.
- `fresh_when` on read actions; `<% cache %>` on expensive partials.
- Never invalidate a cache manually — `touch: true` does it.

**Your turn.** Give your aggregate a filter object that builds its query from optional criteria, starting from an authorized scope. Add `fresh_when` to your index action and confirm a second request returns 304.

---

## III.21 Files and rich text

**The idea.** Active Storage handles file attachments; Action Text handles rich text with embedded attachments. Both are in the box.

**How Fizzy does it.**

```ruby
# app/models/card.rb
has_one_attached :image, dependent: :purge_later
has_rich_text :description
```

Two lines. `has_one_attached` gives you `card.image`, `card.image.attached?`, `card.image=`, variants, and direct uploads. `has_rich_text` gives a `description` backed by an `ActionText::RichText` record that can contain formatted text and embedded files.

`dependent: :purge_later` means deleting the card enqueues the blob deletion rather than doing it inline.

Consuming rich text is format-aware:

```ruby
json.description card.description.to_plain_text
json.description_html card.description.to_s
```

Fizzy uses **Lexxy** as the editor rather than Trix, and adapts it into the app's design tokens via `--lexxy-*` variables in `lexxy.css` — the house approach to third-party UI: bridge it into your token system rather than forking it.

**File access is a security concern.** Rails' default blob URLs are signed but not authorized — anyone with the URL can fetch the file. Fizzy patches that:

```
lib/rails_ext/active_storage_authorization.rb
lib/rails_ext/active_storage_blob_service_url_for_direct_upload_expiry.rb
lib/rails_ext/active_storage_analyze_job_skip_detached.rb
lib/rails_ext/active_storage_analyze_job_suppress_broadcasts.rb
```

This is the pattern to internalize: attachments inherit the access rules of the record they belong to, and if the framework doesn't enforce that, you extend the framework rather than routing every file through a custom controller.

**Variants are processed immediately**, configured by reopening Action Text's own concern:

```ruby
# config/initializers/action_text.rb — abridged
module ActionText
  module Extensions
    module RichText
      extend ActiveSupport::Concern

      included do
        # This overrides the default :embeds association!
        has_many_attached :embeds do |attachable|
          ::Attachments::VARIANTS.each do |variant_name, variant_options|
            attachable.variant variant_name, **variant_options, process: :immediately
          end
        end
      end
    end
  end
end

ActiveSupport.on_load(:action_text_rich_text) do
  include ActionText::Extensions::RichText
end
```

`process: :immediately` rather than lazily, because lazy generation on a read replica would try to write from a read-only connection.

**Storage accounting.** Fizzy tracks per-account storage as a ledger — `app/models/concerns/storage/tracked.rb`, `app/models/account/storage.rb`, `app/models/board/storage.rb` — rather than summing blob sizes on demand. Batched, incremental, and cheap to read:

```ruby
# app/models/account/storage.rb
boards.sum { |board| board.send(:calculate_real_storage_bytes) }
```

The lesson generalizes: when a number is expensive to compute and read constantly, maintain it as data.

**The rules.**

- `has_one_attached` / `has_many_attached` / `has_rich_text` — don't build an uploads system.
- Attachments inherit the authorization of their parent record. Verify this; the default doesn't.
- `dependent: :purge_later` so deletes don't block.
- Adapt third-party editor CSS into your tokens rather than forking it.
- Track expensive aggregates as data, updated incrementally.

**Your turn.** Add an attachment and a rich text field to your aggregate. Render both. Confirm that a signed-out user cannot fetch the attachment URL — and if they can, fix it.

---

## III.22 Advanced subsystems

These are the parts of Fizzy you won't need on day one but should know exist, because each demonstrates a principle worth generalizing.

### Import and export

Accounts can export their entire contents and import them into another instance — that's what makes moving between the hosted product and a self-hosted one real rather than theoretical. The models live in `app/models/account/data_transfer/` and `app/models/zip_file/`.

Two constraints shape the design: exports can exceed 500GB, and instances may store to local disk *or* S3, so both must work everywhere.

- **`zip_kit`** streams ZIP output rather than building it in memory or on disk.
- Work is chunked into resumable jobs, not one long-running process.
- Storage is an abstraction with local and S3 implementations.

The generalizable rule: when data volume is unbounded, stream and checkpoint. Never `to_a` something a customer controls the size of.

There's a good bug in the git history illustrating why exports are subtle. `Column::Colored` overrides the `color` accessor to return a `Color` struct, so `record.to_json` serialized `{"name":"Blue","value":"var(--color-card-default)"}` instead of the raw CSS string, and re-importing lost custom colors. The fix:

```
Export raw DB values via record.attributes.slice(*attributes).to_json
```

**Serialization for data transfer must read raw attributes, not accessors.** Accessors are presentation.

### Push notifications

Web Push via VAPID, in `lib/web_push/` and `app/models/push/`. Subscriptions are records; delivery is a job. Development needs a key pair:

```ruby
vapid_key = WebPush.generate_key

puts "VAPID_PRIVATE_KEY=#{vapid_key.private_key}"
puts "VAPID_PUBLIC_KEY=#{vapid_key.public_key}"
```

### Native and PWA

The iOS and Android apps are Hotwire Native wrappers around the same HTML. `ApplicationPlatform` (`app/models/application_platform.rb`) detects the client; the `SetPlatform` controller concern exposes it; views and CSS adapt via `[data-platform~=ios]` and the `native`/`platform` cascade layers; and `app/javascript/bridge/` holds the JS bridge components.

One application, three clients, no second codebase.

### Framework extensions

```
lib/rails_ext/
  action_mailer_mail_delivery_job.rb                SMTP error handling
  action_pack_passkey_infer_name_from_aaguid.rb     passkey naming
  active_record_date_arithmetic.rb                  adapter-agnostic date math
  active_record_replica_support.rb                  conditional replica routing
  active_record_uuid_type.rb                        UUIDv7 + base36
  active_storage_authorization.rb                   attachment access control
  active_support_array_conversions.rb               Array#to_choice_sentence
  prepend_order.rb                                  Relation#prepend_order
  string.rb                                         String#all_emoji?
```

Every one follows the same shape — define a module, `prepend` or `include` it at a documented Rails load hook:

```ruby
# lib/rails_ext/active_record_date_arithmetic.rb
module MysqlDateArithmetic
  def date_subtract(date_column, seconds_expression)
    "DATE_SUB(#{date_column}, INTERVAL #{seconds_expression} SECOND)"
  end
end

module SqliteDateArithmetic
  def date_subtract(date_column, seconds_expression)
    "datetime(#{date_column}, '-' || (#{seconds_expression}) || ' seconds')"
  end
end

ActiveSupport.on_load(:active_record) do
  # Prepend MySQL date arithmetic to AbstractMysqlAdapter (covers Trilogy, Mysql2, etc.)
  if defined?(ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter)
    ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter.prepend(MysqlDateArithmetic)
  end

  # Prepend SQLite date arithmetic to SQLite3Adapter
  if defined?(ActiveRecord::ConnectionAdapters::SQLite3Adapter)
    ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend(SqliteDateArithmetic)
  end
end
```

That's what makes the entropy scopes run identically on both databases.

**When patching the framework is right:**

- The extension is small, named, and in `lib/rails_ext/`.
- It uses `prepend`/`include` at an `ActiveSupport.on_load` hook — never reopening a core class ad hoc.
- The alternative is scattering workarounds through application code.
- It's a candidate for upstreaming.

**When it's wrong:** when you're changing framework semantics that other code assumes, or when a supported API exists and you just didn't like it.

**The rules.**

- Stream and checkpoint anything unbounded.
- Serialize raw attributes for data transfer, never accessors.
- Extend the framework at documented hooks, in one directory, with names.
- Adapt one application to many clients; do not build many applications.

**Your turn.** Add an export for one model in your app. Serialize with `record.attributes.slice(...)`, not `to_json` on the record. Write a test that exports and re-imports, and asserts every attribute round-trips — including one with a custom accessor.

---

## III.23 Callbacks, transactions, and side effects

**The idea.** Callbacks are the most abused feature in Rails. They're also indispensable. The difference is entirely about scope.

**The rule that makes them safe:** a callback may maintain a *local truth* — something about this record or its immediate neighbors that must stay consistent — or hand work off asynchronously. It may not orchestrate a business process.

**Good: defaulting and derivation.**

```ruby
# app/models/card.rb
before_save :set_default_title, if: :published?
before_create :assign_number

# app/models/column/positioned.rb
before_create :set_position
```

**Good: keeping neighbors consistent.**

```ruby
# app/models/card.rb
after_save   -> { board.touch }, if: :published?
after_touch  -> { board.touch }, if: :published?

# app/models/column.rb
after_save_commit    -> { cards.touch_all }, if: -> { saved_change_to_name? || saved_change_to_color? }
after_destroy_commit -> { board.cards.touch_all }
```

Note the guards. `saved_change_to_name?` and friends are Active Record's dirty-tracking API, and they're what keeps a callback from firing on every save.

**Good: asynchronous handoff.**

```ruby
# app/models/concerns/notifiable.rb
after_create_commit :notify_recipients_later

# app/models/webhook/delivery.rb
after_create_commit :deliver_later
```

**Bad:** a callback that calls three other aggregates, sends an email, and posts to an external API. That's a business process. Put it in a named method that a controller or job calls explicitly, so the next person can find it by searching for the feature name.

**`after_create` vs `after_create_commit`.** The distinction matters enough to state plainly:

| Callback | Runs | Use for |
|---|---|---|
| `after_create` | Inside the transaction | Local consequences that must roll back with it |
| `after_create_commit` | After commit | Enqueuing jobs, broadcasts, anything external |

Enqueue a job from `after_create` without protection and a worker can pick it up before the transaction commits, then fail to find the record. (Fizzy's global `enqueue_after_transaction_commit = true` guards against this, but the discipline is still right.)

`Event` uses both, deliberately:

```ruby
after_create -> { eventable.event_was_created(self) }   # local: system comment, activity timestamp
after_create_commit :dispatch_webhooks                  # external: HTTP to third parties
```

**Transactions wrap every multi-record transition.** The shape is consistent throughout the codebase:

```ruby
def close(user: Current.user)
  unless closed?
    transaction do
      not_now&.destroy
      create_closure! user: user
      track_event :closed, creator: user
    end
  end
end
```

The event is *inside* the transaction. If the closure fails, no event is written, and the activity feed can never claim something that didn't happen.

Jobs are enqueued *outside*:

```ruby
def handle_board_change
  old_board = account.boards.find_by(id: board_id_before_last_save)

  transaction do
    update! column: nil
    track_board_change_event(old_board.name)
    grant_access_to_assignees unless board.all_access?
  end

  remove_inaccessible_notifications_later
  clean_inaccessible_data_later
end
```

**Locking** for anything that races:

```ruby
# app/models/account/join_code.rb
def redeem_if(&block)
  with_lock do
    increment!(:usage_count) if active? && block.call(account)
  end
end
```

`with_lock` opens a transaction and takes a row lock. Use it for counters, quotas, and state machines that must not double-fire.

**Custom callback chains** for lifecycles that aren't tied to persistence:

```ruby
# app/models/account/cancellable.rb
included do
  has_one :cancellation, dependent: :destroy

  define_callbacks :cancel
  define_callbacks :reactivate
end

def cancel(initiated_by: Current.user)
  with_lock do
    if cancellable? && active?
      run_callbacks :cancel do
        create_cancellation!(initiated_by: initiated_by)
      end

      AccountMailer.cancellation(cancellation).deliver_later
    end
  end
end
```

`define_callbacks`/`run_callbacks` come from Active Support and let other concerns hook `before_cancel` / `after_cancel` without `Account::Cancellable` knowing they exist. This is the right tool when a *domain* event — not a database event — needs extension points.

**The rules.**

- Callbacks maintain local truths or hand off asynchronously. They don't orchestrate.
- Guard them with dirty-tracking predicates and `if:`.
- `after_create` for in-transaction consequences; `after_*_commit` for jobs, broadcasts, and the outside world.
- Wrap multi-record transitions in a transaction, and put the event inside it.
- Enqueue jobs outside the transaction.
- `with_lock` for counters and anything that can race.
- `define_callbacks` for domain lifecycles that need extension points.

**Your turn.** Audit your callbacks. Anything reaching across aggregates or calling an external service should be a named method invoked explicitly, or a job. Wrap your transitions in transactions and verify with a test that a failure mid-transition leaves no partial state.

---
# Part IV — Testing

## 1. Minitest and fixtures, not RSpec and factories

The test suite is Minitest with fixtures. Grep the Gemfile for `rspec` or `factory_bot` and you get nothing:

```ruby
group :test do
  gem "capybara"
  gem "selenium-webdriver"
  gem "webmock"
  gem "vcr"
  gem "mocha"
end
```

**Why Minitest.** It ships with Rails and it's plain Ruby: a test is a method, an assertion is a method call. There's no DSL to learn and no second mental model between you and the code.

**Why fixtures.** Fixtures are a fixed, shared dataset loaded once for the whole suite. Factories build fresh objects per test. The trade-off is real, and 37signals lands on fixtures for two reasons: speed (they're inserted once, and every test runs in a transaction that rolls back), and shared vocabulary — `cards(:logo)` means the same card in every test in the codebase, so you learn the dataset once and read every test faster.

The cost is that fixtures are global state you must maintain. Accept that cost deliberately; don't fight it by creating records in every test.

## 2. `test_helper.rb`

```ruby
# test/test_helper.rb
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

require "rails/test_help"
require "webmock/minitest"
require_relative "webmock_ipaddr_extension"
require "vcr"
require "mocha/minitest"
require "turbo/broadcastable/test_helper"

module ActiveSupport
  class TestCase
    parallelize workers: :number_of_processors, work_stealing: ENV["WORK_STEALING"] != "false"

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include ActiveJob::TestHelper
    include ActionTextTestHelper, CachingTestHelper, CardTestHelper, ChangeTestHelper, SessionTestHelper
    include Turbo::Broadcastable::TestHelper

    setup do
      Current.account = accounts("37s")
    end

    teardown do
      Current.clear_all
    end
  end
end

class ActionDispatch::IntegrationTest
  setup do
    integration_session.default_url_options[:script_name] = "/#{ActiveRecord::FixtureSet.identify("37signals")}"
  end
end
```

Every test starts already tenanted: `Current.account` is set, and integration tests get the account URL prefix. `Current.clear_all` in teardown is essential — `CurrentAttributes` is thread-local, and a leaked account would contaminate the next test.

Tests run in parallel across all cores. Some things can't — system tests get `PARALLEL_WORKERS=1` in CI, and you can force it locally:

```bash
PARALLEL_WORKERS=1 bin/rails test
```

## 3. Fixtures, and the UUID problem

A fixture is YAML with ERB:

```yaml
# test/fixtures/accounts.yml
37s:
  id: <%= ActiveRecord::FixtureSet.identify("37s", :uuid) %>
  name: 37signals
  external_account_id: <%= ActiveRecord::FixtureSet.identify("37signals") %>
  cards_count: 5
```

```yaml
# test/fixtures/cards.yml
logo:
  id: <%= ActiveRecord::FixtureSet.identify("logo", :uuid) %>
  number: 1
  board: writebook_uuid
  creator: david_uuid
  column: writebook_triage_uuid
  title: The logo isn't big enough
  due_on: <%= 3.days.from_now %>
  created_at: <%= 1.week.ago %>
  status: published
  last_active_at: <%= 1.week.ago %>
  account: 37s_uuid
```

Two conventions: associations reference other fixtures by label with a `_uuid` suffix (`board: writebook_uuid`), and ERB gives you relative times (`<%= 1.week.ago %>`) so fixtures stay realistic no matter when the suite runs.

**The UUID problem.** Rails normally derives fixture IDs by hashing the label, which gives stable integers that sort arbitrarily. With UUIDv7 primary keys, arbitrary IDs would break every test that relies on `.first`, `.last`, or creation order. Worse, a record created *during* a test could sort before the fixtures.

Fizzy solves both by generating deterministic UUIDv7s whose embedded timestamp encodes the label's hash:

```ruby
# test/test_helper.rb
module FixturesTestHelper
  extend ActiveSupport::Concern

  class_methods do
    def identify(label, column_type = :integer)
      if label.to_s.end_with?("_uuid")
        column_type = :uuid
        label = label.to_s.delete_suffix("_uuid")
      end

      # Rails passes :string for varchar columns, so handle both :uuid and :string
      return super(label, column_type) unless column_type.in?([ :uuid, :string ])
      generate_fixture_uuid(label)
    end

    private

    def generate_fixture_uuid(label)
      # Generate deterministic UUIDv7 for fixtures that sorts by fixture ID
      # This allows .first/.last to work as expected in tests
      # Use the same CRC32 algorithm as Rails' default fixture ID generation
      # so that UUIDs sort in the same order as integer IDs
      fixture_int = Zlib.crc32("fixtures/#{label}") % (2**30 - 1)

      # Translate the deterministic order into times in the past, so that records
      # created during test runs are also always newer than the fixtures.
      base_time = Time.utc(2024, 1, 1, 0, 0, 0)
      timestamp = base_time + (fixture_int / 1000.0)

      uuid_v7_with_timestamp(timestamp, label)
    end
  end
end

ActiveSupport.on_load(:active_record_fixture_set) do
  prepend(FixturesTestHelper)
end
```

Anchoring `base_time` in 2024 guarantees every fixture is older than anything the suite creates. It's a small piece of infrastructure that removes an entire category of flaky test.

## 4. Model tests

```ruby
# test/models/card_test.rb
require "test_helper"

class CardTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:david)
  end

  test "create assigns a number to the card" do
    user = users(:david)
    board = boards(:writebook)
    account = board.account
    card = nil

    assert_difference -> { account.reload.cards_count }, +1 do
      card = Card.create!(title: "Test", board: board, creator: user)
    end

    assert_equal account.reload.cards_count, card.number
  end

  test "assignment toggling" do
    assert cards(:logo).assigned_to?(users(:kevin))

    assert_difference({ -> { cards(:logo).assignees.count } => -1, -> { Event.count } => +1 }) do
      cards(:logo).toggle_assignment users(:kevin)
    end

    assert_not cards(:logo).reload.assigned_to?(users(:kevin))
    unassign_event = Event.last
    assert_equal "card_unassigned", unassign_event.action
    assert_equal [ users(:kevin) ], unassign_event.assignees
  end

  test "send back to triage when moved to a new board" do
    cards(:logo).update! column: columns(:writebook_in_progress)

    assert_changes -> { cards(:logo).reload.triaged? }, from: true, to: false do
      cards(:logo).update! board: boards(:private)
    end
  end
end
```

The vocabulary you'll use constantly:

| Assertion | Use |
|---|---|
| `assert_difference -> { X.count }, +1 do ... end` | a count changed by N |
| `assert_difference({ -> { A } => -1, -> { B } => +1 })` | several counts at once |
| `assert_no_difference -> { X.count } do ... end` | nothing was created |
| `assert_changes -> { x }, from: a, to: b do ... end` | a value transitioned |
| `assert_enqueued_with(job: MyJob) do ... end` | a job was enqueued |
| `perform_enqueued_jobs only: MyJob do ... end` | run jobs inline |
| `travel_to 3.months.from_now do ... end` | freeze/shift time |
| `assert_response :no_content` | HTTP status |

`test "name" do ... end` is Minitest's macro for defining a method from a string. `setup do ... end` runs before each test.

Note `.reload` before assertions. Ruby objects hold stale attributes after a database write elsewhere; `reload` re-reads. Forgetting it is the most common cause of a "why is this test failing when the code is right?" hour.

## 5. Controller / integration tests

```ruby
# test/controllers/cards/closures_controller_test.rb
require "test_helper"

class Cards::ClosuresControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "create" do
    card = cards(:logo)

    assert_changes -> { card.reload.closed? }, from: false, to: true do
      post card_closure_path(card), as: :turbo_stream
      assert_card_container_rerendered(card)
    end
  end

  test "destroy" do
    card = cards(:shipping)

    assert_changes -> { card.reload.closed? }, from: true, to: false do
      delete card_closure_path(card), as: :turbo_stream
      assert_card_container_rerendered(card)
    end
  end

  test "create as JSON" do
    card = cards(:logo)

    assert_not card.closed?

    post card_closure_path(card), as: :json

    assert_response :no_content
    assert card.reload.closed?
  end
end
```

These are `ActionDispatch::IntegrationTest` — a real request through the full middleware stack, router, controller, and view. Not a controller unit test with a mocked request.

`as: :turbo_stream` and `as: :json` set the format. Notice both are tested: HTML and API are the same code path, so both get asserted.

Authorization gets its own tests, and they're the ones reviewers look for:

```ruby
# test/controllers/cards_controller_test.rb
test "non-admins cannot delete cards they did not create" do
  logout_and_sign_in_as :jz

  assert_no_difference -> { Card.count } do
    delete card_path(cards(:logo))
  end

  assert_response :forbidden
end
```

**Sign-in** comes from a custom helper that drives the real magic-link flow rather than faking a session:

```ruby
# test/test_helpers/session_test_helper.rb
def sign_in_as(identity)
  cookies.delete :session_token

  if identity.is_a?(User)
    user = identity
    identity = user.identity
    raise "User #{user.name} (#{user.id}) doesn't have an associated identity" unless identity
  elsif !identity.is_a?(Identity)
    identity = identities(identity)
  end

  identity.send_magic_link
  magic_link = identity.magic_links.order(id: :desc).first

  untenanted do
    post session_path, params: { email_address: identity.email_address }
    post session_magic_link_url, params: { code: magic_link.code }
  end

  assert_response :redirect, "Posting the Magic Link code should grant access"

  cookie = cookies.get_cookie "session_token"
  assert_not_nil cookie, "Expected session_token cookie to be set after sign in"
end

def untenanted(&block)
  original_script_name = integration_session.default_url_options[:script_name]
  integration_session.default_url_options[:script_name] = ""
  yield
ensure
  integration_session.default_url_options[:script_name] = original_script_name
end
```

`sign_in_as` accepts a symbol, an `Identity`, or a `User` — a small kindness that removes friction from hundreds of tests. `untenanted` temporarily drops the account URL prefix for routes that live outside a tenant, and restores it in `ensure`.

## 6. System tests

Full browser tests via Capybara and headless Chrome. There are only **three system test files** in the whole repository, and that ratio is intentional: browser tests are slow and flaky, so they cover critical end-to-end journeys and nothing else.

```ruby
# test/system/smoke_test.rb
require "application_system_test_case"

class SmokeTest < ApplicationSystemTestCase
  test "joining an account" do
    account = accounts("37s")

    visit join_url(code: account.join_code.code, script_name: account.slug)
    fill_in "Email address", with: "newbie@example.com"
    click_on "Continue"

    assert_selector "h1", text: "Check your email"
    identity = Identity.find_by!(email_address: "newbie@example.com")
    code = identity.magic_links.active.first.code
    fill_in "code", with: code
    send_keys :enter

    assert_selector "input[id=user_name]"
    assert account.users.find_by!(identity:).verified?, "User was not properly verified"
    fill_in "Full name", with: "New Bee"
    click_on "Continue"

    assert_selector "h1", text: "Writebook"
  end

  test "create a card" do
    sign_in_as(users(:david))

    visit board_url(boards(:writebook))
    click_on "Add a card"
    fill_in "card_title", with: "Hello, world!"
    fill_in_lexxy with: "I am editing this thing"
    click_on "Create card"

    assert_selector "h3", text: "Hello, world!"
  end
end
```

Capybara drives the browser by what a user sees — `click_on "Add a card"`, `fill_in "Email address"` — not by CSS selectors. That makes the tests readable and resistant to markup churn.

System tests sign in differently, because there's no cookie jar to manipulate:

```ruby
# test/application_system_test_case.rb
private
  def sign_in_as(user)
    visit session_transfer_url(user.identity.transfer_id, script_name: nil)
    assert_current_path root_path
  end
```

## 7. Mocks, stubs, and HTTP

Mocha is available and used sparingly, for external boundaries:

```ruby
# test/jobs/account/incinerate_due_job_test.rb
setup do
  if defined?(Stripe::Subscription)
    Stripe::Subscription.stubs(:update).returns(true)
    Stripe::Subscription.stubs(:cancel).returns(true)
  end
end

test "finds accounts up for incineration" do
  @account.cancel(initiated_by: @user)
  @account.cancellation.update!(created_at: 31.days.ago)

  Account.any_instance.expects(:incinerate).once

  Account::IncinerateDueJob.perform_now
end
```

WebMock blocks unexpected HTTP; VCR records and replays real responses into cassettes under `test/vcr_cassettes/`.

**The house position:** mock third-party services, not your own objects. Your objects are cheap to instantiate and hit a real (transactional) database. A test that mocks your own model is testing your mocks.

## 8. `bin/ci`

```ruby
# bin/ci
#!/usr/bin/env ruby
require_relative "../config/boot"
require "active_support/continuous_integration"

CI = ActiveSupport::ContinuousIntegration
require_relative "../config/ci.rb"
```

```ruby
# config/ci.rb
require_relative "../lib/fizzy"

OSS_ENV = "SAAS=false BUNDLE_GEMFILE=Gemfile"
SAAS_ENV = "SAAS=true BUNDLE_GEMFILE=Gemfile.saas"
SYSTEM_TEST_ENV = "PARALLEL_WORKERS=1" # system tests can't run reliably in parallel

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  step "Gemfile: Drift check", "bin/bundle-drift check"
  step "Security: Gem audit", "bin/bundler-audit check --update"
  step "Security: Importmap audit", "bin/importmap audit"
  step "Security: Brakeman audit", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Security: Gitleaks audit", "bin/gitleaks-audit"

  if Fizzy.saas?
    step "Tests: SaaS",          "#{SAAS_ENV} bin/rails test"
    step "Tests: SaaS System",   "#{SAAS_ENV} #{SYSTEM_TEST_ENV} bin/rails test:system"
    step "Tests: OSS",           "#{OSS_ENV} bin/rails test"
    step "Tests: OSS System",    "#{OSS_ENV} #{SYSTEM_TEST_ENV} bin/rails test:system"
  else
    step "Tests: SQLite",        "#{OSS_ENV} bin/rails test"
    step "Tests: SQLite System", "#{OSS_ENV} #{SYSTEM_TEST_ENV} bin/rails test:system"
  end

  if success?
    step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  else
    failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  end
end
```

Style, four security scans, then the full suite against both database backends. `ActiveSupport::ContinuousIntegration` is a Rails 8.1 feature — the CI definition is Ruby, runs locally, and looks the same on your laptop as in GitHub Actions.

The security steps are worth copying wholesale into any app: dependency CVEs (`bundler-audit`), JavaScript CVEs (`importmap audit`), static analysis (`brakeman`), and committed secrets (`gitleaks`).

## The rules

- Minitest and fixtures. No RSpec, no factories.
- Test the model for behavior, integration for the request, the browser for a handful of journeys.
- Test both the HTML and JSON paths of an action.
- Always test that unauthorized access is denied.
- `.reload` before asserting on a record you changed indirectly.
- Custom helpers for anything repeated across many tests; put them in `test/test_helpers/`.
- Mock third-party services, never your own objects.
- Run `bin/ci` before opening a pull request.

**Your turn.** For your transition: a model test asserting the state change and the event with `assert_difference`, an integration test hitting the route in both formats, and an authorization test proving a foreign user gets 404 or 403. Then run `bin/ci`.

---

# Part V — Operations

## 1. Development

```bash
bin/setup              # dependencies, database, seed data
bin/setup --reset      # drop and rebuild
bin/dev                # run the server
```

Development lives at `http://fizzy.localhost:3006`. Sign in with `david@example.com` and take the verification code from the browser console.

`bin/dev` is a plain shell script, not `foreman` with a `Procfile.dev`. Solid Queue can run inside Puma (`SOLID_QUEUE_IN_PUMA: true`), so there's no second process to babysit in development.

## 2. Databases

SQLite by default, MySQL when you want it:

```bash
DATABASE_ADAPTER=mysql bin/setup --reset
DATABASE_ADAPTER=mysql bin/ci
```

`config/database.yml` is a dispatcher that picks `config/database.sqlite.yml` or `config/database.mysql.yml`. Both define the same four logical databases — `primary`, `cable`, `queue`, `cache` — each with its own migrations path.

SQLite as a production database sounds wrong if you learned web development in the 2010s. With WAL mode, a modern SSD, and a single-server deployment it comfortably serves a real product, and it removes an entire tier from your operations. Rails 8 was explicitly built to make this viable.

## 3. The Solid trio

| Gem | Replaces | Storage |
|---|---|---|
| Solid Queue | Sidekiq / Resque + Redis | `queue` database |
| Solid Cache | Redis / Memcached | `cache` database |
| Solid Cable | Redis pub/sub | `cable` database |

One dependency (your database) instead of four. You back up one thing, monitor one thing, secure one thing. For the overwhelming majority of applications the performance difference is irrelevant and the operational difference is enormous.

Job concurrency is configured in `config/queue.yml`:

```yaml
Integer(ENV.fetch("JOB_CONCURRENCY") { Concurrent.physical_processor_count })
```

## 4. Deployment

**Docker.** A multi-stage build: `base` → `build` (gems, bootsnap, asset precompile) → a minimal runtime running as a non-root `rails` user. The entrypoint prepares the database only when the container is starting the web server:

```bash
# bin/docker-entrypoint
#!/bin/bash -e

if [ "${1}" == "./bin/thrust" ] && [ "${2}" == "./bin/rails" ] && [ "${3}" == "server" ]; then
  MIGRATE=1 ./bin/rails db:prepare
fi

exec "${@}"
```

**Kamal** deploys containers to plain servers over SSH — no Kubernetes, no managed platform:

```yaml
# config/deploy.yml
service: fizzy
image: fizzy

servers:
  web:
    - fizzy.example.com

ssh:
  user: root

proxy:
  ssl: true
  host: fizzy.example.com

env:
  secret:
    - SECRET_KEY_BASE
    - VAPID_PUBLIC_KEY
    - VAPID_PRIVATE_KEY
    - SMTP_USERNAME
    - SMTP_PASSWORD
  clear:
    BASE_URL: https://fizzy.example.com # The public URL of your Fizzy instance
    MAILER_FROM_ADDRESS: support@example.com # The email "from" address that Fizzy sends email from
    SMTP_ADDRESS: mail.example.com # The SMTP server you'll use to send email
    MULTI_TENANT: false # Set to true to allow multiple accounts to sign up
    SOLID_QUEUE_IN_PUMA: true # Run background jobs in the app container
```

```bash
bin/rails saas:enable        # pre-deploy step for the hosted variant
bin/kamal deploy -d production
```

Destinations: `production`, `staging`, `beta1`–`beta4`. Secrets come from `.kamal/secrets*`, resolved through the 1Password CLI. Kamal's proxy handles TLS certificates automatically. Handy aliases (`kamal console`, `kamal shell`, `kamal logs`, `kamal dbc`) wrap `kamal app exec`.

Persistent state lives in a volume:

```yaml
volumes:
  - "fizzy_storage:/rails/storage"
```

That's the SQLite databases and Active Storage files. Back that directory up and you've backed up the application.

## 5. The OSS / SaaS split

`saas/` is a Rails engine packaged as a gem, layered on top of the open-source app to build the hosted product: billing, admin auditing (`console1984`/`audits1984`), native push, and Prometheus metrics via `yabeda`. `Gemfile.saas` starts with `eval_gemfile "Gemfile"` and adds those gems on top.

`bin/rails saas:enable` / `saas:disable` toggle it, and `bin/ci` runs the suite both ways so neither variant breaks the other.

The generalizable pattern: keep the open-source core complete and honest, and layer commercial features as an engine rather than forking or littering the core with `if premium?`.

## 6. Monitoring

- **Mission Control::Jobs** at `/admin/jobs` — inspect, retry, and discard jobs.
- **`stackprof`** — sampling profiler.
- **`rack-mini-profiler`** — per-request timings in development.
- **`autotuner`** — GC tuning suggestions from real traffic.
- **Sentry + Yabeda** — in the SaaS variant only.

**The rules.**

- One server, one database, one container until you have measured evidence you need more.
- Prefer the thing already in the box over the thing that adds a tier.
- Every environment variable that is a secret goes in `env.secret`, never `clear`.
- Back up the volume.
- Run the suite against every database backend you support.

---
# Part VI — House style

> We aim to write code that is a pleasure to read, and we have a lot of opinions about how to do it well. Writing great code is an essential part of our programming culture, and we deliberately set a high bar for every code change anyone contributes. We care about how code reads, how code looks, and how code makes you feel when you read it.
> — `STYLE.md`

That is not decoration. Style feedback on a pull request here is substantive feedback.

## 1. Expanded conditionals over guard clauses

The default is an expanded `if`/`else`:

```ruby
# Bad
def todos_for_new_group
  ids = params.require(:todolist)[:todo_ids]
  return [] unless ids
  @bucket.recordings.todos.find(ids.split(","))
end

# Good
def todos_for_new_group
  if ids = params.require(:todolist)[:todo_ids]
    @bucket.recordings.todos.find(ids.split(","))
  else
    []
  end
end
```

Guard clauses are permitted in exactly two situations: when the return is the very first line of the method, and when the main body is long enough that an extra indent level would hurt.

```ruby
def after_recorded_as_commit(recording)
  return if recording.parent.was_created?

  if recording.was_created?
    broadcast_new_column(recording)
  else
    broadcast_column_change(recording)
  end
end
```

Coming from a codebase where "early return" is unquestioned dogma, this will feel wrong for about a week. The reasoning is that a stack of guards forces you to hold negated conditions in your head, while an `if`/`else` shows both branches at once.

## 2. Method ordering

Within a class:

1. Class methods
2. Public methods, with `initialize` first
3. Private methods

And vertically, methods are ordered by **invocation order** — you read a class top to bottom in the order the code runs:

```ruby
class SomeClass
  def some_method
    method_1
    method_2
  end

  private
    def method_1
      method_1_1
      method_1_2
    end

    def method_1_1
    end

    def method_1_2
    end

    def method_2
    end
end
```

`Card#handle_board_change` followed by `track_board_change_event` is a real instance of this: the caller precedes the callee.

## 3. Visibility modifiers

No blank line after `private`; contents indented one extra level:

```ruby
class SomeClass
  def some_method
  end

  private
    def some_private_method_1
    end

    def some_private_method_2
    end
end
```

If a module contains only private methods, `private` goes at the top, followed by a blank line, with **no** extra indentation:

```ruby
module SomeModule
  private

  def some_private_method
  end
end
```

Rubocop does not enforce this. Reviewers do.

## 4. Bang methods

`!` marks the variant of a method that already exists without one. It does not mean "destructive". `destroy` is destructive and has no bang; `save!` has one because `save` exists.

## 5. CRUD controllers

```ruby
# Bad
resources :cards do
  post :close
  post :reopen
end

# Good
resources :cards do
  resource :closure
end
```

Covered in [Part III §11](#iii11-routes-as-resources), repeated here because it's the rule most often broken by newcomers.

## 6. Controllers call models directly

```ruby
class Cards::CommentsController < ApplicationController
  def create
    @comment = @card.comments.create!(comment_params)
  end
end
```

```ruby
class Cards::GoldnessesController < ApplicationController
  def create
    @card.gild
  end
end
```

Plain Active Record calls in a controller are fine. Intention-revealing model APIs are better. A service class between them is neither.

## 7. Rubocop

```yaml
# .rubocop.yml
inherit_gem: { rubocop-rails-omakase: rubocop.yml }

AllCops:
  Exclude:
    - 'db/migrate/**/*'
    - 'db/schema*.rb'
    - 'saas/db/migrate/**/*'
    - 'saas/db/saas_schema.rb'
```

`rubocop-rails-omakase` is 37signals' deliberately small rule set. It enforces the mechanical things — double-quoted strings, two-space indentation, spaces inside `%w[ ]` and `[ ]` literals, trailing whitespace — and declines to enforce taste. It will not tell you your method is too long or your class has too many lines, because those are judgment calls a reviewer makes.

Run it: `bin/rubocop`, or `bin/rubocop -a` to autocorrect.

## 8. Commits and pull requests

From the log, the convention is clear: an imperative subject line, then a body explaining the cause and the fix.

```
Fix export/import losing custom column colors

record.to_json serializes through model accessors. Column::Colored
overrides the color accessor to return a Color struct, which serializes
as {"name":"Blue","value":"var(--color-card-default)"} instead of the
raw CSS string.

Two fixes:
- Export raw DB values via record.attributes.slice(*attributes).to_json
- Color.for_value parses legacy JSON format so columns imported from
  old exports self-heal when read
```

Notice what the body does: it explains *why the bug happened*, not what the diff changed. The diff already shows what changed.

Commits are small and single-purpose — `Tweak alignments`, `Change CSS selector`, `Add a button to sign in with a passkey`. Work lands via pull request to `main`.

## 9. Patterns this codebase deliberately avoids

| Pattern | Why not | Instead |
|---|---|---|
| Service objects | Business logic belongs next to its data | Model methods (`card.close`) |
| Interactors / commands | Same, with more ceremony | Model methods |
| Repositories | Relations already compose better | `Current.user.cards.active` |
| Query objects (as a rule) | Scopes compose and are discoverable | `scope`; a domain object like `Filter` when it earns one |
| Policy objects (Pundit) | Authorization by scoping can't be forgotten | `Current.user.accessible_cards` |
| Presenters / decorators | Extra layer for little gain | Helpers and small POROs |
| Serializers (as a layer) | jbuilder is a view, and views are the right place | `_card.json.jbuilder` |
| Form objects (as a rule) | Most forms map to a model | `params.expect`; a PORO when the form spans models |
| SPA front end | Doubles the application | Hotwire |
| GraphQL | Solves a problem this app doesn't have | REST + jbuilder |
| Redis | Another tier to operate | Solid Queue / Cache / Cable |
| RSpec | Second mental model | Minitest |
| FactoryBot | Slower, no shared vocabulary | Fixtures |
| `default_scope` | Invisible, and surprising to remove | Explicit scopes at call sites |
| `rescue_from` sprawl | Hides failures | Bang methods, Rails' default error pages |
| STI for state | Rigid, hard to evolve | State transitions as records |

Every row is a decision that can be revisited with evidence. None of them should be revisited by accident in a pull request.

## 10. Self-review checklist

Before you open a PR:

**Naming and structure**
- [ ] Does every file's path match its constant name?
- [ ] Is new model behavior in a named concern rather than piled onto the model?
- [ ] Does the concern name describe a capability a user would recognize?

**Domain**
- [ ] Is business logic on the model, not the controller or the job?
- [ ] Does a new state transition create a record instead of flipping a column?
- [ ] Does the transition record `belongs_to` its parent with `touch: true`?
- [ ] Are multi-record changes wrapped in a transaction, with the event inside it?

**HTTP**
- [ ] Is each new action CRUD on a resource, not a custom verb?
- [ ] Are records loaded through `Current.user` / `Current.account`?
- [ ] Strong parameters via `params.expect`?
- [ ] Does the action respond to every format its siblings do?

**Correctness and performance**
- [ ] Any new N+1? Did you use the `preloaded` scope?
- [ ] Is `find_each` used for anything that could be large?
- [ ] Does the new table have `account_id`, `null: false`, indexed?

**Callbacks and jobs**
- [ ] Do callbacks maintain local truths only?
- [ ] Is job enqueuing in `after_*_commit`?
- [ ] Is the job one line?

**Style**
- [ ] Expanded conditionals unless a guard clause is genuinely warranted?
- [ ] Private methods indented under `private`?
- [ ] Methods ordered by invocation?
- [ ] `bin/rubocop` clean?

**Tests**
- [ ] Model test for the behavior?
- [ ] Integration test for the request, in every format it serves?
- [ ] A test proving unauthorized access is refused?
- [ ] `bin/ci` green?

---

# Part VII — Appendices

## Appendix A — Where does this go?

| You have | It goes | Example |
|---|---|---|
| A new action on an existing record | A nested resource + controller | `resource :closure` → `Cards::ClosuresController` |
| Business logic | A method on the model | `card.close` |
| Behavior only one model has | `app/models/<model>/<capability>.rb` | `Card::Closeable` |
| Behavior several models share | `app/models/concerns/` | `Eventable` |
| A repeated `before_action` set | `app/controllers/concerns/*_scoped.rb` | `CardScoped` |
| A request-scoped value | `Current` | `Current.account` |
| Something slow or external | A job, called via a `_later` method | `deliver_later` |
| Something on a schedule | `config/recurring.yml` | `auto_postpone_all_due` |
| A state with an actor or timestamp | A record | `Closure` |
| A state with neither | A column or an enum | `Card#status` |
| Presentation logic | A helper, or a PORO in `app/models` | `card_article_tag`, `Event::Description` |
| Reusable markup | A partial taking locals | `_comment.html.erb` |
| Browser-side behavior | A Stimulus controller | `auto_save_controller.js` |
| Shared browser-side function | `app/javascript/helpers/` | `submitForm` |
| A component's styling | A file in `app/assets/stylesheets/`, in `@layer components` | `cards.css` |
| A per-record style value | An inline CSS custom property | `style="--card-color: …"` |
| A framework shortcoming | `lib/rails_ext/`, via `ActiveSupport.on_load` | `active_record_uuid_type.rb` |
| A cross-cutting request behavior | A concern included in `ApplicationController` | `TurboFlash` |

## Appendix B — Glossary for polyglots

| Ruby / Rails | Nearest equivalent | Note |
|---|---|---|
| Gem | package / library | `Gemfile` is `package.json` / `pom.xml` |
| Bundler | npm / Maven / pip | `Gemfile.lock` is the lockfile |
| Module | interface + trait + namespace | Provides implementation, unlike a Java interface |
| `include` | trait mixin | Adds instance methods |
| `extend` | static mixin | Adds class methods |
| Concern | trait with class-level setup | `included do` runs in the includer |
| Symbol | interned string / enum member | `:closed` |
| Block | lambda / closure | Passed to a method, not a value by default |
| `yield` | invoking the callback | Calls the block passed in |
| Proc / lambda | function object | Lambdas check arity, procs don't |
| Active Record model | ORM entity + repository + DAO | All three at once, deliberately |
| Scope | named query fragment | Composable; returns a relation |
| Migration | schema change script | Ordered, timestamped, reversible |
| `Current` | request-scoped DI container | Use narrowly |
| Job | queued task | Active Job is the interface; Solid Queue the backend |
| ERB | JSP / Razor / Jinja | Server-side templating |
| Partial | component / include | Server-rendered, takes locals |
| Turbo Frame | HTMX target / island | Scoped navigation |
| Turbo Stream | server-pushed DOM patch | Over HTTP response or WebSocket |
| Stimulus controller | small behavior component | No state ownership, no rendering |
| Fixture | seeded test dataset | Shared across the suite |
| Minitest | JUnit / pytest | Ships with Rails |
| Rack | WSGI / servlet API | Middleware protocol |
| Zeitwerk | classloader | Path determines constant name |

## Appendix C — Daily Ruby cheat sheet

```ruby
# Conditionals
do_thing if condition
do_thing unless condition
x = condition ? a : b
if value = lookup_something
  use(value)
end

# nil handling
user&.name                    # nil if user is nil
name ||= "Anonymous"          # assign if nil/false
value.presence || default     # nil if blank
title.blank? / title.present?

# Blocks
items.each { |i| puts i }
items.map(&:name)
items.select { it.active? }   # Ruby 3.4 implicit param
items.each_with_object({}) { |i, h| h[i.id] = i }
records.find_each { |r| r.process }

# Keyword args, defaults, forwarding
def close(user: Current.user, **options); end
def initialize(...); super; end
def with_account(value, &) = with(account: value, &)

# Hash shorthand
create!(creator:, board:, particulars:)

# Chaining
value.tap { |v| log(v) }      # returns value
value.then { transform(it) }  # returns block result

# Class-level DSL
belongs_to :board
has_many :comments, dependent: :destroy
scope :latest, -> { order(created_at: :desc) }
before_save :normalize, if: :published?
enum :status, %w[ drafted published ].index_by(&:itself)
normalizes :email, with: -> { it.strip.downcase }
delegate :name, to: :user, allow_nil: true

# Active Support
1.week.ago / 3.days.from_now / 30.minutes / Time.current
Array.wrap(maybe_one_thing)
"Card::NotNow".demodulize.underscore

# Query
Model.where(x: 1).order(:y).limit(10)
Model.where.missing(:closure)
Model.find_by!(number: 42)
relation.preload(:board, comments: :creator)
account.increment!(:cards_count)
record.with_lock { ... }
Model.transaction { ... }
```

## Appendix D — Mistakes newcomers make here

**1. Zeitwerk naming.** `app/models/card/closeable.rb` defining `Closeable` instead of `Card::Closeable`. The error message tells you exactly this; read it.

**2. Loading records globally.** `Card.find(params[:id])` instead of `Current.user.accessible_cards.find_by!(...)`. This is a security bug, not a style preference.

**3. Forgetting `account_id`.** A new table without it can't be scoped, exported, or deleted with the account.

**4. N+1 queries.** Rendering a collection without `preloaded`. Check the development log; every repeated query is a bug.

**5. Fat controllers.** If your action has an `if` about domain state, that logic belongs on the model.

**6. Custom controller verbs.** `POST /cards/:id/close`. Make it a resource.

**7. Boolean columns for transitions.** `closed_at` + `closed_by_id` where a `Closure` record belongs.

**8. `Current` abuse.** Stashing anything that isn't identity, tenancy, or request metadata. It always looks reasonable and always turns into a debugging nightmare.

**9. Callbacks that orchestrate.** A callback that touches three aggregates and calls an API. Name it, and call it explicitly.

**10. Enqueuing from `after_create`.** Use `after_create_commit`.

**11. Not calling `.reload` in tests.** Your test fails, your code is fine, you lose an hour.

**12. Fighting the fixtures.** Creating records in every test instead of learning the dataset. Add a fixture; other tests will use it too.

**13. Missing `status: :unprocessable_entity`.** Turbo silently ignores a 200 response to a failed form. Your validation errors never appear.

**14. Reaching for a gem.** Check whether Rails already does it. It usually does.

## Appendix E — A reading path through the real code

In order, shortest to hardest:

1. `app/models/closure.rb` — 5 lines. A transition record.
2. `app/controllers/application_controller.rb` — 13 lines. Composition root.
3. `app/models/current.rb` — request context with cascading writers.
4. `app/models/card/closeable.rb` — a complete capability.
5. `app/controllers/cards/closures_controller.rb` — a thin controller.
6. `app/controllers/concerns/card_scoped.rb` — authorization by scoping.
7. `app/views/cards/closures/create.turbo_stream.erb` — the response.
8. `test/controllers/cards/closures_controller_test.rb` — how it's tested.
9. `app/models/concerns/eventable.rb` — `track_event`.
10. `app/models/card.rb` — the aggregate.
11. `config/routes.rb` — the whole resource map.
12. `app/models/card/postponable.rb` — a three-step transition.
13. `app/models/event.rb` — the fan-out point.
14. `app/models/notifier.rb` — a factory PORO.
15. `config/initializers/tenanting/account_slug.rb` — the tenancy middleware.
16. `config/initializers/active_job.rb` — tenancy in jobs.
17. `app/models/filter.rb` — complex querying as a domain object.
18. `app/models/concerns/searchable.rb` — the search index.
19. `test/test_helper.rb` — fixtures and UUID generation.
20. `lib/rails_ext/active_record_uuid_type.rb` — a framework extension.

## Appendix F — Further reading

In this repository:

- `STYLE.md` — the house style rules, verbatim and authoritative.
- `AGENTS.md` — the orientation document for contributors.
- `CSS.md` — the full CSS guide, more detailed than [Part III §16](#iii16-css-and-assets).
- `ARCHITECTURE_AND_PRINCIPLES.md` and `RUBY_ON_RAILS_GUIDE.md` — companion architecture narratives.
- `docs/API.md` — the public JSON API.
- `docs/development.md`, `docs/kamal-deployment.md`, `docs/docker-deployment.md`.
- `CONTRIBUTING.md` — how work gets proposed and landed.

Outside it:

- The Rails Guides — accurate, thorough, and the right first stop for any framework question.
- `bin/rails console` and `source_location` — the fastest way to answer "where does this come from?"
- The Hotwire handbooks for Turbo and Stimulus.
- 37signals' writing at dev.37signals.com, particularly "Vanilla Rails is plenty."

---

## A closing note

The hardest part of working in this codebase is not Ruby, and it's not Rails. It's resisting the urge to add structure.

You will look at a model with 23 concerns and want to introduce a service layer. You will look at authorization scattered across association definitions and want a policy framework. You will look at a controller calling `@card.close` and want an application service to mediate it.

Every one of those instincts was earned in codebases where the framework gave you less. Rails gives you more, and the reward for trusting it is a thirteen-thousand-line application that a single person can read in a week and change with confidence.

Build the small thing. Add the layer when it hurts, not before.
