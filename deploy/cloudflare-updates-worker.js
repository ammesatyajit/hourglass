// Hourglass fresh-download and Sparkle-update counter.
//
// Bind a Cloudflare KV namespace to this Worker as `COUNTS`. Each request is
// recorded under its own key, so simultaneous downloads cannot overwrite one
// another. The Worker then redirects to the real GitHub release asset.
//
// Public links:
//   /download/<version>/<file>  Fresh/manual install (README and website)
//   /update/<version>/<file>    Sparkle auto-update (appcast enclosure only)
//   /stats                      Separate fresh-download and update totals
//
// A GET records one event. HEAD requests are redirected without being counted,
// which avoids inflating totals when a client only probes the asset.

const GH_RELEASES = "https://github.com/ammesatyajit/hourglass/releases/download";
const ASSET_ROUTE = /^\/(download|update)\/([\w.+-]+)\/([A-Za-z0-9._-]+)$/;

// GitHub recorded 84 DMG downloads before this Worker began separating fresh
// installs from Sparkle traffic. Release and appcast timing produced a single
// historical estimate of 67 fresh downloads. Keep it visibly labeled as an
// estimate rather than inventing historical per-request KV events.
const HISTORICAL_BASELINE = Object.freeze({
  through: "2026-08-14",
  githubAssetDownloads: 84,
  freshDownloadsEstimate: 67,
  updatesEstimate: 17,
});

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    // Anonymous site-visit counter: the website pings this once per page
    // load. Aggregate-only — no cookies, IPs, or identifiers, matching the
    // download counters. HEAD is not counted (same rule as assets).
    if (url.pathname === "/visit") {
      let counted = false;
      if (request.method === "GET" && env.COUNTS) {
        try {
          await recordEvent(env.COUNTS, "visit", "site");
          counted = true;
        } catch (error) {
          console.error("Failed to record Hourglass visit event", error);
        }
      }
      return new Response(null, {
        status: 204,
        headers: {
          "Cache-Control": "no-store",
          "Access-Control-Allow-Origin": "*",
          "X-Hourglass-Counted": String(counted),
        },
      });
    }

    if (url.pathname === "/stats") {
      if (!env.COUNTS) {
        return Response.json(
          { error: "Missing the COUNTS KV binding." },
          { status: 503, headers: { "Cache-Control": "no-store" } },
        );
      }

      const stats = await readStats(env.COUNTS);
      // CORS: the hourglass website reads this client-side to show a small
      // download counter. Read-only public aggregates, so * is fine.
      return Response.json(stats, {
        headers: {
          "Cache-Control": "no-store",
          "Access-Control-Allow-Origin": "*",
        },
      });
    }

    const match = url.pathname.match(ASSET_ROUTE);
    if (!match) {
      return Response.json({
        service: "Hourglass download counter",
        countingReady: Boolean(env.COUNTS),
        routes: {
          freshDownload: "/download/<version>/<file>",
          sparkleUpdate: "/update/<version>/<file>",
          stats: "/stats",
        },
      });
    }

    const [, kind, version, file] = match;
    let counted = false;

    // Fail open: a temporary KV problem must never prevent someone from
    // downloading Hourglass. It only means this one event may be missed.
    if (request.method === "GET" && env.COUNTS) {
      try {
        await recordEvent(env.COUNTS, kind, version);
        counted = true;
      } catch (error) {
        console.error("Failed to record Hourglass download event", error);
      }
    }

    return new Response(null, {
      status: 302,
      headers: {
        Location: `${GH_RELEASES}/v${version}/${file}`,
        "Cache-Control": "no-store",
        "X-Hourglass-Counted": String(counted),
      },
    });
  },
};

async function recordEvent(kv, kind, version) {
  const key = [
    "events",
    kind,
    version,
    Date.now(),
    crypto.randomUUID(),
  ].join(":");
  await kv.put(key, "1");
}

async function readStats(kv) {
  const freshDownloads = {};
  const updates = {};
  let siteVisits = 0;
  let cursor;

  do {
    const options = { prefix: "events:" };
    if (cursor) options.cursor = cursor;
    const page = await kv.list(options);

    for (const key of page.keys) {
      const [, kind, version] = key.name.split(":");
      if (kind === "visit") {
        siteVisits += 1;
        continue;
      }
      const bucket = kind === "download" ? freshDownloads
        : kind === "update" ? updates
        : null;
      if (bucket && version) bucket[version] = (bucket[version] || 0) + 1;
    }

    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);

  const trackedFreshDownloads = sum(Object.values(freshDownloads));
  const trackedUpdates = sum(Object.values(updates));

  return {
    freshDownloads,
    updates,
    historicalBaseline: HISTORICAL_BASELINE,
    trackedSince: "2026-08-14",
    // Site visits have no historical baseline — tracking starts when the
    // /visit route deploys, so tracked and total are the same number.
    trackedTotals: {
      freshDownloads: trackedFreshDownloads,
      updates: trackedUpdates,
      siteVisits,
    },
    totals: {
      freshDownloads:
        HISTORICAL_BASELINE.freshDownloadsEstimate + trackedFreshDownloads,
      updates: HISTORICAL_BASELINE.updatesEstimate + trackedUpdates,
      siteVisits,
    },
    totalsIncludeEstimatedHistoricalBaseline: true,
  };
}

function sum(values) {
  return values.reduce((total, value) => total + value, 0);
}
