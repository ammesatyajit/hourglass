// Hourglass auto-update counter + redirect (Cloudflare Worker).
//
// WHY: the Sparkle appcast <enclosure url> normally points straight at the
// GitHub release DMG — the SAME url new users download from — so GitHub's
// asset download_count conflates "new downloads" with "auto-updates".
//
// This Worker sits in front of the update download ONLY: Sparkle fetches the
// enclosure through here, we bump a per-version counter in KV, then 302 to the
// real DMG on GitHub. New-user downloads still go straight to GitHub. So:
//
//     new_downloads(version) = GitHub asset download_count(version)
//                              − updates(version)   // this counter
//
// Setup: bind a KV namespace as COUNTS (dashboard → Worker → Settings →
// Bindings → KV namespace → variable name COUNTS).
//
// Routes:
//   GET /update/<version>/<file>   count an update, then redirect to the GitHub DMG
//                                   e.g. /update/0.3.2/Hourglass.dmg
//   GET /stats                     JSON of every per-version counter (read anytime)

const GH_RELEASES = "https://github.com/ammesatyajit/hourglass/releases/download";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Read the tallies whenever you want: https://<worker>/stats
    if (url.pathname === "/stats") {
      const { keys } = await env.COUNTS.list({ prefix: "updates:" });
      const out = {};
      for (const k of keys) out[k.name] = Number(await env.COUNTS.get(k.name)) || 0;
      return Response.json(out);
    }

    // The Sparkle enclosure url. Count one update, then hand off to GitHub.
    const m = url.pathname.match(/^\/update\/([\w.+-]+)\/(.+)$/);
    if (m) {
      const [, version, file] = m;
      const key = `updates:${version}`;
      const n = Number(await env.COUNTS.get(key)) || 0;
      // Low-volume counter — KV read/modify/write is fine here (a rare
      // simultaneous update could undercount by one; irrelevant at this scale).
      await env.COUNTS.put(key, String(n + 1));
      return Response.redirect(`${GH_RELEASES}/v${version}/${file}`, 302);
    }

    return new Response("Hourglass update counter", { status: 200 });
  },
};
