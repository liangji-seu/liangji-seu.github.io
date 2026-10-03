(function (root) {
  'use strict';

  const API_URL = 'https://api.github.com/repos/liangji-seu/paper2zh/releases';
  const PAGE_SIZE = 100;
  const MAX_PAGES = 100;
  const CACHE_KEY = 'paper2zh-download-count-v1';
  const CACHE_TTL_MS = 15 * 60 * 1000;
  const INSTALLER_NAME = /^paper2zh-Setup-.+-win64\.exe$/;

  function headerValue(headers, name) {
    if (!headers) return '';
    if (typeof headers.get === 'function') return headers.get(name) || '';
    return headers[name] || headers[name.toLowerCase()] || '';
  }

  function parseNextLink(headers) {
    const value = headerValue(headers, 'link');
    if (!value) return null;
    const parts = value.split(/,(?=\s*<)/);
    for (const part of parts) {
      if (!/rel\s*=\s*["']?next["']?/i.test(part)) continue;
      const match = part.match(/<([^>]+)>/);
      if (!match) throw new Error('Malformed pagination link');
      return match[1];
    }
    return null;
  }

  function aggregateReleases(releases) {
    if (!Array.isArray(releases)) throw new Error('Malformed releases response');
    let total = 0;
    for (const release of releases) {
      if (!release || typeof release !== 'object' || typeof release.draft !== 'boolean' || !Array.isArray(release.assets)) {
        throw new Error('Malformed release data');
      }
      for (const asset of release.assets) {
        if (!asset || typeof asset !== 'object' || typeof asset.name !== 'string' || typeof asset.state !== 'string') {
          throw new Error('Malformed release asset');
        }
        if (!INSTALLER_NAME.test(asset.name) || asset.state !== 'uploaded') continue;
        if (!Number.isSafeInteger(asset.download_count) || asset.download_count < 0) {
          throw new Error('Malformed installer download count');
        }
        if (release.draft === false) {
          total += asset.download_count;
          if (!Number.isSafeInteger(total)) throw new Error('Download count overflow');
        }
      }
    }
    return total;
  }

  async function fetchTotal(fetchImpl, signal, maxPages = MAX_PAGES) {
    if (typeof fetchImpl !== 'function') throw new Error('Fetch unavailable');
    let next = `${API_URL}?per_page=${PAGE_SIZE}&page=1`;
    let page = 0;
    const releases = [];
    while (next) {
      page += 1;
      if (page > maxPages) throw new Error('Release pagination limit reached');
      const response = await fetchImpl(next, {
        headers: { Accept: 'application/vnd.github+json' },
        signal
      });
      if (!response || response.ok !== true || typeof response.json !== 'function') {
        throw new Error(`GitHub releases request failed (${response && response.status ? response.status : 'unknown'})`);
      }
      const batch = await response.json();
      if (!Array.isArray(batch) || batch.length > PAGE_SIZE) throw new Error('Malformed releases page');
      releases.push(...batch);
      const linkedNext = parseNextLink(response.headers);
      if (linkedNext) {
        next = linkedNext;
      } else if (batch.length === PAGE_SIZE) {
        if (page >= maxPages) throw new Error('Release pagination limit reached');
        next = `${API_URL}?per_page=${PAGE_SIZE}&page=${page + 1}`;
      } else {
        next = null;
      }
    }
    return aggregateReleases(releases);
  }

  function validCache(cache) {
    return !!cache && Number.isSafeInteger(cache.count) && cache.count >= 0 && Number.isFinite(cache.cachedAt);
  }

  async function resolveCount(cache, now, fetcher) {
    if (validCache(cache) && now >= cache.cachedAt && now - cache.cachedAt < CACHE_TTL_MS) {
      return { count: cache.count, source: 'cache' };
    }
    try {
      const count = await fetcher();
      return { count, source: 'live' };
    } catch (error) {
      if (validCache(cache)) return { count: cache.count, source: 'cache' };
      throw error;
    }
  }

  function readCache() {
    try {
      const raw = root && root.localStorage ? root.localStorage.getItem(CACHE_KEY) : null;
      if (!raw) return null;
      const cache = JSON.parse(raw);
      return validCache(cache) ? cache : null;
    } catch (error) {
      return null;
    }
  }

  function writeCache(count) {
    try {
      if (root && root.localStorage) {
        root.localStorage.setItem(CACHE_KEY, JSON.stringify({ count, cachedAt: Date.now() }));
      }
    } catch (error) {
      // Private browsing and storage quotas must not affect the page or download link.
    }
  }

  function renderCount(result) {
    const formatted = result.count.toLocaleString('zh-CN');
    const suffix = result.source === 'cache' ? '（缓存数据）' : '';
    const nodes = root.document.querySelectorAll('[data-download-count]');
    nodes.forEach((node) => { node.textContent = `Windows 安装包累计下载 ${formatted} 次${suffix}`; });
    root.document.querySelectorAll('[data-download-meter]').forEach((meter) => { meter.dataset.state = result.source; });
  }

  function renderUnavailable() {
    root.document.querySelectorAll('[data-download-count]').forEach((node) => { node.textContent = '下载量暂不可用'; });
    root.document.querySelectorAll('[data-download-meter]').forEach((meter) => { meter.dataset.state = 'unavailable'; });
  }

  async function requestTotal() {
    const Controller = root.AbortController || (typeof AbortController !== 'undefined' ? AbortController : null);
    const controller = Controller ? new Controller() : null;
    const timer = root.setTimeout(() => { if (controller) controller.abort(); }, 10000);
    try {
      return await fetchTotal(root.fetch.bind(root), controller ? controller.signal : undefined);
    } finally {
      root.clearTimeout(timer);
    }
  }

  function init() {
    if (!root || !root.document || !root.document.querySelector('[data-download-count]')) return;
    const cache = readCache();
    resolveCount(cache, Date.now(), requestTotal).then((result) => {
      if (result.source === 'live') writeCache(result.count);
      renderCount(result);
    }).catch(() => {
      renderUnavailable();
    });
  }

  const api = { aggregateReleases, fetchTotal, parseNextLink, resolveCount };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) init();
}(typeof window !== 'undefined' ? window : null));
