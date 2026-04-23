// FILE: desktop-handler.js
// Purpose: Handles explicit desktop handoff, display wake, and bridge preference RPCs for Codex.app.
// Layer: Bridge handler
// Exports: handleDesktopRequest
// Depends on: child_process, fs, os, path, ./rollout-watch

const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { promisify } = require("util");
const { findRolloutFileForThread, resolveSessionsRoot } = require("./rollout-watch");

const execFileAsync = promisify(execFile);
const DEFAULT_BUNDLE_ID = "com.openai.codex";
const DEFAULT_APP_PATH = "/Applications/Codex.app";
const DEFAULT_PLATFORM = process.platform;
const HANDOFF_TIMEOUT_MS = 20_000;
const DEFAULT_RELAUNCH_WAIT_MS = 300;
const DEFAULT_APP_BOOT_WAIT_MS = 1_200;
const DEFAULT_THREAD_MATERIALIZE_WAIT_MS = 4_000;
const DEFAULT_THREAD_MATERIALIZE_POLL_MS = 250;
const DEFAULT_WAKE_DISPLAY_DURATION_SECONDS = 30;

function handleDesktopRequest(rawMessage, sendResponse, options = {}) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (!method.startsWith("desktop/")) {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};

  handleDesktopMethod(method, params, options)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "desktop_error";
      const message = err.userMessage || err.message || "Unknown desktop handoff error";
      sendResponse(JSON.stringify({
        id,
        error: {
          code: -32000,
          message,
          data: { errorCode },
        },
      }));
    });

  return true;
}

async function handleDesktopMethod(method, params, options = {}) {
  const platform = options.platform || DEFAULT_PLATFORM;
  const bundleId = options.bundleId || DEFAULT_BUNDLE_ID;
  const appPath = options.appPath || DEFAULT_APP_PATH;
  const executor = options.executor || execFileAsync;
  const env = options.env || process.env;
  const fsModule = options.fsModule || fs;
  const osModule = options.osModule || os;
  const isAppRunning = options.isAppRunning || null;
  const sleepFn = options.sleepFn || sleep;
  const appBootWaitMs = options.appBootWaitMs ?? DEFAULT_APP_BOOT_WAIT_MS;
  const relaunchWaitMs = options.relaunchWaitMs ?? DEFAULT_RELAUNCH_WAIT_MS;
  const threadMaterializeWaitMs = options.threadMaterializeWaitMs ?? DEFAULT_THREAD_MATERIALIZE_WAIT_MS;
  const threadMaterializePollMs = options.threadMaterializePollMs ?? DEFAULT_THREAD_MATERIALIZE_POLL_MS;

  if (platform !== "darwin") {
    throw desktopError(
      "unsupported_platform",
      "Mac handoff is only available when the bridge is running on macOS."
    );
  }

  switch (method) {
    case "desktop/continueOnMac":
      return continueOnMac(params, {
        bundleId,
        appPath,
        executor,
        env,
        fsModule,
        isAppRunning,
        sleepFn,
        appBootWaitMs,
        relaunchWaitMs,
        threadMaterializeWaitMs,
        threadMaterializePollMs,
      });
    case "desktop/wakeDisplay":
      return wakeDisplay({
        executor,
      });
    case "desktop/preferences/read":
      return readBridgePreferences(options);
    case "desktop/preferences/update":
      return updateBridgePreferences(params, options);
    case "desktop/filesystem/listDirectory":
      return listLocalDirectory(params, { fsModule, osModule });
    default:
      throw desktopError("unknown_method", `Unknown desktop method: ${method}`);
  }
}

function listLocalDirectory(params, { fsModule, osModule }) {
  const directoryPath = resolveDirectoryPath(params, { fsModule, osModule });
  const children = readChildDirectories(directoryPath, { fsModule });

  return {
    directory: buildDirectoryDescriptor(directoryPath, { fsModule, osModule }),
    parentDirectory: buildParentDirectoryDescriptor(directoryPath, { fsModule, osModule }),
    children,
  };
}

// Waits for fresh phone-authored chats to materialize locally before deep-linking them on Mac.
async function continueOnMac(
  params,
  {
    bundleId,
    appPath,
    executor,
    env,
    fsModule,
    isAppRunning,
    sleepFn,
    appBootWaitMs,
    relaunchWaitMs,
    threadMaterializeWaitMs,
    threadMaterializePollMs,
  }
) {
  const threadId = resolveThreadId(params);
  if (!threadId) {
    throw desktopError("missing_thread_id", "A thread id is required to continue on Mac.");
  }

  const targetUrl = `codex://threads/${threadId}`;
  const desktopKnown = isThreadLikelyKnownOnDesktop(threadId, { env, fsModule });
  const appRunning = typeof isAppRunning === "function"
    ? await isAppRunning(appPath)
    : await detectRunningCodexApp(appPath, executor);

  // If Codex.app is already open, explicit handoff should still feel like a
  // real device switch: close, reopen, then focus the requested thread.
  if (desktopKnown && !appRunning) {
    try {
      // Cold-launch the desktop app first, then deep-link the thread once the
      // router is ready. A single `open codex://threads/...` can land on the
      // default new-chat route when Codex.app is not fully booted yet.
      await openCodexApp({ bundleId, appPath, executor });
      await sleepFn(appBootWaitMs);
      await openWhenThreadReady(threadId, targetUrl, {
        bundleId,
        appPath,
        executor,
        env,
        fsModule,
        sleepFn,
        waitMs: threadMaterializeWaitMs,
        pollMs: threadMaterializePollMs,
      });
    } catch (error) {
      throw desktopError(
        "handoff_failed",
        "Could not open Codex.app on this Mac.",
        error
      );
    }

    return {
      success: true,
      relaunched: false,
      targetUrl,
      threadId,
      desktopKnown,
    };
  }

  // Brand-new phone-authored threads still need a short boot/materialization
  // window before the final deep link is likely to work.
  if (!appRunning) {
    try {
      await openCodexApp({ bundleId, appPath, executor });
      await sleepFn(appBootWaitMs);
      await openWhenThreadReady(threadId, targetUrl, {
        bundleId,
        appPath,
        executor,
        env,
        fsModule,
        sleepFn,
        waitMs: threadMaterializeWaitMs,
        pollMs: threadMaterializePollMs,
      });
    } catch (error) {
      throw desktopError(
        "handoff_failed",
        "Could not open Codex.app on this Mac.",
        error
      );
    }

    return {
      success: true,
      relaunched: false,
      targetUrl,
      threadId,
      desktopKnown,
    };
  }

  try {
    await forceRelaunchCodexApp({
      bundleId,
      appPath,
      executor,
      isAppRunning,
      sleepFn,
      relaunchWaitMs,
      appBootWaitMs,
    });
    await openWhenThreadReady(threadId, targetUrl, {
      bundleId,
      appPath,
      executor,
      env,
      fsModule,
      sleepFn,
      waitMs: threadMaterializeWaitMs,
      pollMs: threadMaterializePollMs,
    });
  } catch (error) {
    throw desktopError(
      "handoff_failed",
      "Could not force close and reopen Codex.app on this Mac.",
      error
    );
  }

  return {
    success: true,
    relaunched: true,
    targetUrl,
    threadId,
    desktopKnown,
  };
}

// Sends a stronger display wake pulse: mark user activity and hold the display awake briefly
// so a sleeping panel has time to relight before the Mac drifts back into idle display sleep.
async function wakeDisplay({ executor }) {
  try {
    await executor("/usr/bin/caffeinate", ["-d", "-u", "-t", String(DEFAULT_WAKE_DISPLAY_DURATION_SECONDS)], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  } catch (error) {
    throw desktopError(
      "wake_display_failed",
      "Could not wake your Mac display right now.",
      error
    );
  }

  return {
    success: true,
    durationSeconds: DEFAULT_WAKE_DISPLAY_DURATION_SECONDS,
  };
}

function readBridgePreferences(options = {}) {
  if (typeof options.readBridgePreferences !== "function") {
    throw desktopError(
      "unsupported_bridge_preferences",
      "This bridge does not support preference sync yet."
    );
  }

  return options.readBridgePreferences();
}

async function updateBridgePreferences(params, options = {}) {
  if (typeof options.updateBridgePreferences !== "function") {
    throw desktopError(
      "unsupported_bridge_preferences",
      "This bridge does not support preference sync yet."
    );
  }

  if (!params || typeof params !== "object" || typeof params.keepMacAwake !== "boolean") {
    throw desktopError(
      "invalid_bridge_preferences",
      "The bridge preference payload is invalid."
    );
  }

  return options.updateBridgePreferences({
    keepMacAwake: params.keepMacAwake,
  });
}

function resolveDirectoryPath(params, { fsModule, osModule }) {
  const requestedPath = firstNonEmptyString([
    params?.path,
    params?.directoryPath,
    params?.directory_path,
  ]);
  const defaultPath = osModule.homedir();
  const expandedPath = expandHomePath(requestedPath || defaultPath, osModule);
  const absolutePath = path.isAbsolute(expandedPath)
    ? expandedPath
    : path.resolve(defaultPath, expandedPath);
  const normalizedPath = realpathIfPossible(absolutePath, fsModule);

  if (!fsModule.existsSync(normalizedPath)) {
    throw desktopError(
      "directory_not_found",
      "That folder is not available on this Mac."
    );
  }

  if (!isDirectoryPath(normalizedPath, fsModule)) {
    throw desktopError(
      "not_a_directory",
      "The selected path is not a folder."
    );
  }

  return normalizedPath;
}

function readChildDirectories(directoryPath, { fsModule }) {
  let entries;
  try {
    entries = fsModule.readdirSync(directoryPath, { withFileTypes: true });
  } catch (error) {
    throw desktopError(
      "directory_read_failed",
      "Could not read that folder on this Mac.",
      error
    );
  }

  return entries
    .map((entry) => normalizeDirectoryEntry(entry, directoryPath, fsModule))
    .filter((entry) => entry && entry.isDirectory && !entry.isHidden)
    .map((entry) => buildDirectoryDescriptor(entry.path, { fsModule }))
    .sort(compareDirectoryDescriptors);
}

function normalizeDirectoryEntry(entry, directoryPath, fsModule) {
  if (!entry) {
    return null;
  }

  if (typeof entry === "string") {
    const entryPath = path.join(directoryPath, entry);
    return {
      name: entry,
      path: entryPath,
      isDirectory: isDirectoryPath(entryPath, fsModule),
      isHidden: entry.startsWith("."),
    };
  }

  const name = typeof entry.name === "string" ? entry.name : "";
  if (!name) {
    return null;
  }

  const entryPath = path.join(directoryPath, name);
  const isDirectory = typeof entry.isDirectory === "function"
    ? entry.isDirectory()
    : isDirectoryPath(entryPath, fsModule);

  return {
    name,
    path: entryPath,
    isDirectory,
    isHidden: name.startsWith("."),
  };
}

function buildDirectoryDescriptor(directoryPath, { fsModule, osModule } = {}) {
  const normalizedPath = realpathIfPossible(directoryPath, fsModule || fs);
  const homePath = osModule?.homedir?.() || null;
  return {
    path: normalizedPath,
    name: directoryDisplayName(normalizedPath, homePath),
    isHomeDirectory: !!homePath && samePath(normalizedPath, homePath),
    isRootDirectory: path.dirname(normalizedPath) === normalizedPath,
  };
}

function buildParentDirectoryDescriptor(directoryPath, { fsModule, osModule }) {
  const parentPath = path.dirname(directoryPath);
  if (parentPath === directoryPath) {
    return null;
  }

  return buildDirectoryDescriptor(parentPath, { fsModule, osModule });
}

function directoryDisplayName(directoryPath, homePath = null) {
  if (homePath && samePath(directoryPath, homePath)) {
    return "Home";
  }

  const baseName = path.basename(directoryPath);
  return baseName || directoryPath;
}

function compareDirectoryDescriptors(left, right) {
  if (!!left.isHidden !== !!right.isHidden) {
    return left.isHidden ? 1 : -1;
  }

  return left.name.localeCompare(right.name, undefined, {
    sensitivity: "base",
    numeric: true,
  });
}

function expandHomePath(value, osModule) {
  if (typeof value !== "string") {
    return osModule.homedir();
  }

  if (value === "~") {
    return osModule.homedir();
  }

  if (value.startsWith("~/")) {
    return path.join(osModule.homedir(), value.slice(2));
  }

  return value;
}

function realpathIfPossible(targetPath, fsModule) {
  try {
    if (typeof fsModule.realpathSync?.native === "function") {
      return fsModule.realpathSync.native(targetPath);
    }
    if (typeof fsModule.realpathSync === "function") {
      return fsModule.realpathSync(targetPath);
    }
  } catch {
    // Fall back to the requested path below; existence is checked separately.
  }

  return targetPath;
}

function isDirectoryPath(targetPath, fsModule) {
  try {
    return fsModule.statSync(targetPath).isDirectory();
  } catch {
    return false;
  }
}

function samePath(left, right) {
  if (typeof left !== "string" || typeof right !== "string") {
    return false;
  }

  return path.resolve(left) === path.resolve(right);
}

function firstNonEmptyString(values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }

  return "";
}

function resolveThreadId(params) {
  if (!params || typeof params !== "object") {
    return "";
  }

  const candidates = [
    params.threadId,
    params.thread_id,
  ];

  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim()) {
      return candidate.trim();
    }
  }

  return "";
}

function desktopError(errorCode, userMessage, cause = null) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  if (cause) {
    error.cause = cause;
  }
  return error;
}

function isThreadLikelyKnownOnDesktop(threadId, { env, fsModule }) {
  const sessionsRoot = resolveSessionsRootForEnv(env);
  // Any rollout means the thread already materialized locally, even if it originated on iPhone.
  return findRolloutFileForThread(sessionsRoot, threadId, { fsModule }) != null;
}

function resolveSessionsRootForEnv(env) {
  if (env?.CODEX_HOME) {
    return path.join(env.CODEX_HOME, "sessions");
  }

  return resolveSessionsRoot();
}

async function detectRunningCodexApp(appPath, executor) {
  const appName = path.basename(appPath, ".app");

  try {
    await executor("pgrep", ["-x", appName], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
    return true;
  } catch {
    return false;
  }
}

async function openCodexTarget(targetUrl, { bundleId, appPath, executor }) {
  try {
    await executor("open", ["-b", bundleId, targetUrl], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  } catch {
    await executor("open", ["-a", appPath, targetUrl], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  }
}

async function openCodexApp({ bundleId, appPath, executor }) {
  try {
    await executor("open", ["-b", bundleId], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  } catch {
    await executor("open", ["-a", appPath], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  }
}

// Gives the desktop a short window to materialize the requested thread before the final deep link.
async function openWhenThreadReady(
  threadId,
  targetUrl,
  { bundleId, appPath, executor, env, fsModule, sleepFn, waitMs, pollMs }
) {
  await waitForThreadMaterialization(threadId, {
    env,
    fsModule,
    sleepFn,
    timeoutMs: waitMs,
    pollMs,
  });
  await openCodexTarget(targetUrl, { bundleId, appPath, executor });
}

async function forceRelaunchCodexApp({
  bundleId,
  appPath,
  executor,
  isAppRunning,
  sleepFn,
  relaunchWaitMs,
  appBootWaitMs,
}) {
  const appName = path.basename(appPath, ".app");

  try {
    await executor("pkill", ["-x", appName], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  } catch (error) {
    if (error?.code !== 1) {
      throw error;
    }
  }

  await waitForAppExit(appPath, executor, isAppRunning);
  await sleepFn(relaunchWaitMs);
  await openCodexApp({ bundleId, appPath, executor });
  await sleepFn(appBootWaitMs);
}

async function waitForAppExit(appPath, executor, isAppRunning) {
  const deadline = Date.now() + HANDOFF_TIMEOUT_MS;

  while (Date.now() < deadline) {
    const isRunning = typeof isAppRunning === "function"
      ? await isAppRunning(appPath)
      : await detectRunningCodexApp(appPath, executor);
    if (!isRunning) {
      return;
    }

    await sleep(100);
  }

  throw desktopError("handoff_timeout", "Timed out waiting for Codex.app to close.");
}

function hasDesktopRolloutForThread(threadId, { env, fsModule }) {
  const sessionsRoot = resolveSessionsRootForEnv(env);
  return findRolloutFileForThread(sessionsRoot, threadId, { fsModule }) != null;
}

async function waitForThreadMaterialization(
  threadId,
  { env, fsModule, sleepFn, timeoutMs, pollMs }
) {
  if (hasDesktopRolloutForThread(threadId, { env, fsModule })) {
    return true;
  }

  const deadline = Date.now() + Math.max(0, timeoutMs);
  while (Date.now() < deadline) {
    await sleepFn(pollMs);
    if (hasDesktopRolloutForThread(threadId, { env, fsModule })) {
      return true;
    }
  }

  return false;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = {
  handleDesktopRequest,
};
