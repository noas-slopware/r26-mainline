# ci

The workflow that builds the Alpine packages of the `alpine` branch and publishes them on GitHub
Pages (after linux-hiby-rs6's Nura workflow, scaled down to three packages).

| path | what |
|---|---|
| `.github/workflows/alpine-packages.yml` | plan, build (abuild in an armv7 Alpine container, natively on an arm64 runner where it can), publish to Pages, mirror to YuruMirror |
| `.github/alpine/repo.py` | plan (package hashes against the published `built.json`), merge (the published files of unchanged packages plus this run's builds), fetch (the live repository, for the mirror) |
| `.github/alpine/index.sh` | `apk index` + `abuild-sign`, as abuild does it |
| `.github/alpine/index.html` | the Pages front page |
| `.github/actions/mirror/` | rsync of `alpine/` to mirror.funami.tech over Tailscale; skips without its secrets |
| `keys/r26-mainline-1cc0db58.rsa.pub` | the repository's public key; the private key is the `R26_REPO_PRIVKEY` secret |

Run it with `gh workflow run alpine-packages.yml --ref ci` (`-f force=true` rebuilds everything);
it also runs daily and on every push to this branch. A push to `alpine` does not start it.

Secrets: `R26_REPO_PRIVKEY` (required). For the mirror: `TS_OAUTH_CLIENT_ID`, `TS_AUDIENCE`,
`SSH_HOST`, `SSH_USER`, `SSH_KEY`, `REMOTE_DIR`, the same set the other ports' workflows use.
