# rails-b2b

Rails application template for B2B SaaS foundations:
- Magic-link authentication
- Organization onboarding + membership
- Inertia + React + TypeScript + Vite baseline
- AWS SES SMTP defaults for production mail

## Use directly from local path

```bash
rails new my_app -d postgresql --skip-javascript --skip-hotwire -m /Users/pd/Library/CloudStorage/Dropbox/Work/rails-b2b/template.rb
```

## Use from GitHub

```bash
rails new my_app -d postgresql --skip-javascript --skip-hotwire -m https://raw.githubusercontent.com/<org-or-user>/rails-b2b/main/template.rb
```

## Initialize this template repo with git

```bash
cd /Users/pd/Library/CloudStorage/Dropbox/Work/rails-b2b
git init
git add .
git commit -m "Initial rails-b2b template"
```

Then create/push the remote and use the raw `template.rb` URL.

## One-command helper

`bin/new` wraps `rails new ... -m template.rb` for local usage.

## Notes

- `--skip-javascript --skip-hotwire` is intentional to avoid Turbo defaults.
- The template then installs Vite + React + Inertia explicitly.
- Solid Queue/Cache/Cable are explicitly configured to use SQLite databases (`queue`, `cache`, `cable`).
