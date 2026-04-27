import type { JsonValue, ThreadSummary, TimelineItem } from './types';

export interface TimelineNotificationResult {
  item: TimelineItem | null;
  completedTurnId?: string;
  startedTurnId?: string;
  threadId?: string;
}

export function normalizeThread(value: JsonValue): ThreadSummary | null {
  if (!isObject(value)) return null;
  const id = stringField(value, 'id') || stringField(value, 'threadId') || stringField(value, 'thread_id');
  if (!id) return null;
  return {
    id,
    title: threadTitleFromValue(value),
    cwd: stringField(value, 'cwd') || stringField(value, 'workingDirectory') || stringField(value, 'working_directory') || undefined,
    updatedAt: stringField(value, 'updatedAt') || stringField(value, 'updated_at') || undefined,
    archived: Boolean(value.archived),
    model: threadIdentityFromValue(value, 'model', 'modelName', 'model_name') || undefined,
    modelProvider: threadIdentityFromValue(value, 'modelProvider', 'model_provider', 'modelProviderId', 'model_provider_id', 'provider') || undefined,
  };
}

export function extractThreads(result: JsonValue): ThreadSummary[] {
  const object = isObject(result) ? result : {};
  const array = asArray(object.data) || asArray(object.items) || asArray(object.threads) || [];
  return array.map(normalizeThread).filter(Boolean) as ThreadSummary[];
}

export function extractThreadFromStart(result: JsonValue): ThreadSummary | null {
  const object = isObject(result) ? result : null;
  if (!object) return null;
  return normalizeThread(object.thread ?? result);
}

export function timelineItemsFromThreadRead(result: JsonValue, threadId: string): TimelineItem[] {
  const root = isObject(result) ? result : {};
  const threadObject = isObject(root.thread) ? root.thread : root;
  const turns = asArray(threadObject.turns) || asArray(root.turns) || [];
  const items: TimelineItem[] = [];
  const fallbackCreatedAt = Date.now();
  let sortIndex = 0;

  for (const turn of turns) {
    if (!isObject(turn)) continue;
    const turnId = stringField(turn, 'id') || stringField(turn, 'turnId') || stringField(turn, 'turn_id');
    const turnThreadId = stringField(turn, 'threadId') || stringField(turn, 'thread_id') || threadId;
    const rawItems = asArray(turn.items) || asArray(turn.messages) || asArray(turn.outputItems) || asArray(turn.output_items);

    if (rawItems?.length) {
      for (const rawItem of rawItems) {
        const mapped = itemFromHistoryItem(rawItem, turnThreadId, turnId, {
          fallbackCreatedAt: fallbackCreatedAt + sortIndex,
          sortIndex,
        });
        sortIndex += 1;
        if (mapped) items.push(mapped);
      }
      continue;
    }

    const input = textFromUnknown(turn.input) || stringField(turn, 'prompt');
    if (input) {
      items.push(makeItem({
        threadId: turnThreadId,
        role: 'user',
        kind: 'chat',
        text: input,
        turnId,
        createdAt: numericField(turn, 'createdAt') || numericField(turn, 'timestamp') || fallbackCreatedAt + sortIndex,
        sortIndex,
      }));
      sortIndex += 1;
    }
    const output = textFromUnknown(turn.output) || stringField(turn, 'response') || stringField(turn, 'summary');
    if (output) {
      items.push(makeItem({
        threadId: turnThreadId,
        role: 'assistant',
        kind: 'chat',
        text: output,
        turnId,
        createdAt: numericField(turn, 'createdAt') || numericField(turn, 'timestamp') || fallbackCreatedAt + sortIndex,
        sortIndex,
      }));
      sortIndex += 1;
    }
  }

  return reduceTimeline([], items);
}

export function titleFromTimelineItems(items: TimelineItem[]): string {
  const firstUserMessage = items.find((item) => item.role === 'user' && item.kind === 'chat' && item.text.trim());
  return truncateThreadTitle(firstUserMessage?.text || '');
}

export function shouldUseFallbackThreadTitle(title?: string): boolean {
  const normalized = normalizeTitleText(title || '');
  if (!normalized) return true;
  return /^(untitled chat|new chat|loading chat|无标题|未命名)$/i.test(normalized);
}

export function notificationToTimeline(method: string, params: JsonValue, fallbackThreadId: string | null): TimelineNotificationResult {
  const normalizedMethod = normalizeMethod(method);
  const object = isObject(params) ? params : {};
  const nested = firstObject(object.item, object.message, object.delta, object.event) || object;
  const threadId = stringField(object, 'threadId') || stringField(object, 'thread_id') || stringField(nested, 'threadId') || stringField(nested, 'thread_id') || fallbackThreadId;
  const turnId = stringField(object, 'turnId') || stringField(object, 'turn_id') || stringField(nested, 'turnId') || stringField(nested, 'turn_id');
  const itemId = stringField(object, 'itemId') || stringField(object, 'item_id') || stringField(nested, 'id') || stringField(nested, 'itemId') || stringField(nested, 'item_id');

  if (normalizedMethod.includes('turn/started')) {
    return { item: null, startedTurnId: turnId || undefined, threadId: threadId || undefined };
  }
  if (normalizedMethod.includes('turn/completed') || normalizedMethod.includes('turn/failed') || normalizedMethod.includes('turn/cancelled')) {
    return { item: null, completedTurnId: turnId || undefined, threadId: threadId || undefined };
  }
  if (!threadId) return { item: null };

  const extractedText = extractText(object, nested);
  const kind = classifyKind(normalizedMethod, nested, extractedText);
  const text = kind === 'tool'
    ? toolActivityText(normalizedMethod, object, nested) || extractedText
    : extractedText;
  const role = classifyRole(normalizedMethod, nested, kind);
  if (!text && kind === 'chat') return { item: null };

  return {
    item: makeItem({
      threadId,
      role,
      kind,
      text: text || labelForKind(kind),
      turnId: turnId || undefined,
      itemId: itemId || toolItemId(normalizedMethod, object, nested) || undefined,
      appendMode: kind === 'tool' ? toolAppendMode(normalizedMethod) : undefined,
      streaming: true,
      createdAt: numericField(object, 'createdAt') || numericField(object, 'timestamp') || Date.now(),
    }),
  };
}

export function itemFromNotification(method: string, params: JsonValue, fallbackThreadId: string | null): TimelineItem | null {
  return notificationToTimeline(method, params, fallbackThreadId).item;
}

export function mergeTimeline(existing: TimelineItem[], incoming: TimelineItem[]): TimelineItem[] {
  return reduceTimeline(existing, incoming);
}

export function reduceTimeline(existing: TimelineItem[], incoming: TimelineItem[], options: { completedTurnId?: string } = {}): TimelineItem[] {
  const next: TimelineItem[] = existing.map((item, index) => ({ ...item, sortIndex: item.sortIndex ?? index }));
  let nextSortIndex = next.reduce((maximum, item) => Math.max(maximum, item.sortIndex ?? 0), -1) + 1;

  for (const item of incoming) {
    const normalizedItem = {
      ...item,
      sortIndex: item.sortIndex ?? nextSortIndex,
    };
    nextSortIndex += 1;
    if (shouldIgnoreLateTurnlessActivity(next, normalizedItem)) continue;
    const index = findMergeTarget(next, normalizedItem);
    if (index >= 0) {
      next[index] = mergeItem(next[index], normalizedItem);
    } else {
      next.push(normalizedItem);
    }
  }

  if (options.completedTurnId) {
    for (const item of next) {
      if (item.turnId === options.completedTurnId) item.streaming = false;
    }
  }

  return orderTimeline(collapseThinkingRows(next));
}

export function markTurnCompleted(existing: TimelineItem[], turnId?: string): TimelineItem[] {
  if (!turnId) return existing;
  return reduceTimeline(existing, [], { completedTurnId: turnId });
}

function itemFromHistoryItem(
  rawItem: JsonValue,
  threadId: string,
  turnId: string | undefined,
  order: { fallbackCreatedAt: number; sortIndex: number },
): TimelineItem | null {
  if (!isObject(rawItem)) return null;
  const itemId = stringField(rawItem, 'id') || stringField(rawItem, 'itemId') || stringField(rawItem, 'item_id');
  const type = normalizeMethod(stringField(rawItem, 'type') || stringField(rawItem, 'kind') || stringField(rawItem, 'role'));
  const baseText = extractText(rawItem, rawItem);
  const kind = classifyKind(type, rawItem, baseText);
  const text = kind === 'tool' ? toolActivityText(type, rawItem) || baseText : baseText;
  if (!text && !type) return null;
  return makeItem({
    threadId,
    role: classifyRole(type, rawItem, kind),
    kind,
    text: text || labelForKind(kind),
    turnId,
    itemId: itemId || toolItemId(type, rawItem) || undefined,
    appendMode: kind === 'tool' ? toolAppendMode(type) : undefined,
    streaming: false,
    createdAt: numericField(rawItem, 'createdAt') || numericField(rawItem, 'timestamp') || order.fallbackCreatedAt,
    sortIndex: order.sortIndex,
  });
}

function findMergeTarget(items: TimelineItem[], incoming: TimelineItem): number {
  if (incoming.itemId) {
    const exactItem = items.findIndex((item) => item.itemId === incoming.itemId);
    if (exactItem >= 0) return exactItem;
  }

  if (incoming.turnId && incoming.role === 'assistant' && incoming.kind === 'chat') {
    const assistantIndex = findLastIndex(items, (item, index) =>
      item.turnId === incoming.turnId
      && item.role === 'assistant'
      && item.kind === 'chat'
      && !hasUserBoundaryAfter(items, index, incoming)
    );
    if (assistantIndex >= 0) return assistantIndex;
  }

  if (incoming.turnId && incoming.kind === 'tool') {
    const toolIndex = findLastIndex(items, (item, index) =>
      item.turnId === incoming.turnId
      && item.kind === 'tool'
      && item.role === incoming.role
      && !hasUserBoundaryAfter(items, index, incoming)
    );
    if (toolIndex >= 0) return toolIndex;
  }

  if (incoming.turnId && incoming.kind === 'thinking') {
    const activityIndex = findLastIndex(items, (item) =>
      item.turnId === incoming.turnId
      && item.kind === incoming.kind
      && item.role === incoming.role
      && item.streaming === true
    );
    if (activityIndex >= 0) return activityIndex;
  }

  return -1;
}

function hasUserBoundaryAfter(items: TimelineItem[], candidateIndex: number, incoming: TimelineItem): boolean {
  const incomingSortIndex = incoming.sortIndex ?? Number.MAX_SAFE_INTEGER;
  return items.slice(candidateIndex + 1).some((item) =>
    item.threadId === incoming.threadId
    && item.role === 'user'
    && item.kind === 'chat'
    && (item.sortIndex ?? Number.MAX_SAFE_INTEGER) <= incomingSortIndex
  );
}

function mergeItem(current: TimelineItem, incoming: TimelineItem): TimelineItem {
  const text = shouldAppendToolActivity(current, incoming)
    ? appendToolActivity(current.text, incoming.text, incoming.appendMode)
    : shouldAppendAsSeparateBlock(current, incoming)
    ? appendBlock(current.text, incoming.text)
    : appendDelta(current.text, incoming.text);
  return {
    ...current,
    itemId: current.itemId || incoming.itemId,
    turnId: incoming.turnId || current.turnId,
    text,
    streaming: incoming.streaming,
    createdAt: Math.min(current.createdAt, incoming.createdAt),
    sortIndex: Math.min(current.sortIndex ?? 0, incoming.sortIndex ?? 0),
  };
}

function shouldAppendToolActivity(current: TimelineItem, incoming: TimelineItem): boolean {
  return current.kind === 'tool' || incoming.kind === 'tool';
}

function shouldAppendAsSeparateBlock(current: TimelineItem, incoming: TimelineItem): boolean {
  return Boolean(
    current.turnId
    && incoming.turnId
    && current.turnId === incoming.turnId
    && current.role === 'assistant'
    && incoming.role === 'assistant'
    && current.kind === 'chat'
    && incoming.kind === 'chat'
    && current.itemId
    && incoming.itemId
    && current.itemId !== incoming.itemId
  );
}

function shouldIgnoreLateTurnlessActivity(items: TimelineItem[], incoming: TimelineItem): boolean {
  if (incoming.turnId || incoming.role !== 'assistant' || incoming.kind === 'chat') return false;
  const last = items[items.length - 1];
  return Boolean(last && last.role === 'system' && last.kind === 'event' && /completed|failed|cancelled/i.test(last.text));
}

function collapseThinkingRows(items: TimelineItem[]): TimelineItem[] {
  const output: TimelineItem[] = [];
  for (const item of items) {
    const previous = output[output.length - 1];
    if (previous && previous.role === item.role && previous.kind === 'thinking' && item.kind === 'thinking' && previous.turnId === item.turnId) {
      output[output.length - 1] = mergeItem(previous, item);
    } else {
      output.push(item);
    }
  }
  return output;
}

function orderTimeline(items: TimelineItem[]): TimelineItem[] {
  return [...items].sort((a, b) => {
    if (a.createdAt !== b.createdAt) return a.createdAt - b.createdAt;
    return (a.sortIndex ?? 0) - (b.sortIndex ?? 0);
  });
}

function classifyKind(method: string, item: Record<string, JsonValue>, text: string): TimelineItem['kind'] {
  const type = normalizeMethod(stringField(item, 'type') || stringField(item, 'kind'));
  if (method.includes('plan') || type.includes('plan')) return 'event';
  if (method.includes('diff') || type.includes('file_change') || type.includes('patch') || /^diff --git/m.test(text)) return 'tool';
  if (method.includes('reason') || method.includes('thinking') || type.includes('reason') || type.includes('thinking')) return 'thinking';
  if (method.includes('exec') || method.includes('tool') || method.includes('command') || type.includes('tool') || type.includes('command')) return 'tool';
  return 'chat';
}

function classifyRole(method: string, item: Record<string, JsonValue>, kind: TimelineItem['kind']): TimelineItem['role'] {
  const role = normalizeMethod(stringField(item, 'role'));
  if (role.includes('user') || method.includes('user')) return 'user';
  if (kind === 'event') return 'system';
  return 'assistant';
}

function extractText(...objects: Record<string, JsonValue>[]): string {
  for (const object of objects) {
    const direct = stringField(object, 'text') || stringField(object, 'delta') || stringField(object, 'message') || stringField(object, 'content') || stringField(object, 'output');
    if (direct) return direct;
    const nestedText = textFromUnknown(object.content) || textFromUnknown(object.delta) || textFromUnknown(object.message);
    if (nestedText) return nestedText;
  }
  return '';
}

function toolActivityText(method: string, ...objects: Record<string, JsonValue>[]): string {
  const command = firstStringField(objects, 'command', 'cmd', 'raw_command');
  const cwd = firstStringField(objects, 'cwd', 'workingDirectory', 'working_directory');
  const status = firstStringField(objects, 'status', 'state');
  const chunk = firstStringField(objects, 'chunk', 'delta');
  const output = firstStringField(objects, 'output', 'stdout', 'stderr', 'result');
  const message = firstStringField(objects, 'message', 'text');
  const toolName = firstStringField(objects, 'name', 'toolName', 'tool_name');

  if (method.includes('exec/command/begin') || method.includes('exec/command/start')) {
    const lines = command
      ? [`Running command`, '', '```bash', command, '```']
      : [message || `Running ${toolName || 'tool'}`];
    if (cwd) lines.push('', `cwd: \`${cwd}\``);
    lines.push('', 'Output:', '');
    return lines.join('\n');
  }

  if (method.includes('exec/command/output') || method.includes('output/delta')) {
    return chunk || output || message;
  }

  if (method.includes('exec/command/end') || method.includes('exec/command/completed')) {
    const parts = [`Command ${status || 'completed'}`];
    const exitCode = firstStringField(objects, 'exitCode', 'exit_code', 'code');
    if (exitCode) parts.push(`exit code: ${exitCode}`);
    return parts.join('\n');
  }

  if (command) return `Command\n\n\`\`\`bash\n${command}\n\`\`\``;
  if (chunk || output) return chunk || output;
  return message || (toolName ? `Running ${toolName}` : '');
}

function toolItemId(method: string, ...objects: Record<string, JsonValue>[]): string {
  const callId = firstStringField(objects, 'call_id', 'callId', 'toolCallId', 'tool_call_id');
  if (!callId) return '';
  if (method.includes('output')) return `${callId}:output`;
  if (method.includes('end') || method.includes('completed')) return `${callId}:end`;
  if (method.includes('begin') || method.includes('start')) return `${callId}:begin`;
  return callId;
}

function toolAppendMode(method: string): TimelineItem['appendMode'] {
  return method.includes('output') ? 'delta' : 'block';
}

function textFromUnknown(value: JsonValue | undefined): string {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    return value.map((entry) => {
      if (typeof entry === 'string') return entry;
      if (isObject(entry)) return stringField(entry, 'text') || stringField(entry, 'content') || stringField(entry, 'output');
      return '';
    }).filter(Boolean).join('\n');
  }
  if (isObject(value)) return stringField(value, 'text') || stringField(value, 'content') || stringField(value, 'output');
  return '';
}

function firstNonEmptyText(value: Record<string, JsonValue>): string {
  return textFromUnknown(value.input) || textFromUnknown(value.output) || extractText(value);
}

function threadTitleFromValue(value: Record<string, JsonValue>): string {
  const explicitTitle = stringField(value, 'title') || stringField(value, 'name');
  const fallbackTitle = truncateThreadTitle(firstUserTextInValue(value) || firstNonEmptyText(value));
  if (shouldUseFallbackThreadTitle(explicitTitle)) {
    return fallbackTitle || normalizeTitleText(explicitTitle) || 'Untitled chat';
  }
  return normalizeTitleText(explicitTitle);
}

function threadIdentityFromValue(value: Record<string, JsonValue>, ...keys: string[]): string {
  const direct = firstStringField([value], ...keys);
  if (direct) return direct;
  if (isObject(value.metadata)) {
    return firstStringField([value.metadata], ...keys);
  }
  return '';
}

function firstUserTextInValue(value: Record<string, JsonValue>): string {
  const directInput = textFromUnknown(value.input) || textFromUnknown(value.prompt);
  if (directInput) return directInput;

  const collections = [
    asArray(value.turns),
    asArray(value.items),
    asArray(value.messages),
    asArray(value.outputItems),
    asArray(value.output_items),
  ].filter(Boolean) as JsonValue[][];

  for (const collection of collections) {
    for (const entry of collection) {
      if (!isObject(entry)) continue;
      const turnInput = textFromUnknown(entry.input) || textFromUnknown(entry.prompt);
      if (turnInput) return turnInput;

      const role = normalizeMethod(stringField(entry, 'role'));
      if (role.includes('user')) {
        const text = extractText(entry, entry) || textFromUnknown(entry.content);
        if (text) return text;
      }

      const nestedItems = asArray(entry.items) || asArray(entry.messages) || asArray(entry.outputItems) || asArray(entry.output_items);
      if (!nestedItems) continue;
      for (const nestedItem of nestedItems) {
        if (!isObject(nestedItem)) continue;
        const nestedRole = normalizeMethod(stringField(nestedItem, 'role'));
        if (!nestedRole.includes('user')) continue;
        const text = extractText(nestedItem, nestedItem) || textFromUnknown(nestedItem.content);
        if (text) return text;
      }
    }
  }

  return '';
}

function truncateThreadTitle(text: string, maxLength = 42): string {
  const normalized = normalizeTitleText(text);
  if (normalized.length <= maxLength) return normalized;
  return `${normalized.slice(0, maxLength - 1).trimEnd()}…`;
}

function normalizeTitleText(text: string): string {
  return text.replace(/\s+/g, ' ').trim();
}

function appendDelta(current: string, incoming: string): string {
  if (!incoming) return current;
  if (!current) return incoming;
  if (incoming.startsWith(current)) return incoming;
  return `${current}${incoming}`;
}

function appendBlock(current: string, incoming: string): string {
  if (!incoming) return current;
  if (!current) return incoming;
  if (incoming.startsWith(current)) return incoming;
  const separator = current.endsWith('\n') ? '\n' : '\n\n';
  return `${current}${separator}${incoming}`;
}

function appendToolActivity(current: string, incoming: string, appendMode: TimelineItem['appendMode']): string {
  if (!incoming) return current;
  if (!current) return incoming;
  if (incoming.startsWith(current)) return incoming;
  if (appendMode === 'delta') return `${current}${incoming}`;
  if (current.includes(incoming.trim())) return current;
  return appendBlock(current.replace(/\n+$/g, ''), incoming);
}

function makeItem(input: {
  threadId: string;
  role: TimelineItem['role'];
  kind: TimelineItem['kind'];
  text: string;
  turnId?: string;
  itemId?: string;
  appendMode?: TimelineItem['appendMode'];
  streaming?: boolean;
  createdAt?: number;
  sortIndex?: number;
}): TimelineItem {
  const createdAt = input.createdAt || Date.now();
  return {
    id: input.itemId || `${input.role}-${input.kind}-${input.turnId || crypto.randomUUID()}-${createdAt}`,
    threadId: input.threadId,
    role: input.role,
    kind: input.kind,
    text: input.text,
    turnId: input.turnId,
    itemId: input.itemId,
    streaming: input.streaming ?? false,
    createdAt,
    sortIndex: input.sortIndex,
    appendMode: input.appendMode,
  };
}

function firstStringField(objects: Record<string, JsonValue>[], ...keys: string[]): string {
  for (const object of objects) {
    for (const key of keys) {
      const value = object[key];
      if (typeof value === 'string' && value.trim()) return value.trim();
      if (typeof value === 'number' && Number.isFinite(value)) return String(value);
    }
  }
  return '';
}

function firstObject(...values: (JsonValue | undefined)[]): Record<string, JsonValue> | null {
  for (const value of values) {
    if (isObject(value)) return value;
  }
  return null;
}

function stringField(object: Record<string, JsonValue>, key: string): string {
  const value = object[key];
  return typeof value === 'string' ? value : '';
}

function numericField(object: Record<string, JsonValue>, key: string): number | undefined {
  const value = object[key];
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

function asArray(value: JsonValue | undefined): JsonValue[] | null {
  return Array.isArray(value) ? value : null;
}

function isObject(value: JsonValue | undefined): value is Record<string, JsonValue> {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value));
}

function normalizeMethod(value: string): string {
  return value.trim().toLowerCase().replace(/_/g, '/');
}

function labelForKind(kind: TimelineItem['kind']): string {
  if (kind === 'thinking') return 'Thinking…';
  if (kind === 'tool') return 'Tool activity';
  if (kind === 'event') return 'Event';
  return '';
}

function findLastIndex<T>(values: T[], predicate: (value: T, index: number) => boolean): number {
  for (let index = values.length - 1; index >= 0; index -= 1) {
    if (predicate(values[index], index)) return index;
  }
  return -1;
}
