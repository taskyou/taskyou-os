# Linear CLI

Command-line tool for interacting with Linear workspaces.

## Commands

### Create an issue

```bash
linear issue create --title "Issue title" --body "Description" --label "Agent Handoff" --state Todo
```

- `--title` (required): Issue title
- `--body`: Issue description (markdown supported)
- `--body-file`: Read body from a file (use `-` for stdin)
- `--label`: Apply a label (e.g. "Agent Handoff")
- `--state`: Set initial state (e.g. "Todo")

### List issues

```bash
linear issue list
linear issue list --limit 20
```

### Show issue details

```bash
linear issue show IK-93
```

Shows title, state, labels, description, and all comments.

### Add a comment

```bash
linear comment add IK-93 "Your comment here"
```

By default, comments are posted using the agents token. To post as the main user:

```bash
linear comment add IK-93 "Comment" --as-user
```

### List comments

```bash
linear comment list IK-93
```

## Options

- `--json` — Output machine-readable JSON (works with all commands)
- `--as-user` — Use main token for comments instead of agents token

## Configuration

API tokens and workspace config are in `.env` in the same directory as this script. Required variables:

```
LINEAR_TOKEN=lin_api_...           # Main user token
LINEAR_TOKEN_AGENTS=lin_api_...    # Agents token (for comments)
LINEAR_TEAM_ID=uuid                # Team UUID
LINEAR_TEAM_KEY=IK                 # Team key prefix
LINEAR_LABELS={"agent handoff":"uuid"}  # Label name→ID mapping
LINEAR_STATES={"todo":"uuid"}           # State name→ID mapping
```
