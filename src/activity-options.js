(() => {
  const config = JSON.parse(document.getElementById('activity-config').textContent);
  const storageKey = config.storage_key;
  const cards = [...document.querySelectorAll('[data-card]')];
  const checkboxes = cards.map((card) => card.querySelector('input[type="checkbox"]'));
  const filterButtons = [...document.querySelectorAll('[data-filter]')];
  const search = document.querySelector('[data-search]');
  const draftCount = document.querySelector('[data-draft-count]');
  const addedCount = document.querySelector('[data-added-count]');
  const removedCount = document.querySelector('[data-removed-count]');
  const noResults = document.querySelector('[data-no-results]');
  const toast = document.querySelector('[data-toast]');
  let activeFilter = 'all';

  const defaults = Object.fromEntries(checkboxes.map((box) => [box.value, box.dataset.default === 'true']));

  const changeState = (box) => {
    if (defaults[box.value] && box.checked) return 'already-picked';
    if (defaults[box.value] && !box.checked) return 'removed';
    if (!defaults[box.value] && box.checked) return 'added';
    return 'available';
  };

  const announce = (message) => {
    toast.textContent = message;
    toast.hidden = false;
    window.clearTimeout(announce.timer);
    announce.timer = window.setTimeout(() => { toast.hidden = true; }, 1800);
  };

  const save = () => {
    try {
      localStorage.setItem(storageKey, JSON.stringify(Object.fromEntries(checkboxes.map((box) => [box.value, box.checked]))));
    } catch (_) {
      // The page remains fully usable when browser storage is unavailable.
    }
  };

  const restore = () => {
    try {
      const saved = JSON.parse(localStorage.getItem(storageKey));
      if (!saved || typeof saved !== 'object') return;
      checkboxes.forEach((box) => {
        if (typeof saved[box.value] === 'boolean') box.checked = saved[box.value];
      });
    } catch (_) {
      // Ignore malformed or unavailable local browser data.
    }
  };

  const refreshCount = () => {
    draftCount.textContent = String(checkboxes.filter((box) => box.checked).length);
    addedCount.textContent = String(checkboxes.filter((box) => changeState(box) === 'added').length);
    removedCount.textContent = String(checkboxes.filter((box) => changeState(box) === 'removed').length);
    checkboxes.forEach((box) => {
      const card = box.closest('[data-card]');
      const state = changeState(box);
      const labels = {
        'already-picked': 'Already picked',
        removed: 'Removed',
        added: 'Newly added',
        available: 'Available'
      };
      const controlLabels = {
        'already-picked': 'Picked',
        removed: 'Restore',
        added: 'Added',
        available: 'Pick'
      };
      card.dataset.change = state;
      card.classList.toggle('is-draft-selected', box.checked);
      card.querySelector('[data-change-status]').textContent = labels[state];
      box.nextElementSibling.querySelector('.pick-control__label').textContent = controlLabels[state];
    });
  };

  const applyFilters = () => {
    const query = search.value.trim().toLowerCase();
    let visibleCount = 0;
    document.querySelectorAll('.destination').forEach((destination) => {
      let destinationCount = 0;
      destination.querySelectorAll('[data-card]').forEach((card) => {
        const stateMatches = activeFilter === 'all' ||
          card.dataset.state === activeFilter ||
          (activeFilter === 'community' && card.dataset.community === 'true') ||
          (activeFilter === 'changed' && ['added', 'removed'].includes(card.dataset.change));
        const textMatches = !query || card.dataset.name.includes(query);
        card.hidden = !(stateMatches && textMatches);
        if (!card.hidden) {
          destinationCount += 1;
          visibleCount += 1;
        }
      });
      destination.querySelector('[data-empty]').hidden = destinationCount !== 0;
    });
    noResults.hidden = visibleCount !== 0;
  };

  restore();
  refreshCount();
  applyFilters();

  checkboxes.forEach((box) => box.addEventListener('change', () => {
    save();
    refreshCount();
    applyFilters();
    const state = changeState(box);
    const label = box.closest('[data-card]').dataset.label;
    if (state === 'added') announce(`Added ${label}`);
    if (state === 'removed') announce(`Removed ${label}`);
    if (state === 'already-picked') announce(`Restored ${label}`);
    if (state === 'available') announce(`Undid addition of ${label}`);
  }));

  filterButtons.forEach((button) => button.addEventListener('click', () => {
    activeFilter = button.dataset.filter;
    filterButtons.forEach((candidate) => candidate.setAttribute('aria-pressed', String(candidate === button)));
    applyFilters();
  }));

  search.addEventListener('input', applyFilters);

  document.querySelector('[data-reset]').addEventListener('click', () => {
    checkboxes.forEach((box) => { box.checked = defaults[box.value]; });
    save();
    refreshCount();
    applyFilters();
    announce('Reset to the current itinerary');
  });

  document.querySelector('[data-copy]').addEventListener('click', async () => {
    const groupCards = (selectedCards) => {
      const grouped = new Map();
      selectedCards.forEach((card) => {
        if (!grouped.has(card.dataset.destination)) grouped.set(card.dataset.destination, []);
        grouped.get(card.dataset.destination).push(card.dataset.label);
      });
      return grouped;
    };
    const appendGroups = (lines, title, selectedCards, marker) => {
      lines.push(`${title} (${selectedCards.length})`);
      if (!selectedCards.length) {
        lines.push('- None', '');
        return;
      }
      groupCards(selectedCards).forEach((labels, destination) => {
        lines.push(destination, ...labels.map((label) => `${marker} ${label}`), '');
      });
    };
    const added = cards.filter((card) => card.dataset.change === 'added');
    const removed = cards.filter((card) => card.dataset.change === 'removed');
    const picked = cards.filter((card) => card.querySelector('input[type="checkbox"]').checked);
    const lines = [config.export_title, '', 'CHANGES FROM CURRENT ITINERARY', ''];
    appendGroups(lines, 'ADDED', added, '+');
    appendGroups(lines, 'REMOVED', removed, '−');
    appendGroups(lines, 'CURRENT DRAFT', picked, '-');
    const output = lines.join('\n').trim();
    try {
      await navigator.clipboard.writeText(output);
      announce(`Copied ${added.length} added · ${removed.length} removed`);
    } catch (_) {
      const link = document.createElement('a');
      link.href = URL.createObjectURL(new Blob([output], { type: 'text/plain' }));
      link.download = config.export_filename;
      link.click();
      URL.revokeObjectURL(link.href);
      announce('Downloaded your picks');
    }
  });
})();
