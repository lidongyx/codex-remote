// FILE: ios-app-compatibility.test.js
// Purpose: Verifies the bridge-side App Store iPhone compatibility policy stays conservative and explicit.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/ios-app-compatibility

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  buildCachedIOSAppCompatibilityWarning,
  buildIOSAppCompatibilitySnapshot,
  compareNumericVersions,
  shouldEnforceIOSAppCompatibility,
} = require("../src/ios-app-compatibility");

test("compareNumericVersions compares dotted versions numerically", () => {
  assert.equal(compareNumericVersions("1.3.8", "1.3.7"), 1);
  assert.equal(compareNumericVersions("1.1", "1.5"), -1);
  assert.equal(compareNumericVersions("1.5", "1.5.0"), 0);
});

test("shouldEnforceIOSAppCompatibility stays disabled for local-first bridge builds", () => {
  assert.equal(shouldEnforceIOSAppCompatibility("1.3.8"), false);
  assert.equal(shouldEnforceIOSAppCompatibility("1.3.9"), false);
  assert.equal(shouldEnforceIOSAppCompatibility("1.5.1"), false);
});

test("buildIOSAppCompatibilitySnapshot allows older iPhone app versions", () => {
  const snapshot = buildIOSAppCompatibilitySnapshot({
    bridgeVersion: "1.5.1",
    iosAppVersion: "1.3",
  });

  assert.equal(snapshot.enforcesMinimumIOSAppVersion, false);
  assert.equal(snapshot.requiresAppUpdate, false);
  assert.equal(snapshot.isCompatible, true);
  assert.equal(snapshot.message, "");
});

test("buildIOSAppCompatibilitySnapshot stays permissive when the iPhone version is unknown", () => {
  const snapshot = buildIOSAppCompatibilitySnapshot({
    bridgeVersion: "1.5.1",
    iosAppVersion: "",
  });

  assert.equal(snapshot.requiresAppUpdate, false);
  assert.equal(snapshot.isKnownIOSAppVersion, false);
});

test("buildCachedIOSAppCompatibilityWarning does not warn for cached older iPhone apps", () => {
  const warning = buildCachedIOSAppCompatibilityWarning({
    bridgeVersion: "1.5.1",
    iosAppVersion: "1.3",
  });

  assert.equal(warning, "");
});
