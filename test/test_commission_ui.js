const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const elementLookup = require("./html-fixture");

function quickSetup() {
  const source = fs.readFileSync(path.join(__dirname, "../src/ha/commission-ui.js"), "utf8");
  const sent = [];
  const document = {
    hidden: false,
    addEventListener(event, handler) { this[event] = handler; },
    getElementById: elementLookup(() => ({
        value: "",
        parentNode: { classList: { toggle() {} } },
        contains() { return false; },
        querySelectorAll() { return []; },
        setAttribute() {},
        focus() { document.activeElement = this; },
        addEventListener(event, handler) { this[event] = handler; },
    }), "drivers/coordinator/www/html/index.html"),
  };
  let options;
  vm.runInNewContext(source, {
    document,
    window: { addEventListener() {} },
    requestAnimationFrame() {},
    setTimeout() {},
    clearTimeout() {},
    SwitchUpgradePage: { connect() {} },
    Kit: {
      esc(value) { return value; },
      sendCommand(command, params) { sent.push({ command, params }); },
      connectDriver(config) { options = config; },
    },
  });
  options.onConnect();
  function reply(online, request = sent.at(-1).params.request) {
    options.handlers.HA_ADD_STATE({
      request,
      can_browse: online,
      rooms: [{ id: 19, name: "Room" }],
      setups: [{ id: "lighting", name: "Lighting" }],
    });
  }
  return {
    sent, document, reply,
    connected: options.handlers.HA_ADD_CONNECTED,
    disconnected: options.handlers.HA_ADD_DISCONNECTED,
  };
}

test("an authenticated connection opens the device list without manual retry", () => {
  const { sent, document, reply, connected } = quickSetup();
  const retry = document.getElementById("reload-state");
  reply(false);
  assert.equal(retry.hidden, false);
  retry.focus();
  connected();
  assert.equal(sent.at(-1).command, "HA_ADD_GET");
  reply(true);
  assert.equal(sent.at(-1).command, "HA_ADD_BROWSE");
  assert.equal(retry.hidden, true);
  assert.equal(document.activeElement, document.getElementById("search"));
  connected();
  assert.equal(sent.length, 3);
});

test("an online signal takes precedence over an in-flight offline response", () => {
  const { sent, document, reply, connected } = quickSetup();
  const stale = sent[0].params.request;
  connected();
  reply(false, stale);
  assert.equal(sent.length, 2);
  reply(true);
  assert.equal(sent.at(-1).command, "HA_ADD_BROWSE");
  assert.equal(document.getElementById("connection").textContent, "Connected");
});

test("returning to a disconnected tab checks state once if it missed the push", () => {
  const { sent, document, reply } = quickSetup();
  const stale = sent[0].params.request;
  document.hidden = true;
  document.visibilitychange();
  assert.equal(sent.length, 1);
  document.hidden = false;
  document.visibilitychange();
  reply(false, stale);
  assert.equal(sent.length, 2);
  reply(true);
  assert.equal(sent.at(-1).command, "HA_ADD_BROWSE");
});

test("an open picker stops showing Connected on loss and resumes browsing on reconnect", () => {
  const { sent, document, reply, connected, disconnected } = quickSetup();
  reply(true);
  disconnected();
  assert.equal(document.getElementById("connection").textContent, "Checking connection…");
  assert.equal(sent.at(-1).command, "HA_ADD_GET");
  reply(false);
  assert.equal(document.getElementById("reload-state").hidden, false);
  connected();
  reply(true);
  assert.equal(document.getElementById("connection").textContent, "Connected");
  assert.equal(sent.at(-1).command, "HA_ADD_BROWSE");
});
