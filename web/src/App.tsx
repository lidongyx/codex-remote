import { useEffect, useMemo, useRef, useState } from 'react';
import type {
  ConnectionState,
  DirectoryListResult,
  JsonRpcNotification,
  ModelOption,
  PairingPayload,
  SkillMetadata,
  ThreadSummary,
  TimelineItem,
  TurnImageAttachment,
  TurnSkillMention,
} from './domain/types';
import {
  extractThreadFromStart,
  extractThreads,
  markTurnCompleted,
  mergeTimeline,
  notificationToTimeline,
  shouldUseFallbackThreadTitle,
  timelineItemsFromThreadRead,
  titleFromTimelineItems,
} from './domain/timeline';
import { CodexClient } from './services/codexClient';
import { clearPairing, fetchBootstrapPairing, loadSavedPairing, parsePairingPayload, savePairing } from './services/pairing';
import { MarkdownContent } from './components/MarkdownContent';

interface ProjectGroup {
  key: string;
  name: string;
  cwd?: string;
  threads: ThreadSummary[];
}

interface ComposerAttachment {
  id: string;
  name: string;
  mimeType: string;
  size: number;
  kind: 'image' | 'file';
  dataUrl?: string;
  text?: string;
  error?: string;
}

type AccessMode = 'default' | 'auto-review' | 'full-access';

const DEFAULT_MODEL_OPTIONS: ModelOption[] = [
  {
    id: 'gpt-5.5',
    model: 'gpt-5.5',
    displayName: 'GPT-5.5',
    supportedReasoningEfforts: [
      { reasoningEffort: 'xhigh', description: 'Extra High' },
      { reasoningEffort: 'high', description: 'High' },
      { reasoningEffort: 'medium', description: 'Medium' },
      { reasoningEffort: 'low', description: 'Low' },
    ],
    defaultReasoningEffort: 'xhigh',
  },
  {
    id: 'gpt-5.4',
    model: 'gpt-5.4',
    displayName: 'GPT-5.4',
    supportedReasoningEfforts: [
      { reasoningEffort: 'xhigh', description: 'Extra High' },
      { reasoningEffort: 'high', description: 'High' },
      { reasoningEffort: 'medium', description: 'Medium' },
      { reasoningEffort: 'low', description: 'Low' },
    ],
    defaultReasoningEffort: 'xhigh',
  },
  {
    id: 'gpt-5.4-mini',
    model: 'gpt-5.4-mini',
    displayName: 'GPT-5.4-Mini',
    supportedReasoningEfforts: [
      { reasoningEffort: 'high', description: 'High' },
      { reasoningEffort: 'medium', description: 'Medium' },
      { reasoningEffort: 'low', description: 'Low' },
    ],
    defaultReasoningEffort: 'medium',
  },
];

const MAX_ATTACHMENT_COUNT = 8;
const MAX_TEXT_ATTACHMENT_BYTES = 256 * 1024;

export default function App() {
  const clientRef = useRef<CodexClient | null>(null);
  const autoConnectSuppressedRef = useRef(false);
  const copyResetTimerRef = useRef<number | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const threadIdByTurnIdRef = useRef<Map<string, string>>(new Map());
  const [pairingInput, setPairingInput] = useState('');
  const [pairing, setPairing] = useState<PairingPayload | null>(() => loadSavedPairing());
  const [connectionState, setConnectionState] = useState<ConnectionState>('idle');
  const [statusDetail, setStatusDetail] = useState('Paste the bridge pairing payload to connect.');
  const [threads, setThreads] = useState<ThreadSummary[]>([]);
  const [activeThreadId, setActiveThreadId] = useState<string | null>(null);
  const [runningThreadIds, setRunningThreadIds] = useState<Set<string>>(() => new Set());
  const [collapsedProjects, setCollapsedProjects] = useState<Set<string>>(() => new Set());
  const [timeline, setTimeline] = useState<Record<string, TimelineItem[]>>({});
  const [copiedMessageId, setCopiedMessageId] = useState<string | null>(null);
  const [projectPickerOpen, setProjectPickerOpen] = useState(false);
  const [projectBrowser, setProjectBrowser] = useState<DirectoryListResult | null>(null);
  const [isProjectBrowserLoading, setIsProjectBrowserLoading] = useState(false);
  const [isCreatingProject, setIsCreatingProject] = useState(false);
  const [availableModels, setAvailableModels] = useState<ModelOption[]>(DEFAULT_MODEL_OPTIONS);
  const [selectedModelId, setSelectedModelId] = useState(DEFAULT_MODEL_OPTIONS[0].id);
  const [selectedReasoningEffort, setSelectedReasoningEffort] = useState(DEFAULT_MODEL_OPTIONS[0].defaultReasoningEffort ?? 'xhigh');
  const [isLoadingModels, setIsLoadingModels] = useState(false);
  const [availableSkills, setAvailableSkills] = useState<SkillMetadata[]>([]);
  const [isLoadingSkills, setIsLoadingSkills] = useState(false);
  const [selectedSkillMentions, setSelectedSkillMentions] = useState<TurnSkillMention[]>([]);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [composerAttachments, setComposerAttachments] = useState<ComposerAttachment[]>([]);
  const [composerMenuOpen, setComposerMenuOpen] = useState(false);
  const [pluginMenuOpen, setPluginMenuOpen] = useState(false);
  const [permissionMenuOpen, setPermissionMenuOpen] = useState(false);
  const [planModeEnabled, setPlanModeEnabled] = useState(false);
  const [selectedAccessMode, setSelectedAccessMode] = useState<AccessMode>('default');
  const [draft, setDraft] = useState('');
  const [isSending, setIsSending] = useState(false);
  const activeThread = threads.find((thread) => thread.id === activeThreadId) ?? null;
  const activeItems = activeThreadId ? timeline[activeThreadId] ?? [] : [];
  const activeThreadTitle = activeThread ? displayThreadTitle(activeThread, activeItems) : 'No chat selected';
  const activeThreadRunning = activeThreadId ? runningThreadIds.has(activeThreadId) : false;
  const selectedModel = selectedModelOption(availableModels, selectedModelId);
  const reasoningOptions = selectedModel?.supportedReasoningEfforts ?? [];
  const effectiveReasoningEffort = selectedReasoningEffortForModel(selectedModel, selectedReasoningEffort);
  const providerLabel = activeThread?.modelProvider || selectedModel?.provider || 'Runtime';
  const projectGroups = useMemo(() => groupThreadsByProject(threads), [threads]);

  const client = useMemo(() => {
    const next = new CodexClient();
    next.onState((state, detail) => {
      setConnectionState(state);
      if (detail) setStatusDetail(detail);
    });
    next.onNotification((notification) => handleNotification(notification));
    clientRef.current = next;
    return next;
  }, []);

  async function connectWithPairing(nextPairing = pairing) {
    if (!nextPairing) {
      setStatusDetail('Paste the JSON pairing payload printed by the bridge QR flow.');
      return;
    }
    autoConnectSuppressedRef.current = false;
    try {
      setStatusDetail('Connecting to relay...');
      await client.connect(nextPairing);
      savePairing(nextPairing);
      setPairing(nextPairing);
      setStatusDetail('Secure channel ready. Syncing threads...');
      await refreshThreads();
      void refreshModels();
      setStatusDetail('Connected. Threads synced.');
    } catch (error) {
      setConnectionState('error');
      setStatusDetail(error instanceof Error ? error.message : 'Connection failed.');
    }
  }

  async function refreshThreads() {
    const result = await client.request('thread/list', {
      sourceKinds: ['cli', 'vscode', 'appServer', 'exec', 'unknown'],
      cursor: null,
      limit: 70,
    });
    const nextThreads = extractThreads(result);
    setThreads(nextThreads);
    const nextActive = activeThreadId ?? nextThreads[0]?.id ?? null;
    setActiveThreadId(nextActive);
    if (nextActive) await openThread(nextActive);
  }

  async function refreshModels() {
    setIsLoadingModels(true);
    try {
      const models = await client.listModels();
      if (!models.length) return;
      setAvailableModels(models);
      const nextSelected = selectedModelOption(models, selectedModelId) ?? defaultModelOption(models);
      if (nextSelected) {
        setSelectedModelId(nextSelected.id);
        setSelectedReasoningEffort((current) => selectedReasoningEffortForModel(nextSelected, current) ?? '');
      }
    } catch (error) {
      setStatusDetail(error instanceof Error ? `Model list unavailable: ${error.message}` : 'Model list unavailable.');
    } finally {
      setIsLoadingModels(false);
    }
  }

  async function loadSkills(forceReload = false) {
    if (connectionState !== 'connected') return;
    setIsLoadingSkills(true);
    try {
      const skills = await client.listSkills(activeThread?.cwd ? [activeThread.cwd] : undefined, forceReload);
      setAvailableSkills(skills);
      setStatusDetail(skills.length ? `已加载 ${skills.length} 个本地插件。` : '当前项目没有可用插件。');
    } catch (error) {
      setStatusDetail(error instanceof Error ? `插件列表不可用：${error.message}` : '插件列表不可用。');
    } finally {
      setIsLoadingSkills(false);
    }
  }

  async function openThread(threadId: string) {
    setActiveThreadId(threadId);
    setSidebarOpen(false);
    try {
      const result = await client.readThread(threadId);
      const items = timelineItemsFromThreadRead(result, threadId);
      if (items.length) {
        setTimeline((current) => ({ ...current, [threadId]: items }));
        updateThreadTitleFromItems(threadId, items);
      }
    } catch {
      setTimeline((current) => current[threadId] ? current : {
        ...current,
        [threadId]: [{
          id: `system-${threadId}`,
          threadId,
          role: 'system',
          kind: 'event',
          text: 'Thread opened. History backfill is unavailable for this runtime response shape.',
          createdAt: Date.now(),
        }],
      });
    }
  }

  async function createThread(cwd?: string) {
    try {
      const result = await client.startThread(cwd);
      const thread = extractThreadFromStart(result);
      if (!thread) throw new Error('thread/start did not return a thread.');
      const nextThread = {
        ...thread,
        cwd: thread.cwd || cwd,
      };
      setThreads((current) => [nextThread, ...current.filter((item) => item.id !== nextThread.id)]);
      setActiveThreadId(thread.id);
      setSidebarOpen(false);
      setTimeline((current) => ({ ...current, [thread.id]: [] }));
      setStatusDetail(cwd ? `New project ready: ${projectName(cwd)}.` : 'New chat ready.');
      return nextThread;
    } catch (error) {
      setStatusDetail(error instanceof Error ? error.message : 'Could not create thread.');
      return null;
    }
  }

  async function sendDraft() {
    const input = draft.trim();
    if ((!input && composerAttachments.length === 0 && selectedSkillMentions.length === 0) || isSending) return;
    const attachmentsToSend = composerAttachments;
    const skillsToSend = selectedSkillMentions;
    const outboundInput = buildOutboundInput(input, attachmentsToSend);
    const displayText = buildDisplayInput(input, attachmentsToSend, skillsToSend);
    const imageAttachments = imageAttachmentsForTurn(attachmentsToSend);
    setIsSending(true);
    setDraft('');
    setComposerAttachments([]);
    setSelectedSkillMentions([]);
    let sendingThreadId = activeThreadId;
    try {
      let threadId = sendingThreadId;
      if (!threadId) {
        const result = await client.startThread();
        const thread = extractThreadFromStart(result);
        if (!thread) throw new Error('Could not create a thread.');
        threadId = thread.id;
        sendingThreadId = threadId;
        setThreads((current) => [thread, ...current]);
        setActiveThreadId(threadId);
      }
      markThreadRunning(threadId, true);
      const userItem: TimelineItem = {
        id: crypto.randomUUID(),
        threadId,
        role: 'user',
        kind: 'chat',
        text: displayText,
        createdAt: Date.now(),
      };
      setTimeline((current) => ({ ...current, [threadId!]: mergeTimeline(current[threadId!] ?? [], [userItem]) }));
      updateThreadTitleFromItems(threadId, [userItem]);
      await client.startTurn(threadId, outboundInput, {
        imageAttachments,
        model: selectedModel?.model,
        effort: effectiveReasoningEffort || undefined,
        accessMode: selectedAccessMode,
        planMode: planModeEnabled,
        skillMentions: skillsToSend,
      });
      setPlanModeEnabled(false);
    } catch (error) {
      if (sendingThreadId) markThreadRunning(sendingThreadId, false);
      setDraft(input);
      setComposerAttachments(attachmentsToSend);
      setSelectedSkillMentions(skillsToSend);
      setStatusDetail(error instanceof Error ? error.message : 'Send failed.');
    } finally {
      setIsSending(false);
    }
  }

  async function stopTurn() {
    if (!activeThreadId) return;
    try {
      await client.interruptTurn(activeThreadId);
      markThreadRunning(activeThreadId, false);
    } catch (error) {
      setStatusDetail(error instanceof Error ? error.message : 'Stop failed.');
    }
  }

  function handlePairingSubmit() {
    try {
      const parsed = parsePairingPayload(pairingInput);
      autoConnectSuppressedRef.current = false;
      setPairing(parsed);
      void connectWithPairing(parsed);
    } catch (error) {
      setConnectionState('error');
      setStatusDetail(error instanceof Error ? error.message : 'Invalid pairing payload.');
    }
  }

  function handleNotification(notification: JsonRpcNotification) {
    const result = notificationToTimeline(notification.method, notification.params ?? null, activeThreadId);
    if (result.startedTurnId && result.threadId) {
      threadIdByTurnIdRef.current.set(result.startedTurnId, result.threadId);
      markThreadRunning(result.threadId, true);
    }
    if (result.completedTurnId) {
      const completedThreadId = result.threadId || threadIdByTurnIdRef.current.get(result.completedTurnId);
      if (completedThreadId) {
        markThreadRunning(completedThreadId, false);
        threadIdByTurnIdRef.current.delete(result.completedTurnId);
      }
      setTimeline((current) => {
        const next: Record<string, TimelineItem[]> = {};
        for (const [threadId, items] of Object.entries(current)) {
          next[threadId] = markTurnCompleted(items, result.completedTurnId);
        }
        return next;
      });
    }
    if (!result.item) return;
    if (result.item.turnId) {
      threadIdByTurnIdRef.current.set(result.item.turnId, result.item.threadId);
      markThreadRunning(result.item.threadId, true);
    }
    setTimeline((current) => ({ ...current, [result.item!.threadId]: mergeTimeline(current[result.item!.threadId] ?? [], [result.item!]) }));
  }

  function forgetPairing() {
    clearPairing();
    autoConnectSuppressedRef.current = true;
    setPairing(null);
    setPairingInput('');
    clientRef.current?.disconnect();
    setConnectionState('idle');
    setStatusDetail('Pairing cleared. Paste a fresh bridge payload.');
  }

  function toggleProject(projectKey: string) {
    setCollapsedProjects((current) => {
      const next = new Set(current);
      if (next.has(projectKey)) {
        next.delete(projectKey);
      } else {
        next.add(projectKey);
      }
      return next;
    });
  }

  async function copyMessageText(item: TimelineItem) {
    if (!item.text.trim()) return;
    try {
      await writeClipboardText(item.text);
      setCopiedMessageId(item.id);
      setStatusDetail('已复制该回合内容。');
      if (copyResetTimerRef.current) window.clearTimeout(copyResetTimerRef.current);
      copyResetTimerRef.current = window.setTimeout(() => {
        setCopiedMessageId((current) => current === item.id ? null : current);
        copyResetTimerRef.current = null;
      }, 1400);
    } catch {
      setStatusDetail('复制失败，请检查浏览器剪贴板权限。');
    }
  }

  async function openProjectPicker() {
    if (!connected) {
      setStatusDetail('Connect to the bridge before choosing a local project folder.');
      return;
    }
    setSidebarOpen(false);
    setProjectPickerOpen(true);
    await loadProjectDirectory(projectBrowser?.directory.path);
  }

  async function loadProjectDirectory(path?: string) {
    setIsProjectBrowserLoading(true);
    try {
      const result = await client.listLocalDirectory(path);
      setProjectBrowser(result);
      setStatusDetail('Choose a folder on your Mac for the new project.');
    } catch (error) {
      setStatusDetail(error instanceof Error ? error.message : 'Could not read local folders.');
    } finally {
      setIsProjectBrowserLoading(false);
    }
  }

  async function createProjectFromCurrentDirectory() {
    const cwd = projectBrowser?.directory.path;
    if (!cwd || isCreatingProject) return;
    setIsCreatingProject(true);
    try {
      const thread = await createThread(cwd);
      if (thread) {
        setProjectPickerOpen(false);
        setProjectBrowser(null);
      }
    } finally {
      setIsCreatingProject(false);
    }
  }

  function updateThreadTitleFromItems(threadId: string, items: TimelineItem[]) {
    const fallbackTitle = titleFromTimelineItems(items);
    if (!fallbackTitle) return;
    setThreads((current) => current.map((thread) => (
      thread.id === threadId && shouldUseFallbackThreadTitle(thread.title)
        ? { ...thread, title: fallbackTitle }
        : thread
    )));
  }

  function markThreadRunning(threadId: string, running: boolean) {
    setRunningThreadIds((current) => {
      const next = new Set(current);
      if (running) {
        next.add(threadId);
      } else {
        next.delete(threadId);
      }
      return next;
    });
  }

  async function handleAttachmentInput(files: FileList | null) {
    if (!files?.length) return;
    const remainingSlots = Math.max(0, MAX_ATTACHMENT_COUNT - composerAttachments.length);
    if (remainingSlots === 0) {
      setStatusDetail(`最多可附加 ${MAX_ATTACHMENT_COUNT} 个文件或照片。`);
      return;
    }

    const acceptedFiles = Array.from(files).slice(0, remainingSlots);
    const nextAttachments = await Promise.all(acceptedFiles.map(readComposerAttachment));
    setComposerAttachments((current) => [...current, ...nextAttachments]);
    if (files.length > remainingSlots) {
      setStatusDetail(`已添加 ${remainingSlots} 个附件，剩余文件被忽略。`);
    } else {
      setStatusDetail(`已添加 ${acceptedFiles.length} 个附件。`);
    }
  }

  function removeAttachment(id: string) {
    setComposerAttachments((current) => current.filter((attachment) => attachment.id !== id));
  }

  function openAttachmentPicker() {
    setComposerMenuOpen(false);
    setPluginMenuOpen(false);
    fileInputRef.current?.click();
  }

  function togglePlanMode() {
    setPlanModeEnabled((current) => !current);
    setStatusDetail(planModeEnabled ? '计划模式已关闭。' : '计划模式已开启，下一条消息会按 Plan 发送。');
    setComposerMenuOpen(false);
    setPluginMenuOpen(false);
  }

  function openPluginPicker() {
    setPluginMenuOpen(true);
    if (availableSkills.length === 0 && !isLoadingSkills) void loadSkills();
  }

  function toggleSkillMention(skill: SkillMetadata) {
    if (!skill.enabled) return;
    setSelectedSkillMentions((current) => {
      const skillId = skill.name.trim();
      const selected = current.some((mention) => mention.id === skillId);
      if (selected) return current.filter((mention) => mention.id !== skillId);
      return [...current, { id: skillId, name: skill.name, path: skill.path }];
    });
  }

  function removeSkillMention(id: string) {
    setSelectedSkillMentions((current) => current.filter((mention) => mention.id !== id));
  }

  function chooseAccessMode(accessMode: AccessMode) {
    setSelectedAccessMode(accessMode);
    setPermissionMenuOpen(false);
  }

  const connected = connectionState === 'connected';

  useEffect(() => {
    if (!activeThread?.cwd) return;
    setCollapsedProjects((current) => {
      if (!current.has(activeThread.cwd!)) return current;
      const next = new Set(current);
      next.delete(activeThread.cwd!);
      return next;
    });
  }, [activeThread?.cwd]);

  useEffect(() => {
    setAvailableSkills([]);
  }, [activeThread?.cwd]);

  useEffect(() => {
    if (connectionState !== 'idle' || autoConnectSuppressedRef.current) return;
    if (pairing) {
      setStatusDetail('Using saved pairing. Connecting...');
      void connectWithPairing(pairing);
      return;
    }
    let cancelled = false;
    setStatusDetail('Looking for local bridge bootstrap...');
    void fetchBootstrapPairing().then((bootstrapPairing) => {
      if (cancelled) return;
      if (bootstrapPairing) {
        setPairing(bootstrapPairing);
        setStatusDetail('Found local bridge pairing. Connecting...');
        void connectWithPairing(bootstrapPairing);
      } else {
        setStatusDetail('Paste the bridge pairing payload, or start the bridge with local Web bootstrap enabled.');
      }
    });
    return () => {
      cancelled = true;
    };
  }, [pairing, connectionState]);

  useEffect(() => {
    if (!composerMenuOpen && !permissionMenuOpen && !pluginMenuOpen) return;

    function closeComposerMenus(event: PointerEvent) {
      const target = event.target;
      if (target instanceof Element && target.closest('.composer-menu-wrap')) return;
      setComposerMenuOpen(false);
      setPluginMenuOpen(false);
      setPermissionMenuOpen(false);
    }

    function closeComposerMenusWithKeyboard(event: KeyboardEvent) {
      if (event.key !== 'Escape') return;
      setComposerMenuOpen(false);
      setPluginMenuOpen(false);
      setPermissionMenuOpen(false);
    }

    document.addEventListener('pointerdown', closeComposerMenus);
    document.addEventListener('keydown', closeComposerMenusWithKeyboard);
    return () => {
      document.removeEventListener('pointerdown', closeComposerMenus);
      document.removeEventListener('keydown', closeComposerMenusWithKeyboard);
    };
  }, [composerMenuOpen, permissionMenuOpen, pluginMenuOpen]);

  useEffect(() => {
    if (!sidebarOpen) return;

    function closeSidebarWithKeyboard(event: KeyboardEvent) {
      if (event.key === 'Escape') setSidebarOpen(false);
    }

    document.addEventListener('keydown', closeSidebarWithKeyboard);
    return () => document.removeEventListener('keydown', closeSidebarWithKeyboard);
  }, [sidebarOpen]);

  useEffect(() => () => {
    if (copyResetTimerRef.current) window.clearTimeout(copyResetTimerRef.current);
  }, []);

  return (
    <main className="app-shell">
      <aside className={`sidebar glass-panel ${sidebarOpen ? 'open' : ''}`} aria-label="Projects sidebar">
        <div className="brand-row">
          <img className="brand-icon" src="/remodex-ios-icon.png" alt="" />
          <div>
            <h1>Remodex</h1>
            <p>Web remote</p>
          </div>
        </div>

        <div className={`status-pill ${connectionState}`}>
          <span className="status-dot" />
          {connectionState}
        </div>
        <p className="status-copy">{statusDetail}</p>

        {!connected && (
          <section className="pairing-card">
            <label>Pairing payload</label>
            <textarea
              value={pairingInput}
              onChange={(event) => setPairingInput(event.target.value)}
              placeholder='Paste QR payload JSON: { "v": 2, "relay": "ws://.../relay", ... }'
            />
            <div className="button-row">
              <button className="primary" onClick={handlePairingSubmit}>Connect</button>
              {pairing && <button onClick={() => void connectWithPairing()}>Use saved</button>}
              <button onClick={async () => {
                autoConnectSuppressedRef.current = false;
                const bootstrapPairing = await fetchBootstrapPairing();
                if (bootstrapPairing) {
                  setPairing(bootstrapPairing);
                  await connectWithPairing(bootstrapPairing);
                } else {
                  setStatusDetail('No local bootstrap endpoint found at /local-web/bootstrap or 127.0.0.1:8787.');
                }
              }}>Auto</button>
            </div>
          </section>
        )}

        <div className="sidebar-actions">
          <button className="primary" disabled={!connected} onClick={() => void createThread()}>New chat</button>
          <button disabled={!connected} onClick={() => void openProjectPicker()}>New project</button>
          <button disabled={!connected} onClick={() => void refreshThreads()}>Refresh</button>
        </div>

        <nav className="project-list" aria-label="Projects and channels">
          {projectGroups.map((group) => {
            const collapsed = collapsedProjects.has(group.key);
            const hasActiveThread = group.threads.some((thread) => thread.id === activeThreadId);
            return (
              <section className="project-group" key={group.key}>
                <button
                  className={hasActiveThread ? 'project-header active' : 'project-header'}
                  onClick={() => toggleProject(group.key)}
                  aria-expanded={!collapsed}
                >
                  <FolderIcon />
                  <span className="project-name">{group.name}</span>
                  <span className="project-count">{group.threads.length}</span>
                  <span className="project-chevron">{collapsed ? '›' : '⌄'}</span>
                </button>
                {!collapsed && (
                  <div className="channel-list">
                    {group.threads.map((thread) => (
                      <button
                        key={thread.id}
                        className={thread.id === activeThreadId ? 'channel-row active' : 'channel-row'}
                        onClick={() => void openThread(thread.id)}
                      >
                        <span className="channel-title">{displayThreadTitle(thread, timeline[thread.id])}</span>
                        <time>{formatRelativeTime(thread.updatedAt)}</time>
                      </button>
                    ))}
                  </div>
                )}
              </section>
            );
          })}
        </nav>

        <button className="subtle" onClick={forgetPairing}>Forget pairing</button>
      </aside>
      {sidebarOpen && <button className="sidebar-backdrop" type="button" aria-label="Close sidebar" onClick={() => setSidebarOpen(false)} />}

      <section className="conversation glass-panel">
        <header className="conversation-header">
          <button
            className="mobile-menu-button"
            type="button"
            aria-label="Open project menu"
            aria-expanded={sidebarOpen}
            onClick={() => setSidebarOpen(true)}
          >
            <MenuIcon />
          </button>
          <div className="conversation-title">
            <p className="eyebrow">Current thread</p>
            <h2>{activeThreadTitle}</h2>
            <span>{activeThread?.cwd || 'Local Mac runtime through relay + bridge'}</span>
          </div>
          <div className="thread-runtime-summary">
            <span>{providerLabel}</span>
            <span>{displayModelName(selectedModel?.model || activeThread?.model || selectedModelId)}</span>
            <span>{displayReasoningLabel(effectiveReasoningEffort)}</span>
          </div>
        </header>

        <div className="timeline">
          {activeItems.length === 0 ? (
            <div className="empty-state">
              <div className="empty-icon">⌘</div>
              <h3>Start from your Mac context</h3>
              <p>Connect with the bridge pairing payload, open a chat, or create a project from a local folder.</p>
            </div>
          ) : activeItems.map((item) => (
            <article key={item.id} className={`message ${item.role} ${item.kind}`}>
              <div className="message-meta">
                <span>{item.role}</span>
                <small>{item.kind}</small>
              </div>
              <MarkdownContent text={item.text} />
              <footer className="message-footer">
                <time className="message-time" dateTime={formatMessageDateTime(item.createdAt)}>
                  {formatMessageTime(item.createdAt)}
                </time>
                <button
                  className="message-copy"
                  type="button"
                  aria-label="复制这条消息"
                  title="复制"
                  onClick={() => void copyMessageText(item)}
                >
                  <CopyIcon />
                  <span>{copiedMessageId === item.id ? '已复制' : '复制'}</span>
                </button>
              </footer>
            </article>
          ))}
        </div>

        <footer className="composer-shell">
          <section className="composer-card" aria-label="Chat composer">
            {(composerAttachments.length > 0 || selectedSkillMentions.length > 0) && (
              <div className="attachment-strip">
                {composerAttachments.map((attachment) => (
                  <span className={`attachment-chip ${attachment.kind}`} key={attachment.id}>
                    <AttachmentIcon kind={attachment.kind} />
                    <span>{attachment.name}</span>
                    <button type="button" aria-label={`移除 ${attachment.name}`} onClick={() => removeAttachment(attachment.id)}>×</button>
                  </span>
                ))}
                {selectedSkillMentions.map((mention) => (
                  <span className="attachment-chip skill" key={mention.id}>
                    <PluginIcon />
                    <span>{mention.name || mention.id}</span>
                    <button type="button" aria-label={`移除插件 ${mention.name || mention.id}`} onClick={() => removeSkillMention(mention.id)}>×</button>
                  </span>
                ))}
              </div>
            )}
            <textarea
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
                  event.preventDefault();
                  void sendDraft();
                }
              }}
              placeholder="要求后续变更"
              disabled={!connected}
            />
            <div className="composer-toolbar">
              <div className="composer-left-tools">
                <input
                  ref={fileInputRef}
                  type="file"
                  multiple
                  className="visually-hidden"
                  accept="image/*,.txt,.md,.markdown,.json,.js,.jsx,.ts,.tsx,.css,.html,.py,.swift,.sh,.yaml,.yml,.toml,.xml,.csv"
                  onChange={(event) => {
                    void handleAttachmentInput(event.currentTarget.files);
                    event.currentTarget.value = '';
                  }}
                />
                <div className="composer-menu-wrap">
                  <button
                    className="composer-icon-button"
                    type="button"
                    title="更多输入选项"
                    aria-haspopup="menu"
                    aria-expanded={composerMenuOpen}
                    disabled={!connected}
                    onClick={() => {
                      setComposerMenuOpen((current) => !current);
                      setPluginMenuOpen(false);
                      setPermissionMenuOpen(false);
                    }}
                  >
                    +
                  </button>
                  {composerMenuOpen && !pluginMenuOpen && (
                    <div className="composer-popover input-popover" role="menu" aria-label="输入选项">
                      <button className="composer-popover-row" type="button" role="menuitem" onClick={openAttachmentPicker}>
                        <PaperclipIcon />
                        <span>添加照片和文件</span>
                      </button>
                      <button className="composer-popover-row" type="button" role="menuitem" onClick={togglePlanMode}>
                        <SlidersIcon />
                        <span>计划模式</span>
                        <span className={`composer-switch ${planModeEnabled ? 'on' : ''}`} aria-hidden="true" />
                      </button>
                      <button
                        className="composer-popover-row"
                        type="button"
                        role="menuitem"
                        onClick={openPluginPicker}
                      >
                        <PluginIcon />
                        <span>插件</span>
                        <ChevronRightIcon />
                      </button>
                    </div>
                  )}
                  {composerMenuOpen && pluginMenuOpen && (
                    <div className="composer-popover plugin-popover" role="menu" aria-label="插件">
                      <div className="composer-popover-header">
                        <button className="composer-popover-back" type="button" onClick={() => setPluginMenuOpen(false)}>‹</button>
                        <span>插件</span>
                        <button className="composer-popover-refresh" type="button" onClick={() => void loadSkills(true)}>刷新</button>
                      </div>
                      {isLoadingSkills && (
                        <button className="composer-popover-row" type="button" disabled>
                          <PluginIcon />
                          <span>正在加载插件…</span>
                        </button>
                      )}
                      {!isLoadingSkills && availableSkills.length === 0 && (
                        <button className="composer-popover-row" type="button" disabled>
                          <PluginIcon />
                          <span>没有可用插件</span>
                        </button>
                      )}
                      {!isLoadingSkills && availableSkills.map((skill) => {
                        const selected = selectedSkillMentions.some((mention) => mention.id === skill.name);
                        return (
                          <button
                            className={`composer-popover-row skill-row ${selected ? 'selected' : ''}`}
                            type="button"
                            role="menuitemcheckbox"
                            aria-checked={selected}
                            disabled={!skill.enabled}
                            key={skill.name}
                            onClick={() => toggleSkillMention(skill)}
                          >
                            <PluginIcon />
                            <span>
                              <strong>{skill.name}</strong>
                              {skill.description && <small>{skill.description}</small>}
                            </span>
                            {selected && <CheckIcon />}
                          </button>
                        );
                      })}
                    </div>
                  )}
                </div>
                <div className="composer-menu-wrap">
                  <button
                    className="composer-security-button"
                    type="button"
                    title={`访问模式：${accessModeTitle(selectedAccessMode)}`}
                    aria-haspopup="menu"
                    aria-expanded={permissionMenuOpen}
                    disabled={!connected}
                    onClick={() => {
                      setPermissionMenuOpen((current) => !current);
                      setComposerMenuOpen(false);
                    }}
                  >
                    <ShieldIcon />
                    <ChevronIcon />
                  </button>
                  {permissionMenuOpen && (
                    <div className="composer-popover permission-popover" role="menu" aria-label="访问模式">
                      {(['default', 'auto-review', 'full-access'] as AccessMode[]).map((accessMode) => (
                        <button
                          className={`composer-popover-row ${selectedAccessMode === accessMode ? 'selected' : ''}`}
                          type="button"
                          role="menuitemradio"
                          aria-checked={selectedAccessMode === accessMode}
                          key={accessMode}
                          onClick={() => chooseAccessMode(accessMode)}
                        >
                          {accessMode === 'default' ? <HandIcon /> : <ShieldIcon />}
                          <span>{accessModeTitle(accessMode)}</span>
                          {selectedAccessMode === accessMode && <CheckIcon />}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              </div>

              <div className="composer-runtime-tools">
                <span className="provider-pill">{providerLabel}</span>
                <span className={`runtime-spinner ${activeThreadRunning || isSending ? 'active' : ''}`} aria-hidden="true" />
                <label className="runtime-select">
                  <select
                    value={selectedModelId}
                    disabled={!connected || isLoadingModels}
                    onChange={(event) => {
                      const nextModelId = event.target.value;
                      const nextModel = selectedModelOption(availableModels, nextModelId);
                      setSelectedModelId(nextModelId);
                      if (nextModel) setSelectedReasoningEffort(selectedReasoningEffortForModel(nextModel, selectedReasoningEffort) ?? '');
                    }}
                    aria-label="选择模型"
                  >
                    {availableModels.map((model) => (
                      <option key={model.id} value={model.id}>{displayModelName(model.model)}</option>
                    ))}
                  </select>
                </label>
                <label className="runtime-select reasoning">
                  <select
                    value={effectiveReasoningEffort || ''}
                    disabled={!connected || reasoningOptions.length === 0}
                    onChange={(event) => setSelectedReasoningEffort(event.target.value)}
                    aria-label="选择推理强度"
                  >
                    {reasoningOptions.length === 0 ? (
                      <option value="">推理</option>
                    ) : reasoningOptions.map((option) => (
                      <option key={option.reasoningEffort} value={option.reasoningEffort}>
                        {displayReasoningLabel(option.reasoningEffort)}
                      </option>
                    ))}
                  </select>
                </label>
                <ChevronIcon />
              </div>

              {activeThreadRunning ? (
                <button className="composer-send-button stop" type="button" title="Stop" disabled={!connected || !activeThreadId} onClick={() => void stopTurn()}>
                  <StopIcon />
                </button>
              ) : (
                <button
                  className="composer-send-button"
                  type="button"
                  title="发送"
                  disabled={!connected || isSending || (!draft.trim() && composerAttachments.length === 0 && selectedSkillMentions.length === 0)}
                  onClick={() => void sendDraft()}
                >
                  <ArrowUpIcon />
                </button>
              )}
            </div>
          </section>
        </footer>
      </section>

      {projectPickerOpen && (
        <div className="modal-backdrop">
          <section className="project-picker" role="dialog" aria-modal="true" aria-labelledby="project-picker-title">
            <header className="project-picker-header">
              <div>
                <p className="eyebrow">Local folders</p>
                <h2 id="project-picker-title">New project</h2>
              </div>
              <button className="icon-button" type="button" aria-label="Close project picker" onClick={() => setProjectPickerOpen(false)}>
                ×
              </button>
            </header>

            <div className="current-directory-card">
              <FolderIcon />
              <div>
                <strong>{projectBrowser?.directory.name || 'Loading folders…'}</strong>
                <span>{projectBrowser?.directory.path || 'Reading from your Mac through the bridge.'}</span>
              </div>
            </div>

            <div className="directory-actions">
              <button
                type="button"
                disabled={isProjectBrowserLoading || !projectBrowser?.parentDirectory}
                onClick={() => projectBrowser?.parentDirectory && void loadProjectDirectory(projectBrowser.parentDirectory.path)}
              >
                上一级
              </button>
              <button
                className="primary"
                type="button"
                disabled={isProjectBrowserLoading || isCreatingProject || !projectBrowser?.directory}
                onClick={() => void createProjectFromCurrentDirectory()}
              >
                {isCreatingProject ? 'Creating…' : '用此文件夹新建项目'}
              </button>
            </div>

            <div className="directory-list" aria-busy={isProjectBrowserLoading}>
              {isProjectBrowserLoading && <p className="directory-hint">正在读取文件夹…</p>}
              {!isProjectBrowserLoading && projectBrowser?.children.length === 0 && (
                <p className="directory-hint">这个文件夹下面没有可进入的子文件夹，可以直接使用当前文件夹。</p>
              )}
              {!isProjectBrowserLoading && projectBrowser?.children.map((directory) => (
                <button
                  key={directory.path}
                  type="button"
                  className="directory-row"
                  onClick={() => void loadProjectDirectory(directory.path)}
                >
                  <FolderIcon />
                  <span>{directory.name}</span>
                  <small>{directory.path}</small>
                </button>
              ))}
            </div>
          </section>
        </div>
      )}
    </main>
  );
}

function groupThreadsByProject(threads: ThreadSummary[]): ProjectGroup[] {
  const groups = new Map<string, ProjectGroup>();
  for (const thread of threads) {
    const key = thread.cwd || 'unknown-project';
    const existing = groups.get(key);
    if (existing) {
      existing.threads.push(thread);
    } else {
      groups.set(key, {
        key,
        name: projectName(thread.cwd),
        cwd: thread.cwd,
        threads: [thread],
      });
    }
  }
  return Array.from(groups.values());
}

function displayThreadTitle(thread: ThreadSummary, items: TimelineItem[] = []): string {
  const fallbackTitle = titleFromTimelineItems(items);
  if (fallbackTitle && shouldUseFallbackThreadTitle(thread.title)) return fallbackTitle;
  if (shouldUseFallbackThreadTitle(thread.title)) return 'New chat';
  return thread.title;
}

function selectedModelOption(models: ModelOption[], selectedModelId?: string): ModelOption | null {
  if (!selectedModelId) return defaultModelOption(models);
  return models.find((model) => model.id === selectedModelId || model.model === selectedModelId) ?? defaultModelOption(models);
}

function defaultModelOption(models: ModelOption[]): ModelOption | null {
  return models.find((model) => model.isDefault) ?? models[0] ?? null;
}

function selectedReasoningEffortForModel(model: ModelOption | null, selectedEffort?: string): string | null {
  if (!model) return null;
  const efforts = model.supportedReasoningEfforts.map((option) => option.reasoningEffort);
  if (!efforts.length) return null;
  if (selectedEffort && efforts.includes(selectedEffort)) return selectedEffort;
  if (model.defaultReasoningEffort && efforts.includes(model.defaultReasoningEffort)) return model.defaultReasoningEffort;
  if (efforts.includes('xhigh')) return 'xhigh';
  if (efforts.includes('medium')) return 'medium';
  return efforts[0];
}

function displayModelName(model?: string): string {
  const normalized = (model || '').trim();
  if (!normalized) return 'Model';
  return normalized
    .replace(/^gpt-/i, '')
    .replace(/-mini$/i, ' mini')
    .replace(/-codex$/i, ' codex');
}

function displayReasoningLabel(effort?: string | null): string {
  const normalized = (effort || '').trim().toLowerCase();
  switch (normalized) {
    case 'minimal':
    case 'low':
      return '低';
    case 'medium':
      return '中';
    case 'high':
      return '高';
    case 'xhigh':
    case 'extra_high':
    case 'extra-high':
    case 'very_high':
    case 'very-high':
      return '超高';
    default:
      return normalized ? normalized.replace(/_/g, ' ') : '推理';
  }
}

function accessModeTitle(accessMode: AccessMode): string {
  switch (accessMode) {
    case 'auto-review':
      return '自动审查';
    case 'full-access':
      return '完全访问权限';
    default:
      return '默认权限';
  }
}

async function readComposerAttachment(file: File): Promise<ComposerAttachment> {
  const base = {
    id: crypto.randomUUID(),
    name: file.name,
    mimeType: file.type || 'application/octet-stream',
    size: file.size,
  };

  if (file.type.startsWith('image/')) {
    return {
      ...base,
      kind: 'image',
      dataUrl: await readFileAsDataUrl(file),
    };
  }

  if (file.size > MAX_TEXT_ATTACHMENT_BYTES) {
    return {
      ...base,
      kind: 'file',
      error: `文件超过 ${formatBytes(MAX_TEXT_ATTACHMENT_BYTES)}，未内联内容。`,
    };
  }

  try {
    return {
      ...base,
      kind: 'file',
      text: await file.text(),
    };
  } catch {
    return {
      ...base,
      kind: 'file',
      error: '无法读取该文件内容。',
    };
  }
}

function readFileAsDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ''));
    reader.onerror = () => reject(reader.error || new Error('Could not read file.'));
    reader.readAsDataURL(file);
  });
}

function buildOutboundInput(input: string, attachments: ComposerAttachment[]): string {
  const fileBlocks = attachments
    .filter((attachment) => attachment.kind === 'file')
    .map(formatFileAttachmentForPrompt)
    .filter(Boolean);
  return [input.trim(), ...fileBlocks].filter(Boolean).join('\n\n');
}

function buildDisplayInput(input: string, attachments: ComposerAttachment[], skills: TurnSkillMention[]): string {
  const summary = attachmentSummary(attachments);
  const skillSummaryText = skillSummary(skills);
  if (!summary && !skillSummaryText) return input.trim();
  return [input.trim() || '已选择上下文', summary, skillSummaryText].filter(Boolean).join('\n\n');
}

function imageAttachmentsForTurn(attachments: ComposerAttachment[]): TurnImageAttachment[] {
  return attachments
    .filter((attachment) => attachment.kind === 'image' && attachment.dataUrl)
    .map((attachment) => ({
      name: attachment.name,
      mimeType: attachment.mimeType,
      dataUrl: attachment.dataUrl!,
    }));
}

function attachmentSummary(attachments: ComposerAttachment[]): string {
  if (!attachments.length) return '';
  const names = attachments.map((attachment) => `${attachment.kind === 'image' ? '照片' : '文件'}：${attachment.name}`);
  return `附件：${names.join('、')}`;
}

function skillSummary(skills: TurnSkillMention[]): string {
  if (!skills.length) return '';
  return `插件：${skills.map((skill) => skill.name || skill.id).join('、')}`;
}

function formatFileAttachmentForPrompt(attachment: ComposerAttachment): string {
  const header = `Attached file: ${attachment.name} (${attachment.mimeType}, ${formatBytes(attachment.size)})`;
  if (attachment.error) return `${header}\n${attachment.error}`;
  const text = attachment.text?.trim();
  if (!text) return `${header}\n文件为空或无可读取文本内容。`;
  return `${header}\n\n\`\`\`\n${text}\n\`\`\``;
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${Math.round(value / 102.4) / 10} KB`;
  return `${Math.round(value / 1024 / 102.4) / 10} MB`;
}

function projectName(cwd?: string): string {
  if (!cwd) return 'No project';
  const normalized = cwd.replace(/\/+$/g, '');
  const parts = normalized.split('/');
  return parts[parts.length - 1] || normalized;
}

function formatRelativeTime(value?: string): string {
  if (!value) return '';
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return '';
  const elapsedMs = Math.max(0, Date.now() - timestamp);
  const minute = 60_000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (elapsedMs < minute) return '刚刚';
  if (elapsedMs < hour) return `${Math.max(1, Math.floor(elapsedMs / minute))} 分钟`;
  if (elapsedMs < day) return `${Math.max(1, Math.floor(elapsedMs / hour))} 小时`;
  return `${Math.max(1, Math.floor(elapsedMs / day))} 天`;
}

function formatMessageTime(value: number): string {
  if (!Number.isFinite(value)) return '';
  return new Intl.DateTimeFormat('zh-CN', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(value));
}

function formatMessageDateTime(value: number): string {
  if (!Number.isFinite(value)) return '';
  return new Date(value).toISOString();
}

async function writeClipboardText(text: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const textarea = document.createElement('textarea');
  textarea.value = text;
  textarea.setAttribute('readonly', 'true');
  textarea.style.position = 'fixed';
  textarea.style.left = '-9999px';
  document.body.appendChild(textarea);
  textarea.select();
  const copied = document.execCommand('copy');
  document.body.removeChild(textarea);
  if (!copied) throw new Error('Copy failed');
}

function FolderIcon() {
  return (
    <svg className="folder-icon" viewBox="0 0 20 20" aria-hidden="true">
      <path d="M2.75 5.75A2.25 2.25 0 0 1 5 3.5h3.35c.52 0 1.01.2 1.38.57l1.18 1.18H15A2.25 2.25 0 0 1 17.25 7.5v6A2.25 2.25 0 0 1 15 15.75H5a2.25 2.25 0 0 1-2.25-2.25V5.75Z" />
    </svg>
  );
}

function CopyIcon() {
  return (
    <svg className="copy-icon" viewBox="0 0 18 18" aria-hidden="true">
      <path d="M6.25 5.25a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2h-4a2 2 0 0 1-2-2v-4Z" />
      <path d="M4.75 6.75H4.5a2 2 0 0 0-2 2v4a2 2 0 0 0 2 2h4a2 2 0 0 0 2-2v-.25" />
    </svg>
  );
}

function MenuIcon() {
  return (
    <svg className="menu-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M5 8h14" />
      <path d="M5 16h10" />
    </svg>
  );
}

function PaperclipIcon() {
  return (
    <svg className="composer-small-icon" viewBox="0 0 18 18" aria-hidden="true">
      <path d="m7.1 9.45 3.95-3.95a2.3 2.3 0 0 1 3.25 3.25l-5.15 5.15a3.25 3.25 0 0 1-4.6-4.6l5.35-5.35a1.2 1.2 0 0 1 1.7 0" />
    </svg>
  );
}

function SlidersIcon() {
  return (
    <svg className="composer-small-icon" viewBox="0 0 18 18" aria-hidden="true">
      <path d="M4 5.25h10" />
      <path d="M4 12.75h10" />
      <path d="M7 3.75v3" />
      <path d="M11 11.25v3" />
    </svg>
  );
}

function PluginIcon() {
  return (
    <svg className="composer-small-icon" viewBox="0 0 18 18" aria-hidden="true">
      <path d="M4.25 4.25h3.2v3.2h-3.2z" />
      <path d="M10.55 4.25h3.2v3.2h-3.2z" />
      <path d="M4.25 10.55h3.2v3.2h-3.2z" />
      <path d="M10.55 10.55h3.2v3.2h-3.2z" />
    </svg>
  );
}

function HandIcon() {
  return (
    <svg className="composer-small-icon" viewBox="0 0 18 18" aria-hidden="true">
      <path d="M6.25 8.4V4.85a1 1 0 0 1 2 0v3.2" />
      <path d="M8.25 8V3.95a1 1 0 0 1 2 0V8" />
      <path d="M10.25 8.25V5.05a1 1 0 0 1 2 0v4.3" />
      <path d="M6.25 8.6 5.3 7.65a1.08 1.08 0 0 0-1.55 1.5l3 3.75a4.1 4.1 0 0 0 3.2 1.55h.6a3.7 3.7 0 0 0 3.7-3.7v-2.9a1 1 0 0 0-2 0" />
    </svg>
  );
}

function ShieldIcon() {
  return (
    <svg className="composer-small-icon" viewBox="0 0 18 18" aria-hidden="true">
      <path d="M9 2.5 13.4 4v3.15c0 3.1-1.74 5.83-4.4 7.15-2.66-1.32-4.4-4.05-4.4-7.15V4L9 2.5Z" />
      <path d="m7.2 8.85 1.1 1.1 2.5-2.75" />
    </svg>
  );
}

function ChevronIcon() {
  return (
    <svg className="chevron-icon" viewBox="0 0 12 12" aria-hidden="true">
      <path d="m3 4.5 3 3 3-3" />
    </svg>
  );
}

function ChevronRightIcon() {
  return (
    <svg className="chevron-icon right" viewBox="0 0 12 12" aria-hidden="true">
      <path d="m4.5 3 3 3-3 3" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg className="composer-small-icon check-icon" viewBox="0 0 18 18" aria-hidden="true">
      <path d="m4.5 9.4 2.85 2.85L13.5 5.8" />
    </svg>
  );
}

function ArrowUpIcon() {
  return (
    <svg className="send-icon" viewBox="0 0 20 20" aria-hidden="true">
      <path d="M10 15.5v-11" />
      <path d="m5.5 9 4.5-4.5L14.5 9" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg className="send-icon" viewBox="0 0 20 20" aria-hidden="true">
      <path d="M7 7h6v6H7z" />
    </svg>
  );
}

function AttachmentIcon({ kind }: { kind: ComposerAttachment['kind'] }) {
  return (
    <svg className="attachment-icon" viewBox="0 0 18 18" aria-hidden="true">
      {kind === 'image' ? (
        <>
          <path d="M3.25 4.5a1.75 1.75 0 0 1 1.75-1.75h8A1.75 1.75 0 0 1 14.75 4.5v9A1.75 1.75 0 0 1 13 15.25H5a1.75 1.75 0 0 1-1.75-1.75v-9Z" />
          <path d="m4 12 3-3 2.15 2.15 1.35-1.35L14 13.25" />
          <path d="M11.75 6.25h.01" />
        </>
      ) : (
        <>
          <path d="M5.25 2.75h5L13.75 6.3v6.45a2.5 2.5 0 0 1-2.5 2.5h-6a2.5 2.5 0 0 1-2.5-2.5v-7.5a2.5 2.5 0 0 1 2.5-2.5Z" />
          <path d="M10.25 2.9v2.35c0 .7.55 1.25 1.25 1.25h2.1" />
        </>
      )}
    </svg>
  );
}
