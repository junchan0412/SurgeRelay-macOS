(function installSurgeRelayWebFeedback(global) {
  function createFeedbackController(dependencies = {}) {
    const ui = dependencies.ui || {};
    const documentRef = dependencies.document || global.document;
    const windowRef = dependencies.window || global;
    const navigatorRef = dependencies.navigator || global.navigator || {};
    const setTimeoutImpl = dependencies.setTimeout || global.setTimeout;
    const clearTimeoutImpl = dependencies.clearTimeout || global.clearTimeout;
    const closeDelay = dependencies.closeDelay ?? 165;
    const copySuccessDelay = dependencies.copySuccessDelay ?? 1600;
    const toastDelay = dependencies.toastDelay ?? 2600;
    let toastTimer = null;
    let confirmResolver = null;

    function openDialog(dialog) {
      dialog?.classList?.remove('is-closing');
      dialog?.showModal?.();
    }

    function closeDialog(dialog) {
      return new Promise(resolve => {
        if (!dialog?.open) return resolve();
        dialog.classList?.add('is-closing');
        setTimeoutImpl(() => {
          dialog.close?.();
          dialog.classList?.remove('is-closing');
          resolve();
        }, closeDelay);
      });
    }

    function askConfirmation(title, message, acceptLabel = '确认') {
      if (ui.confirmTitle) ui.confirmTitle.textContent = title;
      if (ui.confirmMessage) ui.confirmMessage.textContent = message;
      if (ui.confirmAccept) ui.confirmAccept.textContent = acceptLabel;
      openDialog(ui.confirmDialog);
      return new Promise(resolve => { confirmResolver = resolve; });
    }

    async function resolveConfirmation(value) {
      const resolver = confirmResolver;
      confirmResolver = null;
      await closeDialog(ui.confirmDialog);
      resolver?.(value);
    }

    function resetHorizontalScroll() {
      if (documentRef?.documentElement) documentRef.documentElement.scrollLeft = 0;
      if (documentRef?.body) documentRef.body.scrollLeft = 0;
      windowRef.scrollTo?.(0, windowRef.scrollY || 0);
    }

    async function copyText(text, button = null) {
      try {
        if (navigatorRef.clipboard?.writeText) await navigatorRef.clipboard.writeText(text || '');
        else {
          const textarea = documentRef.createElement('textarea');
          textarea.value = text || '';
          documentRef.body?.append?.(textarea);
          textarea.select?.();
          documentRef.execCommand?.('copy');
          textarea.remove?.();
        }
        showCopySuccess(button);
        return true;
      } catch (_) {
        showToast('拷贝失败', true);
        return false;
      }
    }

    function showCopySuccess(button) {
      if (!button) return;
      if (!button.dataset.copyLabel) button.dataset.copyLabel = button.innerHTML;
      clearTimeoutImpl(Number(button.dataset.copyTimer || 0));
      button.innerHTML = '<span class="symbol" data-symbol="checkmark"></span>拷贝成功';
      button.classList.add('copy-success');
      const timer = setTimeoutImpl(() => {
        if (!button.isConnected) return;
        button.innerHTML = button.dataset.copyLabel;
        button.classList.remove('copy-success');
        delete button.dataset.copyLabel;
        delete button.dataset.copyTimer;
      }, copySuccessDelay);
      button.dataset.copyTimer = String(timer);
    }

    function showToast(message, isError = false) {
      clearTimeoutImpl(toastTimer);
      if (!ui.toast) return;
      ui.toast.textContent = message;
      ui.toast.classList.toggle('error', isError);
      ui.toast.classList.add('visible');
      toastTimer = setTimeoutImpl(() => ui.toast.classList.remove('visible'), toastDelay);
    }

    return {
      openDialog,
      closeDialog,
      askConfirmation,
      resolveConfirmation,
      resetHorizontalScroll,
      copyText,
      showCopySuccess,
      showToast
    };
  }

  global.SurgeRelayWebFeedback = {
    createFeedbackController
  };
})(globalThis);
