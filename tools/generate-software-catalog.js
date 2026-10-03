#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const FILTER_START = '<!-- SOFTWARE_FILTERS_START -->';
const FILTER_END = '<!-- SOFTWARE_FILTERS_END -->';
const CARDS_START = '<!-- SOFTWARE_CARDS_START -->';
const CARDS_END = '<!-- SOFTWARE_CARDS_END -->';

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]));
}

function validateCatalog(entries) {
  if (!Array.isArray(entries) || entries.length === 0) throw new Error('Software catalog must contain at least one entry');
  const ids = new Set();
  for (const entry of entries) {
    if (!entry || typeof entry !== 'object' || typeof entry.id !== 'string' || typeof entry.name !== 'string' || typeof entry.summary !== 'string' || typeof entry.description !== 'string' || typeof entry.category !== 'string' || !Array.isArray(entry.platforms) || typeof entry.icon !== 'string' || typeof entry.details !== 'string' || typeof entry.release !== 'string' || typeof entry.repo !== 'string' || !Array.isArray(entry.keywords)) {
      throw new Error('Every catalog entry needs id, name, summary, description, category, platforms, icon, details, release, repo and keywords');
    }
    if (ids.has(entry.id)) throw new Error(`Duplicate software id: ${entry.id}`);
    ids.add(entry.id);
  }
  return entries;
}

function replaceMarkedBlock(html, start, end, body) {
  const startAt = html.indexOf(start);
  const endAt = html.indexOf(end);
  if (startAt < 0 || endAt < 0 || endAt < startAt) throw new Error(`Missing catalog markers: ${start} / ${end}`);
  return `${html.slice(0, startAt + start.length)}${body}${html.slice(endAt)}`;
}

function renderFilters(entries) {
  const counts = new Map();
  entries.forEach((entry) => counts.set(entry.category, (counts.get(entry.category) || 0) + 1));
  const filters = [`<button type="button" class="catalog-filter is-active" data-category="all" aria-pressed="true">全部 <span>${entries.length}</span></button>`];
  [...counts.keys()].sort().forEach((category) => {
    filters.push(`<button type="button" class="catalog-filter" data-category="${escapeHtml(category)}" aria-pressed="false">${escapeHtml(category)} <span>${counts.get(category)}</span></button>`);
  });
  return filters.join('');
}

function renderCard(entry) {
  const searchText = [entry.id, entry.name, entry.summary, entry.description, entry.category, ...entry.platforms, ...entry.keywords].join(' ');
  const tags = [...entry.platforms, entry.category, entry.status].filter(Boolean).map((tag) => `<span>${escapeHtml(tag)}</span>`).join('');
  const stats = entry.id === 'paper2zh' && entry.downloadStats === 'paper2zh'
    ? '<div class="catalog-download-meter" data-download-meter="paper2zh"><span data-download-count="paper2zh">下载量统计中…</span><small>公开版本安装包累计</small></div>'
    : '';
  return `<article class="software-card" data-software-id="${escapeHtml(entry.id)}" data-category="${escapeHtml(entry.category)}" data-search="${escapeHtml(searchText)}">
        <div class="software-card-main">
          <div class="software-card-title"><img src="${escapeHtml(entry.icon)}" alt="" width="44" height="44"><div><h2>${escapeHtml(entry.name)}</h2><p>${escapeHtml(entry.summary)}</p></div></div>
          <p class="software-card-summary">${escapeHtml(entry.description)}</p>
        </div>
        <div class="software-card-meta">${tags}</div>
        <div class="software-card-footer"><div class="software-card-links"><a class="software-card-detail" href="${escapeHtml(entry.details)}">查看详情 <span aria-hidden="true">→</span></a><a class="software-card-release" href="${escapeHtml(entry.release)}" rel="noopener">下载 <span aria-hidden="true">↗</span></a></div>${stats}</div>
      </article>`;
}

function updateCatalogHtml(html, entries) {
  const catalog = validateCatalog(entries);
  let updated = replaceMarkedBlock(html, FILTER_START, FILTER_END, renderFilters(catalog));
  updated = replaceMarkedBlock(updated, CARDS_START, CARDS_END, catalog.map(renderCard).join('\n      '));
  let countMatches = 0;
  updated = updated.replace(/(<[^>]*data-catalog-count[^>]*>)[^<]*(<\/[^>]+>)/g, (match, open, close) => {
    countMatches += 1;
    return `${open}${catalog.length}款软件${close}`;
  });
  if (countMatches === 0) throw new Error('Missing catalog result count marker');
  return updated;
}

function loadCatalog(manifestPath) {
  const context = { window: {} };
  vm.runInNewContext(fs.readFileSync(manifestPath, 'utf8'), context, { filename: manifestPath });
  return validateCatalog(context.window.PAPER2ZH_SOFTWARE_CATALOG);
}

function main() {
  const root = path.resolve(__dirname, '..');
  const manifestPath = path.join(root, 'source', 'software', 'assets', 'catalog-data.js');
  const htmlPath = path.join(root, 'source', 'software', 'index.html');
  const entries = loadCatalog(manifestPath);
  const html = fs.readFileSync(htmlPath, 'utf8');
  fs.writeFileSync(htmlPath, updateCatalogHtml(html, entries));
  console.log(`Generated ${entries.length} software catalog card(s) in ${path.relative(root, htmlPath)}`);
}

if (require.main === module) main();
module.exports = { escapeHtml, validateCatalog, renderFilters, renderCard, updateCatalogHtml };
