'use strict';
(() => {
    const form = document.getElementById('waitlist-form');
    if (!form) return;
    const button = form.querySelector('button');
    const status = document.getElementById('waitlist-status');
    form.addEventListener('submit', async event => {
        event.preventDefault();
        if (button.disabled || !form.reportValidity()) return;
        button.disabled = true;
        form.setAttribute('aria-busy', 'true');
        status.dataset.error = 'false';
        status.textContent = 'Saving your place…';
        try {
            const fields = new FormData(form);
            const response = await fetch('/api/waitlist', { method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ email: fields.get('email'), company: fields.get('company'), consent: fields.get('consent') === 'on', variant: document.documentElement.dataset.copyVariant }) });
            const result = await response.json();
            if (!response.ok) throw new Error(result.message || 'Please try again shortly.');
            status.textContent = result.message;
            form.reset();
            button.textContent = "You're on the list";
        } catch (error) {
            status.dataset.error = 'true';
            status.textContent = error instanceof Error ? error.message : "We couldn't save your email. Please try again.";
            button.disabled = false;
        } finally { form.removeAttribute('aria-busy'); }
    });
})();
