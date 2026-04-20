#!/usr/bin/env node
// FILE: remodex-local.js
// Purpose: Repo-local wrapper for the in-tree bridge CLI so developers do not need a global remodex install.
// Layer: Root tooling
// Exports: none
// Depends on: child_process, fs, path

const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const bridgeCliPath = path.join(repoRoot, "phodex-bridge", "bin", "remodex.js");

if (!fs.existsSync(bridgeCliPath)) {
  console.error(`[codex-remote] Missing bridge CLI at ${bridgeCliPath}`);
  process.exit(1);
}

const args = process.argv.slice(2);
const child = spawnSync(process.execPath, [bridgeCliPath, ...args], {
  cwd: repoRoot,
  env: process.env,
  stdio: "inherit",
});

if (child.error) {
  console.error(`[codex-remote] Failed to launch repo-local bridge CLI: ${child.error.message}`);
  process.exit(1);
}

if (typeof child.status === "number") {
  process.exit(child.status);
}

process.exit(1);
