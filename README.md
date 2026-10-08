# Salamendar

A Slack bot built on [`slack_elixir`](https://github.com/ryanwinchester/slack_elixir),
connected over Socket Mode (no public URL needed).

It depends on the fork at [`matzko/slack_elixir`](https://github.com/matzko/slack_elixir),
pinned by commit in `mix.exs`. Upstream only dispatches `events_api` and
`slash_commands` envelopes and leaves `interactive` envelopes (Block Kit button
clicks) unacknowledged, so the clicker sees a warning triangle and
`handle_event/3` never fires. The fork adds the `interactive` clause to
`Slack.Socket.handle_frame/2`.

## Development setup

Toolchain versions (Elixir, Erlang, [`just`](https://just.systems)) are in
`.tool-versions`. Run `mise install` to get them. You also need Docker with
Compose v2 for Postgres.

Run `just` to list the dev commands. The main ones:

| Command | What it does |
| --- | --- |
| `just setup` | Starts Postgres, fetches deps, creates and migrates the database |
| `just run` | Starts Postgres, then `iex -S mix` |
| `just test` | Starts Postgres, then `mix test` (extra args are passed through) |
| `just psql` | Opens psql on the dev database |
| `just down` / `just nuke` | Stops Postgres / stops it and deletes its data |
| `just lint` | Format check, Credo, Dialyzer |

`just` loads `.env` automatically. If something else already uses port 5432,
set `POSTGRES_PORT` in `.env`.

### 1. Create the Slack app

1. Go to <https://api.slack.com/apps> → **Create New App** → **From a manifest**.
2. Pick a workspace and paste `slack-app-manifest.yml`. This turns on Socket
   Mode, Interactivity, the Messages tab, the `/salamendar` command, and the
   scopes and bot events the bot needs.
3. **Basic Information → App-Level Tokens → Generate Token and Scopes**: add
   the `connections:write` scope. This is the `xapp-…` **app token**.
4. **Install App → Install to Workspace**. The **Bot User OAuth Token**
   (`xoxb-…`) is the **bot token**.

### 2. Provide the tokens

Use either one:

- **Config file:** `cp config/.env.exs.example config/.env.exs` and fill it in.
  It's loaded in `:dev` only and is git-ignored.
- **Environment:** set `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN`, for example
  `cp .env.example .env` and fill it in. `just` loads `.env` for you;
  without just, run `set -a; source .env; set +a` first.
  Environment variables take precedence over `config/.env.exs`.

### 3. Run it

```sh
just setup   # first time only
just run
```

Once the log shows `[Slack.Socket] hello`, you're connected. To try it:

- DM the bot: it echoes your message back.
- Invite it to a channel (`/invite @salamendar`) and mention it: it replies
  in a thread with a **Ping** button.
- Run `/salamendar hi` in any channel: you get an ephemeral reply with the button.
- Click **Ping**: you get an ephemeral confirmation (this is the
  interactivity path through the fork).

If the token is missing or invalid, the app fails to boot on purpose.
`Slack.Supervisor` calls `auth.test` at startup and raises unless Slack
answers `ok`.

## Tests

```sh
just test
```

Tests run against `salamendar_test` in the compose Postgres, inside the
Ecto SQL sandbox.

`config/test.exs` sets `start_supervisor?: false`, so the Slack supervision
tree never starts (and never hits the network) under test.

## Slack app gotchas

- After you **add a scope**, you have to reinstall the app, and reinstalling
  may issue a new `xoxb` token. Copy it into `config/.env.exs`. When
  `slack-app-manifest.yml` changes, paste it into *App Manifest* in the app's
  settings, then reinstall.
- **Event subscriptions are separate from scopes.** If you hold `im:history`
  but don't subscribe to `message.im`, DMs are never delivered.
- **Interactivity** has to be on (*Interactivity & Shortcuts*). With it off,
  buttons still render but clicks go nowhere. Socket Mode doesn't need a
  Request URL.
- `slack_elixir`'s `Slack.ChannelServer` calls `users.conversations` for all
  four channel types at startup, so the four `*:read` scopes are required.
