import assert from 'node:assert/strict';
import { appSource, options } from './harness.mjs';

assert.equal(options.scriptHubDefaults.removeCommentedRewrites, true);
assert.ok(
  options.advancedGroups.some(group => group.id === 'script-conversion'),
  'advanced option groups should include script conversion controls'
);
assert.doesNotMatch(
  appSource,
  /function (moduleSubtitle|moduleStatusTitle|failureSummary|folderTitle|publishedRelativePathForDraft|outputPathNotice|isValidHTTPURL|isNativeSurgeSource|validateModuleEditorFields|moduleEditorPayload|activityPresentation|normalizedOutputFileName|suggestedNameFromSource|normalizeFolder|isFileSource|sgmoduleName|existingSgmoduleName|baseName|existingFileBaseName)\(/,
  'app.js should call web-logic helpers directly instead of re-declaring wrappers'
);
assert.doesNotMatch(
  appSource,
  /function (setAdvancedExpanded|animateAdvancedResize|animateOptionGroup|collectScriptHubOptions|populateScriptHubOptions|hasAdvancedValues|populateOutputFolders|updateIconURLPreview|scheduleNameLookup)\(/,
  'app.js should use web-editor helpers for editor UI details'
);
assert.doesNotMatch(
  appSource,
  /form\.(name|category|iconURL|outputFolder|outputFileName|sourceURL|sourceFormat|storageLocation)\.value/,
  'app.js should let web-editor populate and collect module form fields'
);
assert.doesNotMatch(
  appSource,
  /function (openDialog|closeDialog|askConfirmation|resolveConfirmation|resetHorizontalScroll|copyText|showCopySuccess|showToast)\(/,
  'app.js should use web-feedback helpers for feedback and dialog details'
);
assert.doesNotMatch(
  appSource,
  /function (loadPreview|savePreview|restorePreview)\(/,
  'app.js should use web-preview helpers for preview state and actions'
);
assert.doesNotMatch(
  appSource,
  /history\.(pushState|replaceState)\(\{\s*surgeRelay/,
  'app.js should use web-state helpers to construct history entries'
);
assert.doesNotMatch(
  appSource,
  /detail-value monospaced">\$\{escapeHTML\((combined\.subscriptionURL|module\.publishedURL)\)\}/,
  'app.js should use web-markup for copyable URL sections'
);
assert.doesNotMatch(
  appSource,
  /function (renderSidebar|patchSidebarLive)\(/,
  'app.js should use web-sidebar for sidebar rendering and live patching'
);
assert.doesNotMatch(
  appSource,
  /function renderActivity\(/,
  'app.js should use web-activity for update activity rendering'
);
