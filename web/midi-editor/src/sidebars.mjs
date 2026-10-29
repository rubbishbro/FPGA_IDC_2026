// Pointer hover, touch/click and keyboard share one visible/accessibility state.
export function setupSidebars() {
  const bindings = [
    ['tracks-dock', 'toggle-tracks', 'tracks-panel', 'close-tracks'],
    ['inspector-dock', 'toggle-inspector', 'inspector-panel', 'close-inspector'],
  ];
  const drawers = bindings.map(([dockId, handleId, panelId, closeId]) => {
    const dock = document.getElementById(dockId);
    const handle = document.getElementById(handleId);
    const panel = document.getElementById(panelId);
    let hovered = false, timer, suppressFocus = false;
    const editing = () => panel.contains(document.activeElement) &&
      document.activeElement.matches('input, select, textarea');
    const show = () => {
      clearTimeout(timer);
      dock.classList.add('open');
      panel.inert = false;
      panel.setAttribute('aria-hidden', 'false');
      handle.setAttribute('aria-expanded', 'true');
    };
    const hide = () => {
      clearTimeout(timer);
      if (panel.contains(document.activeElement)) {
        suppressFocus = true;
        handle.focus({preventScroll: true});
        suppressFocus = false;
      }
      dock.classList.remove('open');
      panel.inert = true;
      panel.setAttribute('aria-hidden', 'true');
      handle.setAttribute('aria-expanded', 'false');
    };
    const scheduleHide = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        const keyboardFocus = dock.contains(document.activeElement) &&
          document.activeElement.matches(':focus-visible');
        if (!hovered && !editing() && !keyboardFocus) hide();
      }, 220);
    };
    dock.addEventListener('pointerenter', e => {
      if (e.pointerType === 'touch') return;
      hovered = true;
      show();
    });
    dock.addEventListener('pointerleave', e => {
      if (e.pointerType === 'touch') return;
      hovered = false;
      scheduleHide();
    });
    dock.addEventListener('focusin', e => {
      if (!suppressFocus && e.target.matches(':focus-visible')) show();
    });
    dock.addEventListener('focusout', () => { if (!hovered) scheduleHide(); });
    handle.addEventListener('click', show);
    document.getElementById(closeId).addEventListener('click', hide);
    hide();
    return {dock, hide};
  });
  document.addEventListener('pointerdown', e => {
    for (const {dock, hide} of drawers) if (!dock.contains(e.target)) hide();
  });
}
