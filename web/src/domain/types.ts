export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

export interface JsonRpcRequest {
  jsonrpc: '2.0';
  id: number | string;
  method: string;
  params?: JsonValue;
}

export interface JsonRpcResponse {
  jsonrpc?: '2.0';
  id: number | string | null;
  result?: JsonValue;
  error?: {
    code: number;
    message: string;
    data?: JsonValue;
  };
}

export interface JsonRpcNotification {
  jsonrpc?: '2.0';
  method: string;
  params?: JsonValue;
}

export interface PairingPayload {
  v: number;
  relay: string;
  sessionId: string;
  macDeviceId: string;
  macIdentityPublicKey: string;
  expiresAt: number;
}

export interface ThreadSummary {
  id: string;
  title: string;
  cwd?: string;
  updatedAt?: string;
  archived?: boolean;
  model?: string;
  modelProvider?: string;
}

export interface ReasoningEffortOption {
  reasoningEffort: string;
  description?: string;
}

export interface ModelOption {
  id: string;
  model: string;
  displayName: string;
  description?: string;
  isDefault?: boolean;
  provider?: string;
  supportedReasoningEfforts: ReasoningEffortOption[];
  defaultReasoningEffort?: string;
}

export interface TurnImageAttachment {
  name: string;
  mimeType: string;
  dataUrl: string;
}

export interface SkillMetadata {
  name: string;
  description?: string;
  path?: string;
  scope?: string;
  enabled: boolean;
}

export interface TurnSkillMention {
  id: string;
  name?: string;
  path?: string;
}

export interface DirectoryDescriptor {
  path: string;
  name: string;
  isHomeDirectory?: boolean;
  isRootDirectory?: boolean;
}

export interface DirectoryListResult {
  directory: DirectoryDescriptor;
  parentDirectory: DirectoryDescriptor | null;
  children: DirectoryDescriptor[];
}

export type TimelineRole = 'user' | 'assistant' | 'system';
export type TimelineKind = 'chat' | 'thinking' | 'tool' | 'event' | 'error';

export interface TimelineItem {
  id: string;
  threadId: string;
  role: TimelineRole;
  kind: TimelineKind;
  text: string;
  turnId?: string;
  itemId?: string;
  streaming?: boolean;
  createdAt: number;
  sortIndex?: number;
  appendMode?: 'delta' | 'block';
}

export type ConnectionState =
  | 'idle'
  | 'connecting'
  | 'handshaking'
  | 'initializing'
  | 'connected'
  | 'reconnecting'
  | 'disconnected'
  | 'error';
