# surface

Installer for the identity-repo sync server: clone this repo to a VM, run
`./start.sh`, enter secrets once, and it stands up a small Flask service
that lets Okta-authenticated agents sync their work to GitHub without ever
holding a GitHub credential themselves.

## Demo flow

1. **User auth (local machine):** agent opens a browser popup to the Okta
   login URL; user logs in; agent gets an Okta access token.
2. **Local agent action:** agent writes code/skills to a folder and makes
   a local git commit.
3. **Push to VM:** agent sends an HTTPS POST to the VM's `/sync` endpoint
   with the Okta token in the `Authorization: Bearer <token>` header.
4. **VM validation:** the server calls Okta's `/oauth2/v1/userinfo` with
   that token. Okta says yes or no.
5. **Repo provisioning + push:** on success, the server ensures a GitHub
   repo `agent-<user_id>` exists under the configured org (creating it via
   the GitHub API if this is that user's first sync), then pushes the
   current checkout to that repo's `main` branch using a bot PAT. The user
   never touches Git or GitHub credentials.

## Install on a new VM

```bash
git clone <this repo> surface
cd surface
./start.sh
```

`start.sh` is idempotent (safe to re-run) and:

- installs `python3`, `git`, and venv tooling if missing (apt/yum/brew)
- creates `.venv` and installs `requirements.txt`
- prompts for secrets the first time and writes them to `.env`
  (`chmod 600`, git-ignored — never re-prompts unless you opt in)
- offers to install itself as a systemd service (Linux) so it survives
  reboots and SSH disconnects; otherwise runs in the foreground

### Secrets you'll be asked for

| Var | Example | Notes |
|---|---|---|
| `OKTA_DOMAIN` | `dev-12345678.okta.com` | used only to validate the caller's token |
| `GITHUB_PAT` | `github_pat_...` | **fine-grained** token, scoped to `GITHUB_ORG` only, with `Administration:write` + `Contents:write` |
| `GITHUB_ORG` | `autospeeg` | org where per-user repos (`agent-<user_id>`) get created |
| `SYNC_PORT` / `SYNC_HOST` | `5000` / `0.0.0.0` | where the sync server listens |

## Security notes (read before using beyond a demo)

- **Blast radius of the bot PAT.** Any Okta user in your org who can reach
  `/sync` can, through this server, create a new GitHub repo and push to
  it. Use a **fine-grained PAT scoped to one org** with only
  `Administration:write` and `Contents:write` — a classic `repo`-scope
  token would also reach every other repo that token's owner account can
  touch, which is a much bigger blast radius than intended.
- **No guardrail on repo creation yet.** This POC does not rate-limit or
  cap repos-per-user — every distinct Okta `preferred_username` gets its
  own repo on first sync, with no limit. Fine for a demo; add a cap before
  this goes further.
- **Transport.** Flask's built-in dev server is plain HTTP and
  single-threaded. The demo flow assumes the agent POSTs over HTTPS from
  off-box, so put a TLS-terminating reverse proxy (Caddy/nginx) in front of
  this before using it outside localhost.
- **Input sanitization.** The Okta `preferred_username` is external input
  and is sanitized (`[A-Za-z0-9._@-]` only) before it's used as a git
  branch name, a GitHub repo name, or a subprocess argument, to block
  argument/path injection.
- **PAT never touches argv.** The push step passes the PAT to git through
  a `credential.helper` shell function that expands `$GITHUB_PAT` from the
  process environment at git's execution time, rather than embedding it in
  the push URL — so it doesn't show up in `ps` output on a shared host.
