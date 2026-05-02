/**
 * mirror-scrape.js
 * Scrapes fedorapeople.org (Anubis-protected) via Playwright Chromium,
 * extracts the latest N versions of VirtIO and QEMU-GA,
 * and writes a manifest.json with direct Fedora download URLs.
 *
 * Output: ./manifest.json
 */

const { chromium } = require('playwright');
const fs   = require('fs');
const path = require('path');

// ── Config ────────────────────────────────────────────────────────────────
const KEEP_VERSIONS  = parseInt(process.env.KEEP_VERSIONS || '3', 10);
const FPA_BASE       = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads';
const VIRTIO_ARCHIVE = `${FPA_BASE}/archive-virtio/`;
const QEMUGA_ARCHIVE = `${FPA_BASE}/archive-qemu-ga/`;

const VIRTIO_MSI            = 'virtio-win-gt-x64.msi';
const QEMUGA_MSI_CANDIDATES = ['qemu-ga-x86_64.msi', 'qemu-ga-x64.msi'];

// ── Helpers ───────────────────────────────────────────────────────────────

/**
 * Navigates to a URL with Playwright and waits until the Anubis challenge
 * is resolved (indicated by the actual page content being loaded).
 * Returns the complete HTML body.
 */
async function fetchWithBrowser(page, url, waitSelector = 'body', timeout = 30000) {
  console.log(`  [browser] → ${url}`);
  await page.goto(url, { waitUntil: 'networkidle', timeout });

  // Anubis shows a "Checking your browser" text while the PoW is running.
  // We wait until this text is gone and actual content is present.
  try {
    await page.waitForFunction(
      () => !document.body.innerText.includes('Checking your browser'),
      { timeout }
    );
  } catch {
    // If no Anubis check, just continue
  }

  return page.content();
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
    console.log('\n=== VirtIO ===');
    const virtioIndexHtml = await fetchWithBrowser(page, VIRTIO_ARCHIVE);
    const virtioLinks = extractLinks(virtioIndexHtml)
      .filter(h => /^virtio-win-[\d.]+-\d+$/.test(hrefBasename(h)));

    const virtioVersions = virtioLinks
      .map(href => {
        const basename = hrefBasename(href);
        const m = basename.match(/virtio-win-([\d.]+-\d+)/);
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
      })
      .slice(0, KEEP_VERSIONS);

    console.log(`  Found (top ${KEEP_VERSIONS}):`, virtioVersions.map(v => v.version));

    for (const v of virtioVersions) {
      const dirUrl      = `${VIRTIO_ARCHIVE}${v.basename}/`;
      const dirHtml     = await fetchWithBrowser(page, dirUrl);
      const fileBasenames = extractLinks(dirHtml).map(hrefBasename);

      if (!fileBasenames.includes(VIRTIO_MSI)) {
        console.warn(`  ${VIRTIO_MSI} not found in ${dirUrl}, skipping.`);
        continue;
      }

      const msiUrl = `${dirUrl}${VIRTIO_MSI}`;
      console.log(`  ✓ ${v.version}/${VIRTIO_MSI} → ${msiUrl}`);
      manifest.virtio.push({ version: v.version, file: VIRTIO_MSI, url: msiUrl });
    }

    // ── QEMU-GA ────────────────────────────────────────────────────────
    console.log('\n=== QEMU Guest Agent ===');
    const qemuIndexHtml = await fetchWithBrowser(page, QEMUGA_ARCHIVE);
    const qemuLinks = extractLinks(qemuIndexHtml)
      .filter(h => /^qemu-ga-win-[\d.]+-\d+/.test(hrefBasename(h)));

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
      })
      .slice(0, KEEP_VERSIONS);

    console.log(`  Found (top ${KEEP_VERSIONS}):`, qemuVersions.map(v => `${v.version}-${v.release}`));

    for (const v of qemuVersions) {
      const dirUrl      = `${QEMUGA_ARCHIVE}${v.basename}/`;
      const dirHtml     = await fetchWithBrowser(page, dirUrl);
      const fileBasenames = extractLinks(dirHtml).map(hrefBasename);

      let msiFile = null;
      for (const candidate of QEMUGA_MSI_CANDIDATES) {
        if (fileBasenames.includes(candidate)) { msiFile = candidate; break; }
      }

      if (!msiFile) {
        console.warn(`  No matching MSI candidate in ${dirUrl}, skipping.`);
        continue;
      }

      const msiUrl = `${dirUrl}${msiFile}`;
      const verTag = `${v.version}-${v.release}`;
      console.log(`  ✓ ${verTag}/${msiFile} → ${msiUrl}`);
      manifest.qemu_ga.push({ version: verTag, file: msiFile, url: msiUrl });
    }

  } finally {
    await browser.close();
  }

  // ── Write manifest ────────────────────────────────────────────────────
  const manifestPath = path.resolve('./manifest.json');
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  console.log(`\nmanifest.json written:\n${JSON.stringify(manifest, null, 2)}`);
})();
