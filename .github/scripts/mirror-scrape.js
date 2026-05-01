/**
 * mirror-scrape.js
 * Scrapet fedorapeople.org (Anubis-geschützt) via Playwright Chromium,
 * extrahiert die letzten N Versionen von VirtIO und QEMU-GA,
 * lädt die MSIs herunter und schreibt ein manifest.json.
 *
 * Ausgabe: ./mirror-out/<component>/<version>/<file>.msi
 */

const { chromium } = require('playwright');
const fs   = require('fs');
const path = require('path');
const https = require('https');
const http  = require('http');

// ── Config ────────────────────────────────────────────────────────────────
const KEEP_VERSIONS  = parseInt(process.env.KEEP_VERSIONS || '3', 10);
const OUT_DIR        = path.resolve('./mirror-out');
const FPA_BASE       = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads';
const VIRTIO_ARCHIVE = `${FPA_BASE}/archive-virtio/`;
const QEMUGA_ARCHIVE = `${FPA_BASE}/archive-qemu-ga/`;

const VIRTIO_MSI     = 'virtio-win-gt-x64.msi';
const QEMUGA_MSI_CANDIDATES = ['qemu-ga-x86_64.msi', 'qemu-ga-x64.msi'];

// ── Helpers ───────────────────────────────────────────────────────────────

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

/**
 * Navigiert zu einer URL mit Playwright und wartet bis Anubis-Challenge
 * gelöst ist (erkennbar daran dass der echte Seiteninhalt geladen ist).
 * Gibt den kompletten HTML-Body zurück.
 */
async function fetchWithBrowser(page, url, waitSelector = 'body', timeout = 30000) {
  console.log(`  [browser] → ${url}`);
  await page.goto(url, { waitUntil: 'networkidle', timeout });

  // Anubis zeigt einen "Checking your browser"-Text solange der PoW läuft.
  // Wir warten bis dieser Text weg ist und echter Content da ist.
  try {
    await page.waitForFunction(
      () => !document.body.innerText.includes('Checking your browser'),
      { timeout }
    );
  } catch {
    // Falls kein Anubis-Check, einfach weitermachen
  }

  return page.content();
}

/**
 * Extrahiert alle <a href> Links aus einem HTML-String.
 */
function extractLinks(html) {
  const matches = [...html.matchAll(/href="([^"]+)"/gi)];
  return matches.map(m => m[1]);
}

/**
 * Lädt eine Datei per HTTP(S) herunter. Folgt Redirects.
 * Playwright-Cookies werden als Header mitgegeben damit
 * der Download nicht erneut geblockt wird.
 */
async function downloadFile(url, destPath, cookies = []) {
  return new Promise((resolve, reject) => {
    const cookieHeader = cookies.map(c => `${c.name}=${c.value}`).join('; ');
    const options = {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36',
        ...(cookieHeader ? { Cookie: cookieHeader } : {})
      }
    };

    const get = url.startsWith('https') ? https.get : http.get;

    function doGet(targetUrl) {
      get(targetUrl, options, res => {
        // Redirect folgen
        if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
          return doGet(res.headers.location);
        }
        if (res.statusCode !== 200) {
          return reject(new Error(`HTTP ${res.statusCode} für ${targetUrl}`));
        }

        const total = parseInt(res.headers['content-length'] || '0', 10);
        let received = 0;
        let lastPct  = -1;

        const file = fs.createWriteStream(destPath);
        res.on('data', chunk => {
          received += chunk.length;
          if (total > 0) {
            const pct = Math.floor((received / total) * 100);
            if (pct !== lastPct && pct % 10 === 0) {
              process.stdout.write(`\r    ${pct}% (${(received/1024/1024).toFixed(1)} / ${(total/1024/1024).toFixed(1)} MB)`);
              lastPct = pct;
            }
          }
        });
        res.pipe(file);
        file.on('finish', () => { process.stdout.write('\n'); file.close(resolve); });
        file.on('error', reject);
      }).on('error', reject);
    }

    doGet(url);
  });
}

// ── Main ──────────────────────────────────────────────────────────────────

(async () => {
  ensureDir(OUT_DIR);
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
      .filter(h => /virtio-win-[\d.]+-\d+\/?$/.test(h));

    const virtioVersions = virtioLinks
      .map(href => {
        const m = href.match(/virtio-win-([\d.]+-\d+)/);
        return m ? { href: href.replace(/\/$/, ''), version: m[1] } : null;
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

    console.log(`  Gefunden (top ${KEEP_VERSIONS}):`, virtioVersions.map(v => v.version));

    for (const v of virtioVersions) {
      const dirUrl  = `${VIRTIO_ARCHIVE}${v.href}/`;
      const dirHtml = await fetchWithBrowser(page, dirUrl);
      const fileLinks = extractLinks(dirHtml);

      if (!fileLinks.includes(VIRTIO_MSI)) {
        console.warn(`  ⚠️  ${VIRTIO_MSI} nicht in ${dirUrl} gefunden, überspringe.`);
        continue;
      }

      const msiUrl  = `${dirUrl}${VIRTIO_MSI}`;
      const destDir = path.join(OUT_DIR, 'virtio', v.version);
      const destFile = path.join(destDir, VIRTIO_MSI);
      ensureDir(destDir);

      if (fs.existsSync(destFile)) {
        console.log(`  ✓ bereits vorhanden: ${v.version}/${VIRTIO_MSI}`);
      } else {
        console.log(`  ↓ Lade ${v.version}/${VIRTIO_MSI} ...`);
        const cookies = await context.cookies();
        await downloadFile(msiUrl, destFile, cookies);
        console.log(`  ✓ ${v.version}/${VIRTIO_MSI}`);
      }

      manifest.virtio.push({ version: v.version, file: VIRTIO_MSI, url: msiUrl });
    }

    // ── QEMU-GA ────────────────────────────────────────────────────────
    console.log('\n=== QEMU Guest Agent ===');
    const qemuIndexHtml = await fetchWithBrowser(page, QEMUGA_ARCHIVE);
    const qemuLinks = extractLinks(qemuIndexHtml)
      .filter(h => /^qemu-ga-win-[\d.]+-\d+/.test(h));

    const qemuVersions = qemuLinks
      .map(href => {
        const m = href.match(/^qemu-ga-win-([\d.]+)-(\d+)/);
        return m ? { href: href.replace(/\/$/, ''), version: m[1], release: parseInt(m[2], 10) } : null;
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

    console.log(`  Gefunden (top ${KEEP_VERSIONS}):`, qemuVersions.map(v => `${v.version}-${v.release}`));

    for (const v of qemuVersions) {
      const dirUrl  = `${QEMUGA_ARCHIVE}${v.href}/`;
      const dirHtml = await fetchWithBrowser(page, dirUrl);
      const fileLinks = extractLinks(dirHtml);

      let msiFile = null;
      for (const candidate of QEMUGA_MSI_CANDIDATES) {
        if (fileLinks.includes(candidate)) { msiFile = candidate; break; }
      }

      if (!msiFile) {
        console.warn(`  ⚠️  Kein passender MSI-Kandidat in ${dirUrl}, überspringe.`);
        continue;
      }

      const msiUrl   = `${dirUrl}${msiFile}`;
      const verTag   = `${v.version}-${v.release}`;
      const destDir  = path.join(OUT_DIR, 'qemu-ga', verTag);
      const destFile = path.join(destDir, msiFile);
      ensureDir(destDir);

      if (fs.existsSync(destFile)) {
        console.log(`  ✓ bereits vorhanden: ${verTag}/${msiFile}`);
      } else {
        console.log(`  ↓ Lade ${verTag}/${msiFile} ...`);
        const cookies = await context.cookies();
        await downloadFile(msiUrl, destFile, cookies);
        console.log(`  ✓ ${verTag}/${msiFile}`);
      }

      manifest['qemu_ga'].push({ version: verTag, file: msiFile, url: msiUrl });
    }

  } finally {
    await browser.close();
  }

  // ── Manifest schreiben ──────────────────────────────────────────────
  const manifestPath = path.join(OUT_DIR, 'manifest.json');
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  console.log(`\n✅ manifest.json geschrieben:\n${JSON.stringify(manifest, null, 2)}`);
})();