var SwitchUpgradePage = (function () {
  "use strict";
  var el = function (id) { return document.getElementById("migration-" + id); };
  var panel = document.getElementById("migration");
  var selection = new Set(), phase = "loading", plan, pending, sequence = 0, cached = [], results = [];
  var resultToken, removalScope, migrationRunning = false;
  var migrationStatusTimer, statusWait = 18000;
  var openingRecheckToken;
  var readinessChecks = 0, readinessTimer, connectedDuringScan = false;
  var readinessDelays = [2000, 4000, 8000];
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
      summary.textContent = "Couldn’t check for older Home Assistant drivers. Try again.";
      button(refresh, true, "Retry migration check");
    } else {
      summary.textContent = message;
      if (action === "review_removal") backup.checked = false;
      button(refresh, true, timedOut ? "Check migration status"
        : action === "review_removal" || next.dataset.command === "recheck_release" ? "Refresh status"
        : phase === "result" ? "Check migration status" : "Refresh list");
    }
  }

  function startsMigration(action) {
    return action === "start" || action === "resume";
  }

  function request(action, params, answer, errorTarget, retried) {
    if (pending) return;
    var payload = params || {};
    var id = prefix + (++sequence);
    var startingMigration = startsMigration(action);
    payload.action = action;
    payload.request = id;
    if (errorTarget) errorTarget.textContent = "";
    pending = { id: id, action: action, answer: answer, errorTarget: errorTarget, token: payload.token,
      payload: payload, retried: retried, timer: setTimeout(function () {
      if (!pending || pending.id !== id) return;
      if ((action === "availability" || action === "status") && !retried) {
        retryRead();
      } else {
        pending = null;
        if (startingMigration) {
          read(true, false, payload.token);
        } else {
          requestFailed(action, action === "status"
            ? "Couldn’t confirm migration status. Check the connection, then choose Check migration status."
            : "The Coordinator did not reply. Check the connection, then refresh.", true, errorTarget);
        }
      }
      changed();
    }, startingMigration ? 60000 : action === "availability" && !retried ? 5000 : statusWait) };
    if (startingMigration) {
      summary.textContent = "Checking the project and Home Assistant connection…";
    }
    changed();
    Kit.sendCommand("HA_SWITCH_UPGRADE", payload);
  }

  function retryRead() {
    var task = pending;
    clearTimeout(task.timer);
    pending = null;
    request(task.action, Object.assign({}, task.payload), task.answer, task.errorTarget, true);
  }

  function receive(data) {
    if (!pending || pending.id !== data.request) return;
    if (pending.action === "status" && pending.token && !data.error
        && (!data.saved || pending.token !== data.token)) return;
    finishRequest(data);
  }

  function finishRequest(data) {
    var task = pending;
    if (data.error && task.action === "availability" && !task.retried) {
      retryRead();
      return;
    }
    clearTimeout(task.timer);
    pending = null;
    if (data.error) {
      requestFailed(task.action, data.error, false, task.errorTarget);
    } else {
      task.answer(data.running && task.progress && task.progress.token === data.token ? task.progress : data);
      if (data.running && task.completedBeforeReply) read(true, false, data.token);
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
    if (summary.textContent !== message) summary.textContent = message;
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
      if (mixed && row.state === "upgraded" && row.tested && row.referencesReviewed) {
        item.className = "upgrade-complete";
        var completed = document.createElement("strong");
        completed.textContent = driverLabel(row.name, row.room);
        item.appendChild(completed);
        item.appendChild(document.createTextNode(
          " · Testing confirmed"));
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
      var connectionReview = row.state === "review" && row.unresolvedConnections;
      name.textContent = driverLabel(row.name, row.room);
      body.appendChild(name);
      if (row.state === "review" && row.replacement) {
        if (!row.confirmProgramming && row.details && row.details.length) {
          var target = document.createElement("p");
          target.className = "setup-detail";
          target.textContent = row.details.some(function (entry) { return entry.moveTimer; })
            ? "In Composer Programming, follow the steps below for the light events and the timer event."
            : row.details.some(function (entry) { return entry.action; })
            ? "In Device Actions, select " + driverLabel(row.replacement, row.room)
              + ". Keep the other actions in each script."
            : "Move the listed programming to " + driverLabel(row.replacement, row.room) + ".";
          body.appendChild(target);
        }
        if (connectionReview) {
          var destination = document.createElement("p");
          destination.className = "setup-detail";
          destination.textContent = "In Composer Connections, check the marked links for "
            + driverLabel(row.replacement, row.room) + ".";
          body.appendChild(destination);
        }
        if (row.oldDriver) {
          var source = document.createElement("p");
          source.className = "setup-detail";
          source.textContent = driverLabel(row.oldDriver, row.room) + (row.family === "light" ? " still controls the light." : " still controls the switch.");
          body.appendChild(source);
        }
      }
      if (row.device) {
        var facts = document.createElement("span");
        facts.className = "setup-detail";
        facts.textContent = phase === "review" && row.reviewedLoad && row.reviewedLoad.previous
          ? "Currently controls " + row.reviewedLoad.previous
          : "Controls " + row.device;
        body.appendChild(facts);
      }
      var testRow = phase === "result" && row.state === "upgraded" && !row.tested;
      if (testRow) {
        var test = document.createElement("p");
        test.className = "setup-detail";
        test.textContent = row.buttonBehavior === "Buttons only" ? "Test the buttons you use."
          : row.buttonBehavior ? "Test on/off control and the buttons you use."
          : row.family === "light" ? "Test on/off and any dimming or color controls you use."
          : "Turn the switch on and off.";
        body.appendChild(test);
      }
      var namedConnectionReview = connectionReview && row.programming === "none" && row.replacement && row.oldDriver;
      if (row.message && !namedConnectionReview || phase === "review" && row.buttonBehavior) {
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
        proposed.textContent = row.reviewedLoad.previous
          ? "The new driver will control the same device through this Home Assistant light."
          : "Home Assistant load to transfer";
        item.appendChild(proposed);
        showLoad(item, row.reviewedLoad);
        if (row.lightSettings) {
          [["Original settings", row.lightSettings.original], ["Settings on the new driver", row.lightSettings.replacement]]
            .forEach(function (entry) {
              var settings = entry[1], line = document.createElement("p");
              line.className = "setup-detail";
              var values = [settings.kind];
              if (settings.format) values.push(settings.format + " color");
              if (settings.range) values.push(settings.range.replace("-", "–") + " K");
              line.textContent = entry[0] + " · " + values.join(", ");
              item.appendChild(line);
            });
        } else if (row.lightType) {
          var lightType = document.createElement("p");
          lightType.className = "setup-detail";
          lightType.textContent = "Light type · " + row.lightType;
          item.appendChild(lightType);
        }
      } else if (row.recheckLoad) {
        showLoad(item, row.recheckLoad);
      }
      if (row.lighting && row.lighting.length && (phase === "review" || row.state === "review" || testRow)) {
        var previewLighting = phase === "review";
        var lighting = document.createElement(previewLighting ? "details" : "div");
        var lightingTitle = document.createElement(previewLighting ? "summary" : "p");
        lightingTitle.textContent = testRow ? "Lighting to test" : "Lighting scenes and load groups (" + row.lighting.length + ")";
        lighting.appendChild(lightingTitle);
        if (previewLighting && row.automaticScenes) {
          var sceneTransfer = document.createElement("p");
          sceneTransfer.className = "setup-detail";
          sceneTransfer.textContent = "Quick Setup will verify the saved settings as it moves the light in these scenes. It will show you any Composer edits to make. If the move stops partway through, restore the project backup.";
          lighting.appendChild(sceneTransfer);
        }
        var dependencies = document.createElement("ul");
        dependencies.className = "upgrade-worklist";
        row.lighting.forEach(function (reference) {
          var dependency = document.createElement("li");
          dependency.textContent = testRow && reference.kind === "scenes"
            ? "In Agents → Advanced Lighting, select “" + reference.name + "”, click Activate Scene and verify the new light responds."
            : (reference.kind === "scenes" ? "Advanced Lighting · " : "Load group · ") + reference.name;
          dependencies.appendChild(dependency);
        });
        lighting.appendChild(dependencies);
        item.appendChild(lighting);
      }
      if (testRow && row.hadProgramming) {
        var runProgram = document.createElement("p");
        runProgram.className = "setup-detail";
        var events = row.testEvents || row.verifiedActions || [];
        runProgram.textContent = events.length ? "In Programming → Device Events, select each event below. Click Execute in the Script pane and verify the new driver responds."
          : "Run the programming you changed and verify the new driver responds.";
        item.appendChild(runProgram);
        if (events.length) {
          var programs = document.createElement("ul");
          programs.className = "upgrade-worklist";
          events.forEach(function (entry) {
            var program = document.createElement("li");
            program.textContent = entry.location + (entry.event ? " · " + entry.event : " · Event " + entry.eventId);
            programs.appendChild(program);
          });
          item.appendChild(programs);
        }
      }
      if (phase === "review" || row.state === "manual" || connectionReview || row.family && row.state === "review") {
        showConnections(item, row);
      }
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
          if (phase === "result" && row.state === "review" && row.replacement && entry.moveTimer) {
            instructions = "Copy the Timer Agent action to the " + entry.event + " event on "
              + driverLabel(row.replacement, row.room) + ". Keep the same timer, then remove the action from the old driver.";
          } else if (phase === "result" && row.state === "review" && row.replacement && entry.action && row.family) {
            instructions = "Under Commands, choose Device Specific Command → " + entry.action
              + ". In Script Actions, keep " + (entry.count > 1 ? "exactly " + entry.count + " copies" : "one copy")
              + " for " + driverLabel(row.replacement, row.room)
              + " in the original position in the script. Remove any matching actions for "
              + driverLabel(row.oldDriver || row.name, row.room) + ".";
          } else if (phase === "result" && row.state === "review" && row.replacement && entry.action) {
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
      if (!testRow && row.state === "upgraded" && row.verifiedActions && row.verifiedActions.length) {
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
    display(cached.some(function (row) { return row.family; }) ? "Migrate older drivers" : "Migrate switch drivers",
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

  function scan(focus, refreshCatalog) {
    if (pending) return;
    clearTimeout(readinessTimer);
    connectedDuringScan = false;
    if (refreshCatalog) summary.textContent = "Checking for older Home Assistant drivers…";
    request("scan", { refresh: refreshCatalog === true }, function (data) {
      if (data.waiting === "home_assistant" || data.waiting === "driver_versions") {
        if (data.waiting === "home_assistant" && connectedDuringScan) {
          scan(focus, refreshCatalog);
          return;
        }
        phase = "waiting";
        var versions = data.waiting === "driver_versions";
        var delay = versions && readinessDelays[readinessChecks];
        display("Migrate older drivers",
          versions ? (delay ? "Waiting for the installed drivers to report matching versions…"
              : "Check that the Home Assistant drivers are on the same version, then refresh this list.")
            : "Waiting for Home Assistant to connect…",
          cached.map(function (row) { return { id: row.id, name: row.name, room: row.room }; }), false, false);
        button(back, results.length > 0, "Back to migration results");
        button(cleanup, false);
        button(next, false);
        button(refresh, true, "Refresh list");
        if (delay) {
          readinessChecks += 1;
          readinessTimer = setTimeout(function () {
            if (phase === "waiting") scan(false, refreshCatalog);
          }, delay);
        }
        return;
      }
      readinessChecks = 0;
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
      data.rows.some(function (row) { return row.lightSettings; })
        ? "Continuing approves the Home Assistant loads and Light settings shown below."
        : data.rows.some(function (row) { return row.reviewedLoad; })
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
    clearTimeout(migrationStatusTimer);
    if (!data.saved) {
      scan(focus);
      return;
    }
    phase = "result";
    var rows = data.rows || [], count = rows.filter(function (row) { return row.state === "upgraded"; }).length;
    var wasRunning = migrationRunning;
    results = rows;
    resultToken = data.token;
    removalScope = data.removalScope;
    migrationRunning = data.running === true;
    if (migrationRunning) {
      display("Migrating drivers", data.progress || "Checking the project and Home Assistant connection…", rows.map(function (row) {
        return { id: row.id, name: row.name, room: row.room, device: row.device };
      }), false, focus, true);
      el("backup-label").hidden = true;
      button(back, false);
      button(cleanup, false);
      button(next, false);
      button(refresh, true, "Refresh status");
      if (!pending) {
        migrationStatusTimer = setTimeout(function () { read(false, false, data.token); }, statusWait);
      }
      changed();
      return;
    }
    focus = focus || wasRunning;
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
    var releaseRecheck = rows.filter(function (row) { return row.state === "release_recheck"; });
    if (releaseRecheck.length) {
      display("Check the saved migration", "Quick Setup will check the original drivers, their replacements, and the saved lighting scenes. Then you can review what to do next.",
        releaseRecheck, false, focus, false);
      el("backup-label").hidden = true;
      button(back, false);
      button(refresh, true, "Refresh status");
      button(cleanup, false);
      button(next, true, "Check saved migration");
      next.dataset.command = "recheck_release";
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
    var programming = rows.some(function (row) {
      return row.state === "review" && (row.details && row.details.length || row.programming === "check");
    });
    var connections = rows.some(function (row) { return row.state === "review" && row.unresolvedConnections; });
    var lighting = rows.some(function (row) { return row.state === "review" && row.lightingReview; });
    var attention = rows.some(function (row) { return row.state === "attention"; });
    var manual = rows.some(function (row) { return row.state === "manual"; });
    var stageDone = rows.every(function (row) { return row.state === "upgraded" || row.state === "manual"; });
    var testPending = rows.some(function (row) { return row.state === "manual" && row.connectedAutomatically; });
    var targetPending = rows.some(function (row) { return row.state === "target"; });
    var tested = rows.length > 0 && rows.every(function (row) { return row.tested && row.referencesReviewed; });
    var confirmingTests = rows.some(function (row) {
      return row.state === "upgraded" && row.oldDriver && (!row.tested || !row.referencesReviewed);
    });
    var canResume = rows.some(function (row) {
      return ["review", "attention", "pending", "adding", "prepared", "cutover", "restored"].indexOf(row.state) >= 0;
    });
    el("backup-label").hidden = true;
    var heading = data.running ? (rows.some(function (row) { return row.family; }) ? "Migrating drivers" : "Migrating switch drivers") : programming ? "Update programming"
        : targetPending ? "Confirm the Home Assistant load" : testPending ? "Test the new drivers"
        : lighting ? "Update lighting scenes" : connections ? "Check connections" : attention ? "Driver setup needs attention"
          : manual ? "Finish migration in Composer" : count === rows.length
          ? (tested ? "Review migrated drivers" : "Test the new drivers") : "Continue migration";
    var nextTaskAppeared = !data.running && !programming && (targetPending || count === rows.length && !tested)
      && el("heading").textContent !== heading;
    display(heading,
      data.running ? "Preparing new drivers and checking their connections…"
        : data.needsNames ? "Finish applying the original names to the new drivers."
        : count === rows.length && tested ? "Review the old drivers for removal."
        : count === rows.length ? (noOtherDrivers ? "No other older Home Assistant drivers were found. " : "")
          + "In Composer’s System Design, double-click each new driver to test its controls. Follow any scene and programming checks below."
          + (confirmingTests ? " Then choose Confirm testing to see which old drivers are ready to remove." : "")
          + (!noOtherDrivers ? " To see other drivers you can migrate, choose Review more drivers." : "")
        : programming ? "Complete the Composer changes below, then check your changes. The original drivers stay connected while you work."
        : targetPending ? "The original stays connected until you confirm its load."
        : lighting ? "Make the listed lighting changes in Composer, then choose Check Composer changes. The original drivers stay connected while you work."
        : connections ? "Check the marked connections in Composer, then choose Check connections."
          + (confirmingTests ? " Follow the tests below for drivers that are ready." : "")
        : attention ? "Check the devices with setup issues below, then choose Retry driver setup."
          + (confirmingTests ? " You can test the drivers that are ready." : "")
        : "Follow the next step for each driver below.", rows, false, focus || nextTaskAppeared, data.running);
    button(back, false);
    button(refresh, !data.running, "Refresh status");
    button(cleanup, !data.running && !programming && data.canReviewRemoval,
      confirmingTests ? (count < rows.length ? "Confirm tests for ready drivers" : "Confirm testing") : "Review old drivers for removal");
    button(next, !data.running && (data.needsNames || (stageDone && !noOtherDrivers) || canResume),
      data.needsNames ? "Finish naming drivers" : stageDone ? "Review more drivers"
        : programming || lighting ? "Check Composer changes" : connections ? "Check connections"
        : attention ? "Retry driver setup" : "Continue migration");
    next.dataset.command = data.needsNames ? "finish_names" : stageDone ? "scan" : "resume";
    changed();
  }

  function read(focus, noOtherDrivers, token) {
    if (pending) return;
    clearTimeout(migrationStatusTimer);
    request("status", { token: token }, function (data) { renderStatus(data, focus, noOtherDrivers); });
  }

  function checkAvailability(focus) {
    if (!pending && phase === "loading" && !panel.hidden) {
      summary.textContent = "Checking for older Home Assistant drivers…";
    }
    request("availability", { includeStatus: true }, function (data) {
      if (!data.pending && !data.count) {
        hide();
        return;
      }
      if (panel.hidden) {
        display("Migrate drivers", "Checking this project for older Home Assistant drivers…", [], false, false);
        [next, back, refresh, cleanup, el("backup-label")].forEach(function (element) { button(element, false); });
      }
      panel.hidden = false;
      if (data.status && data.status.saved) renderStatus(data.status, focus);
      else if (data.pending) read(focus);
      else scan(focus);
    });
  }

  function checkRemoval() {
    request("review_removal", { tested: backup.checked, referencesReviewed: backup.checked, scope: removalScope }, function (data) {
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
    var lighting = completed.some(function (row) { return row.lighting && row.lighting.length; });
    el("confirmation").textContent = "I tested the controls I use on each new driver."
      + (edited ? " I also ran the programming I changed and verified it worked." : "")
      + (lighting ? " I tested the affected lighting scenes and load groups." : "")
      + " I checked that no scenes, agent settings or programming still use the old drivers.";
    el("backup-label").hidden = false;
    display("Confirm testing before removal",
      "Use the checkbox after testing and checking the old drivers’ references. Choose Check old drivers to see which ones are ready to remove in Composer.",
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
  refresh.onclick = function () {
    if (phase === "list" || phase === "waiting") {
      readinessChecks = 0;
      scan(true, true);
    }
    else if (migrationRunning) read(true, false, resultToken);
    else checkAvailability(true);
  };
  back.onclick = function () {
    if (phase === "list" || phase === "waiting" || phase === "cleanup-confirm" || phase === "cleanup") read(true);
    else renderList(true);
  };
  backup.onchange = changed;
  startDialog.addEventListener("close", function () {
    if (startDialog.returnValue === "start") startMigration();
    if (!migrationRunning) next.focus();
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
        params.token = resultToken;
        var reviewed = Array.from(list.querySelectorAll("[data-manual-review]:checked"), function (checkbox) {
          return Number(checkbox.dataset.manualReview);
        });
        if (reviewed.length) params.reviewed = reviewed;
      }
      request(next.dataset.command, params, function (data) { renderStatus(data, true); });
    }
  };
  Kit.listen("HA_SWITCH_UPGRADE_REPLY", receive);
  Kit.listen("HA_ADD_CONNECTED", function () {
    if (pending && pending.action === "scan") connectedDuringScan = true;
    else if (phase === "waiting" && !pending) scan(false);
  });
  Kit.listen("HA_SWITCH_UPGRADE_PROGRESS", function (data) {
    if (!data.saved || !data.token) return;
    if (pending) {
      if (startsMigration(pending.action) && pending.token === data.token) {
        if (data.running) {
          var firstProgress = !pending.progress;
          pending.completedBeforeReply = false;
          pending.progress = data;
          if (firstProgress) renderStatus(data, true);
          else if (data.progress) summary.textContent = data.progress;
        } else if (pending.progress) {
          finishRequest(data);
        } else {
          // A release recheck can save a non-running snapshot before starting the run.
          pending.completedBeforeReply = true;
        }
      } else if (pending.action === "status" && migrationRunning && data.token === resultToken
          && (!pending.token || pending.token === data.token) && !data.running) {
        finishRequest(data);
      } else if ((pending.action === "availability" || pending.action === "status") && !pending.token && !pending.retried
          && phase === "loading" && !data.running && openingRecheckToken !== data.token) {
        retryRead();
      }
    } else if (phase === "result" && data.token === resultToken && (!data.running || migrationRunning)) {
      renderStatus(data, false);
    } else if (phase === "loading" && !panel.hidden && !data.running && openingRecheckToken !== data.token) {
      openingRecheckToken = data.token;
      checkAvailability(false);
    }
  });
  return { connect: function () { checkAvailability(false); } };
})();
