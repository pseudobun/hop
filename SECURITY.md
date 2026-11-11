# Security policy

## Supported versions

hop is in beta. Only the latest release gets security fixes; it updates itself
(`hop update`), or run `brew upgrade --cask pseudobun/tap/hop`.

## Reporting a vulnerability

Please don't open a public issue. Report it privately:

- on GitHub: **Security → Report a vulnerability**
  (<https://github.com/pseudobun/hop/security/advisories/new>), or
- by email to **urban@bunnys.cloud**.

Include the hop version (`hop version`), your macOS version, the steps to reproduce and what
an attacker gains. You'll hear back within a few days; once a fix is released the advisory is
published with credit, unless you'd rather stay anonymous.

## Trust model

- **The CLI talks to the running hop over a Unix socket** in hop's Application Support folder
  (folder `0700`, socket `0600`). hop answers only a peer that runs as the same user and whose
  code satisfies hop's own designated requirement, i.e. the hop binary itself run as `hop`.
  Other apps and scripts can't drive the running hop.
- Requests are logged (`log show --predicate 'subsystem == "com.pseudobun.hop"' | grep ipc`) and
  more than 10 per second are refused.
- **Your config is code.** `keepass.passwordCommand` and `keepass.cli` run as you. Anything that
  can write `~/.config/hop/` (or the dotfiles repo it is linked from) can run commands through hop
  with hop's permissions. Review config changes like code changes.
- hop's state files are written `0600` inside a `0700` folder; secrets (OpenAI key, KeePassXC
  master password) live in the login Keychain.
