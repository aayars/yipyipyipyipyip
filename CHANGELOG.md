# Changelog

## 2026-06-19 — Mastodon 4.6.0

- Upgraded Mastodon **4.5.8 → 4.6.0**.
- Switched `web` and `sidekiq` from the custom `mastodon-handfish` image to the
  stock upstream `tootsuite/mastodon` image; `streaming` bumped to match
  (`tootsuite/mastodon-streaming`). Images pull directly from Docker Hub — no
  build step, no rsync.
- **Why the themes dropped:** Mastodon 4.6 overhauled the theming system, so the
  Handfish theme variants no longer apply. They are temporarily removed
  pending a re-port to 4.6's new CSS-token theming system. The upstream
  TangerineUI project the themes were based on is discontinued as of the 4.6
  release, so the port is a from-scratch effort (tracked as follow-up).
- Migrations run two-phase per the v4.6.0 release notes
  (`SKIP_POST_DEPLOYMENT_MIGRATIONS=true` pre-deploy, then a plain post-deploy
  `rails db:migrate`).
- Deps satisfied by the stock image + existing services: Ruby 3.3+, Node 22+,
  FFmpeg 5.1+, libvips 8.13+ (image), PostgreSQL 17, Redis 7.
- Pre-upgrade database dump retained on the host for rollback; previous v4.5.8
  images retained.
