var SwitchUpgradePage = (function () {
  "use strict";
  var el = function (id) { return document.getElementById("migration-" + id); };
  var panel = document.getElementById("migration");
  var selection = new Set(), phase = "loading", plan, pending, sequence = 0, cached = [], results = [];
  var resultToken;
  var prefix = "upgrade-" + Math.random().toString(36).slice(2) + "-";
  var summary = el("summary"), next = el("next"), back = el("back"), refresh = el("refresh");
  var backup = el("backup"), list = el("switches"), cleanup = el("cleanup");
  var guide = el("guide"), programmingNotes = {
    found: "Programming to update",
    check: "Programming needs a Composer check",
  };
  function driverLabel(name, room) {
    return name + (room ? " in " + room : " in an unknown room");
  }
  function button(element, visible, label) {
    element.hidden = !visible;
    if (label) element.textContent = label;
  }

  function changed() {
    next.disabled = (phase === "list" && !selection.size)
      || ((phase === "review" || phase === "cleanup-confirm") && !backup.checked);
    next.setAttribute("aria-disabled", pending ? "true" : "false");
    refresh.setAttribute("aria-disabled", pending ? "true" : "false");
  }

  function requestFailed(action, message, timedOut) {
    if (action === "availability" && phase === "loading") {
      panel.hidden = false;
      summary.textContent = "Couldn’t check for older switch drivers. Try again.";
      button(refresh, true, "Retry migration check");
    } else {
      summary.textContent = message;
      button(refresh, true, timedOut || phase === "result" ? "Check migration status" : "Refresh list");
    }
  }

  function request(action, params, answer) {
    if (pending) return;
    var payload = params || {};
    var id = prefix + (++sequence);
    payload.action = action;
    payload.request = id;
    pending = { id: id, action: action, answer: answer, timer: setTimeout(function () {
      if (!pending || pending.id !== id) return;
      pending = null;
      requestFailed(action, "The Coordinator did not reply. Check the connection, then refresh.", true);
      changed();
    }, 18000) };
    changed();
    Kit.sendCommand("HA_SWITCH_UPGRADE", payload);
  }

  function receive(data) {
    if (!pending || pending.id !== data.request) return;
    var task = pending;
    clearTimeout(task.timer);
    pending = null;
    if (data.error) {
      requestFailed(task.action, data.error, false);
    } else {
      task.answer(data);
    }
    changed();
  }

  function display(heading, message, rows, selectable, focus) {
    var title = el("heading");
    if (title.textContent !== heading) title.textContent = heading;
    summary.textContent = message;
    var readyForTesting = phase === "result" && rows.length && rows.every(function (row) { return row.state === "upgraded"; });
    next.classList.toggle("btn-primary", !readyForTesting);
    next.classList.toggle("btn-outline", !!readyForTesting);
    cleanup.classList.toggle("btn-primary", !!readyForTesting);
    cleanup.classList.toggle("btn-outline", !readyForTesting);
    guide.hidden = !rows.some(function (row) {
      return row.state === "review" && (row.details && row.details.length || row.programming === "check");
    });
    if (guide.hidden) guide.open = false;
    el("guide-timing").textContent = "Select the staged driver when moving actions. Test the edited programs after migration finishes.";
    var open = new Set(Array.from(list.querySelectorAll("details[open]")).map(function (item) { return item.dataset.id; }));
    var active = document.activeElement;
    var focusRow = active && active.closest("[data-row]"), focusId = focusRow && focusRow.dataset.row, restore;
    list.textContent = "";
    var mixed = phase === "result" && rows.some(function (row) { return row.state === "review"; });
    if (mixed) {
      rows = rows.filter(function (row) { return row.state === "upgraded"; })
        .concat(rows.filter(function (row) { return row.state !== "upgraded"; }));
    }
    (rows || []).forEach(function (row) {
      var item = document.createElement("li");
      item.dataset.row = row.id;
      if (mixed && row.state === "upgraded") {
        item.className = "upgrade-complete";
        var completed = document.createElement("strong");
        completed.textContent = driverLabel(row.name, row.room);
        item.appendChild(completed);
        item.appendChild(document.createTextNode(
          (row.verifiedActions && row.verifiedActions.length ? " · Programming check passed" : "") + " · Ready to test"));
        list.appendChild(item);
        return;
      }
      var label = document.createElement(selectable && row.state === "ready" ? "label" : "div");
      label.className = "upgrade-row";
      if (selectable && row.state === "ready") {
        var checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.checked = selection.has(row.id);
        checkbox.onchange = function () {
          if (checkbox.checked) selection.add(row.id);
          else selection.delete(row.id);
          renderList(false);
        };
        if (String(row.id) === focusId) restore = checkbox;
        label.appendChild(checkbox);
      }
      var body = document.createElement("span"), name = document.createElement("strong");
      name.textContent = driverLabel(row.name, row.room);
      body.appendChild(name);
      if (row.state === "review" && row.replacement && !row.confirmProgramming) {
        var target = document.createElement("p");
        target.className = "setup-detail";
        target.textContent = "Move the listed programming from " + driverLabel(row.name, row.room)
          + " to " + driverLabel(row.replacement, row.room) + ".";
        body.appendChild(target);
      }
      if (row.device) {
        var facts = document.createElement("span");
        facts.className = "setup-detail";
        facts.textContent = "Controls " + row.device;
        body.appendChild(facts);
      }
      if (row.message) {
        var note = document.createElement("p");
        note.className = "setup-detail";
        note.textContent = row.message;
        body.appendChild(note);
      }
      if (phase === "review" && programmingNotes[row.programming]) {
        var programming = document.createElement("p");
        programming.className = "setup-detail";
        programming.textContent = programmingNotes[row.programming];
        body.appendChild(programming);
      }
      label.appendChild(body);
      item.appendChild(label);
      if ((row.state === "review" || phase === "review") && row.details && row.details.length) {
        var references = document.createElement("ol");
        references.className = "upgrade-worklist";
        row.details.forEach(function (entry) {
          var ref = document.createElement("li");
          var event = document.createElement("strong");
          event.textContent = entry.location + (entry.event ? " · " + entry.event : " · Event " + entry.eventId);
          ref.appendChild(event);
          var instruction = document.createElement("p");
          instruction.textContent = entry.instruction;
          ref.appendChild(instruction);
          references.appendChild(ref);
        });
        if (phase === "review") {
          var details = document.createElement("details"), expand = document.createElement("summary");
          details.dataset.id = row.id;
          details.open = open.has(String(row.id));
          expand.textContent = "See programming changes";
          details.appendChild(expand);
          details.appendChild(references);
          if (String(row.id) === focusId) restore = expand;
          item.appendChild(details);
        } else {
          item.appendChild(references);
        }
      }
      if (row.state === "review" && row.confirmProgramming) {
        var reviewLabel = document.createElement("label"), reviewed = document.createElement("input");
        reviewLabel.className = "upgrade-backup upgrade-programming-confirm";
        reviewed.type = "checkbox";
        reviewed.dataset.manualReview = row.id;
        var confirmationText = "I verified the programming uses " + driverLabel(row.replacement, row.room) + ".";
        reviewLabel.appendChild(reviewed);
        reviewLabel.appendChild(document.createTextNode(confirmationText));
        item.appendChild(reviewLabel);
      }
      if (row.state === "upgraded" && row.verifiedActions && row.verifiedActions.length) {
        var confirmation = document.createElement("p");
        confirmation.textContent = "Programming check passed";
        var verified = document.createElement("ul");
        verified.className = "upgrade-worklist";
        row.verifiedActions.forEach(function (entry) {
          var action = document.createElement("li");
          action.textContent = entry.location + " · " + (entry.event || "Event " + entry.eventId)
            + " → " + entry.command + " on " + driverLabel(row.name, row.room);
          verified.appendChild(action);
        });
        item.appendChild(confirmation);
        item.appendChild(verified);
      }
      list.appendChild(item);
    });
    if (focus && (panel.contains(active) || active === document.body)) title.focus();
    else if (restore) restore.focus({preventScroll: true});
  }

  function renderList(focus) {
    phase = "list";
    el("backup-label").hidden = true;
    var count = selection.size;
    display("Migrate switch drivers",
      "Move these Home Assistant switches to the new Control4 drivers. Their names and rooms stay the same.",
      cached, true, focus);
    button(back, false);
    button(cleanup, false);
    button(refresh, true, "Refresh list");
    button(next, true, count ? "Review " + count + (count === 1 ? " driver" : " drivers") : "Review drivers");
    changed();
  }

  function hide() {
    var focused = panel.contains(document.activeElement);
    panel.hidden = true;
    phase = "loading";
    if (focused) document.getElementById("add-title").focus();
  }

  function scan(focus) {
    request("scan", {}, function (data) {
      cached = data.rows || [];
      if (!cached.length) {
        if (data.pending) read(focus, true);
        else hide();
        return;
      }
      selection.clear();
      cached.filter(function (row) { return row.state === "ready"; }).slice(0, 16).forEach(function (row) {
        selection.add(row.id);
      });
      renderList(focus);
    });
  }

  function renderReview(data) {
    phase = "review";
    plan = data;
    backup.checked = false;
    el("confirmation").textContent = "I saved a backup of this Control4 project.";
    el("backup-label").hidden = false;
    display("Review migration",
      "Control4 prepares a replacement for each switch and pauses any switch that needs your help.",
      data.rows, false, true);
    button(back, true, "Back to driver list");
    button(cleanup, false);
    button(refresh, false);
    button(next, true, "Start migration");
  }

  function renderStatus(data, focus, noOtherDrivers) {
    if (!data.saved) {
      scan(focus);
      return;
    }
    phase = "result";
    var rows = data.rows || [], count = rows.filter(function (row) { return row.state === "upgraded"; }).length;
    results = rows;
    resultToken = data.token;
    var testInstructions = (rows.length === 1 ? "Turn the switch on and off" : "Turn each switch on and off")
      + (rows.some(function (row) { return row.hadProgramming; }) ? " and run the programming you changed." : ".")
      + " Then review the old drivers for removal.";
    var programming = rows.some(function (row) {
      return row.state === "review" && (row.details && row.details.length || row.programming === "check");
    });
    var canResume = rows.some(function (row) {
      return ["review", "attention", "pending", "adding", "prepared", "cutover", "restored"].indexOf(row.state) >= 0;
    });
    el("backup-label").hidden = true;
    display(data.running ? "Migrating switch drivers" : programming ? "Update programming"
        : count === rows.length ? "Test the new drivers" : "Continue migration",
      data.running ? "Preparing new drivers and checking their connections…"
        : data.needsNames ? "Finish applying the original names to the new drivers."
        : count === rows.length ? (noOtherDrivers ? "No other older switch drivers were found. " : "") + testInstructions
        : programming ? "The original still controls each switch that needs programming changes."
        : "Follow the next step for each driver below.", rows, false, focus);
    button(back, false);
    button(refresh, !data.running, "Refresh status");
    button(cleanup, !data.running && !programming && data.canReviewRemoval, "Review old drivers for removal");
    button(next, !data.running && (data.needsNames || (count === rows.length && !noOtherDrivers) || canResume),
      data.needsNames ? "Finish naming drivers" : count === rows.length ? "Review more drivers"
        : programming ? "Check programming" : "Recheck and continue");
    next.dataset.command = data.needsNames ? "finish_names" : count === rows.length ? "scan" : "resume";
    changed();
  }

  function read(focus, noOtherDrivers) {
    request("status", {}, function (data) { renderStatus(data, focus, noOtherDrivers); });
  }

  function checkAvailability(focus) {
    if (!pending && phase === "loading" && !panel.hidden) {
      summary.textContent = "Checking for older switch drivers…";
    }
    request("availability", {}, function (data) {
      if (!data.pending && !data.count) {
        hide();
        return;
      }
      if (panel.hidden) {
        display("Migrate switch drivers", "Checking this project for older switch drivers…", [], false, false);
        [next, back, refresh, cleanup, el("backup-label")].forEach(function (element) { button(element, false); });
      }
      panel.hidden = false;
      if (data.pending) read(focus);
      else scan(focus);
    });
  }

  function checkRemoval() {
    request("review_removal", { tested: backup.checked }, function (data) {
      var rows = data.rows || [];
      var removed = rows.length && rows.every(function (row) { return row.state === "removed"; });
      var ready = rows.some(function (row) { return row.state === "ready"; });
      phase = removed ? "cleanup-done" : "cleanup";
      el("backup-label").hidden = true;
      display(removed ? "Old drivers removed" : "Remove old Control4 drivers",
        removed ? "Control4 confirms the old drivers were removed."
          : ready ? "In the Composer project tree, right-click each driver marked ready to remove and choose Delete. Then select Check removal."
          : "Keep the old drivers listed below and resolve their remaining checks.",
        rows, false, true);
      button(back, !removed, "Back to migration results");
      button(next, true, removed ? "Done" : "Check removal");
    });
  }
  cleanup.onclick = function () {
    phase = "cleanup-confirm";
    backup.checked = false;
    var completed = results.filter(function (row) { return row.state === "upgraded" && row.oldDriver; });
    var edited = completed.some(function (row) { return row.hadProgramming; });
    el("confirmation").textContent = (completed.length === 1
      ? "I verified that the new driver turns the switch on and off."
      : "I verified that each new driver turns its switch on and off.")
      + (edited ? " I also ran the programming I changed and verified it worked." : "");
    el("backup-label").hidden = false;
    display("Confirm testing before removal",
      "Check old drivers shows which originals are ready to delete. You delete them separately in Composer.",
      completed.map(function (row) {
        return { id: row.id, name: row.replacement || row.name, room: row.room,
          message: "Old driver to check · " + driverLabel(row.oldDriver, row.room) };
      }), false, true);
    button(back, true, "Back to migration results");
    button(refresh, false);
    button(cleanup, false);
    button(next, true, "Check old drivers");
    changed();
  };
  refresh.onclick = function () { if (phase === "list") scan(true); else checkAvailability(true); };
  back.onclick = function () {
    if (phase === "cleanup-confirm" || phase === "cleanup") read(true);
    else renderList(true);
  };
  backup.onchange = changed;
  next.onclick = function () {
    if (pending) return;
    if (phase === "list") {
      request("review", { selected: Array.from(selection) }, renderReview);
    } else if (phase === "review") {
      request("start", { token: plan.token, backup: backup.checked }, function (data) { renderStatus(data, true); });
    } else if (phase === "cleanup-confirm" || phase === "cleanup") {
      checkRemoval();
    } else if (phase === "cleanup-done") {
      checkAvailability(true);
    } else if (next.dataset.command === "scan") {
      scan(true);
    } else {
      var params = {};
      if (next.dataset.command === "resume") {
        var reviewed = Array.from(list.querySelectorAll("[data-manual-review]:checked"), function (checkbox) {
          return Number(checkbox.dataset.manualReview);
        });
        if (reviewed.length) params = { token: resultToken, reviewed: reviewed };
      }
      request(next.dataset.command, params, function (data) { renderStatus(data, true); });
    }
  };
  Kit.listen("HA_SWITCH_UPGRADE_REPLY", receive);
  Kit.listen("HA_SWITCH_UPGRADE_PROGRESS", function (data) {
    if (phase === "result" && !pending) renderStatus(data, false);
  });
  return { connect: function () { checkAvailability(false); } };
})();
