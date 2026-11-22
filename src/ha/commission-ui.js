(function () {
  "use strict";

  var batchLimit = 16; // Matches the Coordinator's commissioning request limit.
  var pageId = Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
  var sequence = 0;
  var rooms = [];
  var roomsByName = Object.create(null);
  var roomIndex = Object.create(null);
  var setups = [];
  var setup;
  var canBrowse = false;
  var draft = [];
  var selectedOnly = false;
  var showExisting = false;
  var draftRevision;
  var catalog;
  var browseRequest;
  var pending;
  var plan;
  var finished;
  var decisions = { add: "Create in Control4", resume: "Finish setup", keep: "Keep existing Control4 device", review: "Needs attention" };
  var outcomes = { added: "Added to Control4", resumed: "Setup finished", kept: "Already set up", not_started: "Still to add", needs_attention: "Needs attention" };
  var reasons = {
    multiple_matches: "More than one project device matches.",
    unresolved_add: "An earlier attempt could not confirm this addition. Check the project and review again.",
    different_device_or_coordinator: "This device matches another setup in the project. Check its existing setup.",
    button_device_match: "The listed Control4 driver already uses this device’s buttons. Check its setup before adding another driver.",
    legacy_switch_match: "An older switch driver already controls this device. Check Migrate switch drivers in Quick Setup.",
    legacy_switch_unconfirmed: "Check the existing switch’s Home Assistant device before adding another control.",
    legacy_light_match: "Check this Light’s Properties. If it already controls the Home Assistant device you selected, go back and uncheck that device.",
    legacy_light_unconfirmed: "Check which Home Assistant device this Light controls in Properties. To continue adding other devices, go back and uncheck this device.",
    name_in_use: "The room already has a device with this name. Choose a different name.",
    project_identity_unreadable: "Check the existing devices in the Control4 project before adding another.",
    light_package_required: "In Composer, update an existing Home Assistant Light to the current driver, then review again.",
    light_add_unverified: "Check the Light added in Composer and update it to the current driver, then review again.",
    add_unconfirmed: "Check the project before trying again. The device may have been added.",
    add_rejected: "The controller declined to add this driver.",
    bind_unconfirmed: "The device was added. Check its Coordinator connection before finishing setup.",
    configuration_unconfirmed: "The device was added. Review its setup before trying again.",
    project_changed: "The project changed during setup. Review the devices again.",
    preview_changed: "The project or its devices changed. Review the devices again.",
    permission_denied: "Check the permissions for the Coordinator’s Home Assistant account.",
    timeout: "Check the controller and Home Assistant connections, then review again.",
  };

  function el(id) {
    return document.getElementById(id);
  }

  function text(id, value) {
    var node = el(id);
    if (node.textContent !== (value || "")) node.textContent = value || "";
    if (node.tagName === "P") node.hidden = !value;
  }

  function requestId() {
    sequence += 1;
    return pageId + "-" + sequence;
  }

  function familyName(family) {
    return family === "switch" ? "Switch" : "Light";
  }

  function run(command, args, answer, timeout) {
    if (pending) return;
    cancelBrowse();
    args.request = requestId();
    var active = { id: args.request, answer: answer, command: command };
    pending = active;
    active.timer = setTimeout(function () {
      if (pending !== active) return;
      pending = null;
      answer({ error: command === "HA_ADD_APPLY" ?
        "The controller did not confirm the additions. Review the devices again to see which are already set up." :
        "The Coordinator did not reply. Check its connection and try again." });
    }, timeout || 45000);
    render();
    Kit.sendCommand(command, args);
  }

  function receive(data) {
    if (!pending || data.request !== pending.id) return;
    var active = pending;
    clearTimeout(active.timer);
    pending = null;
    active.answer(data);
  }

  function cancelBrowse() {
    if (browseRequest) {
      clearTimeout(browseRequest.timer);
      browseRequest = null;
    }
    if (catalog) catalog.loading = false;
  }

  function requestPage(cursor, reused) {
    var active = { id: requestId(), reused: reused };
    browseRequest = active;
    var args = { request: active.id, setup: setup };
    if (cursor) args.cursor = cursor;
    if (cursor || reused) args.revision = catalog.revision;
    if (!cursor && !reused && catalog.refresh) args.refresh = true;
    active.timer = setTimeout(function () {
      if (browseRequest !== active) return;
      browseFailed("The device list took too long to load. Refresh to try again.");
    }, 20000);
    Kit.sendCommand("HA_ADD_BROWSE", args);
  }

  function browseFailed(error) {
    cancelBrowse();
    catalog = { error: error, choices: [] };
    renderPicker();
  }

  function recvPage(data) {
    if (!browseRequest || data.request !== browseRequest.id) return;
    var request = browseRequest;
    clearTimeout(request.timer);
    browseRequest = null;
    var next = data.next_cursor;
    if (data.error) {
      if (request.reused) findDevices();
      else browseFailed(data.error);
      return;
    }
    var end = data.cursor + (Array.isArray(data.choices) ? data.choices.length : 0);
    if (!Array.isArray(data.choices) || data.choices.length > 50 || !data.revision ||
        !Number.isInteger(data.total) || data.total < 0 || data.total > 5000 || data.cursor !== catalog.cursor ||
        (catalog.revision && catalog.revision !== data.revision) ||
        (catalog.total !== undefined && catalog.total !== data.total) ||
        (next == null ? end !== data.total + 1 : data.choices.length === 0 || next !== end || next > data.total) ||
        data.choices.some(function (item) {
          if (!item || typeof item.id !== "string" || !item.id || typeof item.name !== "string" ||
              !item.name || catalog.seen[item.id] || (item.existing !== undefined && typeof item.existing !== "boolean") ||
              !Array.isArray(item.families) ||
              !item.families.length || !item.families.includes(item.family) ||
              item.families.some(function (family, index) {
                return (family !== "light" && family !== "switch") || item.families.indexOf(family) !== index;
              }) || (item.resume !== undefined && (!item.resume || item.existing ||
                typeof item.resume.name !== "string" || nameError(item.resume.name) ||
                !Number.isInteger(item.resume.room_id) || item.resume.room_id <= 0 ||
                !item.families.includes(item.resume.family)))) return true;
          catalog.seen[item.id] = item;
          return false;
        })) {
      browseFailed("The list changed while it was loading. Refresh to load it again.");
      return;
    }
    catalog.revision = data.revision;
    catalog.helper = data.helper;
    catalog.total = data.total;
    data.choices.forEach(function (choice) { catalog.choices.push(choice); });
    catalog.loading = next != null;
    catalog.ready = !catalog.loading;
    if (!catalog.loading) renderPicker();
    if (catalog.loading) {
      var open = catalog;
      catalog.cursor = next;
      setTimeout(function () {
        if (catalog === open && catalog.loading && !pending) requestPage(next);
      }, 0);
    }
  }

  function findDevices(useCurrentRevision, refresh) {
    if (!canBrowse || pending) return;
    var revision = useCurrentRevision === true && catalog && catalog.ready ? catalog.revision : null;
    cancelBrowse();
    catalog = { choices: [], seen: Object.create(null), cursor: 1, loading: true, revision: revision, refresh: refresh };
    renderPicker();
    requestPage(undefined, !!revision);
  }

  function picked(id) {
    return draft.find(function (item) { return item.choice_id === id; });
  }

  function staleDraft() {
    return draftRevision && catalog && catalog.revision && catalog.revision !== draftRevision;
  }

  function nameKey(value) {
    return typeof value === "string" ? value.trim().toLowerCase() : "";
  }

  function matchingRoom(area) {
    var matches = roomsByName[nameKey(area)] || [];
    return matches.length === 1 ? matches[0].id : null;
  }

  function roomLabel(room) {
    return roomsByName[nameKey(room.name)].length > 1 ? room.name + " (room " + room.id + ")" : room.name;
  }

  function roomOptions() {
    return '<option value="">Choose a room</option>' + rooms.map(function (room) {
      return '<option value="' + room.id + '">' + Kit.esc(roomLabel(room)) + '</option>';
    }).join("");
  }

  function nameError(name) {
    return !name || /[\x00-\x1f\x7f]/.test(name) || new TextEncoder().encode(name).length > 128;
  }

  function defaultName(name) {
    var encoder = new TextEncoder();
    var output = "";
    for (var character of name.trim()) {
      if (/[\x00-\x1f\x7f]/.test(character)) continue;
      if (encoder.encode(output + character).length > 128) break;
      output += character;
    }
    return output.trim();
  }

  function choiceField(id, field) {
    var checkbox = el("pick-" + id);
    return checkbox && checkbox.closest("tr").querySelector('[data-field="' + field + '"]');
  }

  function focusChoice(id, field) {
    if (!choiceField(id, field)) {
      selectedOnly = true;
      renderPicker();
    }
    var target = choiceField(id, field);
    if (target && !target.disabled) target.focus();
  }

  function keepFocusVisible() {
    var target = document.activeElement;
    var screen = target.closest(".quick-picker");
    if (!screen || target.closest(".quick-footer")) return;
    var footer = screen.querySelector(".quick-footer").getBoundingClientRect();
    var field = target.getBoundingClientRect();
    var bottom = footer.top >= 0 && footer.top < innerHeight ? footer.top : innerHeight;
    if (field.top < 4) window.scrollBy(0, field.top - 4);
    else if (field.bottom + 4 > bottom) window.scrollBy(0, field.bottom + 4 - bottom);
  }

  function renderPicker() {
    var rows = el("choice-rows");
    var search = el("search").value.trim().toLowerCase();
    var data = catalog || { choices: [] };
    var stale = staleDraft();
    var active = rows.contains(document.activeElement) ? document.activeElement : null;
    var focus = active && { id: active.closest("tr").dataset.choice, field: active.dataset.field };
    var roomHTML = roomOptions();
    var visible = showExisting ? data.choices : data.choices.filter(function (item) { return !item.existing; });
    var matching = selectedOnly ? draft.map(function (item) { return item.source; }) : visible.filter(function (item) {
      var savedRoom = item.resume && roomIndex[item.resume.room_id];
      return [item.name, item.area, item.description, item.resume && item.resume.name, savedRoom && savedRoom.name]
        .join(" ").toLowerCase().includes(search);
    });
    rows.innerHTML = matching.map(function (item) {
      var selection = picked(item.id);
      var resume = item.resume;
      var room = roomIndex[selection ? selection.room_id : resume ? resume.room_id : matchingRoom(item.area)];
      var detail = [item.area, item.description, item.existing && "Already in Control4"].filter(Boolean).join(" · ");
      var escapeName = Kit.esc(item.name);
      var checkboxId = "pick-" + Kit.esc(item.id);
      var nameId = "name-" + Kit.esc(item.id);
      var resumeId = "resume-" + Kit.esc(item.id);
      var disabled = !data.ready || stale || (!selection && draft.length >= batchLimit);
      return '<tr data-choice="' + Kit.esc(item.id) + '"' + (selection ? ' class="is-picked"' : '') + '>' +
        '<td class="quick-select-cell"><input id="' + checkboxId + '" type="checkbox" data-field="checked" aria-label="Select ' + escapeName + '"' +
        (resume ? ' aria-describedby="' + resumeId + '"' : '') +
        (selection ? ' checked' : '') + (disabled ? ' disabled' : '') + '></td>' +
        '<td><label class="quick-row-name" for="' + checkboxId + '">' + escapeName + '</label>' +
        (detail ? '<div class="quick-row-detail">' + Kit.esc(detail) + '</div>' : '') +
        (resume ? '<div class="quick-row-detail" id="' + resumeId + '">Finish setting up ' + Kit.esc(resume.name) + '</div>' : '') +
        (selection && !resume ? '<div class="quick-name-field"><label for="' + nameId + '">Control4 name</label>' +
          '<input id="' + nameId + '" type="text" data-field="name" aria-label="Control4 name for ' + escapeName +
          '" aria-invalid="' + nameError(selection.name.trim()) + '" maxlength="128" required value="' +
          Kit.esc(selection.name) + '"' + (stale ? ' disabled' : '') + '></div>' : '') +
        '</td><td>' +
        (selection && !resume ? '<select data-field="room_id" required aria-label="Control4 room for ' + escapeName +
          '" aria-invalid="' + !room + '"' +
          (stale ? ' disabled' : '') + '>' + roomHTML + '</select>' :
          '<span class="quick-row-detail">' + Kit.esc(room ? roomLabel(room) : "—") + '</span>') +
        '</td><td>' + (selection && !resume && item.families.length > 1 ?
          '<select data-field="family" aria-label="Add ' + escapeName + ' as"' + (stale ? ' disabled' : '') + '>' +
          item.families.map(function (family) {
            return '<option value="' + family + '">' + familyName(family) + '</option>';
          }).join("") + '</select>' :
          familyName(selection ? selection.family : resume ? resume.family : item.family)) + '</td></tr>';
    }).join("");
    Array.prototype.forEach.call(rows.querySelectorAll("tr.is-picked"), function (row) {
      var item = picked(row.dataset.choice);
      var room = row.querySelector('[data-field="room_id"]');
      if (room) room.value = item.room_id || "";
      var family = row.querySelector('[data-field="family"]');
      if (family) family.value = item.family;
    });
    el("filters").hidden = selectedOnly;
    el("device-scope").hidden = selectedOnly;
    el("toggle-existing").disabled = !data.ready || !!pending;
    text("toggle-existing", showExisting ? "Show devices to add" : "Show all devices");
    text("review-hint", showExisting ? "Showing all supported Home Assistant devices." : "Showing devices to add or finish setting up.");
    el("selected-view").hidden = !selectedOnly;
    el("choices").hidden = !matching.length;
    el("helper").hidden = selectedOnly || data.helper !== false;
    el("browse").setAttribute("aria-disabled", String(data.loading === true || !!pending));
    text("catalog-status", data.error ||
      (stale ? "The device list changed. Clear your selection and choose devices again." :
        data.loading ? "Loading devices…" :
          data.ready && !selectedOnly && !matching.length ? (search ? (showExisting ? "No matching devices." : "No matching devices to add.") :
            data.choices.length ? "All devices in this category already have a Control4 driver." : "No compatible devices found.") :
            data.ready && !selectedOnly && search ? matching.length + " of " + visible.length + " devices shown" : ""));
    updateBatch();
    if (focus) {
      var field = choiceField(focus.id, focus.field);
      if (field && !field.disabled) field.focus({ preventScroll: true });
    }
  }

  function reviewIssue() {
    if (staleDraft()) return { message: "The device list changed. Clear your selection." };
    if (!rooms.length) return { message: "Add a room to the Control4 project.",
      label: "Check for rooms", action: readState };
    if (!draft.length) return null;
    if (!catalog || !catalog.ready) return catalog && catalog.loading ? { message: "Wait for the device list to finish loading." } :
      { message: "Refresh the device list to review your selection.", label: "Refresh devices", action: findDevices };
    var issues = draft.filter(function (item) { return !roomIndex[item.room_id] || nameError(item.name.trim()); });
    if (!issues.length) return null;
    var first = issues[0];
    if (first.source.resume) return {
      message: "Check the driver’s room in Composer, then refresh rooms.",
      label: "Refresh rooms", action: readState,
    };
    var field = roomIndex[first.room_id] ? "name" : "room_id";
    return {
      message: (field === "name" ? "Check the Control4 name for " : "Choose a room for ") + first.source.name +
        (issues.length > 1 ? " · " + issues.length + " to fix" : ""),
      label: "Fix selection",
      action: function () { focusChoice(first.choice_id, field); },
    };
  }

  function updateBatch() {
    var checking = pending && pending.command === "HA_ADD_PREVIEW";
    var unassigned = draft.filter(function (item) { return !item.source.resume && !roomIndex[item.room_id]; });
    var showBatch = unassigned.length && rooms.length && !staleDraft();
    var roomSelected = !!roomIndex[el("bulk-room").value];
    var includesHidden = unassigned.some(function (item) { return !choiceField(item.choice_id, "room_id"); });
    var issue = reviewIssue();
    text("selected-count", draft.length ? draft.length + " selected" +
      (draft.length === batchLimit ? " (batch limit)" : "") : "No devices selected");
    el("clear").hidden = !draft.length;
    el("clear").disabled = !!pending;
    el("batch").hidden = !showBatch;
    el("batch").parentNode.classList.toggle("has-batch", !!showBatch);
    el("bulk-room").disabled = !!pending;
    el("assign-room").disabled = !roomSelected || !!pending;
    el("batch-scope").hidden = !showBatch || (!roomSelected && !includesHidden);
    text("batch-scope", includesHidden ? "Fills empty rooms across your selection, including hidden devices." :
      "Fills empty rooms for the selected devices.");
    el("review-issues").hidden = !!pending || !issue;
    text("review-blocker", issue && issue.message);
    el("fix-selection").hidden = !issue || !issue.action;
    text("fix-selection", issue && issue.label);
    el("review").disabled = !checking && (!draft.length || !!pending || !!issue);
    el("review").setAttribute("aria-disabled", checking ? "true" : "false");
    requestAnimationFrame(keepFocusVisible);
  }

  function selectChoice(id, selected) {
    if (!catalog || !catalog.ready || staleDraft()) return;
    if (selected && draft.length < batchLimit && !picked(id)) {
      var row = catalog.seen[id];
      if (!row) return;
      var resume = row.resume || { family: row.family, room_id: matchingRoom(row.area), name: defaultName(row.name) };
      draftRevision = catalog.revision;
      draft.push({
        choice_id: id, source: row, family: resume.family, room_id: resume.room_id, name: resume.name,
      });
    } else if (!selected) {
      draft = draft.filter(function (item) { return item.choice_id !== id; });
      if (!draft.length) {
        draftRevision = null;
        if (selectedOnly) {
          showAll();
          return;
        }
      }
    }
    renderPicker();
  }

  function render() {
    el("picker").hidden = !canBrowse || !!plan || !!finished;
    el("preview").hidden = !plan;
    el("results").hidden = !finished;
    el("picker-inputs").inert = !!pending;
    el("reload-state").disabled = !!pending;
    el("edit").disabled = !!pending;
    renderPicker();
    if (plan) renderPlan();
  }

  function renderPlan() {
    var counts = { add: 0, resume: 0, keep: 0, review: 0 };
    plan.items.forEach(function (item) { counts[item.decision]++; });
    var summary = [];
    if (counts.add) summary.push("Create " + counts.add + (counts.add === 1
      ? " driver in the room shown and link it to its Home Assistant device."
      : " drivers in the rooms shown and link each to its Home Assistant device."));
    if (counts.resume) summary.push("Finish setup for " + counts.resume + (counts.resume === 1 ? " existing driver." : " existing drivers."));
    if (counts.keep) summary.push("Keep " + counts.keep + (counts.keep === 1 ? " existing driver." : " existing drivers."));
    if (counts.review) summary.push("Resolve the items marked Needs attention before confirming.");
    var driverCount = counts.add + (counts.add === 1 ? " driver" : " drivers");
    el("apply").disabled = counts.review > 0 || !(counts.add || counts.resume);
    el("apply").setAttribute("aria-disabled", el("apply").disabled || pending ? "true" : "false");
    text("apply", counts.add ? "Create " + driverCount + (counts.resume ? " and finish setup" : "") :
      counts.resume ? "Finish setup for " + counts.resume + (counts.resume === 1 ? " driver" : " drivers") : "Confirm setup changes");
    text("review-detail", summary.join(" "));
    text("apply-status", pending ? "Applying your confirmed changes…" : "");
    el("preview-rows").innerHTML = plan.items.map(function (item) {
      var reason = reasons[item.reason] || (item.decision === "review" ? "Check this device in the project before continuing." : "");
      return "<li><strong>" + Kit.esc(item.name) + "</strong>" +
        (item.source_name && item.source_name !== item.name ? '<p class="setup-detail">Home Assistant device: ' +
          Kit.esc(item.source_name) + "</p>" : "") +
        '<p class="setup-detail">' + Kit.esc([familyName(item.family), item.room_name, decisions[item.decision]].filter(Boolean).join(" · ")) +
        "</p>" + (reason ? "<p>" + Kit.esc(reason) + "</p>" : "") + "</li>";
    }).join("");
  }

  function readState() {
    var active = document.activeElement;
    var returnFocus = el("picker").contains(active) || el("preview").contains(active) || active === el("reload-state");
    cancelBrowse();
    catalog = null;
    if (pending) {
      var interrupted = pending;
      clearTimeout(interrupted.timer);
      pending = null;
      if (interrupted.command === "HA_ADD_APPLY") {
        interrupted.answer({ error: "The connection changed before the controller confirmed setup. Review the devices again to see which are already set up." });
      } else if (interrupted.command === "HA_ADD_PREVIEW") {
        text("addition-status", "The connection changed. Review the selected devices again when the list is ready.");
      }
    }
    if (plan) {
      plan = null;
      text("addition-status", "The connection changed. Review the selected devices again.");
    }
    canBrowse = false;
    text("connection", "Checking connection…");
    run("HA_ADD_GET", {}, function (data) {
      rooms = Array.isArray(data.rooms) ? data.rooms.filter(function (room) {
        return room && Number.isInteger(room.id) && room.id > 0 && typeof room.name === "string" && nameKey(room.name);
      }) : [];
      roomsByName = Object.create(null);
      roomIndex = Object.create(null);
      rooms.forEach(function (room) {
        var key = nameKey(room.name);
        (roomsByName[key] || (roomsByName[key] = [])).push(room);
        roomIndex[room.id] = room;
      });
      el("bulk-room").innerHTML = roomOptions();
      setups = Array.isArray(data.setups) ? data.setups.filter(function (item) {
        return item && typeof item.id === "string" && /^[a-z][a-z0-9_]*$/.test(item.id) &&
          typeof item.name === "string" && item.name.trim();
      }) : [];
      if (!setups.some(function (item) { return item.id === setup; })) setup = setups[0] && setups[0].id;
      el("setup-kind").innerHTML = setups.map(function (item) {
        return '<option value="' + Kit.esc(item.id) + '">' + Kit.esc(item.name) + "</option>";
      }).join("");
      if (setup) el("setup-kind").value = setup;
      canBrowse = data.can_browse === true && !!setup;
      text("connection", data.error || (canBrowse ? "Connected" :
        data.can_browse ? "This Coordinator version does not offer Quick Setup." :
          "Check the Home Assistant address and access token in Properties. Devices appear when Home Assistant connects."));
      el("reload-state").hidden = canBrowse;
      render();
      if (canBrowse && !finished) findDevices();
      if (returnFocus && !finished) {
        if (canBrowse) focusReview();
        else el("reload-state").focus();
      }
    });
  }

  function focusReview() {
    if (!el("review").disabled) el("review").focus();
    else if (!el("fix-selection").hidden) el("fix-selection").focus();
    else if (staleDraft()) el("clear").focus();
    else (selectedOnly ? el("show-all") : el("search")).focus();
  }

  function refreshWaitingConnection() {
    if (!canBrowse && (!pending || pending.command === "HA_ADD_GET")) readState();
  }

  function requestPreview() {
    if (pending || el("review").disabled) return;
    var choices = draft.map(function (item) {
      return { choice_id: item.choice_id, family: item.family, name: item.name.trim(), room_id: item.room_id };
    });
    el("review").focus();
    text("addition-status", "Checking devices against the project…");
    run("HA_ADD_PREVIEW", { revision: draftRevision, choices: choices }, function (data) {
      if (data.error || !data.id || !Array.isArray(data.items) || data.items.length !== choices.length ||
          choices.some(function (choice, index) {
            var item = data.items[index];
            return !item || item.choice_id !== choice.choice_id || !Object.prototype.hasOwnProperty.call(decisions, item.decision);
          })) {
        text("addition-status", data.error || "The review could not be loaded. Review the devices again.");
      } else {
        plan = data;
        text("addition-status", "");
      }
      render();
      if (plan) el("preview-title").focus();
      else focusReview();
    });
  }

  function apply() {
    if (!plan || pending || el("apply").disabled) return;
    el("apply").focus();
    run("HA_ADD_APPLY", { id: plan.id }, function (data) {
      var names = Object.create(null);
      plan.items.forEach(function (item) { names[item.choice_id] = item.name; });
      plan = null;
      finished = true;
      if (data.complete) {
        draft = [];
        draftRevision = null;
        selectedOnly = false;
      }
      text("result-detail", data.error || (data.complete ? "The selected devices are set up in Control4." :
        "Check the items below. Review the devices again to finish setting them up."));
      el("result-rows").innerHTML = (Array.isArray(data.items) ? data.items : []).map(function (item) {
        var reason = reasons[item.reason] || "";
        return "<li><strong>" + Kit.esc(names[item.choice_id] || "Device") + "</strong><p>" +
          Kit.esc(outcomes[item.status] || "Check setup") + "</p>" + (reason ? "<p>" + Kit.esc(reason) + "</p>" : "") + "</li>";
      }).join("");
      render();
      el(data.error ? "back" : "results-title").focus();
    }, 1200000);
  }

  function showAll() {
    selectedOnly = false;
    renderPicker();
    el("search").focus();
  }

  el("reload-state").addEventListener("click", readState);
  el("browse").addEventListener("click", function (event) {
    if (event.currentTarget.getAttribute("aria-disabled") !== "true") findDevices(false, true);
  });
  el("toggle-existing").addEventListener("click", function () {
    showExisting = !showExisting;
    renderPicker();
  });
  el("setup-kind").addEventListener("change", function () {
    setup = el("setup-kind").value;
    findDevices(true);
  });
  el("search").addEventListener("input", function () {
    renderPicker();
  });
  el("choice-rows").addEventListener("change", function (event) {
    var field = event.target.dataset.field;
    if (!field) return;
    var id = event.target.closest("tr").dataset.choice;
    if (field === "checked") {
      selectChoice(id, event.target.checked);
    } else {
      var item = picked(id);
      if (!item || staleDraft()) return;
      if (field === "room_id") {
        item.room_id = roomIndex[event.target.value] ? Number(event.target.value) : null;
        event.target.setAttribute("aria-invalid", item.room_id ? "false" : "true");
      } else if (field === "family" && item.source.families.includes(event.target.value)) {
        item.family = event.target.value;
      }
      updateBatch();
    }
  });
  el("choice-rows").addEventListener("input", function (event) {
    if (event.target.dataset.field !== "name" || staleDraft()) return;
    var item = picked(event.target.closest("tr").dataset.choice);
    if (!item) return;
    item.name = event.target.value;
    event.target.setAttribute("aria-invalid", String(nameError(item.name.trim())));
    updateBatch();
  });
  el("bulk-room").addEventListener("change", updateBatch);
  el("assign-room").addEventListener("click", function () {
    var room = roomIndex[el("bulk-room").value];
    if (!room || pending || staleDraft()) return;
    draft.forEach(function (item) {
      if (!item.source.resume && !roomIndex[item.room_id]) item.room_id = room.id;
    });
    el("bulk-room").value = "";
    renderPicker();
    focusReview();
  });
  el("clear").addEventListener("click", function () {
    draft = [];
    draftRevision = null;
    text("addition-status", "");
    showAll();
  });
  el("show-all").addEventListener("click", showAll);
  el("fix-selection").addEventListener("click", function () {
    var issue = reviewIssue();
    if (!issue || !issue.action || pending) return;
    issue.action();
    if (issue.action === findDevices) focusReview();
  });
  el("review").addEventListener("click", requestPreview);
  el("apply").addEventListener("click", apply);
  el("edit").addEventListener("click", function () {
    var issue = plan.items.find(function (item) { return item.decision === "review"; });
    plan = null;
    render();
    if (issue) focusChoice(issue.choice_id, issue.reason === "name_in_use" ? "name" : "checked");
    else focusReview();
  });
  el("back").addEventListener("click", function () {
    finished = false;
    text("addition-status", "");
    if (canBrowse) findDevices(true);
    render();
    if (canBrowse) focusReview();
    else el("reload-state").focus();
  });
  el("picker").addEventListener("focusin", function () { requestAnimationFrame(keepFocusVisible); });
  window.addEventListener("resize", keepFocusVisible);
  window.addEventListener("pagehide", cancelBrowse);
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) refreshWaitingConnection();
  });
  Kit.connectDriver({
    handlers: {
      HA_ADD_CONNECTED: refreshWaitingConnection,
      HA_ADD_STATE: receive,
      HA_ADD_PAGE: recvPage,
      HA_ADD_PREVIEWED: receive,
      HA_ADD_RESULT: receive,
    },
    onConnect: function () {
      readState();
      SwitchUpgradePage.connect();
    },
  });
})();
