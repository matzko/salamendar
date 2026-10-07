# Loads `.env` (Slack tokens, POSTGRES_PORT, ...) into every recipe.
set dotenv-load

mix := "mise exec -- mix"

# List recipes
default:
    @just --list

# Start Postgres and wait until it accepts connections
up:
    docker compose up -d --wait

# Stop services (data is kept)
down:
    docker compose down

# Stop services and delete the database volume
nuke:
    docker compose down --volumes

# Tail service logs
logs:
    docker compose logs -f

# Open psql against the dev database
psql db="salamendar_dev":
    docker compose exec postgres psql -U postgres {{db}}

# First-time setup: deps, database, migrations
setup: up
    {{mix}} deps.get
    {{mix}} ecto.setup

# Run the bot in IEx
run: up
    mise exec -- iex -S mix

# Run migrations
migrate: up
    {{mix}} ecto.migrate

# Generate a migration: just gen-migration create_events
gen-migration name:
    {{mix}} ecto.gen.migration {{name}}

# Drop, recreate, and migrate the dev database
reset: up
    {{mix}} ecto.reset

# Run the test suite (extra args go to mix test)
test *args: up
    {{mix}} test {{args}}

# Format check, Credo, and Dialyzer
lint:
    {{mix}} format --check-formatted
    {{mix}} credo --strict
    {{mix}} dialyzer
