# Release flow

Where the bits live:

- **Appcast feed**: `docs/appcast.xml`, served via GitHub Pages at
  `https://ammesatyajit.github.io/hourglass/appcast.xml`.
- **DMG origin**: GitHub Releases, using tag `v<MARKETING>` and asset
  `Hourglass.dmg`.
- **Fresh/manual downloads**: the README and website use
  `https://hourglass-downloads.ammesatyajit.workers.dev/download/<MARKETING>/Hourglass.dmg`.
- **Sparkle updates**: appcast enclosures use
  `https://hourglass-downloads.ammesatyajit.workers.dev/update/<MARKETING>/Hourglass.dmg`.
  The Worker records these separately and redirects both routes to GitHub.
- **Counts**: `https://hourglass-downloads.ammesatyajit.workers.dev/stats`.
  `totals.freshDownloads` intentionally excludes Sparkle updates. The all-time
  totals include an explicitly labeled historical estimate (67 fresh, 17
  updates) for the 84 GitHub asset downloads that predate request-level
  tracking; `trackedTotals` contains Cloudflare-only exact counts from August
  14, 2026 onward.

## Steps

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. `./scripts/generate.sh && ./scripts/build.sh && ./scripts/test.sh`.
3. `DEVELOPER_ID="Developer ID Application: …" NOTARY_PROFILE=NotaryHourglass ./scripts/package.sh`
   — produces a signed + notarized + sparkle-signed DMG at `build/Hourglass.dmg`
   plus a ready-to-paste `<item>` block in stdout.
4. `gh release create vX.Y.Z build/Hourglass.dmg` (add title and notes flags
   as needed).
5. Paste the `<item>` block into `docs/appcast.xml` inside `<channel>`,
   newest entry first. Its enclosure should use the Worker's `/update` route.
6. Update the README's `/download/<MARKETING>/Hourglass.dmg` link to the new
   version. Do not use GitHub's download count as the fresh-install metric.
7. `git commit README.md docs/appcast.xml && git push` — Pages auto-deploys in ~30s
   and Sparkle clients see the update on their next scheduled poll.

## Notes

- XML comments inside `docs/appcast.xml` MUST NOT contain `--` (double
  hyphen — illegal per the XML spec). Sparkle's feed parser will fail with
  "An error occurred while parsing the update feed" otherwise. Keep prose
  documentation in this markdown file, not in the appcast.
- Only GET requests through `/download` or `/update` are counted. HEAD probes
  redirect without incrementing either total.
