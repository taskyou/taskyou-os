# TaskYouOS

This is the TaskYouOS template repo. It generates fully working AI agent management systems from a config file.

## Repository Structure

- `setup.sh` — Main setup script. Reads config.env, renders templates, provisions server.
- `config.example.env` — Documented example configuration
- `templates/` — All `.tmpl` files use `{{VARIABLE}}` placeholders, rendered by setup.sh
- `templates/hooks/` — Server-side TaskYou hooks
- `modules/linear/` — Optional Linear integration (CLI + @agent polling)
- `modules/r2/` — Optional R2 asset hosting config

## Template Syntax

- `{{VARIABLE}}` — Simple variable substitution
- `{{#FEATURE}} ... {{/FEATURE}}` — Conditional block, kept if FEATURE_ENABLED=true

## How to Work on This

- Templates are the source of truth. Never edit generated output — edit the template.
- Test changes by running `./setup.sh local /tmp/test-project` with a test config.env.
- If you have an existing GM at `~/Projects/gms/<name>/`, use it as a reference implementation.

## Adding New Templates

1. Create `templates/new-thing.tmpl` with `{{VARIABLE}}` placeholders
2. Add the render_file call in setup.sh's `setup_local` or `setup_server` function
3. Document any new variables in config.example.env
