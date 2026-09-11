"""
Identity-repo sync server.

Accepts a Bearer token from a local agent, validates it against Okta,
and on success ensures that user has their own GitHub repo (creating
it under a fixed org on first sync) and pushes this checkout's
current content there as `main` — using a bot PAT so the caller never
handles Git or GitHub credentials directly.

The bot PAT should be a fine-grained token scoped to GITHUB_ORG only,
with "Administration: write" (to create repos) and "Contents: write"
(to push) — NOT a classic `repo`-scope token, which would also reach
every other repo that token's owner account can already touch.
"""
import os
import re
import subprocess
from pathlib import Path

from flask import Flask, request, jsonify
import requests

OKTA_DOMAIN = os.environ["OKTA_DOMAIN"]
GITHUB_PAT = os.environ["GITHUB_PAT"]
GITHUB_ORG = os.environ["GITHUB_ORG"]  # e.g. "autospeeg" — where per-user repos are created
PORT = int(os.environ.get("SYNC_PORT", "5000"))
HOST = os.environ.get("SYNC_HOST", "0.0.0.0")

REPO_DIR = Path(__file__).resolve().parent
REPO_PREFIX = "agent-"
GITHUB_API = "https://api.github.com"
GITHUB_API_HEADERS = {
    "Authorization": f"Bearer {GITHUB_PAT}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}

# Only letters/digits/._- are allowed in a synced branch/repo name. Okta's
# preferred_username is attacker-influenced input (it's whatever the
# identity provider account is named) and previously flowed straight
# into subprocess argv/branch names and now a GitHub repo name — this
# blocks git argument injection (e.g. a username starting with "-") and
# path traversal / API-path injection.
SAFE_USER_RE = re.compile(r"[^A-Za-z0-9._@-]")

app = Flask(__name__)


def sanitize_user_id(raw: str) -> str:
    cleaned = SAFE_USER_RE.sub("_", raw).strip("._-")
    return cleaned or "unknown_user"


def run_git(*args):
    return subprocess.run(
        ["git", *args],
        cwd=REPO_DIR,
        check=True,
        capture_output=True,
        text=True,
    )


def ensure_user_repo(repo_name: str):
    """Create <GITHUB_ORG>/<repo_name> if it doesn't already exist."""
    resp = requests.get(
        f"{GITHUB_API}/repos/{GITHUB_ORG}/{repo_name}",
        headers=GITHUB_API_HEADERS,
        timeout=10,
    )
    if resp.status_code == 200:
        return
    if resp.status_code != 404:
        resp.raise_for_status()

    resp = requests.post(
        f"{GITHUB_API}/orgs/{GITHUB_ORG}/repos",
        headers=GITHUB_API_HEADERS,
        json={"name": repo_name, "private": True, "auto_init": False},
        timeout=10,
    )
    resp.raise_for_status()


@app.route("/sync", methods=["POST"])
def sync():
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return "No token", 401
    token = auth_header.split(" ", 1)[1]

    try:
        user_info = requests.get(
            f"https://{OKTA_DOMAIN}/oauth2/v1/userinfo",
            headers={"Authorization": f"Bearer {token}"},
            timeout=5,
        )
    except requests.RequestException:
        return "Okta unreachable", 502
    if user_info.status_code != 200:
        return "Bad Okta token", 403

    user_id = sanitize_user_id(user_info.json().get("preferred_username", "unknown_user"))
    repo_name = f"{REPO_PREFIX}{user_id}"
    push_url = f"https://github.com/{GITHUB_ORG}/{repo_name}.git"

    try:
        ensure_user_repo(repo_name)
    except requests.RequestException as e:
        return jsonify(error="GitHub repo create/lookup failed", detail=str(e)), 502

    try:
        run_git("fetch", "origin")
        run_git("checkout", "-B", f"sync/{user_id}")
        # Credential helper below is a literal shell script passed to git;
        # git executes it via `sh -c`, which expands $GITHUB_PAT from this
        # process's environment at that point — the PAT itself never
        # appears in this process's argv (visible to `ps` on shared hosts).
        run_git(
            "-c",
            "credential.helper=!f() { echo username=x-access-token; echo \"password=$GITHUB_PAT\"; }; f",
            "push",
            push_url,
            f"sync/{user_id}:main",
        )
    except subprocess.CalledProcessError as e:
        return jsonify(error="git push failed", detail=e.stderr), 500

    return jsonify(message=f"Synced to {GITHUB_ORG}/{repo_name} (main)"), 200


if __name__ == "__main__":
    # Flask's dev server is HTTP only and single-threaded — fine for a
    # demo, but the real deployment described in the design (agent
    # posting a Bearer token over HTTPS from off-box) needs a TLS
    # reverse proxy (Caddy/nginx) and a production WSGI server in
    # front of this before it's more than a POC.
    app.run(host=HOST, port=PORT)
