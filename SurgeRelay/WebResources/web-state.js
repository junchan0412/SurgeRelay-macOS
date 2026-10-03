(function installSurgeRelayWebState(global) {
  function combinedEnabled(snapshot) {
    return Boolean(snapshot?.combined?.isEnabled);
  }

  function fallbackSelection(snapshot, isMobile = false) {
    if (!snapshot || isMobile) return null;
    return 'overview';
  }

  function resolveInitialSelection(snapshot, options = {}) {
    const requested = options.requestedModuleID || '';
    const isMobile = Boolean(options.isMobile);
    const requestedExists = requested === 'overview' || requested === 'activity' ? true : requested === 'combined'
      ? combinedEnabled(snapshot)
      : Boolean(requested && snapshot?.modules?.some(module => module.id === requested));

    if (requestedExists) {
      return { selectedID: requested, hasSelection: true };
    }
    if (isMobile) {
      return { selectedID: null, hasSelection: false };
    }

    const selectedID = fallbackSelection(snapshot, false);
    return { selectedID, hasSelection: Boolean(selectedID) };
  }

  function normalizeSelection(snapshot, selectedID, isMobile = false) {
    const before = selectedID;
    let next = selectedID;

    if (next === 'combined' && !combinedEnabled(snapshot)) {
      next = fallbackSelection(snapshot, isMobile);
    }
    if (next && !['combined', 'overview', 'activity'].includes(next) && !snapshot?.modules?.some(module => module.id === next)) {
      next = fallbackSelection(snapshot, isMobile);
    }
    if (!next && !isMobile) {
      next = fallbackSelection(snapshot, false);
    }

    return { selectedID: next, changed: before !== next };
  }

  function moduleIDFromLocation(locationRef = global.location) {
    if (!locationRef?.href) return '';
    return new URL(locationRef.href).searchParams.get('module') || '';
  }

  function urlWithModule(locationRef = global.location, moduleID = '') {
    const url = new URL(locationRef.href);
    url.searchParams.set('module', moduleID || '');
    return url;
  }

  function urlWithoutModule(locationRef = global.location) {
    const url = new URL(locationRef.href);
    url.searchParams.delete('module');
    return url;
  }

  function initialHistoryTransition(locationRef = global.location, historyState = null) {
    if (historyState?.surgeRelay) return null;
    const moduleID = moduleIDFromLocation(locationRef);
    if (moduleID) {
      return {
        replace: {
          state: { surgeRelay: true, view: 'list', module: null },
          url: urlWithoutModule(locationRef)
        },
        push: {
          state: { surgeRelay: true, view: 'detail', module: moduleID, cameFromList: true },
          url: urlWithModule(locationRef, moduleID)
        }
      };
    }
    return {
      replace: {
        state: { surgeRelay: true, view: 'list', module: null },
        url: locationRef?.href || ''
      },
      push: null
    };
  }

  function detailHistoryEntry(locationRef = global.location, moduleID = '', cameFromList = false) {
    return {
      state: { surgeRelay: true, view: 'detail', module: moduleID, cameFromList: Boolean(cameFromList) },
      url: urlWithModule(locationRef, moduleID)
    };
  }

  function listHistoryEntry(locationRef = global.location) {
    return {
      state: { surgeRelay: true, view: 'list', module: null },
      url: urlWithoutModule(locationRef)
    };
  }

  function mobileBackAction(historyState = null) {
    return historyState?.surgeRelay && historyState?.cameFromList ? 'back' : 'show-list';
  }

  function historyNavigationTarget(locationRef = global.location, eventState = null, isMobile = false, fallbackID = null) {
    const moduleID = moduleIDFromLocation(locationRef);
    if (isMobile && (!moduleID || eventState?.view === 'list')) {
      return { action: 'show-list', moduleID: null };
    }
    return { action: 'select', moduleID: moduleID || fallbackID || null };
  }

  function createStateEventController(dependencies = {}) {
    const EventSourceImpl = dependencies.EventSource || global.EventSource;
    const documentRef = dependencies.document || global.document;
    const setIntervalImpl = dependencies.setInterval || global.setInterval;
    const clearIntervalImpl = dependencies.clearInterval || global.clearInterval;
    const setTimeoutImpl = dependencies.setTimeout || global.setTimeout;
    const clearTimeoutImpl = dependencies.clearTimeout || global.clearTimeout;
    const { loadState, applyState } = dependencies;
    const applyActivity = dependencies.applyActivity;
    const fetchActivity = dependencies.fetchActivity;
    const isWorking = dependencies.isWorking || (() => false);
    const getWorkspaceID = dependencies.getWorkspaceID || (() => null);
    const getRuntimeID = dependencies.getRuntimeID || (() => null);
    const eventURL = new URL(dependencies.eventsURL || '/api/events', 'http://relay.invalid');
    eventURL.searchParams.set('activity', '1');
    const eventPath = `${eventURL.pathname}${eventURL.search}`;
    const establishSession = dependencies.establishSession || (() => Promise.resolve());
    const onConnectionChange = dependencies.onConnectionChange || (() => {});
    const reconnectDelay = dependencies.reconnectDelay ?? 3000;
    const activityPollInterval = dependencies.activityPollInterval ?? 1000;
    let stateEvents = null;
    let pollingTimer = null;
    let activityTimer = null;
    let reconnectTimer = null;
    let generation = 0;
    let running = false;
    let stateInFlight = null;
    let activityInFlight = null;
    let reconnectAttempts = 0;
    let softReconnectUntil = 0;

    function disconnect() {
      if (stateEvents) { stateEvents.onerror = null; stateEvents.close?.(); }
      stateEvents = null;
    }

    function stopActivityPolling() {
      if (activityTimer != null) clearIntervalImpl(activityTimer);
      activityTimer = null;
    }

    function close() {
      running = false;
      generation += 1;
      stateInFlight = null; activityInFlight = null;
      disconnect();
      stopActivityPolling();
      if (pollingTimer != null) clearIntervalImpl(pollingTimer);
      if (reconnectTimer != null) clearTimeoutImpl?.(reconnectTimer);
      pollingTimer = null;
      reconnectTimer = null;
      softReconnectUntil = 0;
    }

    function pollState(epoch) {
      if (!running || epoch !== generation || documentRef?.hidden || stateInFlight) return;
      const request = {}; stateInFlight = request;
      Promise.resolve().then(() => loadState(false, false)).catch(() => {}).finally(() => { if (stateInFlight === request) stateInFlight = null; });
    }

    function syncActivityPolling() {
      const needed = running && !documentRef?.hidden && isWorking() && !stateEvents && fetchActivity && applyActivity;
      if (!needed) { stopActivityPolling(); return; }
      if (activityTimer != null) return;
      const epoch = generation;
      activityTimer = setIntervalImpl(() => {
        if (!running || epoch !== generation || documentRef?.hidden || !isWorking()) { stopActivityPolling(); return; }
        if (activityInFlight) return;
        const request = {}; activityInFlight = request;
        const workspaceID = getWorkspaceID();
        const runtimeID = getRuntimeID();
        Promise.resolve().then(fetchActivity).then(activity => {
          if (!activity || !running || epoch !== generation || stateEvents || documentRef?.hidden || getWorkspaceID() !== workspaceID || getRuntimeID() !== runtimeID) return;
          const responseWorkspaceID = activity.workspaceID ?? workspaceID;
          const responseRuntimeID = activity.runtimeID ?? runtimeID;
          if (responseWorkspaceID !== workspaceID || responseRuntimeID !== runtimeID) return;
          applyActivity(activity, { source: 'poll', workspaceID: responseWorkspaceID, runtimeID: responseRuntimeID, revision: activity.revision });
        }).catch(() => {}).finally(() => { if (activityInFlight === request) activityInFlight = null; });
      }, activityPollInterval);
    }

    function connect(epoch) {
      if (!running || epoch !== generation || documentRef?.hidden) return;
      disconnect();
      if (!EventSourceImpl) {
        if (pollingTimer == null) pollingTimer = setIntervalImpl(() => pollState(epoch), 5000);
        syncActivityPolling();
        onConnectionChange('polling');
        return;
      }
      onConnectionChange(reconnectAttempts ? 'reconnecting' : 'connecting');
      const stream = new EventSourceImpl(eventPath);
      stateEvents = stream;
      let stateSequence = 0;
      let stateWorkspaceID = null;
      let stateRuntimeID = null;
      let lastStateRevision = -1;
      let lastActivityRevision = -1;
      const retiredRuntimes = new Set();
      let receivedState = false;
      let stateReady = false;
      let pendingActivity = null;
      const isCurrent = () => running && epoch === generation && stateEvents === stream && !documentRef?.hidden;
      function deliverActivity(envelope) {
        if (!applyActivity || !isCurrent() || !stateReady || envelope.workspaceID !== stateWorkspaceID) return;
        const currentWorkspaceID = getWorkspaceID();
        if (currentWorkspaceID && currentWorkspaceID !== envelope.workspaceID) return;
        const runtimeID = envelope.runtimeID || null;
        if (runtimeID !== stateRuntimeID || (getRuntimeID() && getRuntimeID() !== runtimeID)) return;
        applyActivity(envelope.activity, { source: 'sse', workspaceID: envelope.workspaceID, runtimeID, revision: envelope.revision });
      }
      stream.addEventListener('state', event => {
        if (!isCurrent()) return;
        try {
          const snapshot = JSON.parse(event.data);
          const runtimeID = snapshot.runtimeID || null;
          const revision = Number.isSafeInteger(snapshot.revision) ? snapshot.revision : null;
          if (runtimeID && retiredRuntimes.has(runtimeID)) return;
          if (runtimeID !== stateRuntimeID) {
            if (stateRuntimeID) retiredRuntimes.add(stateRuntimeID);
            stateRuntimeID = runtimeID; lastStateRevision = -1; lastActivityRevision = -1;
          }
          if (revision != null && revision <= lastStateRevision) return;
          if (revision != null) { lastStateRevision = revision; lastActivityRevision = Math.max(lastActivityRevision, revision); }
          const sequence = ++stateSequence;
          stateWorkspaceID = snapshot.workspace?.id || null;
          receivedState = true; stateReady = false;
          if (pendingActivity && (pendingActivity.workspaceID !== stateWorkspaceID || (pendingActivity.runtimeID || null) !== stateRuntimeID || (revision != null && pendingActivity.revision < revision))) pendingActivity = null;
          if (Number.isSafeInteger(pendingActivity?.revision)) lastActivityRevision = Math.max(lastActivityRevision, pendingActivity.revision);
          const complete = accepted => {
            if (!isCurrent() || sequence !== stateSequence || accepted === false) return;
            stateReady = true;
            reconnectAttempts = 0; softReconnectUntil = 0;
            onConnectionChange('connected');
            if (pendingActivity) { const latest = pendingActivity; pendingActivity = null; deliverActivity(latest); }
            syncActivityPolling();
          };
          const result = applyState(snapshot, false, false);
          if (result && typeof result.then === 'function') Promise.resolve(result).then(complete).catch(() => {});
          else complete(result);
        } catch (_) {}
      });
      stream.addEventListener('activity', event => {
        if (!isCurrent() || !applyActivity) return;
        try {
          const envelope = JSON.parse(event.data);
          if (!envelope || typeof envelope.workspaceID !== 'string' || !envelope.activity || typeof envelope.activity !== 'object') return;
          if (receivedState && (envelope.workspaceID !== stateWorkspaceID || (envelope.runtimeID || null) !== stateRuntimeID)) return;
          if (Number.isSafeInteger(envelope.revision)) {
            if (envelope.revision <= lastActivityRevision) return;
            lastActivityRevision = envelope.revision;
          }
          if (!stateReady) pendingActivity = envelope;
          else deliverActivity(envelope);
        } catch (_) {}
      });
      stream.onerror = () => {
        if (!running || epoch !== generation || stateEvents !== stream) return;
        softReconnectUntil = Date.now() + 8000;
        disconnect();
        onConnectionChange('reconnecting');
        syncActivityPolling();
        Promise.resolve().then(establishSession).then(() => {
          if (running && epoch === generation && !documentRef?.hidden) return loadState(false, false);
        }).catch(() => {}).finally(() => {
          if (!running || epoch !== generation || documentRef?.hidden) return;
          const delay = Math.min(reconnectDelay * 2 ** reconnectAttempts++, 30000);
          reconnectTimer = setTimeoutImpl(() => { reconnectTimer = null; connect(epoch); }, delay);
        });
      };
      syncActivityPolling();
    }

    function start() {
      close();
      running = true;
      reconnectAttempts = 0;
      connect(generation);
    }

    function visibilityChanged() {
      if (documentRef?.hidden) { close(); onConnectionChange('paused'); }
      else { start(); pollState(generation); }
    }
    documentRef?.addEventListener?.('visibilitychange', visibilityChanged);

    return {
      start, close, syncActivityPolling, stopActivityPolling,
      dispose() { close(); documentRef?.removeEventListener?.('visibilitychange', visibilityChanged); },
      get currentEventSource() { return stateEvents; },
      get isSoftReconnecting() { return Date.now() < softReconnectUntil; }
    };
  }

  global.SurgeRelayWebState = {
    combinedEnabled,
    fallbackSelection,
    resolveInitialSelection,
    normalizeSelection,
    moduleIDFromLocation,
    urlWithModule,
    urlWithoutModule,
    initialHistoryTransition,
    detailHistoryEntry,
    listHistoryEntry,
    mobileBackAction,
    historyNavigationTarget,
    createStateEventController
  };
})(globalThis);
