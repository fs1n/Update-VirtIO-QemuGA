/**
 * mirror-scrape.js
 * Scrapes fedorapeople.org (Anubis-protected) via Playwright Chromium,
 * finds ALL versions of VirtIO and QEMU-GA, and writes manifest.json
 * with direct Fedora download URLs.
 *
 * Output: ./manifest.json
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

// ── Main ──────────────────────────────────────────────────────────────────

(async () => {
  const manifest = { generated: new Date().toISOString(), virtio: [], qemu_ga: [] };

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36'
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
      .filter(Boolean)
      .sort((a, b) => {
        const va = a.version.replace('-', '.').split('.').map(Number);
        const vb = b.version.replace('-', '.').split('.').map(Number);
        for (let i = 0; i < Math.max(va.length, vb.length); i++) {
          const diff = (vb[i] || 0) - (va[i] || 0);
          if (diff !== 0) return diff;
        }
        return 0;
      });

    console.log(`  Versions found (${virtioVersions.length}):`, virtioVersions.map(v => v.version).join(', '));

    for (const v of virtioVersions) {
      const msiUrl = `${VIRTIO_ARCHIVE}${v.basename}/${VIRTIO_MSI}`;
      manifest.virtio.push({ version: v.version, file: VIRTIO_MSI, url: msiUrl });
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
      .filter(Boolean)
      .sort((a, b) => {
        const va = a.version.split('.').map(Number);
        const vb = b.version.split('.').map(Number);
        for (let i = 0; i < Math.max(va.length, vb.length); i++) {
          const diff = (vb[i] || 0) - (va[i] || 0);
          if (diff !== 0) return diff;
        }
        return b.release - a.release;
      });

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
      manifest.qemu_ga.push({ version: verTag, file: msiFile, url: msiUrl });
    }

  } finally {
    await browser.close();
  }

  // ── Write manifest ────────────────────────────────────────────────────
  const manifestPath = path.resolve('./manifest.json');
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  console.log(`\nmanifest.json written — ${manifest.virtio.length} VirtIO, ${manifest.qemu_ga.length} QEMU-GA versions`);
})();
