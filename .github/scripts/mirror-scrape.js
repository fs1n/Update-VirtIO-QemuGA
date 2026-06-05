/**
 * mirror-scrape.js
 * Scrapes fedorapeople.org (Anubis-protected) via Playwright Chromium,
 * finds ALL versions of VirtIO and QEMU-GA, and MERGES them into
 * manifest.json so old entries are preserved if a scrape only sees
 * a subset of versions.
 *
 * Output: ./manifest.json
 *
 * Set BROWSER_PROFILE_DIR to a persistent path so Anubis cookies survive
 * between runs (paired with actions/cache in the workflow).
 *
 * Behaviour:
 *  - If the scrape itself fails (all retries exhausted on an index page),
 *    nothing is written and the process exits non-zero.
 *  - If the scrape succeeds but a component yields 0 versions, that
 *    component is not touched in the manifest.
 *  - For each component, new entries replace existing ones with the same
 *    version, and existing entries with versions not seen this run are
 *    preserved (so older versions don't disappear when the front page
 *    cycles them off).
 */

const { chromium } = require('playwright');
const fs   = require('fs');
const path = require('path');

// ── Config ────────────────────────────────────────────────────────────────
const FPA_BASE       = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads';
const VIRTIO_ARCHIVE = `${FPA_BASE}/archive-virtio/`;
const QEMUGA_ARCHIVE = `${FPA_BASE}/archive-qemu-ga/`;

// VirtIO MSI filename is stable across all archive versions.
const VIRTIO_MSI            = 'virtio-win-gt-x64.msi';
// QEMU-GA changed filename at some point; check both candidates per directory.
const QEMUGA_MSI_CANDIDATES = ['qemu-ga-x86_64.msi', 'qemu-ga-x64.msi'];

const PROFILE_DIR   = process.env.BROWSER_PROFILE_DIR || '/tmp/playwright-profile';
const MANIFEST_PATH = path.resolve('./manifest.json');

// ── Helpers ───────────────────────────────────────────────────────────────

/**
 * Navigates to a URL with Playwright, waits for the Anubis PoW challenge
 * to resolve, and validates that real directory-listing content loaded.
 * Retries up to 3 times before throwing.
 */
async function fetchWithBrowser(page, url, timeout = 60000) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    if (attempt > 1) {
      console.log(`  [browser] retry ${attempt}/3 → ${url}`);
      await new Promise(r => setTimeout(r, 3000 * (attempt - 1)));
    } else {
      console.log(`  [browser] → ${url}`);
    }

    try {
      await page.goto(url, { waitUntil: 'networkidle', timeout });

      // Anubis shows "Checking your browser" while the PoW runs.
      // Wait until that text is gone.
      try {
        await page.waitForFunction(
          () => !document.body.innerText.includes('Checking your browser'),
          { timeout }
        );
      } catch {
        // No Anubis challenge active, or already cleared — continue.
      }

      // Brief pause so any post-challenge redirect can complete,
      // then re-confirm network is idle.
      await page.waitForTimeout(1500);
      await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});

      const html  = await page.content();
      const links = [...html.matchAll(/href="([^"]+)"/gi)].map(m => m[1]);

      // A real directory listing always has several links.
      // Fewer than 3 means we likely got challenge/error HTML.
      if (links.length < 3) {
        console.warn(`  [browser] only ${links.length} link(s) found — challenge page? retrying...`);
        continue;
      }

      console.log(`  [browser] ✓ ${links.length} links found`);
      return html;
    } catch (err) {
      console.warn(`  [browser] attempt ${attempt} error: ${err.message}`);
      if (attempt === 3) throw err;
    }
  }
  throw new Error(`fetchWithBrowser: all retries exhausted for ${url}`);
}

/**
 * Extracts all <a href> links from an HTML string.
 */
function extractLinks(html) {
  const matches = [...html.matchAll(/href="([^"]+)"/gi)];
  return matches.map(m => m[1]);
}

/**
 * Returns the last path segment of an href, stripping trailing slashes.
 * Handles both relative ("virtio-win-0.1.266-1/") and absolute
 * ("/groups/.../virtio-win-0.1.266-1/") hrefs from directory listings.
 */
function hrefBasename(href) {
  return href.replace(/\/$/, '').split('/').pop();
}

/**
 * Sorts VirtIO version strings ("0.1.285-1", "0.1.262-2", ...) descending
 * using proper numeric component comparison.
 */
function sortVirtioDesc(arr) {
  return [...arr].sort((a, b) => {
    const va = a.version.replace('-', '.').split('.').map(Number);
    const vb = b.version.replace('-', '.').split('.').map(Number);
    for (let i = 0; i < Math.max(va.length, vb.length); i++) {
      const diff = (vb[i] || 0) - (va[i] || 0);
      if (diff !== 0) return diff;
    }
    return 0;
  });
}

/**
 * Sorts QEMU-GA version strings ("110.0.2-1", "7.0-10", ...) descending
 * using proper numeric component comparison.
 */
function sortQemuGaDesc(arr) {
  return [...arr].sort((a, b) => {
    const [av, arRaw] = a.version.split('-');
    const [bv, brRaw] = b.version.split('-');
    const va = av.split('.').map(Number);
    const vb = bv.split('.').map(Number);
    for (let i = 0; i < Math.max(va.length, vb.length); i++) {
      const diff = (vb[i] || 0) - (va[i] || 0);
      if (diff !== 0) return diff;
    }
    return (parseInt(brRaw, 10) || 0) - (parseInt(arRaw, 10) || 0);
  });
}

/**
 * Reads the existing manifest (if any) and returns a sane default on
 * missing/unreadable/unparseable input. Never throws.
 */
async function loadExistingManifest() {
  try {
    const raw = await fs.promises.readFile(MANIFEST_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    return {
      generated: typeof parsed.generated === 'string' ? parsed.generated : null,
      virtio:    Array.isArray(parsed.virtio)    ? parsed.virtio    : [],
      qemu_ga:   Array.isArray(parsed.qemu_ga)   ? parsed.qemu_ga   : [],
    };
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.warn(`[merge] could not read existing manifest (${err.message}) — starting from empty`);
    } else {
      console.log('[merge] no existing manifest — starting from empty');
    }
    return { generated: null, virtio: [], qemu_ga: [] };
  }
}

/**
 * Merges `fresh` into `existing` for a single component, keyed by
 * `version` (last-write-wins from `fresh`). Returns the merged array
 * sorted by `sorter`.
 */
function mergeByVersion(existing, fresh, sorter) {
  const byVersion = new Map();
  for (const entry of existing) {
    if (entry && typeof entry.version === 'string') {
      byVersion.set(entry.version, entry);
    }
  }
  for (const entry of fresh) {
    if (entry && typeof entry.version === 'string') {
      byVersion.set(entry.version, entry);  // fresh wins
    }
  }
  return sorter([...byVersion.values()]);
}

// ── Main ──────────────────────────────────────────────────────────────────

(async () => {
  const existing = await loadExistingManifest();
  console.log(`[merge] existing manifest: ${existing.virtio.length} VirtIO, ${existing.qemu_ga.length} QEMU-GA`);

  // Fresh lists from the current scrape. Start empty so a thrown scraper
  // never partially overwrites the on-disk manifest.
  let freshVirtio  = [];
  let freshQemuGa  = [];

  // launchPersistentContext stores cookies/localStorage in PROFILE_DIR so
  // a solved Anubis PoW cookie survives across workflow runs (via actions/cache).
  // --disable-blink-features=AutomationControlled removes the automation flag
  // that bot-detection systems read via navigator.webdriver.
  const context = await chromium.launchPersistentContext(PROFILE_DIR, {
    headless: true,
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36',
    args: ['--disable-blink-features=AutomationControlled'],
  });

  // Hide the remaining webdriver signal that the args flag alone doesn't cover.
  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  });

  const page = await context.newPage();

  try {
    // ── VirtIO ─────────────────────────────────────────────────────────
    // We know VIRTIO_MSI is stable, so we only need the archive index —
    // no per-version directory fetch required.
    console.log('\n=== VirtIO ===');
    const virtioIndexHtml = await fetchWithBrowser(page, VIRTIO_ARCHIVE);
    const virtioLinks = extractLinks(virtioIndexHtml)
      .filter(h => /^virtio-win-[\d.]+-\d+/.test(hrefBasename(h)));

    console.log(`  Raw folder matches: ${virtioLinks.length}`);

    const virtioVersions = virtioLinks
      .map(href => {
        const basename = hrefBasename(href);
        const m = basename.match(/^virtio-win-([\d.]+-\d+)/);
        return m ? { basename, version: m[1] } : null;
      })
      .filter(Boolean);

    console.log(`  Versions found (${virtioVersions.length}):`, virtioVersions.map(v => v.version).join(', '));

    for (const v of virtioVersions) {
      const msiUrl = `${VIRTIO_ARCHIVE}${v.basename}/${VIRTIO_MSI}`;
      freshVirtio.push({ version: v.version, file: VIRTIO_MSI, url: msiUrl });
    }

    // ── QEMU-GA ────────────────────────────────────────────────────────
    // Filename changed between old and new versions, so we check each directory.
    console.log('\n=== QEMU Guest Agent ===');
    const qemuIndexHtml = await fetchWithBrowser(page, QEMUGA_ARCHIVE);
    const qemuLinks = extractLinks(qemuIndexHtml)
      .filter(h => /^qemu-ga-win-[\d.]+-\d+/.test(hrefBasename(h)));

    console.log(`  Raw folder matches: ${qemuLinks.length}`);

    const qemuVersions = qemuLinks
      .map(href => {
        const basename = hrefBasename(href);
        const m = basename.match(/^qemu-ga-win-([\d.]+)-(\d+)/);
        return m ? { basename, version: m[1], release: parseInt(m[2], 10) } : null;
      })
      .filter(Boolean);

    console.log(`  Versions found (${qemuVersions.length}):`, qemuVersions.map(v => `${v.version}-${v.release}`).join(', '));

    for (const v of qemuVersions) {
      const dirUrl        = `${QEMUGA_ARCHIVE}${v.basename}/`;
      const dirHtml       = await fetchWithBrowser(page, dirUrl);
      const fileBasenames = extractLinks(dirHtml).map(hrefBasename);

      let msiFile = null;
      for (const candidate of QEMUGA_MSI_CANDIDATES) {
        if (fileBasenames.includes(candidate)) { msiFile = candidate; break; }
      }

      if (!msiFile) {
        console.warn(`  skipping ${v.basename}: no known MSI candidate found`);
        continue;
      }

      const msiUrl = `${dirUrl}${msiFile}`;
      const verTag = `${v.version}-${v.release}`;
      console.log(`  ✓ ${verTag}/${msiFile}`);
      freshQemuGa.push({ version: verTag, file: msiFile, url: msiUrl });
    }

  } finally {
    await context.close();
  }

  // ── Safety gates before writing ──────────────────────────────────────
  // Hard requirement: each component that returned a usable list must be
  // non-empty. We never want to nuke the manifest because the site 5xx'd.
  if (freshVirtio.length === 0) {
    console.error('[merge] no VirtIO versions found this run — manifest NOT written');
    process.exit(2);
  }
  if (freshQemuGa.length === 0) {
    console.error('[merge] no QEMU-GA versions found this run — manifest NOT written');
    process.exit(2);
  }

  const mergedVirtio = mergeByVersion(existing.virtio, freshVirtio, sortVirtioDesc);
  const mergedQemuGa = mergeByVersion(existing.qemu_ga, freshQemuGa, sortQemuGaDesc);

  const manifest = {
    generated: new Date().toISOString(),
    virtio:    mergedVirtio,
    qemu_ga:   mergedQemuGa,
  };

  await fs.promises.writeFile(MANIFEST_PATH, JSON.stringify(manifest, null, 2));

  const addedVirtio = mergedVirtio.length - existing.virtio.length;
  const addedQemuGa = mergedQemuGa.length - existing.qemu_ga.length;
  console.log(`\n[merge] manifest written: ${mergedVirtio.length} VirtIO (${addedVirtio >= 0 ? '+' : ''}${addedVirtio}), ${mergedQemuGa.length} QEMU-GA (${addedQemuGa >= 0 ? '+' : ''}${addedQemuGa})`);
})();
