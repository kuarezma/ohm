document.addEventListener('DOMContentLoaded', () => {
  initTheme();
  initLiveWattage();
  initReceipt();
  initLanes();
  initCopyButton();
});

function initTheme() {
  const toggleBtn = document.getElementById('theme-toggle');
  const root = document.documentElement;
  const storageKey = 'ohm-theme-pref';

  const savedTheme = localStorage.getItem(storageKey);
  if (savedTheme === 'dark' || savedTheme === 'light') {
    root.setAttribute('data-theme', savedTheme);
  }

  function getEffectiveTheme() {
    const attr = root.getAttribute('data-theme');
    if (attr) return attr;
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  function updateToggleLabel() {
    if (!toggleBtn) return;
    const current = getEffectiveTheme();
    const icon = toggleBtn.querySelector('.theme-icon');
    const text = toggleBtn.querySelector('.theme-text');
    if (icon) icon.textContent = current === 'dark' ? '☼' : '☾';
    if (text) text.textContent = current === 'dark' ? 'Light' : 'Dark';
    toggleBtn.setAttribute('aria-label', `Switch to ${current === 'dark' ? 'light' : 'dark'} theme`);
  }

  if (toggleBtn) {
    toggleBtn.addEventListener('click', () => {
      const next = getEffectiveTheme() === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      localStorage.setItem(storageKey, next);
      updateToggleLabel();
    });
  }

  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (!localStorage.getItem(storageKey)) updateToggleLabel();
  });

  updateToggleLabel();
}

function initLiveWattage() {
  const liveWattEl = document.getElementById('live-wattage');
  const pClusterVal = document.getElementById('p-cluster-val');
  const eClusterVal = document.getElementById('e-cluster-val');
  const pClusterBar = document.getElementById('p-cluster-bar');
  const eClusterBar = document.getElementById('e-cluster-bar');

  if (!liveWattEl) return;

  function updateMeters() {
    const totalW = (5.8 + Math.random() * (9.4 - 5.8)).toFixed(1);
    liveWattEl.textContent = `${totalW} W`;

    const pRatio = 0.68 + (Math.random() * 0.08 - 0.04);
    const pW = (totalW * pRatio).toFixed(1);
    const eW = (totalW - pW).toFixed(1);

    if (pClusterVal) pClusterVal.textContent = `${pW} W`;
    if (eClusterVal) eClusterVal.textContent = `${eW} W`;

    if (pClusterBar) {
      const pPercent = Math.min(92, Math.max(35, Math.round((pW / 7.2) * 100)));
      pClusterBar.style.width = `${pPercent}%`;
    }
    if (eClusterBar) {
      const ePercent = Math.min(80, Math.max(18, Math.round((eW / 3.0) * 100)));
      eClusterBar.style.width = `${ePercent}%`;
    }
  }

  setInterval(updateMeters, 1200);
}

function initReceipt() {
  const container = document.querySelector('.receipt-container');
  const rows = document.querySelectorAll('.receipt-row');
  const foot = document.querySelector('.receipt-foot');
  const totalValueEl = document.getElementById('receipt-total-value');
  const savingsBanner = document.getElementById('receipt-savings-banner');
  const totalSavedText = document.getElementById('total-saved-text');

  const initialRowData = {
    chrome: { name: 'Google Chrome', minutes: 72, saved: 25, formatted: '1h 12m' },
    slack: { name: 'Slack', minutes: 38, saved: 13, formatted: '38m' },
    xcode: { name: 'Xcode', minutes: 27, saved: 9, formatted: '27m' },
    spotify: { name: 'Spotify', minutes: 9, saved: 3, formatted: '9m' },
    other: { name: 'Other (display, radios)', minutes: 124, saved: 0, formatted: '2h 04m' }
  };

  const state = { chrome: false, slack: false, xcode: false, spotify: false };

  if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches && container && rows.length > 0) {
    container.classList.add('js-animating');
    const stagger = 120;
    const startDelay = 200;

    rows.forEach((row, index) => {
      setTimeout(() => row.classList.add('printed'), startDelay + index * stagger);
    });

    const footDelay = startDelay + rows.length * stagger + 60;
    setTimeout(() => {
      if (foot) foot.classList.add('printed');
      setTimeout(() => container.classList.remove('js-animating'), 350);
    }, footDelay);
  }

  function formatTime(minutes) {
    if (minutes >= 60) {
      const h = Math.floor(minutes / 60);
      const m = minutes % 60;
      return `${h}h ${m < 10 ? '0' : ''}${m}m`;
    }
    return `${minutes}m`;
  }

  function updateTotal() {
    let totalMinutes = initialRowData.other.minutes;
    let totalSaved = 0;

    for (const [key, isEActive] of Object.entries(state)) {
      const data = initialRowData[key];
      if (isEActive) {
        totalMinutes += (data.minutes - data.saved);
        totalSaved += data.saved;
      } else {
        totalMinutes += data.minutes;
      }
    }

    if (totalValueEl) totalValueEl.textContent = formatTime(totalMinutes);

    if (savingsBanner && totalSavedText) {
      if (totalSaved > 0) {
        savingsBanner.classList.add('active');
        totalSavedText.textContent = `${totalSaved} min`;
      } else {
        savingsBanner.classList.remove('active');
      }
    }
  }

  document.querySelectorAll('.receipt-row .btn-e').forEach(btn => {
    btn.addEventListener('click', () => {
      const appKey = btn.getAttribute('data-app');
      if (!appKey || !initialRowData[appKey]) return;

      const nextState = btn.getAttribute('aria-pressed') !== 'true';
      state[appKey] = nextState;
      btn.setAttribute('aria-pressed', nextState ? 'true' : 'false');

      const row = btn.closest('.receipt-row');
      const timeContainer = document.getElementById(`time-${appKey}`);
      const data = initialRowData[appKey];

      if (row) {
        row.classList.add('reprinting');
        setTimeout(() => row.classList.remove('reprinting'), 250);
      }

      if (timeContainer) {
        if (nextState) {
          const netMinutes = data.minutes - data.saved;
          timeContainer.innerHTML = `
            <del class="struck-time">${data.formatted}</del>
            <span class="active-time">${formatTime(netMinutes)}</span>
            <span class="saved-tag">−${data.saved}m</span>
          `;
          btn.setAttribute('aria-label', `Move ${data.name} back to performance cores`);
        } else {
          timeContainer.innerHTML = `<span class="active-time">${data.formatted}</span>`;
          btn.setAttribute('aria-label', `Switch ${data.name} to efficiency cores`);
        }
      }

      updateTotal();
    });
  });
}

function initLanes() {
  const pArea = document.getElementById('p-chips');
  const eArea = document.getElementById('e-chips');
  const allChips = document.querySelectorAll('.lanes-interactive-board .app-chip');

  if (!pArea || !eArea || !allChips.length) return;

  allChips.forEach(chip => {
    chip.addEventListener('click', () => {
      const parentArea = chip.parentElement;
      const appName = chip.querySelector('.chip-name')?.textContent || 'App';
      const actionSpan = chip.querySelector('.chip-action');

      chip.style.opacity = '0.4';
      chip.style.transform = 'scale(0.96)';

      setTimeout(() => {
        if (parentArea === pArea) {
          eArea.appendChild(chip);
          if (actionSpan) actionSpan.textContent = '→ P-lane';
          chip.setAttribute('aria-label', `${appName} on Efficiency lane. Click to shift to Performance lane.`);
        } else {
          pArea.appendChild(chip);
          if (actionSpan) actionSpan.textContent = '→ E-lane';
          chip.setAttribute('aria-label', `${appName} on Performance lane. Click to shift to Efficiency lane.`);
        }
        chip.style.opacity = '1';
        chip.style.transform = 'none';
      }, 160);
    });
  });
}

function initCopyButton() {
  const copyBtn = document.getElementById('btn-copy');
  const copyStatus = document.getElementById('copy-status');
  const brewCode = document.getElementById('brew-code');

  if (!copyBtn || !copyStatus || !brewCode) return;

  copyBtn.addEventListener('click', async () => {
    const text = brewCode.textContent.trim();
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(text);
      } else {
        const textarea = document.createElement('textarea');
        textarea.value = text;
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
      }
      copyStatus.textContent = 'Copied!';
      copyBtn.style.borderColor = 'var(--band-violet)';
      copyBtn.style.color = 'var(--band-violet)';

      setTimeout(() => {
        copyStatus.textContent = 'Copy';
        copyBtn.style.borderColor = '';
        copyBtn.style.color = '';
      }, 2000);
    } catch {
      copyStatus.textContent = 'Failed';
      setTimeout(() => { copyStatus.textContent = 'Copy'; }, 1500);
    }
  });
}
