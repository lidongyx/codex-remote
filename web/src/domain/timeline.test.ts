import { describe, expect, it } from 'vitest';
import type { TimelineItem } from './types';
import {
  markTurnCompleted,
  normalizeThread,
  notificationToTimeline,
  reduceTimeline,
  timelineItemsFromThreadRead,
} from './timeline';

function item(overrides: Partial<TimelineItem>): TimelineItem {
  return {
    id: overrides.id ?? crypto.randomUUID(),
    threadId: overrides.threadId ?? 'thread-1',
    role: overrides.role ?? 'assistant',
    kind: overrides.kind ?? 'chat',
    text: overrides.text ?? '',
    turnId: overrides.turnId,
    itemId: overrides.itemId,
    streaming: overrides.streaming ?? false,
    createdAt: overrides.createdAt ?? Date.now(),
  };
}

describe('timeline reducer', () => {
  it('falls back to a truncated user message when a thread title is missing', () => {
    const thread = normalizeThread({
      id: 'thread-title',
      title: 'Untitled chat',
      turns: [{
        input: '请基于当前项目做一个类似 iOS app 的网页版，并且直接打开网页可用，还要支持远程目录选择和项目分组',
      }],
    });

    expect(thread?.title.startsWith('请基于当前项目做一个类似 iOS app')).toBe(true);
    expect(thread?.title.endsWith('…')).toBe(true);
    expect(thread?.title.length).toBeLessThanOrEqual(42);
  });

  it('merges assistant deltas by item id', () => {
    const first = item({ itemId: 'item-a', turnId: 'turn-1', text: 'Hel', streaming: true, createdAt: 1 });
    const second = item({ itemId: 'item-a', turnId: 'turn-1', text: 'lo', streaming: true, createdAt: 2 });

    const result = reduceTimeline([], [first, second]);

    expect(result).toHaveLength(1);
    expect(result[0].text).toBe('Hello');
    expect(result[0].itemId).toBe('item-a');
  });

  it('merges distinct assistant chat items in the same turn', () => {
    const result = reduceTimeline([], [
      item({ itemId: 'think-1', turnId: 'turn-1', kind: 'thinking', text: 'Thinking', createdAt: 1 }),
      item({ itemId: 'answer-1', turnId: 'turn-1', kind: 'chat', text: 'Answer', createdAt: 2 }),
      item({ itemId: 'tool-1', turnId: 'turn-1', kind: 'tool', text: 'Ran command', createdAt: 3 }),
      item({ itemId: 'answer-2', turnId: 'turn-1', kind: 'chat', text: 'More', createdAt: 4 }),
    ]);

    expect(result.map((entry) => entry.itemId)).toEqual(['think-1', 'answer-1', 'tool-1']);
    expect(result.find((entry) => entry.itemId === 'answer-1')?.text).toBe('Answer\n\nMore');
  });

  it('keeps user and assistant messages in chronological chat order when timestamps match', () => {
    const result = reduceTimeline([], [
      item({ id: 'user-1', role: 'user', text: 'first question', createdAt: 10 }),
      item({ id: 'assistant-1', role: 'assistant', text: 'first answer', createdAt: 10 }),
      item({ id: 'user-2', role: 'user', text: 'second question', createdAt: 10 }),
      item({ id: 'assistant-2', role: 'assistant', text: 'second answer', createdAt: 10 }),
    ]);

    expect(result.map((entry) => [entry.role, entry.text])).toEqual([
      ['user', 'first question'],
      ['assistant', 'first answer'],
      ['user', 'second question'],
      ['assistant', 'second answer'],
    ]);
  });

  it('does not merge assistant chat across a later user boundary', () => {
    const result = reduceTimeline([], [
      item({ itemId: 'assistant-1', turnId: 'turn-1', role: 'assistant', text: 'first answer', createdAt: 1 }),
      item({ itemId: 'user-2', turnId: 'turn-1', role: 'user', text: 'follow-up', createdAt: 2 }),
      item({ itemId: 'assistant-2', turnId: 'turn-1', role: 'assistant', text: 'second answer', createdAt: 3 }),
    ]);

    expect(result.map((entry) => [entry.role, entry.text])).toEqual([
      ['assistant', 'first answer'],
      ['user', 'follow-up'],
      ['assistant', 'second answer'],
    ]);
  });

  it('merges tool activity for a turn while preserving command output', () => {
    const begin = notificationToTimeline('codex/event/exec_command_begin', {
      threadId: 'thread-1',
      turnId: 'turn-1',
      call_id: 'call-1',
      command: 'npm test',
      cwd: '/tmp/project',
    }, null).item!;
    const output = notificationToTimeline('codex/event/exec_command_output_delta', {
      threadId: 'thread-1',
      turnId: 'turn-1',
      call_id: 'call-1',
      chunk: 'PASS timeline.test.ts\n',
    }, null).item!;
    const end = notificationToTimeline('codex/event/exec_command_end', {
      threadId: 'thread-1',
      turnId: 'turn-1',
      call_id: 'call-1',
      status: 'completed',
    }, null).item!;

    const result = reduceTimeline([], [begin, output, end]);

    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('tool');
    expect(result[0].text).toContain('npm test');
    expect(result[0].text).toContain('PASS timeline.test.ts');
    expect(result[0].text).toContain('Command completed');
  });

  it('does not merge tool activity across a later user boundary', () => {
    const firstTool = item({
      role: 'assistant',
      kind: 'tool',
      turnId: 'turn-1',
      text: 'first tool',
      appendMode: 'block',
      createdAt: 1,
    });
    const result = reduceTimeline([], [
      firstTool,
      item({ itemId: 'user-2', turnId: 'turn-1', role: 'user', text: 'next prompt', createdAt: 2 }),
      item({
        role: 'assistant',
        kind: 'tool',
        turnId: 'turn-1',
        text: 'second tool',
        appendMode: 'block',
        createdAt: 3,
      }),
    ]);

    expect(result.map((entry) => [entry.role, entry.kind, entry.text])).toEqual([
      ['assistant', 'tool', 'first tool'],
      ['user', 'chat', 'next prompt'],
      ['assistant', 'tool', 'second tool'],
    ]);
  });

  it('marks all turn rows complete on turn completion', () => {
    const rows = reduceTimeline([], [
      item({ turnId: 'turn-1', itemId: 'a', text: 'A', streaming: true }),
      item({ turnId: 'turn-1', itemId: 'b', kind: 'thinking', text: 'B', streaming: true }),
    ]);

    const completed = markTurnCompleted(rows, 'turn-1');

    expect(completed.every((entry) => entry.streaming === false)).toBe(true);
  });

  it('ignores late turn-less activity after a completed event marker', () => {
    const existing = [
      item({ id: 'done', role: 'system', kind: 'event', text: 'Turn completed', createdAt: 10 }),
    ];
    const result = reduceTimeline(existing, [
      item({ role: 'assistant', kind: 'tool', text: 'late tool output', createdAt: 11 }),
    ]);

    expect(result).toHaveLength(1);
    expect(result[0].text).toBe('Turn completed');
  });

  it('maps notifications into typed timeline rows', () => {
    const result = notificationToTimeline('turn/reasoning/delta', {
      threadId: 'thread-1',
      turnId: 'turn-1',
      itemId: 'reason-1',
      delta: 'checking files',
    }, null);

    expect(result.item?.kind).toBe('thinking');
    expect(result.item?.text).toBe('checking files');
    expect(result.item?.itemId).toBe('reason-1');
  });

  it('extracts item-aware history from thread/read turns', () => {
    const rows = timelineItemsFromThreadRead({
      thread: {
        turns: [{
          id: 'turn-1',
          items: [
            { id: 'user-1', role: 'user', type: 'message', content: [{ type: 'input_text', text: 'Hi' }] },
            { id: 'assistant-1', role: 'assistant', type: 'message', content: [{ type: 'output_text', text: 'Hello' }] },
          ],
        }],
      },
    }, 'thread-1');

    expect(rows.map((entry) => [entry.role, entry.text])).toEqual([
      ['user', 'Hi'],
      ['assistant', 'Hello'],
    ]);
    expect(rows.map((entry) => entry.itemId)).toEqual(['user-1', 'assistant-1']);
  });

  it('preserves thread/read multi-turn order without timestamps', () => {
    const rows = timelineItemsFromThreadRead({
      thread: {
        turns: [
          { id: 'turn-1', input: 'First?', output: 'First.' },
          { id: 'turn-2', input: 'Second?', output: 'Second.' },
        ],
      },
    }, 'thread-1');

    expect(rows.map((entry) => [entry.role, entry.text])).toEqual([
      ['user', 'First?'],
      ['assistant', 'First.'],
      ['user', 'Second?'],
      ['assistant', 'Second.'],
    ]);
  });
});
