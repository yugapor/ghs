# ghs

Switch GitHub accounts for **both** `gh` and `git` in one shot.

`gh auth switch` only changes the account used by the `gh` CLI. `ghs` also
rewrites the global `git config user.name` / `user.email`, so your commits
follow the account you switched to.

## Usage

```
ghs              pick an account interactively
ghs <login>      switch gh + git user.name/user.email to <login>
ghs list         list logged-in accounts
ghs status       show current gh account, git identity and remote
```

Name and email are taken from the GitHub API. If the account's email is
private, the noreply address (`<id>+<login>@users.noreply.github.com`) is used.

Per-account overrides:

```
git config --global ghs.<login>.name  "Your Name"
git config --global ghs.<login>.email "you@example.com"
```

Tip: run `gh auth setup-git` once so that git's HTTPS credentials also follow
the active `gh` account.

## Install

Download a binary from [Releases](../../releases) (Windows / macOS / Linux,
x86_64 and aarch64) and put it on your `PATH`. Requires `gh` and `git`.

## Build

Requires Zig 0.16.

```
zig build                      # ./zig-out/bin/ghs
zig build test
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall
```

Releases are built by GitHub Actions when a `v*` tag is pushed.

## License

MIT
