import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const root = new URL('../../', import.meta.url);

export const logicSource = readFileSync(new URL('SurgeRelay/WebResources/web-logic.js', root), 'utf8');
export const optionsSource = readFileSync(new URL('SurgeRelay/WebResources/web-options.js', root), 'utf8');
export const formatSource = readFileSync(new URL('SurgeRelay/WebResources/web-format.js', root), 'utf8');
export const markupSource = readFileSync(new URL('SurgeRelay/WebResources/web-markup.js', root), 'utf8');
export const sidebarSource = readFileSync(new URL('SurgeRelay/WebResources/web-sidebar.js', root), 'utf8');
export const activitySource = readFileSync(new URL('SurgeRelay/WebResources/web-activity.js', root), 'utf8');
export const apiSource = readFileSync(new URL('SurgeRelay/WebResources/web-api.js', root), 'utf8');
export const stateSource = readFileSync(new URL('SurgeRelay/WebResources/web-state.js', root), 'utf8');
export const editorSource = readFileSync(new URL('SurgeRelay/WebResources/web-editor.js', root), 'utf8');
export const feedbackSource = readFileSync(new URL('SurgeRelay/WebResources/web-feedback.js', root), 'utf8');
export const previewSource = readFileSync(new URL('SurgeRelay/WebResources/web-preview.js', root), 'utf8');
export const appSource = readFileSync(new URL('SurgeRelay/WebResources/app.js', root), 'utf8');
export const indexHTML = readFileSync(new URL('SurgeRelay/WebResources/index.html', root), 'utf8');

export const context = vm.createContext({ console, URL });
vm.runInContext(logicSource, context, { filename: 'web-logic.js' });
vm.runInContext(optionsSource, context, { filename: 'web-options.js' });
vm.runInContext(formatSource, context, { filename: 'web-format.js' });
vm.runInContext(markupSource, context, { filename: 'web-markup.js' });
vm.runInContext(sidebarSource, context, { filename: 'web-sidebar.js' });
vm.runInContext(activitySource, context, { filename: 'web-activity.js' });
vm.runInContext(apiSource, context, { filename: 'web-api.js' });
vm.runInContext(stateSource, context, { filename: 'web-state.js' });
vm.runInContext(editorSource, context, { filename: 'web-editor.js' });
vm.runInContext(feedbackSource, context, { filename: 'web-feedback.js' });
vm.runInContext(previewSource, context, { filename: 'web-preview.js' });

export const logic = context.SurgeRelayWebLogic;
export const options = context.SurgeRelayWebOptions;
export const format = context.SurgeRelayWebFormat;
export const markup = context.SurgeRelayWebMarkup;
export const sidebarHelpers = context.SurgeRelayWebSidebar;
export const activityHelpers = context.SurgeRelayWebActivity;
export const api = context.SurgeRelayWebAPI;
export const stateHelpers = context.SurgeRelayWebState;
export const editorHelpers = context.SurgeRelayWebEditor;
export const feedbackHelpers = context.SurgeRelayWebFeedback;
export const previewHelpers = context.SurgeRelayWebPreview;

assert.ok(logic, 'web logic should install a global testable API');
assert.ok(options, 'web options should install a global testable API');
assert.ok(format, 'web format should install a global testable API');
assert.ok(markup, 'web markup should install a global testable API');
assert.ok(sidebarHelpers, 'web sidebar should install a global testable API');
assert.ok(activityHelpers, 'web activity should install a global testable API');
assert.ok(api, 'web api should install a global testable API');
assert.ok(stateHelpers, 'web state should install a global testable API');
assert.ok(editorHelpers, 'web editor should install a global testable API');
assert.ok(feedbackHelpers, 'web feedback should install a global testable API');
assert.ok(previewHelpers, 'web preview should install a global testable API');
