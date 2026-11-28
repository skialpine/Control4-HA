(function () {
  "use strict";

  var rowsPerView = 10;
  var maxChoices = 5000;
  var entityID = /^[a-z][a-z0-9_]*\.[a-z0-9_]+$/;
  // Composer broadcasts replies to all tabs on this driver. Correlate each request to its originating tab.
  var pageId = Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
  var sequence = 0;
  var state = {};
  var readRequest;
  var readTimer;
  var browse;
  var pending;
  var feedbackError = false;
  var previousIndicators;
  var migrationResult = typeof installSwitchMigration === "function" ? installSwitchMigration(requestId, function () {
    readState(true);
    focusRecovery();
  }) : function () {};

  function el(id) {
    return document.getElementById(id);
  }

  function requestId() {
    sequence += 1;
    return pageId + "-" + sequence;
  }

  function message(id, text) {
    el(id).textContent = text || "";
    el(id).hidden = !text;
  }

  function fact(label, id, value) {
    el(label).hidden = !value;
    message(id, value);
  }

  function distinctTarget() {
    if (state.separate_target || state.target === "Buttons only") return state.target;
    return state.title && state.target && state.title.toLowerCase() === state.target.toLowerCase() ? "" : state.target;
  }

  function updateIndicatorSection() {
    var wrapper = el("indicator-section");
    var settings = el("indicator-settings");
    var source = el("indicator-source");
    var active = document.activeElement;
    settings.hidden = state.indicator_policy !== "all";
    source.hidden = !state.indicator_policy || (state.indicator_policy === "single" && !state.indicator_following);
    if ((settings.hidden && settings.contains(active)) || (source.hidden && source.contains(active))) {
      var behavior = el("indicator-rows").querySelector('[data-field="behavior"] select');
      if (behavior) behavior.focus();
      else focusRecovery();
    }
    el("indicator-title").textContent = state.title ? "Indicator lights on " + state.title : "Indicator lights";
    message("indicator-hint", state.indicator_hint);
    el("indicator-help").hidden = !!state.native_endpoint || !state.selected_id ||
      !!state.indicator_hint || !!state.indicator_lease;
    var unavailable = el("indicators").hidden && (settings.hidden || settings.parentElement.hidden) &&
      (source.hidden || source.parentElement.hidden) && !state.indicator_hint;
    if (unavailable && wrapper.contains(document.activeElement)) focusRecovery();
    wrapper.hidden = unavailable;
  }

  function updateButtonControls() {
    var settings = el("button-settings");
    var appLink = el("app-link-settings");
    var behavior = settings.querySelector("select");
    var hideLink = !state.app_link_available || appLink.parentElement.hidden;
    if (hideLink && appLink.contains(document.activeElement)) {
      if (behavior) behavior.focus();
      else focusRecovery();
    }
    appLink.hidden = hideLink;
    el("button-controls").hidden = settings.parentElement.hidden && hideLink && el("linked-settings-help").hidden;
  }

  function renderState() {
    var focused = document.activeElement;
    var summary = el("button-behavior-summary");
    var summaryChanged = summary.textContent !== (state.button_behavior_summary || "");
    var capabilities = Array.isArray(state.capabilities) ? state.capabilities.join(", ") : "";
    el("device-title").textContent = state.title || "Device Setup";
    el("device-status").textContent = state.status || "Connecting";
    var detail = state.detail || (state.status ? "" : "Connecting to the driver…");
    message("device-detail", state.status === "Device connected" &&
      detail === "Home Assistant is reporting its state." ? "" : detail);
    var target = distinctTarget();
    el("device-facts").hidden = !target && !capabilities;
    var buttonsOnly = state.target === "Buttons only";
    el("target-label").textContent = buttonsOnly ? "App control" : "Controls";
    fact("target-label", "device-target", buttonsOnly ? "Off" : target);
    fact("capabilities-label", "device-capabilities", capabilities);
    el("browse").textContent = state.selected_id ? "Change device" : "Choose device";
    el("browse").disabled = !state.can_browse || !!pending;
    el("browse").hidden = !!state.read_retry;
    el("retry").textContent = state.feedback_retry ? "Refresh device state" : "Retry setup";
    el("retry").hidden = state.retry !== true;
    el("retry").disabled = !!pending;
    el("browse").className = state.retry ? "btn btn-outline" : "btn btn-primary";
    el("retry").className = "btn btn-primary";
    el("read-retry").hidden = !state.read_retry;
    message("setup-operation", pending || state.operation === el("setup-message").textContent ? "" : state.operation);
    if (summaryChanged) message("button-behavior-summary", state.button_behavior_summary);
    message("linked-settings-help", state.linked_settings_help);
    updateButtonControls();
    var migration = el("switch-migration");
    if (migration) {
      migration.hidden = !state.migration_available;
      if (migration.hidden && migration.contains(focused)) focusRecovery();
    }
    el("timing-report").disabled = el("timing-reset").disabled = !state.status || !!pending;
    if (browse) {
      if (state.can_browse) renderChoices();
      else closePicker(el("picker").contains(focused));
    }
    if ((el("browse").disabled && focused === el("browse")) ||
        (el("retry").hidden && focused === el("retry")) ||
        (el("read-retry").hidden && focused === el("read-retry"))) focusRecovery();
    renderIndicators();
    updateIndicatorSection();
    if (summaryChanged && !summary.hidden && el("button-settings").contains(document.activeElement)) {
      summary.parentElement.scrollIntoView({ block: "nearest" });
      document.activeElement.scrollIntoView({ block: "nearest" });
    }
  }

  function focusRecovery() {
    var browseButton = el("browse");
    (state.read_retry ? el("read-retry") : browseButton.disabled ? el("device-detail") : browseButton).focus();
  }

  function readState(send) {
    clearTimeout(readTimer);
    readRequest = requestId();
    state = {};
    renderState();
    readTimer = setTimeout(function () {
      var restore = document.activeElement === el("device-detail");
      readRequest = null;
      state = {
        status: "Driver did not respond",
        detail: "Check Driver Status and Next step in Properties, then try again.",
        read_retry: true,
      };
      renderState();
      if (restore) focusRecovery();
    }, 10000);
    if (send) Kit.sendCommand("HA_SETUP_GET", { request: readRequest });
  }

  var behaviors = {
    always_on: "Always on",
    always_off: "Always off",
    follow_load: "On when the device is on",
    follow_load_inverted: "On when the device is off",
    follow_bound: "Follow the linked light",
    use_device_setting: "Keep current LED setting",
  };
  var colors = { FF0000: "Red", "00FF00": "Green", "0000FF": "Blue", FFFFFF: "White", FFFF00: "Yellow", FF00FF: "Magenta", "00FFFF": "Cyan" };

  function indicatorField(field, label, control, apply) {
    return '<form class="indicator-field" data-field="' + field + '"><label>' +
      label + control + '</label>' + (apply ? '<button class="btn btn-outline" type="submit">Apply</button>' : '') + '</form>';
  }

  function indicatorOptions(items, current, label) {
    return '<select name="value" required><option value="" disabled' +
      (items.indexOf(current) === -1 ? ' selected' : '') + '>Choose…</option>' +
      items.map(function (value) {
        return '<option value="' + Kit.esc(value) + '"' + (value === current ? " selected" : "") +
          '>' + Kit.esc(label(value)) + '</option>';
      }).join("") + '</select>';
  }

  function indicatorForm(id, field) {
    return Array.from(el("indicator-rows").querySelectorAll("form")).find(function (form) {
      return form.dataset.field === field && form.closest(".indicator-item").dataset.id === id;
    });
  }

  function indicatorDraft(form) {
    var input = form.elements.value;
    var initial = input.defaultValue;
    if (input.options) {
      var selected = Array.from(input.options).find(function (option) { return option.defaultSelected; });
      initial = (selected || input.options[0]).value;
    }
    return input.value !== initial ? input.value : undefined;
  }

  function renderIndicators() {
    var rows = Array.isArray(state.indicators) ? state.indicators : [];
    var signature = JSON.stringify([state.indicator_lease, state.indicator_policy, state.indicator_following, rows]);
    var element = el("indicator-rows");
    el("indicators").hidden = (!state.indicator_lease || rows.length === 0) && el("indicator-status").hidden;
    element.inert = !!pending;
    if (signature === previousIndicators) return;
    previousIndicators = signature;
    var active = document.activeElement;
    var editing = element.contains(active) && active.closest("form");
    var lease = state.indicator_lease || "";
    var draft = editing && element.dataset.lease === lease ? indicatorDraft(editing) : undefined;
    element.dataset.lease = lease;
    element.innerHTML = rows.map(function (row) {
      var inputs = [];
      if (Array.isArray(row.colors) && row.colors.length) {
        inputs.push(indicatorField("color", "Indicator color", indicatorOptions(row.colors, row.configured_color || row.color, function (value) {
          return colors[value] || "#" + value;
        })));
      }
      if (Array.isArray(row.tracking_colors) && row.tracking_colors.length) {
        ["on", "off"].forEach(function (state) {
          var field = state + "_color";
          inputs.push(indicatorField(field, "When the light is " + state, indicatorOptions(row.tracking_colors, row[field], function (value) {
            return value === "000000" ? "Off" : colors[value] || "#" + value;
          })));
        });
      }
      if (row.brightness_supported) {
        var discrete = Array.isArray(row.levels) && row.levels.length > 0;
        var level = discrete ?
          indicatorOptions(row.levels, row.brightness, function (value) { return value + "%"; }) :
          '<input type="number" name="value" min="0" max="100" step="1" required value="' + Kit.esc(row.brightness) + '">';
        inputs.push(indicatorField("brightness", "Brightness (%)", level, !discrete));
      }
      if (Array.isArray(row.behaviors) && row.behaviors.length) {
        var options = row.behaviors;
        var behavior = row.behavior;
        if (state.indicator_policy === "single") {
          options = options.concat("follow_bound");
          if (state.indicator_following) {
            options = options.concat("use_device_setting");
            behavior = "follow_bound";
          }
        }
        inputs.push(indicatorField("behavior", "Behavior", indicatorOptions(options, behavior, function (value) {
          return behaviors[value];
        })));
      }
      return '<div class="indicator-item" data-id="' + Kit.esc(row.id) + '"><strong>' + Kit.esc(row.label) +
        '</strong><div class="indicator-controls">' + inputs.join("") + '</div></div>';
    }).join("");
    if (editing) {
      var form = indicatorForm(editing.closest(".indicator-item").dataset.id, editing.dataset.field);
      if (!form) {
        focusRecovery();
        return;
      }
      var input = form.elements.value;
      if (draft !== undefined) {
        var confirmed = input.value;
        input.value = draft;
        if (input.value !== draft || !input.checkValidity()) input.value = confirmed;
      }
      ((active.type === "submit" && form.querySelector("button")) || input).focus();
    }
  }

  function closePicker(restoreFocus) {
    if (browse) clearTimeout(browse.timer);
    browse = null;
    el("picker").hidden = true;
    el("browse").setAttribute("aria-expanded", "false");
    el("search").value = "";
    el("choice-rows").textContent = "";
    if (restoreFocus) focusRecovery();
  }

  function renderChoices() {
    var query = el("search").value.trim().toLowerCase();
    var exactID = entityID.test(query);
    var current = state.selected_id && browse.choices.find(function (choice) {
      return choice.id === state.selected_id;
    });
    var selected = state.selected_id && (state.title || (current && current.name));
    var target = distinctTarget();
    message("picker-current", [selected && ("Current device: " + selected),
      target && (target === "Buttons only" ? "App control is off" : "Controls: " + target)
    ].filter(Boolean).join(" · "));
    var matches = browse.choices.filter(function (choice) {
      if (exactID) return choice.id === query || (choice.entity_ids || []).includes(query);
      return [choice.name, choice.area, choice.description, choice.target].filter(Boolean).join(" ")
        .toLowerCase().indexOf(query) !== -1;
    });
    var visible = matches.slice(browse.offset, browse.offset + rowsPerView);
    var existing = el("choice-rows");
    var focused = document.activeElement;
    var restore = existing.contains(focused) ? focused.value : null;

    existing.innerHTML = visible.map(function (choice) {
      var isCurrent = choice.id === state.selected_id;
      var target = isCurrent ? distinctTarget() : choice.target;
      var detail = [isCurrent && "Current device", choice.area, choice.description,
        target && (target === "Buttons only" ? "App control is off" :
          (isCurrent ? "Controls: " : "Home Assistant control: ") + target)
      ].filter(Boolean).join(" · ");
      return '<label class="setup-choice"><input type="radio" name="device" value="' + Kit.esc(choice.id) + '"' +
        (browse.picked === choice.id ? " checked" : "") + '><span>' + Kit.esc(choice.name) +
        (detail ? '<span class="choice-detail">' + Kit.esc(detail) + "</span>" : "") + "</span></label>";
    }).join("");

    el("choices").hidden = !visible.length;
    el("previous").hidden = browse.offset === 0;
    el("more").hidden = matches.length <= browse.offset + visible.length;
    message("picker-names", browse.namesWarning ? "Custom names and rooms are unavailable. Showing names from Home Assistant." : "");
    el("picker-helper").hidden = !!state.native_endpoint || browse.helper !== false || !!browse.error || exactID;
    el("reload").disabled = browse.loading;
    el("apply").hidden = !visible.length || !!browse.error;
    el("apply").disabled = !browse.picked || !visible.some(function (choice) { return choice.id === browse.picked; }) ||
      !!browse.error;
    message("picker-status", browse.error || (browse.loading ? "Finding devices…" :
      !matches.length ? (exactID ? "No device matches this entity ID. Check it in Home Assistant." :
        query ? "No matching devices." : "No supported devices found.") :
        matches.length > visible.length ? "Showing " + (browse.offset + 1) + "–" + (browse.offset + visible.length) + " of " + matches.length + " results." : ""));
    if (restore !== null) {
      var inputs = existing.querySelectorAll("input");
      for (var i = 0; i < inputs.length; i += 1) {
        if (inputs[i].value === restore) {
          inputs[i].focus();
          break;
        }
      }
    }
  }

  function browseFailed(error) {
    browse.loading = false;
    browse.error = error;
    browse.choices = [];
    browse.picked = null;
    renderChoices();
  }

  function requestPage(cursor) {
    var request = requestId();
    browse.request = request;
    browse.timer = setTimeout(function () {
      if (!browse || browse.request !== request) return;
      browse.request = null;
      browseFailed("The device list took too long to load. Reload devices to try again.");
    }, 20000);
    Kit.sendCommand("HA_SETUP_BROWSE", cursor ? { request: request, cursor: cursor, revision: browse.revision } : { request: request, refresh: browse.refresh });
  }

  function openPicker(refresh) {
    if (!state.can_browse || pending) return;
    var query = refresh && browse ? el("search").value : "";
    closePicker(false);
    message("setup-message", "");
    browse = { choices: [], loading: true, refresh: refresh, offset: 0, cursor: 1, seen: Object.create(null) };
    el("search").value = query;
    el("picker").hidden = false;
    el("browse").setAttribute("aria-expanded", "true");
    renderChoices();
    el("picker").scrollIntoView({ block: "start" });
    el("search").focus({ preventScroll: true });
    requestPage();
  }

  function receivePage(data) {
    if (!browse || data.request !== browse.request) return;
    clearTimeout(browse.timer);
    browse.request = null;
    if (data.error) {
      browseFailed(data.error);
      return;
    }
    var choices = data.choices;
    var next = data.next_cursor;
    var end = data.cursor + (Array.isArray(choices) ? choices.length : 0);
    if (data.cursor !== browse.cursor || typeof data.revision !== "string" || !data.revision ||
        (browse.revision && (data.revision !== browse.revision || data.total !== browse.total)) ||
        !Array.isArray(choices) || choices.length > 50 || !Number.isInteger(data.total) || data.total < 0 ||
        data.total > maxChoices || end > data.total + 1 ||
        (next == null ? end !== data.total + 1 : !choices.length || next !== end || next > data.total) ||
        choices.some(function (choice) {
          if (!choice || typeof choice.id !== "string" || !choice.id || typeof choice.name !== "string" ||
              !choice.name || browse.seen[choice.id] || (choice.entity_ids !== undefined &&
                (!Array.isArray(choice.entity_ids) || choice.entity_ids.some(function (id) {
                  return typeof id !== "string" || !entityID.test(id);
                })))) return true;
          browse.seen[choice.id] = true;
          return false;
        })) {
      browseFailed("The device list changed. Reload devices to see the latest choices.");
      return;
    }
    var firstPage = !browse.revision;
    browse.revision = data.revision;
    browse.helper = data.helper;
    browse.namesWarning = browse.namesWarning || data.catalogWarning;
    browse.total = data.total;
    browse.choices = browse.choices.concat(choices);
    browse.loading = next != null;
    renderChoices();
    if (firstPage && document.activeElement === el("search") && el("apply").getBoundingClientRect().bottom > window.innerHeight) {
      el("picker").scrollIntoView({ block: "start" });
    }
    if (browse.loading) {
      var opened = browse;
      browse.cursor = next;
      // Yield to the webview so search and close remain responsive during a large transfer.
      browse.timer = setTimeout(function () {
        if (browse === opened) requestPage(next);
      }, 0);
    }
  }

  function restoreIndicatorFocus(work) {
    if (!work.indicator || document.activeElement !== el("indicator-status")) return;
    var form = indicatorForm(work.indicator.id, work.indicator.field);
    if (form) (form.querySelector("button") || form.elements.value).focus();
  }

  function run(command, args, isTiming, progress, outputId) {
    if (pending) return;
    closePicker(false);
    args.request = requestId();
    var request = args.request;
    var output = outputId || (isTiming ? "timing-status" : "setup-message");
    if (output === "setup-message") feedbackError = false;
    pending = { request: request, timing: isTiming, output: output, action: args.action, feedback: args.feedback === true };
    if (command === "HA_SETUP_INDICATOR") pending.indicator = { id: args.id, field: args.field };
    var work = pending;
    pending.timer = setTimeout(function () {
      if (!pending || pending.request !== request) return;
      pending = null;
      if (work.indicator) previousIndicators = null;
      var restore = output === "setup-message" && document.activeElement === el(output);
      if (output === "setup-message") feedbackError = work.feedback && state.feedback_retry === true;
      message(output, work.feedback && state.status === "Device connected" ? "" :
        "The driver did not reply. Check its connection and try again.");
      renderState();
      restoreIndicatorFocus(work);
      if (restore) {
        if (state.retry) el("retry").focus();
        else focusRecovery();
      }
    }, 65000);
    message(output, progress);
    if (work.indicator) el(output).focus();
    renderState();
    Kit.sendCommand(command, args);
  }

  el("browse").addEventListener("click", function () {
    if (browse) closePicker(true);
    else openPicker();
  });
  el("close-picker").addEventListener("click", function () { closePicker(true); });
  el("picker").addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      event.preventDefault();
      closePicker(true);
    }
  });
  window.addEventListener("pagehide", function () { closePicker(false); });
  el("reload").addEventListener("click", function () { openPicker(true); });
  el("search").addEventListener("input", function () {
    browse.offset = 0;
    renderChoices();
  });
  function changeResultPage(delta) {
    browse.offset += delta;
    renderChoices();
    el("choice-rows").querySelector("input").focus();
  }

  el("more").addEventListener("click", function () { changeResultPage(rowsPerView); });
  el("previous").addEventListener("click", function () { changeResultPage(-rowsPerView); });
  el("choice-rows").addEventListener("change", function (event) {
    if (browse && event.target.name === "device") {
      browse.picked = event.target.value;
      el("apply").disabled = !!browse.error;
    }
  });
  el("apply").addEventListener("click", function () {
    if (!browse || !browse.picked || el("apply").disabled) return;
    var selection = { choice_id: browse.picked, revision: browse.revision };
    run("HA_SETUP_CHOOSE", selection, false, state.selected_id ? "Checking the new device…" : "Setting up the device…");
    el("setup-message").focus();
  });
  el("retry").addEventListener("click", function () {
    var feedback = state.feedback_retry === true;
    run("HA_SETUP_RETRY", feedback ? { feedback: true } : {}, false,
      feedback ? "Checking the current device state…" : "Retrying setup…");
    el("setup-message").focus();
  });
  el("read-retry").addEventListener("click", function () {
    readState(true);
    el("device-detail").focus();
  });
  function changeIndicator(form) {
    var item = form.closest(".indicator-item");
    if (pending || !item || !state.indicator_lease || !form.checkValidity()) return;
    var field = form.dataset.field;
    var value = form.elements.value.value;
    run("HA_SETUP_INDICATOR", {
      lease: state.indicator_lease,
      id: item.dataset.id,
      field: field,
      value: field === "brightness" ? Number(value) : value,
    }, false, field === "on_color" || field === "off_color" ? "Saving indicator preference…" : "Sending indicator change…", "indicator-status");
  }
  el("indicator-rows").addEventListener("submit", function (event) {
    event.preventDefault();
    if (!event.target.elements.value.options) changeIndicator(event.target);
  });
  el("indicator-rows").addEventListener("change", function (event) {
    if (event.target.tagName === "SELECT") changeIndicator(event.target.form);
  });
  el("timing-report").addEventListener("click", function () {
    run("HA_SETUP_ACTION", { action: "timing_report" }, true, "Reading timing samples…");
  });
  el("timing-reset").addEventListener("click", function () {
    if (window.confirm("Clear the recorded timing samples on this driver?")) {
      run("HA_SETUP_ACTION", { action: "timing_reset" }, true, "Clearing timing samples…");
    }
  });

  Kit.initPropertiesCard(el("settings"), {
    exclude: ["Driver Status", "Manual entity ID"],
    sections: [
      { el: el("button-settings"), names: ["Button behavior"] },
      { el: el("app-link-settings"), names: ["App Control Link"] },
      { el: el("indicator-settings"), names: ["LED Behavior"] },
      { el: el("indicator-source"), names: ["LED Feedback Source"] },
      { el: el("light-compatibility-choices"), names: ["Light type override", "Color format override"] },
      { el: el("light-compatibility-range"), names: ["White temperature limits (K)"], apply: "Apply" },
    ],
    labels: {
      "Discovery Catalog Entity ID": "Sensor for custom device names",
      "App Control Link": "Light controlled by the app",
      "LED Behavior": "Indicator behavior",
      "LED Feedback Source": "Follow the light linked to",
    },
    readouts: true,
    afterRender: function () {
      el("light-compatibility").hidden =
        el("light-compatibility-choices").parentElement.hidden && el("light-compatibility-range").parentElement.hidden;
      updateIndicatorSection();
      var settings = el("button-settings");
      var behavior = settings.querySelector("select");
      if (behavior) behavior.setAttribute("aria-describedby", behavior.getAttribute("aria-describedby") + " button-behavior-summary");
      updateButtonControls();
    },
  });
  readState(false);
  Kit.connectDriver({
    handlers: {
      HA_SETUP_STATE: function (data) {
        if (data.request && data.request !== readRequest) return;
        var restore = Boolean(readRequest && document.activeElement === el("device-detail"));
        clearTimeout(readTimer);
        readRequest = null;
        if (state.selected_id !== data.selected_id) {
          if (pending && pending.indicator) {
            clearTimeout(pending.timer);
            pending = null;
          }
          message("indicator-status", "");
        }
        state = data.error ? { status: "Setup unavailable", detail: data.error, read_retry: true } : data;
        if (feedbackError && state.status === "Device connected") {
          feedbackError = false;
          message("setup-message", "");
        }
        renderState();
        if (restore) focusRecovery();
      },
      HA_SETUP_PAGE: receivePage,
      HA_MIGRATION_RESULT: migrationResult,
      HA_SETUP_RESULT: function (data) {
        if (!pending || data.request !== pending.request) return;
        clearTimeout(pending.timer);
        var focus = pending.output === "setup-message" && document.activeElement === el(pending.output);
        var result = data.error || data.message || (pending.action === "timing_reset" ? "Timing samples cleared." : "");
        if (pending.feedback && data.error) {
          feedbackError = state.feedback_retry === true;
          if (state.status === "Device connected") result = "";
        }
        message(pending.output, result);
        if (pending.timing) {
          var report = typeof data.report === "string" ? data.report : data.report && JSON.stringify(data.report, null, 2);
          message("timing-output", report);
        }
        var finished = pending;
        pending = null;
        if (finished.indicator) previousIndicators = null;
        renderState();
        restoreIndicatorFocus(finished);
        if (focus) {
          if (state.retry) el("retry").focus();
          else focusRecovery();
        }
      },
    },
    onConnect: function () {
      readState(true);
    },
  });
})();
