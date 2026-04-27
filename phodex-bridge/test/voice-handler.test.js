// FILE: voice-handler.test.js
// Purpose: Verifies bridge-managed Bailian realtime voice config resolution.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/voice-handler

const test = require("node:test");
const assert = require("node:assert/strict");

const { resolveRealtimeVoiceConfig } = require("../src/voice-handler");

test("resolveRealtimeVoiceConfig returns Bailian realtime defaults when DASHSCOPE_API_KEY is present", () => {
  withEnv({
    REMODEX_BAILIAN_REALTIME_API_KEY: "",
    REMODEX_DASHSCOPE_API_KEY: "",
    DASHSCOPE_API_KEY: "dashscope-test-key",
    REMODEX_BAILIAN_REALTIME_URL: "",
    REMODEX_DASHSCOPE_REALTIME_URL: "",
    DASHSCOPE_REALTIME_URL: "",
    REMODEX_BAILIAN_REALTIME_MODEL: "",
    REMODEX_DASHSCOPE_REALTIME_MODEL: "",
    REMODEX_BAILIAN_REALTIME_LANGUAGE: "",
    REMODEX_DASHSCOPE_REALTIME_LANGUAGE: "",
    REMODEX_BAILIAN_REALTIME_VAD_SILENCE_MS: "",
    REMODEX_BAILIAN_REALTIME_VAD_THRESHOLD: "",
  }, () => {
    const config = resolveRealtimeVoiceConfig();

    assert.deepEqual(config, {
      provider: "bailian_realtime",
      websocketURL: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
      apiKey: "dashscope-test-key",
      model: "qwen3-asr-flash-realtime",
      language: "zh",
      inputSampleRateHz: 16_000,
      inputEncoding: "pcm16",
      vadSilenceDurationMs: 400,
      vadThreshold: 0.5,
    });
  });
});

test("resolveRealtimeVoiceConfig prefers Remodex-specific overrides", () => {
  withEnv({
    DASHSCOPE_API_KEY: "fallback-key",
    REMODEX_DASHSCOPE_API_KEY: "preferred-key",
    REMODEX_BAILIAN_REALTIME_URL: "wss://example.com/realtime",
    REMODEX_BAILIAN_REALTIME_MODEL: "custom-realtime-model",
    REMODEX_BAILIAN_REALTIME_LANGUAGE: "en",
    REMODEX_BAILIAN_REALTIME_VAD_SILENCE_MS: "650",
    REMODEX_BAILIAN_REALTIME_VAD_THRESHOLD: "0.72",
  }, () => {
    const config = resolveRealtimeVoiceConfig();

    assert.equal(config.apiKey, "preferred-key");
    assert.equal(config.websocketURL, "wss://example.com/realtime");
    assert.equal(config.model, "custom-realtime-model");
    assert.equal(config.language, "en");
    assert.equal(config.vadSilenceDurationMs, 650);
    assert.equal(config.vadThreshold, 0.72);
  });
});

test("resolveRealtimeVoiceConfig throws a realtime_config_missing error when no DASHSCOPE key is configured", () => {
  withEnv({
    REMODEX_BAILIAN_REALTIME_API_KEY: "",
    REMODEX_DASHSCOPE_API_KEY: "",
    DASHSCOPE_API_KEY: "",
  }, () => {
    assert.throws(
      () => resolveRealtimeVoiceConfig(),
      (error) => error?.errorCode === "realtime_config_missing"
        && /DASHSCOPE_API_KEY/i.test(error.message)
    );
  });
});

function withEnv(overrides, fn) {
  const previousValues = new Map();
  try {
    for (const [key, value] of Object.entries(overrides)) {
      previousValues.set(key, process.env[key]);
      if (value === "") {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
    fn();
  } finally {
    for (const [key, value] of previousValues.entries()) {
      if (value == null) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
  }
}
