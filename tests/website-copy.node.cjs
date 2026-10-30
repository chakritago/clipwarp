// Offline browser Copy-button test without third-party packages.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const page = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const scripts = [...page.matchAll(/<script>([\s\S]*?)<\/script>/g)];
assert.equal(scripts.length, 1, "one executable inline webpage script");
const source = scripts[0][1];
const installCommand = "irm https://raw.githubusercontent.com/chakritago/clipwarp/main/install.ps1 | iex";

function setup(mode, lang = "en") {
  const classes = () => {
    const set = new Set();
    return {
      toggle(name, enabled) {
        if (enabled) set.add(name); else set.delete(name);
      },
      add(name) {set.add(name);},
      remove(...names) {names.forEach(name => set.delete(name));},
      contains(name) {return set.has(name);}
    };
  };
  const listeners = {};
  const elements = {
    "copyBtn": {classList: classes(), addEventListener(name, handler) { listeners[name] = handler; }},
    "copyLabel": {textContent: "", innerHTML: ""},
    "copyHelp": {hidden: true},
    "cmd": {textContent: installCommand},
    "live": {textContent: ""},
    "btn-en": {classList: classes(), setAttribute() {}},
    "btn-th": {classList: classes(), setAttribute() {}}
  };
  let copied = null, fallbackAttempts = 0, selectionApplied = false, temporaryTextArea = null, clipboardCalls = 0;
  const document = {
    documentElement: {
      attributes: {"data-lang": lang},
      setAttribute(name, val) {this.attributes[name] = val;},
      getAttribute(name) {return this.attributes[name];}
    },
    getElementById(id) {return elements[id] ?? null;},
    createElement(tag) {
      assert.equal(tag, "textarea");
      return {
        value: "", style: {}, setAttribute() {},
        focus() {}, select() {selectionApplied = true;}
      };
    },
    createRange() {
      return {selectNodeContents(node) {assert.equal(node, elements.cmd);}};
    },
    body: {
      appendChild(node) {temporaryTextArea = node;},
      removeChild(node) {assert.equal(node, temporaryTextArea);temporaryTextArea = null;}
    },
    execCommand(command) {
      assert.equal(command, "copy");
      fallbackAttempts++;
      if (mode === "fallback-fails") return false;
      copied = temporaryTextArea.value;
      return true;
    },
    querySelectorAll() {return [];}
  };
  const selection = {removeAllRanges() {}, addRange() {selectionApplied = true;}};
  const window = {getSelection() {return selection;}};
  const navigator = {language: lang};
  if (mode !== "api-missing") {
    navigator.clipboard = {
      writeText(text) {
        clipboardCalls++;
        if (mode === "api-denied" || mode === "fallback-fails") return Promise.reject(new Error("NotAllowedError"));
        if (mode === "api-throws") throw new Error("SecurityError");
        copied = text;
        return Promise.resolve();
      }
    };
  }
  const timers = [];
  const sandbox = {
    document, window, navigator, console,
    localStorage: {getItem() {return lang;}, setItem() {}},
    setTimeout(callback) {timers.push(callback);return timers.length;},
    clearTimeout() {}
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, {timeout: 3000});
  assert.equal(typeof listeners.click, "function", "Copy button must bind a click handler");
  return {
    elements, listeners, timers, sandbox,
    getCopied() {return copied;},
    getAttempts() {return fallbackAttempts;},
    getClipboardCalls() {return clipboardCalls;},
    getSelectionApplied() {return selectionApplied;},
    getTextarea() {return temporaryTextArea;}
  };
}
async function runCase(mode, shouldCopy, shouldFallback, lang = "en") {
  const app = setup(mode, lang);
  // Dispatch actual browser-style click handler and flush async clipboard promise.
  app.listeners.click();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(app.getCopied() === installCommand, shouldCopy, mode + ": copied command");
  assert.equal(app.getAttempts() > 0, shouldFallback, mode + ": legacy fallback");
  assert.equal(app.getTextarea(), null, mode + ": temporary textarea cleaned up");
  assert.equal(app.elements.copyHelp.hidden, shouldCopy, mode + ": manual guidance visibility");
  assert.equal(app.elements.copyBtn.classList.contains("done"), shouldCopy, mode + ": success indicator");
  if (!shouldCopy) {
    assert.equal(app.getSelectionApplied(), true, mode + ": command selected for Ctrl+C");
    assert.match(app.elements.live.textContent, /Ctrl\+C/);
    assert.equal(app.elements.copyBtn.classList.contains("failed"), true);
  } else {
    assert.match(app.elements.live.textContent, lang === "th" ? /คัดลอกแล้ว/ : /Copied/);
  }
  assert.equal(app.timers.length, 1, mode + ": reset timer scheduled");
}
(async () => {
  await runCase("api-success", true, false);
  await runCase("api-denied", true, true);
  await runCase("api-missing", true, true);
  await runCase("api-throws", true, true);
  await runCase("fallback-fails", false, true);
  await runCase("api-denied", true, true, "th");
  console.log("PASS: 6 webpage Copy paths, async permissions, legacy fallback, manual select, Thai status and cleanup");
})().catch(err => {console.error(err);process.exitCode = 1;});
