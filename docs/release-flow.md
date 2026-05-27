# Release flow

Where the bits live:

- **Appcast feed**: `docs/appcast.xml`, served via GitHub Pages at
  `https://ammesatyajit.github.io/hourglass/appcast.xml`.
- **DMG assets**: GitHub Releases. The download URL convention is
  `https://github.com/ammesatyajit/hourglass/releases/download/v<MARKETING>/Hourglass.dmg`.

## Steps

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. `./scripts/generate.sh && ./scripts/build.sh && ./scripts/test.sh`.
3. `DEVELOPER_ID="Developer ID Application: …" NOTARY_PROFILE=NotaryHourglass ./scripts/package.sh`
   — produces a signed + notarized + sparkle-signed DMG at `build/Hourglass.dmg`
   plus a ready-to-paste `<item>` block in stdout.
4. `gh release create vX.Y.Z build/Hourglass.dmg` (add title and notes flags
   as needed).
5. Paste the `<item>` block into `docs/appcast.xml` inside `<channel>`,
   newest entry first.
6. `git commit docs/appcast.xml && git push` — Pages auto-deploys in ~30s
   and Sparkle clients see the update on their next scheduled poll.

## Notes

- XML comments inside `docs/appcast.xml` MUST NOT contain `--` (double
  hyphen — illegal per the XML spec). Sparkle's feed parser will fail with
  "An error occurred while parsing the update feed" otherwise. Keep prose
  documentation in this markdown file, not in the appcast.
- Until step 5 happens for the first time, `<channel>` is intentionally
  empty: Sparkle treats "no `<item>`" as "no updates available," which is
  correct.
