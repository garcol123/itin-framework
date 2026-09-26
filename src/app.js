(() => {
  const buttons = [...document.querySelectorAll('.info-button')];

  const close = (button) => {
    const note = document.getElementById(button.getAttribute('aria-controls'));
    note?.classList.remove('is-open');
    button.setAttribute('aria-expanded', 'false');
  };

  buttons.forEach((button) => {
    button.addEventListener('click', () => {
      const note = document.getElementById(button.getAttribute('aria-controls'));
      const isOpen = !note.classList.contains('is-open');
      buttons.forEach(close);
      note.classList.toggle('is-open', isOpen);
      button.setAttribute('aria-expanded', String(isOpen));
    });
  });

  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    buttons.forEach(close);
  });
})();
