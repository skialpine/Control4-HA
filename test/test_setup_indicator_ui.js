const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const elementLookup = require("./html-fixture");

function setupPage() {
  const document = {
    getElementById: elementLookup(() => ({
        dataset: {},
        parentElement: { hidden: false },
        contains() { return false; },
        querySelector() { return null; },
        addEventListener() {},
        focus() { document.activeElement = this; },
    }), "src/ha/setup.html", "src/ha/migration.html"),
  };
  let options;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../src/ha/setup.js"), "utf8"), {
    document,
    window: { addEventListener() {} },
    clearTimeout() {},
    setTimeout() {},
    Kit: {
      esc(value) { return value; },
      initPropertiesCard() {},
      connectDriver(config) { options = config; },
    },
  });
  function push(indicator, state = {}) {
    options.handlers.HA_SETUP_STATE({
      status: "Device connected",
      selected_id: "selected-light",
      indicator_lease: "current-lease",
      indicators: [{ id: "status_led", label: "Status light", ...indicator }],
      ...state,
    });
  }
  return { document, push, rows: document.getElementById("indicator-rows") };
}

test("one linked indicator shows hardware behavior or active linked tracking in the same selector", () => {
  const { document, push, rows } = setupPage();
  const indicator = { behaviors: ["always_on", "always_off"], behavior: "always_off" };
  const state = { indicator_policy: "single" };
  push(indicator, state);
  assert.match(rows.innerHTML, /value="always_off" selected>Always off/);
  assert.match(rows.innerHTML, /value="follow_bound">Follow the linked light/);
  assert.equal(document.getElementById("indicator-settings").hidden, true);
  assert.equal(document.getElementById("indicator-source").hidden, true);

  push(indicator, { ...state, indicator_following: true });
  assert.match(rows.innerHTML, /value="follow_bound" selected>Follow the linked light/);
  assert.match(rows.innerHTML, /value="use_device_setting">Keep current LED setting/);
  assert.equal(document.getElementById("indicator-source").hidden, false);
});

test("a discrete brightness refresh moves focus from the removed Apply button to its replacement", () => {
  const { document, push, rows } = setupPage();
  const channel = { brightness_supported: true, brightness: 50 };
  push(channel);
  assert.match(rows.innerHTML, /<button[^>]+>Apply/);

  const item = { dataset: { id: "status_led" } };
  const apply = { type: "submit", closest() { return oldForm; } };
  const oldForm = {
    dataset: { field: "brightness" },
    elements: { value: { value: "50", defaultValue: "50" } },
    closest() { return item; },
  };
  const select = { focus() { document.activeElement = this; } };
  const replacement = {
    dataset: oldForm.dataset,
    elements: { value: select },
    closest() { return item; },
    querySelector() { return null; },
  };
  document.activeElement = apply;
  rows.contains = (element) => element === apply;
  rows.querySelectorAll = () => [replacement];
  push({ ...channel, levels: [25, 50, 100] });
  assert.match(rows.innerHTML, /value="50" selected>50%/);
  assert.doesNotMatch(rows.innerHTML, /<button[^>]+>Apply/);
  assert.equal(document.activeElement, select);
});
