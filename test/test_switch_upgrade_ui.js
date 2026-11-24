const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const elementLookup = require("./html-fixture");

function fixture() {
  const page = fs.readFileSync(path.join(__dirname, "../src/ha/switch-upgrade-ui.js"), "utf8");
  const listeners = {};
  const sent = [];
  const timers = new Map();
  let timerId = 0;

  function element() {
    let text;
    return {
      children: [],
      get textContent() { return text; },
      set textContent(value) { text = value; this.children.length = 0; },
      dataset: {},
      classList: { toggle() {} },
      contains() { return false; },
      querySelectorAll() { return []; },
      closest() { return null; },
      appendChild(child) { this.children.push(child); },
      setAttribute() {},
      focus() { document.activeElement = this; },
      addEventListener(event, callback) { this[event] = callback; },
    };
  }
  const get = elementLookup(element, "src/ha/switch-upgrade.html");
  const document = {
    body: element(),
    getElementById: get,
    createElement: element,
    createTextNode(textContent) { return { textContent, children: [] }; },
  };
  const context = {
    document,
    Kit: {
      sendCommand(_, params) { sent.push(params); },
      listen(event, callback) { listeners[event] = callback; },
    },
    setTimeout(run, delay) {
      timers.set(++timerId, { run, delay });
      return timerId;
    },
    clearTimeout(id) { timers.delete(id); },
  };
  vm.runInNewContext(page, context);

  function reply(data, request = sent.at(-1).request) {
    listeners.HA_SWITCH_UPGRADE_REPLY({ ...data, request });
  }
  function advance(delay) {
    const item = [...timers].find(([, timer]) => timer.delay === delay);
    if (!item) return false;
    timers.delete(item[0]);
    item[1].run();
    return true;
  }
  return { context, document, sent, get, reply, advance, connected: listeners.HA_ADD_CONNECTED,
    progress: listeners.HA_SWITCH_UPGRADE_PROGRESS };
}

test("Quick Setup recovers from unsettled driver versions while Home Assistant is connected", () => {
  const { context, sent, get, reply, advance } = fixture();
  const next = get("migration-next"), refresh = get("migration-refresh"), summary = get("migration-summary");
  context.SwitchUpgradePage.connect();
  reply({ count: 1 });
  reply({ waiting: "driver_versions" });
  assert.match(summary.textContent, /drivers to report matching versions/);
  assert.equal(next.hidden, true);
  assert.equal(refresh.hidden, false);
  for (const delay of [2000, 4000, 8000]) {
    assert.equal(advance(delay), true);
    assert.equal(sent.at(-1).action, "scan");
    reply({ waiting: "driver_versions" });
  }
  assert.equal(advance(8000), false);
  assert.match(summary.textContent, /refresh this list/);
  refresh.onclick();
  assert.equal(sent.at(-1).refresh, true);
  assert.match(summary.textContent, /Checking for older/);
  reply({ rows: [{ id: 1, family: "light", name: "Old Patio Light", room: "Patio", state: "ready" }] });
  assert.equal(next.hidden, false);
  assert.equal(next.disabled, false);
  assert.equal(next.textContent, "Review 1 driver");
});

test("Quick Setup handles Home Assistant connecting before a waiting scan replies", () => {
  const { context, sent, get, reply, connected, advance } = fixture();
  context.SwitchUpgradePage.connect();
  reply({ count: 1 });
  connected();
  reply({ waiting: "home_assistant" });
  assert.deepEqual(sent.map((message) => message.action), ["availability", "scan", "scan"]);
  reply({ waiting: "home_assistant" });
  assert.match(get("migration-summary").textContent, /Waiting for Home Assistant to connect/);
  assert.equal(advance(2000), false);
  connected();
  reply({ rows: [{ id: 1, family: "light", name: "Old Patio Light", room: "Patio", state: "ready" }] });
  assert.equal(get("migration-next").hidden, false);
});

test("Quick Setup checks status when completion arrives before the running reply", () => {
  const { context, sent, get, reply, progress } = fixture();
  const row = { state: "review", id: 62, family: "light", name: "Porch", room: "Outside",
    message: "Prior scene instructions" };
  const saved = { saved: true, token: "scene-move" };
  const upgraded = { ...row, state: "upgraded", message: undefined, oldDriver: "Porch (old driver)" };
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply({ ...saved, rows: [row] });
  get("migration-next").onclick();
  progress({ ...saved, running: false, rows: [upgraded] });
  reply({ ...saved, running: true, rows: [row] });
  assert.equal(get("migration-heading").textContent, "Migrating drivers");
  assert.equal(get("migration-refresh").hidden, false);
  assert.equal(sent.at(-1).action, "status");
  reply({ ...saved, running: false, rows: [upgraded] });
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
  progress({ ...saved, running: true, rows: [row] });
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
});

test("Continue shows live migration progress before the first reply", () => {
  const { context, get, reply, progress } = fixture();
  const row = { state: "prepared", id: 62, family: "light", name: "Porch", room: "Outside" };
  const saved = { saved: true, token: "scene-move", rows: [row] };
  const summary = get("migration-summary");
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply(saved);
  get("migration-next").onclick();
  assert.match(summary.textContent, /Checking the project/);
  progress({ ...saved, running: true, progress: "Waiting for the new driver to report its state…" });
  assert.match(summary.textContent, /Waiting for the new driver/);
  progress({ ...saved, token: "unrelated", running: true, progress: "Ignore this" });
  assert.match(summary.textContent, /Waiting for the new driver/);
  reply({ ...saved, running: true, progress: "Preparing the new driver…" });
  assert.match(summary.textContent, /Waiting for the new driver/);
  progress({ ...saved, running: true, progress: "Applying driver names…" });
  assert.match(summary.textContent, /Applying driver names/);
  progress({ ...saved, running: false, rows: [{ ...row, state: "upgraded", oldDriver: "Old porch" }] });
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
});

test("Quick Setup shows verified completion when the resume reply is lost", () => {
  const { context, get, sent, reply, progress, advance } = fixture();
  const row = { state: "prepared", id: 62, family: "light", name: "Porch", room: "Outside" };
  const saved = { saved: true, token: "scene-move", rows: [row] };
  const running = { ...saved, running: true };
  const finished = { ...saved, running: false, rows: [{ ...row, state: "upgraded", oldDriver: "Old porch" }] };
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply(saved);
  get("migration-next").onclick();
  const originalRequest = sent.at(-1).request;
  progress(running);
  assert.equal(get("migration-heading").textContent, "Migrating drivers");
  progress({ ...finished, token: "another-batch" });
  assert.equal(get("migration-heading").textContent, "Migrating drivers");
  progress(finished);
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
  assert.equal(advance(60000), false);
  assert.equal(advance(18000), false);
  reply(running, originalRequest);
  progress({ ...saved, token: "another-batch" });
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
  assert.deepEqual(sent.map((message) => message.action), ["availability", "status", "resume"]);
});

test("Quick Setup opening during migration retries a missing status response automatically", () => {
  const { context, get, sent, reply, advance } = fixture();
  const row = { state: "upgraded", id: 62, family: "light", name: "Porch", room: "Outside", oldDriver: "Old porch" };
  const finished = { saved: true, token: "scene-move", running: false, rows: [row] };
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  assert.equal(advance(18000), true);
  assert.deepEqual(sent.map((message) => message.action), ["availability", "status", "status"]);
  reply(finished);
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
  assert.equal(advance(18000), false);
});

test("Quick Setup retries a lost opening check and displays saved results directly", () => {
  const { context, get, sent, reply, advance } = fixture();
  const row = { state: "upgraded", id: 62, family: "light", name: "Porch", room: "Outside", oldDriver: "Old porch" };
  const status = { saved: true, token: "saved-migration", canReviewRemoval: true, rows: [row] };
  context.SwitchUpgradePage.connect();
  assert.equal(sent.at(-1).includeStatus, true);
  assert.equal(advance(5000), true);
  assert.deepEqual(sent.map((message) => message.action), ["availability", "availability"]);
  assert.equal(sent.at(-1).includeStatus, true);
  reply({ pending: true, status });
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
  assert.equal(get("migration-cleanup").textContent, "Confirm testing");
  assert.equal(advance(18000), false);
});

test("Quick Setup retries a refused opening check once before asking for help", () => {
  const { context, get, sent, reply, advance } = fixture();
  context.SwitchUpgradePage.connect();
  reply({ error: "Project read failed" });
  assert.deepEqual(sent.map((message) => message.action), ["availability", "availability"]);
  assert.equal(advance(18000), true);
  assert.match(get("migration-summary").textContent, /Couldn’t check for older Home Assistant drivers/);
  assert.equal(get("migration-refresh").textContent, "Retry migration check");
  assert.equal(advance(18000), false);
});

test("A later migration completion recovers an opening check that already failed", () => {
  const { context, get, sent, reply, progress, advance } = fixture();
  const row = { state: "upgraded", id: 62, family: "light", name: "Porch", room: "Outside", oldDriver: "Old porch" };
  const status = { saved: true, token: "saved-migration", rows: [row] };
  context.SwitchUpgradePage.connect();
  assert.equal(advance(5000), true);
  assert.equal(advance(18000), true);
  assert.match(get("migration-summary").textContent, /Couldn’t check/);
  progress(status);
  progress(status);
  assert.deepEqual(sent.map((message) => message.action), ["availability", "availability", "availability"]);
  reply({ pending: true, status });
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
  assert.equal(advance(5000), false);
});

test("Completion prompts an immediate status read if Quick Setup reopened without the batch token", () => {
  const { context, get, sent, reply, progress, advance } = fixture();
  const row = { state: "upgraded", id: 62, family: "light", name: "Porch", room: "Outside", oldDriver: "Old porch" };
  const finished = { saved: true, token: "scene-move", running: false, rows: [row] };
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  progress(finished);
  progress(finished);
  assert.deepEqual(sent.map((message) => message.action), ["availability", "status", "status"]);
  reply(finished);
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
  assert.equal(advance(18000), false);
});

test("A lost start reply recovers with status reads for the requested batch only", () => {
  const { context, get, sent, reply, advance } = fixture();
  const row = { state: "ready", id: 62, family: "light", name: "Porch", room: "Outside" };
  context.window = { confirm: () => true };
  context.SwitchUpgradePage.connect();
  reply({ count: 1 });
  reply({ rows: [row] });
  get("migration-switches").children[0].children[0].children[0].onchange({ target: { checked: true } });
  get("migration-next").onclick();
  reply({ token: "scene-move", rows: [row] });
  get("migration-backup").checked = true;
  get("migration-next").onclick();
  assert.equal(advance(60000), true);
  assert.equal(sent.at(-1).token, "scene-move");
  reply({ saved: true, token: "another-batch", rows: [{ ...row, state: "upgraded" }] });
  assert.equal(advance(18000), true);
  reply({ saved: true, token: "scene-move", rows: [{ ...row, state: "upgraded" }] });
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
  assert.deepEqual(sent.map((message) => message.action), ["availability", "scan", "review", "start", "status", "status"]);
});

test("Quick Setup checks quiet running migrations and keeps manual recovery when status stays unavailable", () => {
  const { context, get, sent, reply, advance, progress } = fixture();
  const row = { state: "prepared", id: 62, family: "light", name: "Porch", room: "Outside" };
  const saved = { saved: true, token: "scene-move", rows: [row] };
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply({ ...saved, running: true });
  assert.equal(get("migration-heading").textContent, "Migrating drivers");
  assert.equal(advance(18000), true);
  assert.equal(sent.at(-1).token, "scene-move");
  assert.equal(advance(18000), true);
  assert.equal(advance(18000), true);
  assert.equal(advance(18000), false);
  assert.match(get("migration-summary").textContent, /Couldn’t confirm migration status/);
  assert.equal(get("migration-refresh").textContent, "Check migration status");
  get("migration-refresh").onclick();
  progress({ ...saved, running: false, rows: [{ ...row, state: "upgraded" }] });
  assert.equal(get("migration-heading").textContent, "Test the new drivers");
  assert.equal(advance(18000), false);
});

test("Quick Setup waits for the return instructions to be accepted", () => {
  const { context, document, sent, get, reply } = fixture();
  const next = get("migration-next");
  const backup = get("migration-backup");
  const dialog = get("migration-start-dialog");
  dialog.showModal = () => { dialog.open = true; };
  const row = {
    state: "ready", id: 62, name: "HA Switch", room: "Room",
    connections: [{ role: "Home Assistant connection", target: "HA Coordinator in Room", transfer: true }],
  };
  context.SwitchUpgradePage.connect();
  reply({ count: 1 });
  assert.equal(sent.at(-1).refresh, false);
  reply({ rows: [row] });
  get("migration-refresh").onclick();
  assert.equal(sent.at(-1).action, "scan");
  assert.equal(sent.at(-1).refresh, true);
  reply({ rows: [row] });
  next.onclick();
  reply({ token: "preview", rows: [row] });
  assert.equal(next.disabled, true);
  backup.checked = true;
  backup.onchange();

  next.onclick();
  assert.equal(dialog.open, true);
  assert.match(get("migration-start-message").textContent, /HA Coordinator in Room.*Quick Setup/);
  assert.equal(sent.at(-1).action, "review");
  dialog.returnValue = "back";
  dialog.close();
  assert.equal(document.activeElement, next);
  assert.equal(backup.checked, true);
  assert.equal(sent.at(-1).action, "review");

  next.onclick();
  assert.equal(dialog.returnValue, "");
  dialog.returnValue = "start";
  dialog.close();
  dialog.close();
  const starts = sent.filter((command) => command.action === "start");
  assert.equal(starts.length, 1);
  assert.equal(starts[0].token, "preview");
  assert.equal(starts[0].backup, true);
  assert.match(get("migration-summary").textContent, /Checking the project/);
  reply({ error: "The saved migration could not be checked." });
  assert.match(get("migration-summary").textContent, /could not be checked/);
  assert.equal(next.hidden, false);
  assert.equal(backup.checked, true);
});

test("Quick Setup offers a separate action to restore an interrupted migration", () => {
  const { context, document, sent, get, reply } = fixture();
  const next = get("migration-next");
  const heading = get("migration-heading");
  const row = { state: "cutover", id: 62, name: "HA Switch", room: "Hall", replacement: "New switch" };
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply({ saved: true, token: "saved-cutover", interruptedCutover: true, rows: [row] });
  assert.equal(heading.textContent, "Migration was interrupted");
  assert.equal(next.textContent, "Restore original connections");
  assert.equal(next.hidden, false);
  assert.equal(sent.at(-1).action, "status");
  get("migration").contains = (element) => element === next;
  next.focus();
  next.onclick();
  assert.equal(sent.at(-1).action, "resume");
  assert.equal(sent.at(-1).token, "saved-cutover");
  reply({ saved: true, token: "saved-cutover", rows: [{ ...row, state: "restored" }] });
  assert.equal(next.textContent, "Continue migration");
  assert.equal(document.activeElement, heading);
  assert.equal(sent.filter((command) => command.action === "resume").length, 1);
});

test("a Light migration names both sets of settings before approval", () => {
  const { context, get, reply } = fixture();
  const row = { state: "ready", id: 62, family: "light", name: "Patio Light", room: "Patio" };
  context.SwitchUpgradePage.connect();
  reply({ count: 1 });
  reply({ rows: [row] });
  get("migration-next").onclick();
  const settings = { kind: "Color and white temperature", format: "HS", range: "2700-5500" };
  reply({ token: "preview", rows: [{
    ...row,
    reviewedLoad: { name: "Patio bulb", entity: "light.patio" },
    lightSettings: { original: settings, replacement: settings },
  }] });
  function copy(node) {
    return [node.textContent, ...node.children.flatMap(copy)].filter(Boolean);
  }
  const preview = copy(get("migration-switches")).join("\n");
  assert.match(preview, /Original settings · Color and white temperature, HS color, 2700–5500 K/);
  assert.match(preview, /Settings on the new driver · Color and white temperature, HS color, 2700–5500 K/);
  assert.equal(get("migration-next").disabled, true);
});

test("Quick Setup shows the exact connection to check without unrelated programming steps", () => {
  const { context, document, sent, get, reply } = fixture();
  const heading = get("migration-heading");
  const next = get("migration-next");
  const row = {
    state: "review", id: 62, name: "Fireplace", room: "Patio",
    oldDriver: "Fireplace (old driver 62)", replacement: "Fireplace",
    unresolvedConnections: true, programming: "none", details: [],
    connections: [{ role: "Relay", target: "Fireplace timer in Patio", transfer: false }],
    message: "Check the unresolved connections in Composer. The original driver stays connected.",
  };
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply({ saved: true, token: "saved-review", rows: [row] });
  assert.equal(heading.textContent, "Check connections");
  function displayed(node) {
    return [node.textContent, ...node.children.flatMap(displayed)].filter(Boolean);
  }
  const copy = displayed(get("migration-switches")).join("\n");
  assert.match(copy, /check the marked links for Fireplace in Patio/);
  assert.match(copy, /Fireplace \(old driver 62\) in Patio still controls the switch/);
  assert.match(copy, /Relay → Fireplace timer in Patio · Check in Composer/);
  assert.doesNotMatch(copy, /Move the listed programming|Device Actions/);
  assert.doesNotMatch(copy, /Check the unresolved connections/);
  assert.equal(next.textContent, "Check connections");
  get("migration").contains = (element) => element === next;
  next.focus();
  next.onclick();
  assert.equal(sent.at(-1).action, "resume");
  assert.equal(sent.at(-1).token, "saved-review");
  assert.equal(sent.at(-1).reviewed, undefined);
  reply({ saved: true, token: "saved-review", rows: [{ ...row, state: "upgraded", unresolvedConnections: false }] });
  assert.equal(heading.textContent, "Test the new drivers");
  assert.equal(document.activeElement, heading);
});

test("completed migration explains the exact checks before offering removal", () => {
  const { context, document, sent, get, reply } = fixture();
  const cleanup = get("migration-cleanup");
  const next = get("migration-next");
  const backup = get("migration-backup");
  const panel = get("migration");
  const heading = get("migration-heading");
  const state = { saved: true, canReviewRemoval: true, removalScope: "batch|73:203|75:205", rows: [
    { id: 73, state: "upgraded", family: "light", name: "Scene Light", oldDriver: "Scene Light (old driver)",
      room: "Room", lighting: [{ kind: "scenes", name: "Migration Scene" }] },
    { id: 75, state: "upgraded", family: "switch", name: "Program Switch", oldDriver: "Program Switch (old driver)",
      room: "Room", hadProgramming: true, testEvents: [{ location: "HA Light in Room", event: "Turned On" }] },
  ] };
  function copy(node) {
    return [node.textContent, ...node.children.flatMap(copy)].filter(Boolean);
  }
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply(state);
  assert.equal(cleanup.textContent, "Confirm testing");
  assert.match(get("migration-summary").textContent, /System Design.*Confirm testing/);
  const rows = copy(get("migration-switches")).join("\n");
  assert.match(rows, /Migration Scene.*Activate Scene/);
  assert.match(rows, /Device Events.*Execute/);
  assert.match(rows, /HA Light in Room · Turned On/);
  panel.contains = (element) => element === cleanup || element === get("migration-back");
  cleanup.focus();
  cleanup.onclick();
  assert.equal(document.activeElement, heading);
  assert.equal(heading.textContent, "Confirm testing before removal");
  assert.match(get("migration-confirmation").textContent, /lighting scenes and load groups/);
  assert.equal(next.textContent, "Check old drivers");
  assert.equal(next.disabled, true);
  assert.equal(sent.at(-1).action, "status");
  backup.checked = true;
  backup.onchange();
  assert.equal(next.disabled, false);
  next.onclick();
  assert.equal(sent.at(-1).action, "review_removal");
  assert.equal(sent.at(-1).referencesReviewed, true);
  assert.equal(sent.at(-1).scope, state.removalScope);
  reply({ error: "Refresh migration status before continuing." });
  assert.equal(get("migration-refresh").textContent, "Refresh status");
  assert.equal(backup.checked, false);
  get("migration-refresh").onclick();
  assert.equal(sent.at(-1).action, "availability");
  reply({ pending: true, status: { ...state, removalScope: "latest|73:203|75:205" } });
  cleanup.onclick();
  assert.equal(next.disabled, true);
  backup.checked = true;
  backup.onchange();
  next.onclick();
  assert.equal(sent.at(-1).scope, "latest|73:203|75:205");
});

test("mixed migration shows a completed Light's tests when confirmation is available", () => {
  const { context, get, reply } = fixture();
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply({ saved: true, canReviewRemoval: true, rows: [
    { id: 73, state: "upgraded", family: "light", name: "Scene Light", oldDriver: "Old Scene Light",
      room: "Room", lighting: [{ kind: "scenes", name: "Migration Scene" }] },
    { id: 75, state: "review", name: "Switch", room: "Room", unresolvedConnections: true },
  ] });
  function copy(node) {
    return [node.textContent, ...node.children.flatMap(copy)].filter(Boolean);
  }
  assert.equal(get("migration-heading").textContent, "Check connections");
  assert.match(get("migration-summary").textContent, /Follow the tests below/);
  assert.equal(get("migration-cleanup").hidden, false);
  assert.match(copy(get("migration-switches")).join("\n"), /Migration Scene.*Activate Scene/);
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply({ saved: true, canReviewRemoval: true, rows: [
    { id: 73, state: "upgraded", family: "light", name: "Scene Light", oldDriver: "Old Scene Light",
      room: "Room", tested: true, referencesReviewed: true },
    { id: 75, state: "review", name: "Switch", room: "Room", unresolvedConnections: true },
  ] });
  assert.match(copy(get("migration-switches")).join("\n"), /Testing confirmed/);
});

test("reopening a mixed result shows a specific retry without starting it", () => {
  const { context, document, sent, get, reply } = fixture();
  const heading = get("migration-heading");
  const next = get("migration-next");
  const ready = { id: 73, state: "upgraded", name: "Test Light", oldDriver: "Old Test Light" };
  const blocked = { id: 75, state: "attention", name: "Test Switch" };
  context.SwitchUpgradePage.connect();
  reply({ pending: true });
  reply({ saved: true, token: "mixed", canReviewRemoval: true, rows: [ready, blocked] });
  assert.equal(heading.textContent, "Driver setup needs attention");
  assert.equal(next.textContent, "Retry driver setup");
  assert.match(get("migration-summary").textContent, /Retry driver setup.*test the drivers that are ready/);
  assert.equal(get("migration-cleanup").textContent, "Confirm tests for ready drivers");
  assert.deepEqual(sent.map(({action}) => action), ["availability", "status"]);
  get("migration").contains = (element) => element === next;
  next.focus();
  next.onclick();
  assert.equal(sent.at(-1).action, "resume");
  assert.equal(sent.at(-1).token, "mixed");
  reply({ saved: true, token: "mixed", canReviewRemoval: true, rows: [ready, { ...blocked, state: "upgraded" }] });
  assert.equal(heading.textContent, "Test the new drivers");
  assert.equal(document.activeElement, heading);
  assert.match(get("migration-summary").textContent, /To see other drivers you can migrate, choose Review more drivers/);
  assert.equal(next.textContent, "Review more drivers");
  next.onclick();
  assert.equal(sent.at(-1).action, "scan");
});
