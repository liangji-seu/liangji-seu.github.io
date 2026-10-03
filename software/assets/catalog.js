(function () {
  'use strict';

  const entries = Array.isArray(window.PAPER2ZH_SOFTWARE_CATALOG) ? window.PAPER2ZH_SOFTWARE_CATALOG : [];
  const cards = Array.from(document.querySelectorAll('[data-software-id]'));
  const filters = document.getElementById('software-filters');
  const search = document.getElementById('software-search');
  const resultCount = document.querySelector('[data-catalog-count]');
  const empty = document.getElementById('software-empty');
  const clear = document.getElementById('software-clear');
  let activeCategory = 'all';

  const entryById = new Map(entries.map((entry) => [entry.id, entry]));

  function searchText(entry, card) {
    return [entry.id, entry.name, entry.summary, entry.category, ...(entry.platforms || []), ...(entry.keywords || []), card.dataset.search || ''].join(' ').toLocaleLowerCase();
  }

  function setFilter(category) {
    activeCategory = category;
    filters.querySelectorAll('[data-category]').forEach((button) => {
      const selected = button.dataset.category === category;
      button.classList.toggle('is-active', selected);
      button.setAttribute('aria-pressed', String(selected));
    });
    render();
  }

  function renderFilters() {
    const counts = new Map();
    entries.forEach((entry) => counts.set(entry.category, (counts.get(entry.category) || 0) + 1));
    filters.replaceChildren();
    const all = document.createElement('button');
    all.type = 'button';
    all.className = 'catalog-filter is-active';
    all.dataset.category = 'all';
    all.setAttribute('aria-pressed', 'true');
    all.innerHTML = `全部 <span>${entries.length}</span>`;
    filters.appendChild(all);
    [...counts.keys()].sort().forEach((category) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'catalog-filter';
      button.dataset.category = category;
      button.setAttribute('aria-pressed', 'false');
      button.innerHTML = `${category} <span>${counts.get(category)}</span>`;
      filters.appendChild(button);
    });
    filters.addEventListener('click', (event) => {
      const button = event.target.closest('[data-category]');
      if (button) setFilter(button.dataset.category);
    });
  }

  function render() {
    const query = (search.value || '').trim().toLocaleLowerCase();
    let visible = 0;
    cards.forEach((card) => {
      const entry = entryById.get(card.dataset.softwareId);
      const categoryMatch = activeCategory === 'all' || (entry && entry.category === activeCategory);
      const queryMatch = !query || (entry && searchText(entry, card).includes(query));
      const show = categoryMatch && queryMatch;
      card.hidden = !show;
      if (show) visible += 1;
    });
    resultCount.textContent = `${visible}款软件`;
    empty.hidden = visible !== 0;
  }

  search.addEventListener('input', render);
  clear.addEventListener('click', () => {
    search.value = '';
    setFilter('all');
    search.focus();
  });
  renderFilters();
  render();
}());
