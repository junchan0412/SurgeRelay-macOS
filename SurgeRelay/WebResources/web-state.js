(function installSurgeRelayWebState(global) {
  function combinedEnabled(snapshot) {
    return Boolean(snapshot?.combined?.isEnabled);
  }

  function fallbackSelection(snapshot, isMobile = false) {
    if (!snapshot || isMobile) return null;
    if (combinedEnabled(snapshot)) return 'combined';
    return snapshot.modules?.[0]?.id || null;
  }

  function resolveInitialSelection(snapshot, options = {}) {
    const requested = options.requestedModuleID || '';
    const isMobile = Boolean(options.isMobile);
    const requestedExists = requested === 'combined'
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
    if (next && next !== 'combined' && !snapshot?.modules?.some(module => module.id === next)) {
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
    const setTimeoutImpl = dependencies.setTimeout || global.setTimeout;
    const loadState = dependencies.loadState;
    const applyState = dependencies.applyState;
    const establishSession = dependencies.establishSession || (() => Promise.resolve());
    const reconnectDelay = dependencies.reconnectDelay ?? 3000;
    let stateEvents = null;
    let pollingTimer = null;

    function close() {
      stateEvents?.close?.();
      stateEvents = null;
    }

    function start() {
      if (!EventSourceImpl) {
        if (pollingTimer == null) {
          pollingTimer = setIntervalImpl(() => {
            if (!documentRef?.hidden) loadState(false, false);
          }, 5000);
        }
        return;
      }

      close();
      stateEvents = new EventSourceImpl('/api/events');
      stateEvents.addEventListener('state', event => {
        try {
          applyState(JSON.parse(event.data), false, false);
        } catch (_) {
          // The next event contains a complete state snapshot.
        }
      });
      stateEvents.onerror = () => {
        close();
        if (!documentRef?.hidden) {
          Promise.resolve(establishSession())
            .catch(() => {})
            .finally(() => {
              Promise.resolve(loadState(false, false))
                .finally(() => setTimeoutImpl(start, reconnectDelay));
            });
        }
      };
    }

    return {
      start,
      close,
      get currentEventSource() {
        return stateEvents;
      }
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
