const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

function fixture() {
  const page = fs.readFileSync(path.join(__dirname, "../src/ha/switch-upgrade-ui.js"), "utf8");
  const elements = new Map();
  const listeners = {};
  const sent = [];

  function element() {
    return {
      dataset: {},
      classList: { toggle() {} },
      contains() { return false; },
      querySelectorAll() { return []; },
      closest() { return null; },
      appendChild() {},
      setAttribute() {},
      focus() { document.activeElement = this; },
      addEventListener(event, callback) { this[event] = callback; },
    };
  }
  function get(id) {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  }
  const document = {
    body: element(),
    getElementById: get,
    createElement: element,
    createTextNode: element,
  };
  const context = {
    document,
    Kit: {
      sendCommand(_, params) { sent.push(params); },
      listen(event, callback) { listeners[event] = callback; },
    },
    setTimeout() {},
    clearTimeout() {},
  };
  vm.runInNewContext(page, context);

  function reply(data) {
    listeners.HA_SWITCH_UPGRADE_REPLY({ ...data, request: sent.at(-1).request });
  }
  return { context, document, sent, get, reply };
}

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
  assert.equal(next.textContent, "Recheck and continue");
  assert.equal(document.activeElement, heading);
  assert.equal(sent.filter((command) => command.action === "resume").length, 1);
});
