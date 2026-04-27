import type {
  ConnectionState,
  DirectoryDescriptor,
  DirectoryListResult,
  JsonRpcNotification,
  JsonRpcResponse,
  JsonValue,
  ModelOption,
  PairingPayload,
  SkillMetadata,
  TurnImageAttachment,
  TurnSkillMention,
} from '../domain/types';
import { relaySocketUrl } from './pairing';
import { SecureTransport } from './secureTransport';

type NotificationHandler = (notification: JsonRpcNotification) => void;
type StateHandler = (state: ConnectionState, detail?: string) => void;

interface TurnStartOptions {
  imageAttachments?: TurnImageAttachment[];
  model?: string;
  effort?: string;
  serviceTier?: string;
  accessMode?: 'default' | 'auto-review' | 'full-access';
  planMode?: boolean;
  skillMentions?: TurnSkillMention[];
}

export class CodexClient {
  private socket: WebSocket | null = null;
  private secure = new SecureTransport();
  private nextRequestId = 1;
  private pending = new Map<string, { resolve: (value: JsonRpcResponse) => void; reject: (error: Error) => void; timeout: number }>();
  private notificationHandlers = new Set<NotificationHandler>();
  private stateHandlers = new Set<StateHandler>();

  onNotification(handler: NotificationHandler): () => void {
    this.notificationHandlers.add(handler);
    return () => this.notificationHandlers.delete(handler);
  }

  onState(handler: StateHandler): () => void {
    this.stateHandlers.add(handler);
    return () => this.stateHandlers.delete(handler);
  }

  async connect(pairing: PairingPayload): Promise<void> {
    this.disconnect();
    this.emitState('connecting');
    const socket = new WebSocket(relaySocketUrl(pairing));
    this.socket = socket;

    await new Promise<void>((resolve, reject) => {
      const timeout = window.setTimeout(() => reject(new Error('Relay connection timed out.')), 12000);
      socket.addEventListener('open', () => {
        window.clearTimeout(timeout);
        resolve();
      }, { once: true });
      socket.addEventListener('error', () => {
        window.clearTimeout(timeout);
        reject(new Error('Could not connect to relay.'));
      }, { once: true });
    });

    this.emitState('handshaking');
    await this.secure.performHandshake(pairing, socket);
    socket.addEventListener('message', (event) => void this.handleWireMessage(String(event.data)));
    socket.addEventListener('close', () => this.emitState('disconnected'));
    this.secure.sendResumeState(socket);

    this.emitState('initializing');
    await this.initialize();
    this.emitState('connected');
  }

  disconnect(): void {
    for (const [id, pending] of this.pending) {
      window.clearTimeout(pending.timeout);
      pending.reject(new Error('Connection closed.'));
      this.pending.delete(id);
    }
    this.socket?.close();
    this.socket = null;
  }

  async request(method: string, params?: JsonValue): Promise<JsonValue> {
    const id = this.nextRequestId++;
    const response = await this.sendRpc({ jsonrpc: '2.0', id, method, params });
    if (response.error) {
      throw new Error(response.error.message || `RPC error ${response.error.code}`);
    }
    return response.result ?? null;
  }

  async notify(method: string, params?: JsonValue): Promise<void> {
    await this.sendWire(JSON.stringify({ jsonrpc: '2.0', method, params }));
  }

  async startThread(cwd?: string): Promise<JsonValue> {
    const params = cwd ? { cwd } : {};
    return this.request('thread/start', params as JsonValue);
  }

  async listThreads(archived = false): Promise<JsonValue> {
    return this.request('thread/list', {
      sourceKinds: ['cli', 'vscode', 'appServer', 'exec', 'unknown'],
      cursor: null,
      limit: archived ? 10 : 70,
      ...(archived ? { archived: true } : {}),
    } as JsonValue);
  }

  async readThread(threadId: string): Promise<JsonValue> {
    return this.request('thread/read', { threadId, includeTurns: true } as JsonValue);
  }

  async startTurn(threadId: string, input: string, options: TurnStartOptions = {}): Promise<JsonValue> {
    const baseParams = buildTurnStartParams(threadId, input, options, 'url');
    try {
      return await this.request('turn/start', baseParams as JsonValue);
    } catch (error) {
      if (options.skillMentions?.length && shouldRetryWithoutSkillItems(error)) {
        const optionsWithoutSkills = { ...options, skillMentions: [] };
        try {
          return await this.request('turn/start', buildTurnStartParams(threadId, input, optionsWithoutSkills, 'url') as JsonValue);
        } catch (retryError) {
          if (!options.imageAttachments?.length || !shouldRetryWithImageUrlField(retryError)) throw retryError;
          return this.request('turn/start', buildTurnStartParams(threadId, input, optionsWithoutSkills, 'image_url') as JsonValue);
        }
      }
      if (!options.imageAttachments?.length || !shouldRetryWithImageUrlField(error)) throw error;
      try {
        return await this.request('turn/start', buildTurnStartParams(threadId, input, options, 'image_url') as JsonValue);
      } catch (retryError) {
        if (!options.skillMentions?.length || !shouldRetryWithoutSkillItems(retryError)) throw retryError;
        return this.request('turn/start', buildTurnStartParams(threadId, input, { ...options, skillMentions: [] }, 'image_url') as JsonValue);
      }
    }
  }

  async interruptTurn(threadId: string, turnId?: string): Promise<JsonValue> {
    return this.request('turn/interrupt', {
      threadId,
      ...(turnId ? { turnId } : {}),
    } as JsonValue);
  }

  async listLocalDirectory(path?: string): Promise<DirectoryListResult> {
    const result = await this.request('desktop/filesystem/listDirectory', path ? { path } : {});
    return parseDirectoryListResult(result);
  }

  async listModels(): Promise<ModelOption[]> {
    const result = await this.request('model/list', {
      cursor: null,
      limit: 50,
      includeHidden: false,
    } as JsonValue);
    return parseModelListResult(result);
  }

  async listSkills(cwds?: string[], forceReload = false): Promise<SkillMetadata[]> {
    const normalizedCwds = (cwds ?? []).map((cwd) => cwd.trim()).filter(Boolean);
    const params = {
      ...(normalizedCwds.length ? { cwds: normalizedCwds } : {}),
      ...(forceReload ? { forceReload: true } : {}),
    };
    try {
      const result = await this.request('skills/list', params as JsonValue);
      return parseSkillListResult(result);
    } catch (error) {
      if (normalizedCwds.length !== 1 || !shouldRetrySkillsListWithCwdFallback(error)) throw error;
      const result = await this.request('skills/list', {
        cwd: normalizedCwds[0],
        ...(forceReload ? { forceReload: true } : {}),
      } as JsonValue);
      return parseSkillListResult(result);
    }
  }

  private async initialize(): Promise<void> {
    await this.request('initialize', {
      clientInfo: {
        name: 'remodex_web',
        title: 'Remodex Web',
        version: '0.1.0',
      },
      capabilities: {
        experimentalApi: true,
      },
    } as JsonValue);
    await this.notify('initialized');
  }

  private async sendRpc(message: { jsonrpc: '2.0'; id: number; method: string; params?: JsonValue }): Promise<JsonRpcResponse> {
    const id = String(message.id);
    const promise = new Promise<JsonRpcResponse>((resolve, reject) => {
      const timeout = window.setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`RPC timed out: ${message.method}`));
      }, 60000);
      this.pending.set(id, { resolve, reject, timeout });
    });
    await this.sendWire(JSON.stringify(message));
    return promise;
  }

  private async sendWire(plaintext: string): Promise<void> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw new Error('Relay socket is not connected.');
    }
    this.socket.send(await this.secure.encryptApplicationMessage(plaintext));
  }

  private async handleWireMessage(rawMessage: string): Promise<void> {
    const plaintext = await this.secure.decryptWireMessage(rawMessage);
    if (!plaintext) return;
    const message = JSON.parse(plaintext) as JsonRpcResponse | JsonRpcNotification;
    if ('id' in message && message.id != null) {
      const pending = this.pending.get(String(message.id));
      if (pending) {
        window.clearTimeout(pending.timeout);
        this.pending.delete(String(message.id));
        pending.resolve(message as JsonRpcResponse);
      }
      return;
    }
    if ('method' in message && typeof message.method === 'string') {
      for (const handler of this.notificationHandlers) {
        handler(message as JsonRpcNotification);
      }
    }
  }

  private emitState(state: ConnectionState, detail?: string): void {
    for (const handler of this.stateHandlers) {
      handler(state, detail);
    }
  }
}

function buildTurnStartParams(
  threadId: string,
  input: string,
  options: TurnStartOptions,
  imageUrlKey: 'url' | 'image_url',
): Record<string, JsonValue> {
  const inputItems: JsonValue[] = [];
  for (const attachment of options.imageAttachments ?? []) {
    if (!attachment.dataUrl.trim()) continue;
    inputItems.push({
      type: 'image',
      [imageUrlKey]: attachment.dataUrl,
    });
  }

  const trimmedInput = input.trim();
  if (trimmedInput) {
    inputItems.push({ type: 'text', text: trimmedInput });
  }

  for (const mention of options.skillMentions ?? []) {
    const normalizedId = mention.id.trim();
    if (!normalizedId) continue;
    inputItems.push({
      type: 'skill',
      id: normalizedId,
      ...(mention.name?.trim() ? { name: mention.name.trim() } : {}),
      ...(mention.path?.trim() ? { path: mention.path.trim() } : {}),
    });
  }

  const params: Record<string, JsonValue> = {
    threadId,
    input: inputItems,
  };
  if (options.model?.trim()) params.model = options.model.trim();
  if (options.effort?.trim()) params.effort = options.effort.trim();
  if (options.serviceTier?.trim()) params.serviceTier = options.serviceTier.trim();
  if (options.planMode && options.model?.trim()) {
    params.collaborationMode = {
      mode: 'plan',
      settings: {
        model: options.model.trim(),
        reasoning_effort: options.effort?.trim() || null,
        developer_instructions: null,
      },
    };
  }
  applyAccessModeParams(params, options.accessMode);
  return params;
}

function applyAccessModeParams(params: Record<string, JsonValue>, accessMode: TurnStartOptions['accessMode']) {
  if (accessMode === 'auto-review') {
    params.sandboxPolicy = {
      type: 'workspaceWrite',
      networkAccess: true,
    };
    params.approvalPolicy = 'on-request';
    return;
  }

  if (accessMode === 'full-access') {
    params.sandboxPolicy = {
      type: 'dangerFullAccess',
    };
    params.approvalPolicy = 'never';
  }
}

function shouldRetryWithImageUrlField(error: unknown): boolean {
  const message = error instanceof Error ? error.message.toLowerCase() : '';
  return message.includes('image')
    || message.includes('url')
    || message.includes('invalid param')
    || message.includes('unknown field')
    || message.includes('unexpected field')
    || message.includes('unrecognized field');
}

function shouldRetryWithoutSkillItems(error: unknown): boolean {
  const message = error instanceof Error ? error.message.toLowerCase() : '';
  return message.includes('skill')
    && (message.includes('invalid param')
      || message.includes('unknown field')
      || message.includes('unexpected field')
      || message.includes('unrecognized field')
      || message.includes('failed to parse')
      || message.includes('unsupported'));
}

function shouldRetrySkillsListWithCwdFallback(error: unknown): boolean {
  const message = error instanceof Error ? error.message.toLowerCase() : '';
  return message.includes('cwds')
    || message.includes('invalid param')
    || message.includes('unknown field')
    || message.includes('unexpected field')
    || message.includes('unrecognized field')
    || message.includes('failed to parse')
    || message.includes('unsupported');
}

function parseModelListResult(value: JsonValue): ModelOption[] {
  const object = isObject(value) ? value : {};
  const items = arrayField(object, 'items') || arrayField(object, 'data') || arrayField(object, 'models') || [];
  return items.map(parseModelOption).filter(Boolean) as ModelOption[];
}

function parseModelOption(value: JsonValue): ModelOption | null {
  if (!isObject(value)) return null;
  const model = stringField(value, 'model') || stringField(value, 'id');
  if (!model) return null;
  const id = stringField(value, 'id') || model;
  return {
    id,
    model,
    displayName: stringField(value, 'displayName') || stringField(value, 'display_name') || model,
    description: stringField(value, 'description') || undefined,
    isDefault: boolField(value, 'isDefault') ?? boolField(value, 'is_default') ?? false,
    provider: modelProviderFromValue(value) || undefined,
    supportedReasoningEfforts: parseReasoningEfforts(
      value.supportedReasoningEfforts ?? value.supported_reasoning_efforts,
    ),
    defaultReasoningEffort: stringField(value, 'defaultReasoningEffort') || stringField(value, 'default_reasoning_effort') || undefined,
  };
}

function parseReasoningEfforts(value: JsonValue | undefined) {
  if (!Array.isArray(value)) return [];
  return value.map((entry) => {
    if (typeof entry === 'string') {
      return { reasoningEffort: entry };
    }
    if (!isObject(entry)) return null;
    const effort = stringField(entry, 'reasoningEffort') || stringField(entry, 'reasoning_effort') || stringField(entry, 'id') || stringField(entry, 'value');
    if (!effort) return null;
    return {
      reasoningEffort: effort,
      description: stringField(entry, 'description') || stringField(entry, 'label') || undefined,
    };
  }).filter(Boolean) as ModelOption['supportedReasoningEfforts'];
}

function modelProviderFromValue(value: Record<string, JsonValue>): string {
  const direct = stringField(value, 'provider')
    || stringField(value, 'providerName')
    || stringField(value, 'provider_name')
    || stringField(value, 'modelProvider')
    || stringField(value, 'model_provider');
  if (direct) return direct;
  if (isObject(value.metadata)) {
    return modelProviderFromValue(value.metadata);
  }
  return '';
}

function parseSkillListResult(value: JsonValue): SkillMetadata[] {
  const object = isObject(value) ? value : {};
  const collected: SkillMetadata[] = [];
  const dataItems = arrayField(object, 'data');

  if (dataItems) {
    for (const item of dataItems) {
      if (!isObject(item)) continue;
      const skills = arrayField(item, 'skills');
      if (skills) collected.push(...skills.map(parseSkillMetadata).filter(Boolean) as SkillMetadata[]);
    }
    if (!collected.length) {
      collected.push(...dataItems.map(parseSkillMetadata).filter(Boolean) as SkillMetadata[]);
    }
  }

  const skills = arrayField(object, 'skills');
  if (skills) {
    collected.push(...skills.map(parseSkillMetadata).filter(Boolean) as SkillMetadata[]);
  }

  const deduped = new Map<string, SkillMetadata>();
  for (const skill of collected) {
    const key = skill.name.trim().toLowerCase();
    const existing = deduped.get(key);
    if (!existing || (!existing.enabled && skill.enabled)) deduped.set(key, skill);
  }

  return Array.from(deduped.values())
    .filter((skill) => skill.name.trim())
    .sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: 'base' }));
}

function parseSkillMetadata(value: JsonValue): SkillMetadata | null {
  if (!isObject(value)) return null;
  const name = stringField(value, 'name') || stringField(value, 'id');
  if (!name) return null;
  return {
    name,
    description: stringField(value, 'description') || undefined,
    path: stringField(value, 'path') || undefined,
    scope: stringField(value, 'scope') || undefined,
    enabled: boolField(value, 'enabled') ?? true,
  };
}

function parseDirectoryListResult(value: JsonValue): DirectoryListResult {
  if (!isObject(value)) throw new Error('Invalid directory response from bridge.');
  const directory = parseDirectoryDescriptor(value.directory);
  if (!directory) throw new Error('Bridge did not return a current directory.');
  const parentDirectory = parseDirectoryDescriptor(value.parentDirectory);
  const children = Array.isArray(value.children)
    ? value.children.map(parseDirectoryDescriptor).filter(Boolean) as DirectoryDescriptor[]
    : [];

  return {
    directory,
    parentDirectory,
    children,
  };
}

function parseDirectoryDescriptor(value: JsonValue | undefined): DirectoryDescriptor | null {
  if (!isObject(value)) return null;
  const path = typeof value.path === 'string' ? value.path : '';
  const name = typeof value.name === 'string' ? value.name : '';
  if (!path || !name) return null;
  return {
    path,
    name,
    isHomeDirectory: typeof value.isHomeDirectory === 'boolean' ? value.isHomeDirectory : undefined,
    isRootDirectory: typeof value.isRootDirectory === 'boolean' ? value.isRootDirectory : undefined,
  };
}

function arrayField(object: Record<string, JsonValue>, key: string): JsonValue[] | null {
  const value = object[key];
  return Array.isArray(value) ? value : null;
}

function stringField(object: Record<string, JsonValue>, key: string): string {
  const value = object[key];
  return typeof value === 'string' ? value.trim() : '';
}

function boolField(object: Record<string, JsonValue>, key: string): boolean | undefined {
  const value = object[key];
  return typeof value === 'boolean' ? value : undefined;
}

function isObject(value: JsonValue | undefined): value is Record<string, JsonValue> {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value));
}
