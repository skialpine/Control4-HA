var SwitchUpgradePage = (function () {
  "use strict";
  var el = function (id) { return document.getElementById("migration-" + id); };
  var panel = document.getElementById("migration");
  var selection = new Set(), phase = "loading", plan, pending, sequence = 0, cached = [], results = [];
  var resultToken;
  var prefix = "upgrade-" + Math.random().toString(36).slice(2) + "-";
  var summary = el("summary"), next = el("next"), back = el("back"), refresh = el("refresh");
  var backup = el("backup"), list = el("switches"), cleanup = el("cleanup");
  var startDialog = el("start-dialog");
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

  function requestFailed(action, message, timedOut, errorTarget) {
    if (errorTarget) {
      errorTarget.textContent = message;
      if (errorTarget.parentElement.contains(document.activeElement)) {
        errorTarget.scrollIntoView({ block: "nearest" });
      }
    } else if (action === "availability" && phase === "loading") {
      panel.hidden = false;
      summary.textContent = "Couldn’t check for older switch drivers. Try again.";
      button(refresh, true, "Retry migration check");
    } else {
      summary.textContent = message;
      button(refresh, true, next.dataset.command === "recheck_release" ? "Refresh status"
        : timedOut || phase === "result" ? "Check migration status" : "Refresh list");
    }
  }

  function request(action, params, answer, errorTarget) {
    if (pending) return;
    var payload = params || {};
    var id = prefix + (++sequence);
    payload.action = action;
    payload.request = id;
    if (errorTarget) errorTarget.textContent = "";
    pending = { id: id, action: action, answer: answer, errorTarget: errorTarget, timer: setTimeout(function () {
      if (!pending || pending.id !== id) return;
      pending = null;
      requestFailed(action, "The Coordinator did not reply. Check the connection, then refresh.", true, errorTarget);
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
      requestFailed(task.action, data.error, false, task.errorTarget);
    } else {
      task.answer(data);
    }
    changed();
  }

  function inlineStatus(container) {
    var status = document.createElement("p");
    status.className = "setup-detail upgrade-step-status";
    status.setAttribute("role", "status");
    container.appendChild(status);
    return status;
  }

  function manualSteps(item, row) {
    var device = row.selectedDevice ? "“" + row.selectedDevice + "”" : "the original Home Assistant device";
    if (row.copiedSettings) {
      var copied = document.createElement("p");
      copied.textContent = "Copied Button behavior (" + row.buttonBehavior + ")"
        + (row.ledBehavior ? " and LED Behavior (" + row.ledBehavior + ")" : "") + ".";
      item.appendChild(copied);
    }
    if (row.unresolvedConnections) {
      var recheck = document.createElement("button");
      recheck.type = "button";
      recheck.className = "btn btn-outline";
      recheck.textContent = "Recheck connections";
      item.appendChild(recheck);
      var connectionStatus = inlineStatus(item);
      recheck.onclick = function () {
        request("recheck_connections", { token: resultToken, manual: row.id },
          function (data) { renderStatus(data, true); }, connectionStatus);
      };
      if ((row.connections || []).some(function (link) { return link.migratePeerFirst; })) return;
    }
    var steps = document.createElement("ol");
    steps.className = "upgrade-worklist";
    var test = row.buttonBehavior === "Buttons only" ? "Test the buttons on the new driver."
      : "Test on/off control and the buttons you use on the new driver.";
    if (row.connectedAutomatically) {
      var check = document.createElement("p");
      check.textContent = driverLabel(row.replacement, row.room) + " is ready to test. "
        + test + (row.hadProgramming ? " Run the programming you moved." : "");
      item.appendChild(check);
      return;
    }
    var connect = [
        "In System Design, find " + driverLabel(row.replacement, row.room) + ". In Device Setup, make sure " + device + " is available before disconnecting the original.",
        "In Connections, disconnect " + driverLabel(row.oldDriver || row.name, row.room)
        + " from Home Assistant. Save " + device + " in the new driver’s Device Setup."
        + (row.copiedSettings ? "" : " Set Button behavior to " + row.buttonBehavior + "."
          + (row.ledBehavior ? " Set LED Behavior to " + row.ledBehavior + "." : ""))
        + ((row.connections || []).some(function (link) { return !link.transfer; })
          ? " Check the remaining connections shown above in Composer." : "")
    ];
    var transferStep = connect.length;
    connect.concat([
      row.relayMigration === "available" ? "After saving the device, move the verified connections to the new driver."
        : row.relayMigration === "moved" && !row.connectedAutomatically ? "Connections moved and verified." : "",
      row.hadProgramming ? "Run the programming you moved and verify any affected scenes." : "",
      test + (row.namesPrepared ? " Then confirm testing." : " Then apply the original name.")
    ]).forEach(function (instruction, index) {
      if (!instruction) return;
      var step = document.createElement("li");
      step.textContent = instruction;
      if (index === transferStep && row.relayMigration === "available") {
        var move = document.createElement("button");
        move.type = "button";
        move.className = "btn btn-outline";
        move.textContent = "Move verified connections";
        move.setAttribute("aria-label", "Move verified connections for " + driverLabel(row.name, row.room));
        var actions = document.createElement("div");
        actions.className = "setup-actions";
        var confirm = document.createElement("label"), same = document.createElement("input");
        confirm.className = "upgrade-backup upgrade-programming-confirm";
        same.type = "checkbox";
        confirm.appendChild(same);
        confirm.appendChild(document.createTextNode("I checked that the replacement uses the original Home Assistant device and load."));
        step.appendChild(confirm);
        move.disabled = true;
        same.onchange = function () { move.disabled = !same.checked; };
        actions.appendChild(move);
        step.appendChild(actions);
        var relayStatus = inlineStatus(step);
        move.onclick = function () {
          request("move_relays", { token: resultToken, manual: row.id, confirmed: same.checked }, function (data) {
            var focused = document.activeElement === move;
            renderStatus(data, false);
            var confirmed = list.querySelector('[data-relay-moved="' + row.id + '"]');
            if (focused && confirmed) confirmed.focus();
          }, relayStatus);
        };
      } else if (index === transferStep && row.relayMigration === "moved") {
        step.dataset.relayMoved = row.id;
        step.tabIndex = -1;
      }
      steps.appendChild(step);
    });
    item.appendChild(steps);
  }

  function showLoad(item, target) {
    var detail = document.createElement("p");
    var label = document.createElement("strong");
    label.textContent = target.name || target.entity;
    detail.appendChild(label);
    if (target.area) detail.appendChild(document.createTextNode(" · Home Assistant area " + target.area));
    if (target.name) {
      var identity = document.createElement("span");
      identity.className = "setup-detail upgrade-load-id";
      identity.textContent = target.entity;
      detail.appendChild(identity);
    }
    item.appendChild(detail);
  }

  function confirmLoad(item, row) {
    var target = row.targetToConfirm;
    showLoad(item, target);
    var help = document.createElement("p");
    help.textContent = "Quick Setup matched the original’s button events to a Home Assistant control. "
      + "If the load shown here is what the new driver should control, confirm the transfer. "
      + "Quick Setup rechecks the match and connections before transferring control.";
    item.appendChild(help);
    var fallback = document.createElement("p");
    fallback.className = "setup-detail";
    fallback.textContent = "If the load looks wrong or you’re unsure, get manual setup steps. The original stays connected.";
    item.appendChild(fallback);
    var actions = document.createElement("div");
    actions.className = "setup-actions";
    var manual = document.createElement("button"), approve = document.createElement("button");
    manual.type = "button";
    manual.className = "btn btn-outline";
    manual.textContent = "Get manual setup steps";
    approve.type = "button";
    approve.className = "btn btn-primary";
    approve.textContent = "Confirm load and transfer";
    actions.appendChild(approve);
    actions.appendChild(manual);
    item.appendChild(actions);
    var notice = inlineStatus(item);
    function choose(accepted) {
      request("approve_target", { token: resultToken, manual: row.id, key: target.key, accepted: accepted },
        function (data) { renderStatus(data, true); }, notice);
    }
    manual.onclick = function () { choose(false); };
    approve.onclick = function () { choose(true); };
  }

  function showConnections(item, row) {
    var heading = document.createElement("p");
    heading.className = "setup-detail";
    heading.textContent = row.selectedDevice ? "Home Assistant device: " + row.selectedDevice : "Control4 connections";
    item.appendChild(heading);
    if (!row.connections || !row.connections.length) {
      var status = document.createElement("p");
      status.className = "setup-detail";
      status.textContent = row.connectionsVerified ? "No other connections found." : "Check the connections in Composer.";
      item.appendChild(status);
      return;
    }
    var links = document.createElement("ul");
    links.className = "upgrade-worklist";
    row.connections.forEach(function (link) {
      var line = document.createElement("li");
      line.textContent = link.role + " → " + link.target
        + (link.migratePeerFirst ? " · Migrate this device first" : link.transfer ? "" : " · Check in Composer");
      links.appendChild(line);
    });
    item.appendChild(links);
  }

  function manualNaming(item, row) {
    var label = document.createElement("label"), tested = document.createElement("input");
    label.className = "upgrade-backup upgrade-programming-confirm";
    tested.type = "checkbox";
    label.appendChild(tested);
    label.appendChild(document.createTextNode("I verified " + driverLabel(row.replacement, row.room)
      + " uses the same Home Assistant device" + (row.buttonBehavior === "Buttons only" ? "." : " and load.")
      + " I tested its buttons"
      + (row.buttonBehavior === "Buttons only" ? "" : " and on/off control")
      + " and checked the programming, scenes and connections I moved."));
    item.appendChild(label);
    var apply = document.createElement("button");
    apply.type = "button";
    apply.className = "btn btn-primary";
    apply.textContent = row.namesPrepared ? "Confirm testing" : "Apply original name";
    apply.setAttribute("aria-label", row.namesPrepared ? "Confirm testing for " + driverLabel(row.name, row.room)
      : "Apply the name " + driverLabel(row.name, row.room) + " to the new driver");
    apply.disabled = true;
    var explanation = document.createElement("p");
    explanation.className = "setup-detail";
    explanation.textContent = row.namesPrepared ? "Quick Setup rechecks the driver names and connections before removal review."
      : "This renames the original as the old driver and gives the new driver the name “" + row.name + "”.";
    item.appendChild(explanation);
    item.appendChild(apply);
    var namingStatus = inlineStatus(item);
    tested.onchange = function () { apply.disabled = !tested.checked; };
    apply.onclick = function () {
      request("finish_names", { token: resultToken, manual: row.id, tested: tested.checked }, function (data) {
        renderStatus(data, true);
      }, namingStatus);
    };
  }

  function display(heading, message, rows, selectable, focus, running) {
    var title = el("heading");
    if (title.textContent !== heading) title.textContent = heading;
    summary.textContent = message;
    var readyForTesting = phase === "result" && rows.length && rows.every(function (row) { return row.state === "upgraded"; });
    var secondary = readyForTesting || phase === "result" && rows.some(function (row) { return row.state === "manual"; })
      && rows.every(function (row) { return row.state === "manual" || row.state === "upgraded"; });
    next.classList.toggle("btn-primary", !secondary);
    next.classList.toggle("btn-outline", !!secondary);
    cleanup.classList.toggle("btn-primary", !!readyForTesting);
    cleanup.classList.toggle("btn-outline", !readyForTesting);
    guide.hidden = !rows.some(function (row) {
      return row.state === "review" && (row.details && row.details.length || row.programming === "check");
    });
    if (guide.hidden) guide.open = false;
    el("guide-timing").textContent = "Select the staged driver when moving actions. Test the edited programs after migration finishes.";
    var open = new Set(Array.from(list.querySelectorAll("details[open]")).map(function (item) { return item.dataset.id; }));
    var active = document.activeElement;
    var focusInside = panel.contains(active);
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
        target.textContent = row.details && row.details.some(function (entry) { return entry.action; })
          ? "In Device Actions, select " + driverLabel(row.replacement, row.room)
            + ". Keep the other actions in each script."
          : "Move the listed programming to " + driverLabel(row.replacement, row.room) + ".";
        body.appendChild(target);
        if (row.oldDriver) {
          var source = document.createElement("p");
          source.className = "setup-detail";
          source.textContent = driverLabel(row.oldDriver, row.room) + " still controls the switch.";
          body.appendChild(source);
        }
      }
      if (row.device) {
        var facts = document.createElement("span");
        facts.className = "setup-detail";
        facts.textContent = "Controls " + row.device;
        body.appendChild(facts);
      }
      if (row.state === "upgraded" && row.buttonBehavior && !row.tested) {
        var test = document.createElement("p");
        test.className = "setup-detail";
        test.textContent = row.buttonBehavior === "Buttons only" ? "Test the buttons you use."
          : "Test on/off control and the buttons you use.";
        body.appendChild(test);
      }
      if (row.message || phase === "review" && row.buttonBehavior) {
        var note = document.createElement("p");
        note.className = "setup-detail";
        note.textContent = phase === "review" && row.unresolvedConnections
          ? "Resolve the connections marked below. The original stays connected."
          : phase === "review" && row.buttonBehavior
          ? "Quick Setup adds a Home Assistant Switch in " + row.room
            + ", copies its supported settings and transfers control when it can verify the device and connections."
          : row.message;
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
      if (phase === "review" && row.reviewedLoad) {
        var proposed = document.createElement("p");
        proposed.className = "setup-detail";
        proposed.textContent = "Home Assistant load to transfer";
        item.appendChild(proposed);
        showLoad(item, row.reviewedLoad);
      } else if (row.recheckLoad) {
        showLoad(item, row.recheckLoad);
      }
      if (phase === "review" || row.state === "manual") showConnections(item, row);
      if (!running && row.state === "manual") manualSteps(item, row);
      if (!running && row.state === "target" && row.targetToConfirm) confirmLoad(item, row);
      if ((row.state === "review" || row.state === "manual" || phase === "review") && row.details && row.details.length) {
        var references = document.createElement("ol");
        references.className = "upgrade-worklist";
        row.details.forEach(function (entry) {
          var ref = document.createElement("li");
          var event = document.createElement("strong");
          event.textContent = entry.location + (entry.event ? " · " + entry.event : " · Event " + entry.eventId);
          ref.appendChild(event);
          var instruction = document.createElement("p");
          var instructions = entry.instruction;
          if (phase === "result" && row.state === "review" && row.replacement && entry.action) {
            instructions = "Under Commands, select Device Specific Command → " + entry.action
              + ". Drag " + (entry.count > 1 ? entry.count + " copies of the action" : "the action")
              + " into Script Actions";
            if (!entry.addOnly) instructions += ", then remove the matching action for "
              + driverLabel(row.oldDriver || row.name, row.room);
            instructions += ".";
          }
          instruction.textContent = instructions;
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
          if (row.state === "manual") {
            var heading = document.createElement("p");
            heading.textContent = "Programming to move";
            item.appendChild(heading);
          }
          item.appendChild(references);
        }
      }
      if (!running && row.state === "manual"
        && !(row.connections || []).some(function (link) { return link.migratePeerFirst; })) manualNaming(item, row);
      if (!running && row.state === "review" && row.confirmProgramming) {
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
    if (focus && (focusInside || active === document.body)) title.focus();
    else if (restore) restore.focus({preventScroll: true});
  }

  function renderList(focus) {
    phase = "list";
    el("backup-label").hidden = true;
    var count = selection.size;
    display("Migrate switch drivers",
      "These older Control4 drivers need replacements to work with the current suite. The new drivers keep the original names and rooms.",
      cached, true, focus);
    button(back, results.length > 0, "Back to migration results");
    button(cleanup, false);
    button(refresh, true, "Refresh list");
    button(next, cached.some(function (row) { return row.state === "ready"; }),
      count ? "Review " + count + (count === 1 ? " driver" : " drivers") : "Review drivers");
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
      data.rows.some(function (row) { return row.reviewedLoad; })
        ? "Continuing approves the Home Assistant loads shown below." : "Review the drivers below before continuing.",
      data.rows, false, true);
    button(back, true, "Back to driver list");
    button(cleanup, false);
    button(refresh, false);
    button(next, true, "Start migration");
  }

  function startMigration() {
    if (phase !== "review" || pending || !backup.checked) return;
    request("start", { token: plan.token, backup: true }, function (data) { renderStatus(data, true); });
  }

  function confirmStart() {
    var coordinators = new Set();
    plan.rows.forEach(function (row) {
      (row.connections || []).forEach(function (link) {
        if (link.role === "Home Assistant connection" && link.target) coordinators.add(link.target);
      });
    });
    var coordinator = coordinators.size === 1 ? Array.from(coordinators)[0] : "the Coordinator you started from";
    var message = "Composer may open the new driver’s Device Setup. In System Design, reselect "
      + coordinator + " and open Quick Setup to continue.";
    if (typeof startDialog.showModal !== "function") {
      if (window.confirm(message)) startMigration();
      return;
    }
    el("start-message").textContent = message;
    startDialog.returnValue = "";
    startDialog.showModal();
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
    var recovery = rows.filter(function (row) { return row.state === "recovery"; });
    if (recovery.length) {
      display("Restore the project backup", "After restoring the backup, select Refresh status.",
        recovery, false, focus, data.running);
      button(back, false);
      button(refresh, !data.running, "Refresh status");
      button(cleanup, false);
      button(next, false);
      el("backup-label").hidden = true;
      changed();
      return;
    }
    if (data.interruptedCutover || data.releaseChanged) {
      var interrupted = data.interruptedCutover;
      display(interrupted ? "Migration was interrupted" : "Recheck saved migration",
        interrupted ? "The drivers were updated before migration finished. Restore the original connections before trying again."
          : "The drivers were updated after migration started. Recheck the original and its replacement before confirming the Home Assistant load.",
        rows.filter(function (row) { return interrupted ? row.state === "cutover" : row.targetToConfirm; }).map(function (row) {
          return { id: row.id, name: row.name, room: row.room, recheckLoad: row.targetToConfirm,
            message: row.replacement ? "Staged replacement · " + driverLabel(row.replacement, row.room) : "" };
        }), false, focus, false);
      el("backup-label").hidden = true;
      button(back, false);
      button(refresh, true, "Refresh status");
      button(cleanup, false);
      button(next, true, interrupted ? "Restore original connections" : "Recheck drivers");
      next.dataset.command = "recheck_release";
      changed();
      return;
    }
    var testInstructions = (rows.some(function (row) { return row.buttonBehavior; }) ? "Test the new drivers’ controls"
        : rows.length === 1 ? "Turn the switch on and off" : "Turn each switch on and off")
      + (rows.some(function (row) { return row.hadProgramming; }) ? " and run the programming you changed." : ".")
      + " Then review the old drivers for removal.";
    var programming = rows.some(function (row) {
      return row.state === "review" && (row.details && row.details.length || row.programming === "check");
    });
    var manual = rows.some(function (row) { return row.state === "manual"; });
    var stageDone = rows.every(function (row) { return row.state === "upgraded" || row.state === "manual"; });
    var testPending = rows.some(function (row) { return row.state === "manual" && row.connectedAutomatically; });
    var targetPending = rows.some(function (row) { return row.state === "target"; });
    var tested = rows.length > 0 && rows.every(function (row) { return row.tested; });
    var canResume = rows.some(function (row) {
      return ["review", "attention", "pending", "adding", "prepared", "cutover", "restored"].indexOf(row.state) >= 0;
    });
    el("backup-label").hidden = true;
    var heading = data.running ? "Migrating switch drivers" : programming ? "Update programming"
        : targetPending ? "Confirm the Home Assistant load" : testPending ? "Test the new drivers"
        : manual ? "Finish migration in Composer" : count === rows.length
          ? (tested ? "Review migrated drivers" : "Test the new drivers") : "Continue migration";
    var nextTaskAppeared = !data.running && !programming && (targetPending || count === rows.length && !tested)
      && el("heading").textContent !== heading;
    display(heading,
      data.running ? "Preparing new drivers and checking their connections…"
        : data.needsNames ? "Finish applying the original names to the new drivers."
        : count === rows.length && tested ? "Review the old drivers for removal."
        : count === rows.length ? (noOtherDrivers ? "No other older switch drivers were found. " : "") + testInstructions
        : programming ? "The original still controls each switch that needs programming changes."
        : targetPending ? "The original stays connected until you confirm its load."
        : "Follow the next step for each driver below.", rows, false, focus || nextTaskAppeared, data.running);
    button(back, false);
    button(refresh, !data.running, "Refresh status");
    button(cleanup, !data.running && !programming && data.canReviewRemoval, "Review old drivers for removal");
    button(next, !data.running && (data.needsNames || (stageDone && !noOtherDrivers) || canResume),
      data.needsNames ? "Finish naming drivers" : stageDone ? "Review more drivers"
        : programming ? "Check programming" : "Recheck and continue");
    next.dataset.command = data.needsNames ? "finish_names" : stageDone ? "scan" : "resume";
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
    request("review_removal", { tested: backup.checked, referencesReviewed: backup.checked }, function (data) {
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
      button(refresh, false);
      button(cleanup, false);
      button(next, true, removed ? "Done" : "Check removal");
    });
  }
  cleanup.onclick = function () {
    backup.checked = false;
    var completed = results.filter(function (row) { return row.state === "upgraded" && row.oldDriver; });
    var untested = completed.filter(function (row) { return !row.tested || !row.referencesReviewed; });
    if (!untested.length) {
      checkRemoval();
      return;
    }
    phase = "cleanup-confirm";
    completed = untested;
    var edited = completed.some(function (row) { return row.hadProgramming; });
    el("confirmation").textContent = (completed.some(function (row) { return row.buttonBehavior; })
      ? "I tested each new driver and verified the controls and buttons it uses."
      : completed.length === 1 ? "I verified that the new driver turns the switch on and off."
        : "I verified that each new driver turns its switch on and off.")
      + (edited ? " I also ran the programming I changed and verified it worked." : "")
      + " I checked that no scenes, agent settings or programming still use the old drivers.";
    el("backup-label").hidden = false;
    display("Confirm testing before removal",
      "In Composer, check Advanced Lighting scene loads, other agent settings, and programming that uses the old drivers. Move any remaining references and test them before deleting the originals.",
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
    if (phase === "list" || phase === "cleanup-confirm" || phase === "cleanup") read(true);
    else renderList(true);
  };
  backup.onchange = changed;
  startDialog.addEventListener("close", function () {
    if (startDialog.returnValue === "start") startMigration();
    next.focus();
  });
  next.onclick = function () {
    if (pending) return;
    if (phase === "list") {
      request("review", { selected: Array.from(selection) }, renderReview);
    } else if (phase === "review") {
      confirmStart();
    } else if (phase === "cleanup-confirm" || phase === "cleanup") {
      checkRemoval();
    } else if (phase === "cleanup-done") {
      checkAvailability(true);
    } else if (next.dataset.command === "scan") {
      scan(true);
    } else if (next.dataset.command === "recheck_release") {
      request("resume", { token: resultToken }, function (data) { renderStatus(data, true); });
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
