// FILE: voice-handler.js
// Purpose: Exposes bridge-managed config for Bailian realtime dictation.
// Layer: Bridge helper
// Exports: resolveRealtimeVoiceConfig
// Depends on: process.env

const DEFAULT_BAILIAN_REALTIME_URL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime";
const DEFAULT_BAILIAN_REALTIME_MODEL = "qwen3-asr-flash-realtime";
const DEFAULT_BAILIAN_REALTIME_LANGUAGE = "zh";
const DEFAULT_BAILIAN_VAD_SILENCE_DURATION_MS = 400;
const DEFAULT_BAILIAN_VAD_THRESHOLD = 0.5;

function resolveRealtimeVoiceConfig() {
  const apiKey = firstNonEmptyString([
    process.env.REMODEX_BAILIAN_REALTIME_API_KEY,
    process.env.REMODEX_DASHSCOPE_API_KEY,
    process.env.DASHSCOPE_API_KEY,
  ]);
  if (!apiKey) {
    throw voiceError(
      "realtime_config_missing",
      "Configure DASHSCOPE_API_KEY on the paired Mac before using Bailian realtime dictation."
    );
  }

  const websocketURL = firstNonEmptyString([
    process.env.REMODEX_BAILIAN_REALTIME_URL,
    process.env.REMODEX_DASHSCOPE_REALTIME_URL,
    process.env.DASHSCOPE_REALTIME_URL,
    DEFAULT_BAILIAN_REALTIME_URL,
  ]);
  const model = firstNonEmptyString([
    process.env.REMODEX_BAILIAN_REALTIME_MODEL,
    process.env.REMODEX_DASHSCOPE_REALTIME_MODEL,
    DEFAULT_BAILIAN_REALTIME_MODEL,
  ]);
  const language = firstNonEmptyString([
    process.env.REMODEX_BAILIAN_REALTIME_LANGUAGE,
    process.env.REMODEX_DASHSCOPE_REALTIME_LANGUAGE,
    DEFAULT_BAILIAN_REALTIME_LANGUAGE,
  ]);
  const vadSilenceDurationMs = readPositiveIntegerEnv(
    "REMODEX_BAILIAN_REALTIME_VAD_SILENCE_MS",
    DEFAULT_BAILIAN_VAD_SILENCE_DURATION_MS
  );
  const vadThreshold = readPositiveNumber(
    firstNonEmptyString([
      process.env.REMODEX_BAILIAN_REALTIME_VAD_THRESHOLD,
      `${DEFAULT_BAILIAN_VAD_THRESHOLD}`,
    ])
  ) || DEFAULT_BAILIAN_VAD_THRESHOLD;

  return {
    provider: "bailian_realtime",
    websocketURL,
    apiKey,
    model,
    language,
    inputSampleRateHz: 16_000,
    inputEncoding: "pcm16",
    vadSilenceDurationMs,
    vadThreshold,
  };
}

function firstNonEmptyString(values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }

  return "";
}

function readPositiveIntegerEnv(name, fallback) {
  const parsed = Number.parseInt(process.env[name] || "", 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function readPositiveNumber(value) {
  const numericValue = typeof value === "number" ? value : Number(value);
  return Number.isFinite(numericValue) && numericValue >= 0 ? numericValue : 0;
}

function voiceError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  return error;
}

module.exports = {
  resolveRealtimeVoiceConfig,
};
