  // A casual browser-side deterrent; the static source remains public.
  try {
    if (sessionStorage.getItem(storageKey) === expected) return;
  } catch (_) {
    // Unlocking still works when browser storage is disabled.
  }
  document.documentElement.classList.add('trip-locked');

  document.addEventListener('DOMContentLoaded', () => {
    const dialog = document.createElement('dialog');
    dialog.id = 'trip-access-gate';
    dialog.setAttribute('aria-labelledby', 'trip-access-title');
    dialog.setAttribute('aria-describedby', 'trip-access-intro');

    const eyebrow = document.createElement('p');
    eyebrow.className = 'access-eyebrow';
    eyebrow.textContent = 'TRAVEL NOTES';
    const title = document.createElement('h1');
    title.id = 'trip-access-title';
    title.textContent = tripTitle;
    const intro = document.createElement('p');
    intro.className = 'access-intro';
    intro.id = 'trip-access-intro';
    intro.textContent = 'Enter the password to open the trip.';

    const form = document.createElement('form');
    const label = document.createElement('label');
    label.htmlFor = 'trip-access-password';
    label.textContent = 'Password';
    const input = document.createElement('input');
    input.id = 'trip-access-password';
    input.type = 'password';
    input.autocomplete = 'current-password';
    input.required = true;
    input.autofocus = true;
    input.setAttribute('aria-describedby', 'trip-access-error');
    const error = document.createElement('p');
    error.id = 'trip-access-error';
    error.setAttribute('role', 'alert');
    error.hidden = true;
    error.textContent = 'That password is incorrect. Try again.';
    const button = document.createElement('button');
    button.type = 'submit';
    button.textContent = 'Unlock trip';

    form.append(label, input, error, button);
    dialog.append(eyebrow, title, intro, form);
    document.body.append(dialog);
    dialog.addEventListener('cancel', (event) => event.preventDefault());
    dialog.showModal();

    input.addEventListener('input', () => {
      input.removeAttribute('aria-invalid');
      error.hidden = true;
    });
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      if (input.value !== expected) {
        error.hidden = false;
        input.setAttribute('aria-invalid', 'true');
        input.select();
        return;
      }
      try {
        sessionStorage.setItem(storageKey, expected);
      } catch (_) {
        // The current page can still be opened without persistent storage.
      }
      dialog.close();
      dialog.remove();
      document.documentElement.classList.remove('trip-locked');
      window.dispatchEvent(new Event('resize'));
      const heading = document.querySelector('main h1, header h1');
      if (heading) {
        heading.setAttribute('tabindex', '-1');
        heading.focus({ preventScroll: true });
      }
    });
  }, { once: true });
