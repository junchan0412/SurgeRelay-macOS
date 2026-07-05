(function installSurgeRelayWebActivity(global) {
  const logic = global.SurgeRelayWebLogic;
  if (!logic) throw new Error('web-logic.js must load before web-activity.js');
  const format = global.SurgeRelayWebFormat;
  if (!format) throw new Error('web-format.js must load before web-activity.js');

  function createActivityController(options = {}) {
    const { ui } = options;
    const getState = options.getState || (() => null);

    function render() {
      const state = getState();
      if (!state) return;
      const activity = logic.activityPresentation(state.activity, {
        formatAutomaticPublish: format.formatTime
      });
      ui.status.textContent = activity.statusText;
      ui.refresh.disabled = activity.refreshDisabled;
      ui.refresh.title = activity.refreshTitle;
      ui.refresh.setAttribute('aria-label', activity.refreshAriaLabel);
      ui.cancelActivity.hidden = !activity.showCancel;
      ui.cancelActivity.disabled = !activity.canCancel;
      ui.cancelActivity.querySelector('span:last-child').textContent = activity.cancelLabel;
      if (activity.progressVisible) {
        ui.percent.textContent = `${activity.progressPercent}%`;
        ui.progressTrack.hidden = false;
        ui.progressFill.style.width = activity.progressWidth;
      } else {
        ui.percent.textContent = '';
        ui.progressTrack.hidden = true;
        ui.progressFill.style.width = activity.progressWidth;
      }
      ui.latestUpdate.textContent = format.formatDate(state.combined.lastUpdatedAt, '尚未更新');
    }

    return { render };
  }

  global.SurgeRelayWebActivity = {
    createActivityController
  };
})(this);
