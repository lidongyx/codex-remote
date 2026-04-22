// FILE: voice-handler.js
// Purpose: Handles bridge-owned voice transcription requests without exposing auth tokens to iPhone.
// Layer: Bridge handler
// Exports: createVoiceHandler
// Depends on: global fetch/FormData/Blob, local codex app-server auth via sendCodexRequest

const fs = require("fs");
const os = require("os");
const path = require("path");

const CHATGPT_TRANSCRIPTIONS_URL = "https://chatgpt.com/backend-api/transcribe";
const DEFAULT_OPENAI_TRANSCRIPTIONS_BASE_URL = "https://api.openai.com/v1";
const DEFAULT_API_TRANSCRIPTION_MODELS = Object.freeze([
  "gpt-4o-transcribe",
  "gpt-4o-mini-transcribe",
  "whisper-1",
]);
const MAX_AUDIO_BYTES = 10 * 1024 * 1024;
const MAX_DURATION_MS = 120_000;

function createVoiceHandler({
  sendCodexRequest,
  fetchImpl = globalThis.fetch,
  FormDataImpl = globalThis.FormData,
  BlobImpl = globalThis.Blob,
  logPrefix = "[remodex]",
} = {}) {
  function handleVoiceRequest(rawMessage, sendResponse) {
    let parsed;
    try {
      parsed = JSON.parse(rawMessage);
    } catch {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method !== "voice/transcribe") {
      return false;
    }

    const id = parsed.id;
    const params = parsed.params || {};

    transcribeVoice(params, {
      sendCodexRequest,
      fetchImpl,
      FormDataImpl,
      BlobImpl,
    })
      .then((result) => {
        sendResponse(JSON.stringify({ id, result }));
      })
      .catch((error) => {
        console.error(`${logPrefix} voice transcription failed: ${error.message}`);
        sendResponse(JSON.stringify({
          id,
          error: {
            code: -32000,
            message: error.userMessage || error.message || "Voice transcription failed.",
            data: {
              errorCode: error.errorCode || "voice_transcription_failed",
            },
          },
        }));
      });

    return true;
  }

  return {
    handleVoiceRequest,
  };
}

// ─── Audio validation helpers ───────────────────────────────

// Validates iPhone-owned audio input and proxies it to the official transcription endpoint.
async function transcribeVoice(
  params,
  { sendCodexRequest, fetchImpl, FormDataImpl, BlobImpl }
) {
  if (typeof sendCodexRequest !== "function") {
    throw voiceError("bridge_not_ready", "Voice transcription is not available right now.");
  }
  if (typeof fetchImpl !== "function" || !FormDataImpl || !BlobImpl) {
    throw voiceError("transcription_unavailable", "Voice transcription is unavailable on this bridge.");
  }

  const mimeType = readString(params.mimeType);
  if (mimeType !== "audio/wav") {
    throw voiceError("unsupported_mime_type", "Only WAV audio is supported for voice transcription.");
  }

  const sampleRateHz = readPositiveNumber(params.sampleRateHz);
  if (sampleRateHz !== 24_000) {
    throw voiceError("unsupported_sample_rate", "Voice transcription requires 24 kHz mono WAV audio.");
  }

  const durationMs = readPositiveNumber(params.durationMs);
  if (durationMs <= 0) {
    throw voiceError("invalid_duration", "Voice messages must include a positive duration.");
  }
  if (durationMs > MAX_DURATION_MS) {
    throw voiceError("duration_too_long", "Voice messages are limited to 120 seconds.");
  }

  const audioBuffer = decodeAudioBase64(params.audioBase64);
  if (audioBuffer.length > MAX_AUDIO_BYTES) {
    throw voiceError("audio_too_large", "Voice messages are limited to 10 MB.");
  }

  const authContext = await loadAuthContext(sendCodexRequest);
  return requestTranscription({
    authContext,
    audioBuffer,
    mimeType,
    fetchImpl,
    FormDataImpl,
    BlobImpl,
    sendCodexRequest,
  });
}

async function requestTranscription({
  authContext,
  audioBuffer,
  mimeType,
  fetchImpl,
  FormDataImpl,
  BlobImpl,
  sendCodexRequest,
}) {
  if (authContext.kind === "api") {
    return requestAPITranscription({
      authContext,
      audioBuffer,
      mimeType,
      fetchImpl,
      FormDataImpl,
      BlobImpl,
      sendCodexRequest,
    });
  }

  const makeAttempt = async (activeAuthContext) => {
    const formData = new FormDataImpl();
    formData.append("file", new BlobImpl([audioBuffer], { type: mimeType }), "voice.wav");

    const headers = {
      Authorization: `Bearer ${activeAuthContext.token}`,
    };

    return fetchImpl(activeAuthContext.transcriptionURL, {
      method: "POST",
      headers,
      body: formData,
    });
  };

  let response = await makeAttempt(authContext);
  if (response.status === 401) {
    const refreshedAuthContext = await loadAuthContext(sendCodexRequest);
    response = await makeAttempt(refreshedAuthContext);
  }

  if (!response.ok) {
    let errorMessage = `Transcription failed with status ${response.status}.`;
    try {
      const errorPayload = await response.json();
      const providerMessage = readString(errorPayload?.error?.message) || readString(errorPayload?.message);
      if (providerMessage) {
        errorMessage = providerMessage;
      }
    } catch {
      // Keep the generic message when the provider body is empty or non-JSON.
    }

    if (response.status === 401 || response.status === 403) {
      throw voiceError("not_authenticated", "Your ChatGPT login has expired. Sign in again.");
    }

    throw voiceError("transcription_failed", errorMessage);
  }

  const payload = await response.json().catch(() => null);
  const text = readString(payload?.text) || readString(payload?.transcript);
  if (!text) {
    throw voiceError("transcription_invalid_response", "The transcription response did not include any text.");
  }

  return { text };
}

async function requestAPITranscription({
  authContext,
  audioBuffer,
  mimeType,
  fetchImpl,
  FormDataImpl,
  BlobImpl,
  sendCodexRequest,
}) {
  let activeAuthContext = authContext;
  let hasRetriedAuth = false;

  for (const model of activeAuthContext.models) {
    let response = await makeAPIAttempt({
      authContext: activeAuthContext,
      model,
      audioBuffer,
      mimeType,
      fetchImpl,
      FormDataImpl,
      BlobImpl,
    });

    if ((response.status === 401 || response.status === 403) && !hasRetriedAuth) {
      activeAuthContext = await loadAuthContext(sendCodexRequest);
      hasRetriedAuth = true;

      if (activeAuthContext.kind !== "api") {
        return requestTranscription({
          authContext: activeAuthContext,
          audioBuffer,
          mimeType,
          fetchImpl,
          FormDataImpl,
          BlobImpl,
          sendCodexRequest,
        });
      }

      response = await makeAPIAttempt({
        authContext: activeAuthContext,
        model,
        audioBuffer,
        mimeType,
        fetchImpl,
        FormDataImpl,
        BlobImpl,
      });
    }

    if (response.ok) {
      const payload = await response.json().catch(() => null);
      const text = readString(payload?.text) || readString(payload?.transcript);
      if (!text) {
        throw voiceError("transcription_invalid_response", "The transcription response did not include any text.");
      }
      return { text };
    }

    const errorMessage = await readProviderErrorMessage(response);
    if (response.status === 401 || response.status === 403) {
      throw voiceError("not_authenticated", "Your API-based voice authentication on the Mac is no longer valid. Refresh it and try again.");
    }

    if (shouldRetryAPIAudioModel(response.status, errorMessage)) {
      continue;
    }

    throw voiceError("transcription_failed", errorMessage);
  }

  throw voiceError(
    "api_transcription_unavailable",
    "The configured API provider does not support the speech-to-text models Remodex tried. Set REMODEX_VOICE_TRANSCRIPTION_MODEL on your Mac if you need a specific OpenAI-compatible model."
  );
}

async function makeAPIAttempt({
  authContext,
  model,
  audioBuffer,
  mimeType,
  fetchImpl,
  FormDataImpl,
  BlobImpl,
}) {
  const formData = new FormDataImpl();
  formData.append("file", new BlobImpl([audioBuffer], { type: mimeType }), "voice.wav");
  formData.append("model", model);

  return fetchImpl(authContext.transcriptionURL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${authContext.token}`,
    },
    body: formData,
  });
}

async function readProviderErrorMessage(response) {
  let errorMessage = `Transcription failed with status ${response.status}.`;

  try {
    const errorPayload = await response.json();
    const providerMessage = firstNonEmptyString([
      errorPayload?.error?.message,
      errorPayload?.message,
      errorPayload?.detail,
    ]);
    if (providerMessage) {
      errorMessage = providerMessage;
    }
  } catch {
    // Keep the generic message when the provider body is empty or non-JSON.
  }

  return errorMessage;
}

function shouldRetryAPIAudioModel(statusCode, errorMessage) {
  if (statusCode !== 400 && statusCode !== 422) {
    return false;
  }

  const normalized = String(errorMessage || "").toLowerCase();
  return normalized.includes("model")
    && (
      normalized.includes("unsupported")
      || normalized.includes("not found")
      || normalized.includes("does not exist")
      || normalized.includes("unknown")
      || normalized.includes("invalid")
    );
}

// Reads the current bridge-owned auth state from the local codex app-server and refreshes if needed.
async function loadAuthContext(sendCodexRequest) {
  const authStatus = await sendCodexRequest("getAuthStatus", {
    includeToken: true,
    refreshToken: true,
  });

  const authMethod = readString(authStatus?.authMethod);
  const token = readString(authStatus?.authToken);
  const isChatGPT = authMethod === "chatgpt" || authMethod === "chatgptAuthTokens";

  if (!token) {
    throw voiceError(
      "not_authenticated",
      "Set up ChatGPT or a compatible API provider on the Mac before using voice transcription."
    );
  }
  if (!isChatGPT) {
    return {
      kind: "api",
      authMethod: authMethod || "apiKey",
      token,
      transcriptionURL: resolveConfiguredAPIAudioTranscriptionsURL(authStatus),
      models: resolveConfiguredAPIAudioModels(),
    };
  }

  return {
    kind: "chatgpt",
    authMethod,
    token,
    isChatGPT,
    transcriptionURL: CHATGPT_TRANSCRIPTIONS_URL,
    chatgptAccountId: readChatGPTAccountIdFromToken(token),
  };
}

function decodeAudioBase64(value) {
  const normalized = normalizeBase64(value);
  if (!normalized) {
    throw voiceError("missing_audio", "The voice request did not include any audio.");
  }

  if (!isLikelyBase64(normalized)) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  const audioBuffer = Buffer.from(normalized, "base64");
  if (!audioBuffer.length) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  if (audioBuffer.toString("base64") !== normalized) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  if (!isLikelyWavBuffer(audioBuffer)) {
    throw voiceError("invalid_audio", "The recorded audio is not a valid WAV file.");
  }

  return audioBuffer;
}

// Keeps the bridge strict about the payload shape so malformed uploads fail before fetch().
function normalizeBase64(value) {
  return typeof value === "string" ? value.replace(/\s+/g, "").trim() : "";
}

function isLikelyBase64(value) {
  return /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value);
}

function isLikelyWavBuffer(buffer) {
  return buffer.length >= 44
    && buffer.toString("ascii", 0, 4) === "RIFF"
    && buffer.toString("ascii", 8, 12) === "WAVE";
}

function readChatGPTAccountIdFromToken(token) {
  const payload = decodeJWTPayload(token);
  const authClaim = payload?.["https://api.openai.com/auth"];
  return readString(
    authClaim?.chatgpt_account_id
      || authClaim?.chatgptAccountId
      || payload?.chatgpt_account_id
      || payload?.chatgptAccountId
  );
}

function decodeJWTPayload(token) {
  const segments = typeof token === "string" ? token.split(".") : [];
  if (segments.length < 2) {
    return null;
  }

  const normalized = segments[1]
    .replace(/-/g, "+")
    .replace(/_/g, "/")
    .padEnd(Math.ceil(segments[1].length / 4) * 4, "=");

  try {
    return JSON.parse(Buffer.from(normalized, "base64").toString("utf8"));
  } catch {
    return null;
  }
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
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

// Returns an ephemeral ChatGPT token so the phone can call the transcription API directly.
// Uses its own token resolution instead of loadAuthContext so errors are specific and actionable.
async function resolveVoiceAuth(sendCodexRequest) {
  let authStatus;
  try {
    authStatus = await sendCodexRequest("getAuthStatus", {
      includeToken: true,
      refreshToken: true,
    });
  } catch (err) {
    console.error(`[remodex] voice/resolveAuth: getAuthStatus RPC failed: ${err.message}`);
    throw voiceError("auth_unavailable", "Could not read ChatGPT session from the Mac runtime. Is the bridge running?");
  }

  const authMethod = readString(authStatus?.authMethod);
  const token = readString(authStatus?.authToken);
  const isChatGPT = authMethod === "chatgpt" || authMethod === "chatgptAuthTokens";

  if (isChatGPT && token) {
    return { token };
  }

  if (!token) {
    console.error(`[remodex] voice/resolveAuth: no token. authMethod=${authMethod || "none"} requiresOpenaiAuth=${authStatus?.requiresOpenaiAuth}`);
    throw voiceError("token_missing", "No ChatGPT session token available. Sign in to ChatGPT on the Mac.");
  }

  throw voiceError(
    "not_chatgpt",
    "This iPhone version expects a ChatGPT session for direct voice upload. Update Remodex on your iPhone to use bridge-based voice transcription with API providers."
  );
}

function resolveConfiguredAPIAudioTranscriptionsURL(authStatus) {
  const explicitBaseUrl = firstNonEmptyString([
    authStatus?.transcriptionUrl,
    authStatus?.transcriptionURL,
    authStatus?.audioTranscriptionsUrl,
    authStatus?.audioTranscriptionsURL,
  ]);
  if (explicitBaseUrl) {
    return explicitBaseUrl;
  }

  const configuredBaseUrl = firstNonEmptyString([
    authStatus?.baseUrl,
    authStatus?.baseURL,
    authStatus?.apiBaseUrl,
    authStatus?.apiBaseURL,
    authStatus?.providerBaseUrl,
    authStatus?.provider_base_url,
    resolveConfiguredOpenAIBaseUrl(authStatus),
    DEFAULT_OPENAI_TRANSCRIPTIONS_BASE_URL,
  ]);

  return joinURLPath(configuredBaseUrl, "audio/transcriptions");
}

function resolveConfiguredAPIAudioModels() {
  return uniqueStrings([
    process.env.REMODEX_VOICE_TRANSCRIPTION_MODEL,
    ...DEFAULT_API_TRANSCRIPTION_MODELS,
  ]);
}

function resolveConfiguredOpenAIBaseUrl(authStatus) {
  const envBaseUrl = firstNonEmptyString([
    process.env.OPENAI_BASE_URL,
    process.env.OPENAI_API_BASE_URL,
    process.env.OPENAI_API_BASE,
    process.env.CODEX_OPENAI_BASE_URL,
  ]);
  if (envBaseUrl) {
    return envBaseUrl;
  }

  const providerName = firstNonEmptyString([
    authStatus?.modelProvider,
    authStatus?.model_provider,
    authStatus?.providerName,
    authStatus?.provider_name,
  ]);
  const config = readCodexConfigToml();
  if (!config) {
    return "";
  }

  const activeProviderName = providerName || config.modelProvider;
  if (!activeProviderName) {
    return "";
  }

  return firstNonEmptyString([
    config.modelProviders[activeProviderName]?.baseUrl,
    config.modelProviders[activeProviderName]?.base_url,
  ]);
}

function readCodexConfigToml() {
  const configPath = process.env.REMODEX_CODEX_CONFIG_PATH
    || path.join(os.homedir(), ".codex", "config.toml");

  let rawConfig;
  try {
    rawConfig = fs.readFileSync(configPath, "utf8");
  } catch {
    return null;
  }

  const parsed = {
    modelProvider: "",
    modelProviders: {},
  };
  let currentSection = "";

  for (const rawLine of rawConfig.split(/\r?\n/)) {
    const line = stripTomlComment(rawLine).trim();
    if (!line) {
      continue;
    }

    const sectionMatch = line.match(/^\[(.+)\]$/);
    if (sectionMatch) {
      currentSection = sectionMatch[1].trim();
      continue;
    }

    const keyValueMatch = line.match(/^([A-Za-z0-9_.-]+)\s*=\s*(.+)$/);
    if (!keyValueMatch) {
      continue;
    }

    const key = keyValueMatch[1];
    const value = parseTomlScalar(keyValueMatch[2]);
    if (!currentSection && key === "model_provider") {
      parsed.modelProvider = readString(value) || "";
      continue;
    }

    const providerSectionMatch = currentSection.match(/^model_providers\.(.+)$/);
    if (!providerSectionMatch) {
      continue;
    }

    const providerName = providerSectionMatch[1].replace(/^\"(.*)\"$/, "$1");
    if (!providerName) {
      continue;
    }

    if (!parsed.modelProviders[providerName]) {
      parsed.modelProviders[providerName] = {};
    }
    parsed.modelProviders[providerName][key] = value;
  }

  return parsed;
}

function stripTomlComment(line) {
  let quote = null;
  let escaped = false;

  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (quote) {
      if (character === "\\" && !escaped) {
        escaped = true;
        continue;
      }
      if (character === quote && !escaped) {
        quote = null;
      }
      escaped = false;
      continue;
    }

    if (character === "\"" || character === "'") {
      quote = character;
      continue;
    }

    if (character === "#") {
      return line.slice(0, index);
    }
  }

  return line;
}

function parseTomlScalar(rawValue) {
  const value = rawValue.trim();
  if (!value) {
    return "";
  }

  if ((value.startsWith("\"") && value.endsWith("\""))
    || (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1);
  }

  if (value === "true") {
    return true;
  }

  if (value === "false") {
    return false;
  }

  return value;
}

function joinURLPath(baseUrl, suffix) {
  const normalizedBaseUrl = ensureTrailingSlash(baseUrl);
  try {
    return new URL(suffix.replace(/^\/+/, ""), normalizedBaseUrl).toString();
  } catch {
    return `${normalizedBaseUrl.replace(/\/+$/, "")}/${suffix.replace(/^\/+/, "")}`;
  }
}

function ensureTrailingSlash(value) {
  const normalized = String(value || "").trim();
  if (!normalized) {
    return `${DEFAULT_OPENAI_TRANSCRIPTIONS_BASE_URL}/`;
  }

  return normalized.endsWith("/") ? normalized : `${normalized}/`;
}

function firstNonEmptyString(values) {
  for (const value of values) {
    const normalized = readString(value);
    if (normalized) {
      return normalized;
    }
  }

  return "";
}

function uniqueStrings(values) {
  const unique = [];
  for (const value of values) {
    const normalized = readString(value);
    if (normalized && !unique.includes(normalized)) {
      unique.push(normalized);
    }
  }
  return unique;
}

module.exports = {
  createVoiceHandler,
  resolveVoiceAuth,
};
