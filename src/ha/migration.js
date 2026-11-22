// Uses the template's existing driver socket. Opening Device Setup performs no migration requests.
function installSwitchMigration(nextId, refreshSetup) {
  var panel = document.getElementById("switch-migration");
  if (!panel) return function () {};
  function field(id) { return document.getElementById("migration-" + id); }
  var token, pending, timer, current = {};
  function status(text) {
    field("message").textContent = text || "";
    field("message").hidden = !text;
  }
  function send(action, params) {
    if (pending) return;
    params = params || {};
    params.action = action;
    params.request = pending = nextId();
    panel.setAttribute("aria-busy", "true");
    timer = setTimeout(function () {
      pending = null; panel.removeAttribute("aria-busy");
      status("The driver did not reply. Reopen the review to check the saved plan.");
      token = null; current = {};
      ["choices", "save-panel", "cutover", "report", "close", "restore-help"].forEach(function (id) { field(id).hidden = true; });
      field("open").hidden = false; field("open").focus();
    }, 15000);
    Kit.sendCommand("HA_MIGRATION", params);
  }
  field("open").onclick = function () { send("open"); };
  field("preview").onclick = function () { send("preview", {source: Number(field("source").value)}); };
  field("backup").onchange = function () { field("save").disabled = !this.checked; };
  field("save").onclick = function () { send("save", {token: token, backup: field("backup").checked}); };
  field("close").onclick = function () { send("cancel", {token: token}); };
  field("refresh").onclick = function () { send("status"); };
  field("check").onclick = function () { send("check"); };
  field("complete").onclick = function () {
    if (window.confirm("Have you tested on/off and status feedback after reload, and checked every scene, button link and programming action that uses this switch?")) {
      send("complete", {confirmed: true});
    }
  };
  ["configure", "transfer", "rollback"].forEach(function (action) {
    field(action).onclick = function () {
      var text = "Use " + current.entity + " on " + current.replacement_name + " now?";
      if (action !== "configure") {
        var retiring = action === "transfer";
        var count = retiring ? current.move_count : current.restore_count;
        text = "Move " + count + " relay connection" + (count === 1 ? "" : "s") + " from " +
          (retiring ? current.source_name : current.replacement_name) + " to " +
          (retiring ? current.replacement_name : current.source_name) + " now?";
      }
      if (window.confirm(text)) send(action, {confirmed: true});
    };
  });
  return function (data) {
    if (!pending || pending !== data.request) return;
    pending = null; clearTimeout(timer); panel.removeAttribute("aria-busy");
    status(data.error || data.message);
    if (data.error) { field("message").focus(); return; }
    var choose = data.phase === "choose", preview = data.phase === "preview", staged = data.phase === "staged";
    var finished = data.phase === "closed" && current.completed;
    token = data.token; current = data;
    field("open").hidden = choose || preview || staged;
    field("choices").hidden = !choose;
    field("close").hidden = !field("open").hidden;
    field("save-panel").hidden = !preview || !data.can_save;
    field("cutover").hidden = !staged;
    field("configure").hidden = !data.can_configure;
    field("check").hidden = !data.can_check;
    field("transfer").hidden = !data.can_transfer;
    field("complete").hidden = !data.can_complete;
    field("rollback").hidden = !data.can_rollback;
    field("restore-help").hidden = !data.rollback_help;
    field("restore-help").textContent = data.rollback_help || "";
    field("backup").checked = false; field("save").disabled = true;
    var report = field("report");
    report.textContent = ""; report.hidden = !data.lines;
    (data.lines || []).forEach(function (line) {
      var item = document.createElement("li"); item.textContent = line; report.appendChild(item);
    });
    if (choose) {
      var select = field("source"); select.textContent = "";
      (data.sources || []).forEach(function (item) {
        var option = document.createElement("option"); option.value = item.id;
        option.textContent = (item.name || item.model) + (item.room ? " in " + item.room : " in an unknown room");
        select.appendChild(option);
      });
      field("preview").disabled = !select.options.length;
      if (!select.options.length) status("No supported older Light or Switch was found in this project.");
      (select.options.length ? select : field("close")).focus();
    } else if (preview || staged) {
      field("message").focus();
    } else if (finished) {
      refreshSetup();
    } else { field("open").focus(); }
  };
}
