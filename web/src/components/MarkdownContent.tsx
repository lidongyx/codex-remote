import type { ReactNode } from 'react';

interface MarkdownContentProps {
  text: string;
}

type MarkdownBlock =
  | { type: 'code'; language: string; text: string }
  | { type: 'heading'; level: number; text: string }
  | { type: 'list'; ordered: boolean; items: string[] }
  | { type: 'quote'; text: string }
  | { type: 'paragraph'; text: string };

export function MarkdownContent({ text }: MarkdownContentProps) {
  const blocks = parseMarkdown(text);
  return (
    <div className="markdown-content">
      {blocks.map((block, blockIndex) => renderBlock(block, `block-${blockIndex}`))}
    </div>
  );
}

function renderBlock(block: MarkdownBlock, key: string): ReactNode {
  if (block.type === 'code') {
    return (
      <pre key={key} className={`code-block language-${safeLanguageClass(block.language)}`}>
        <code>{highlightCode(block.text, block.language)}</code>
      </pre>
    );
  }
  if (block.type === 'heading') {
    const Tag = (`h${Math.min(3, Math.max(1, block.level))}`) as 'h1' | 'h2' | 'h3';
    return <Tag key={key}>{renderInline(block.text, key)}</Tag>;
  }
  if (block.type === 'list') {
    const ListTag = block.ordered ? 'ol' : 'ul';
    return (
      <ListTag key={key}>
        {block.items.map((item, itemIndex) => (
          <li key={`${key}-item-${itemIndex}`}>{renderInline(item, `${key}-item-${itemIndex}`)}</li>
        ))}
      </ListTag>
    );
  }
  if (block.type === 'quote') {
    return <blockquote key={key}>{renderInline(block.text, key)}</blockquote>;
  }
  return <p key={key}>{renderInline(block.text, key)}</p>;
}

function parseMarkdown(text: string): MarkdownBlock[] {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const blocks: MarkdownBlock[] = [];
  let lineIndex = 0;

  while (lineIndex < lines.length) {
    const line = lines[lineIndex];
    const trimmed = line.trim();
    if (!trimmed) {
      lineIndex += 1;
      continue;
    }

    const fence = trimmed.match(/^```([A-Za-z0-9_+-]*)\s*$/);
    if (fence) {
      const language = fence[1] || '';
      lineIndex += 1;
      const codeLines: string[] = [];
      while (lineIndex < lines.length && !lines[lineIndex].trim().startsWith('```')) {
        codeLines.push(lines[lineIndex]);
        lineIndex += 1;
      }
      if (lineIndex < lines.length) lineIndex += 1;
      blocks.push({ type: 'code', language, text: codeLines.join('\n') });
      continue;
    }

    const heading = trimmed.match(/^(#{1,3})\s+(.+)$/);
    if (heading) {
      blocks.push({ type: 'heading', level: heading[1].length, text: heading[2] });
      lineIndex += 1;
      continue;
    }

    const unordered = trimmed.match(/^[-*]\s+(.+)$/);
    if (unordered) {
      const items: string[] = [];
      while (lineIndex < lines.length) {
        const item = lines[lineIndex].trim().match(/^[-*]\s+(.+)$/);
        if (!item) break;
        items.push(item[1]);
        lineIndex += 1;
      }
      blocks.push({ type: 'list', ordered: false, items });
      continue;
    }

    const ordered = trimmed.match(/^\d+[.)]\s+(.+)$/);
    if (ordered) {
      const items: string[] = [];
      while (lineIndex < lines.length) {
        const item = lines[lineIndex].trim().match(/^\d+[.)]\s+(.+)$/);
        if (!item) break;
        items.push(item[1]);
        lineIndex += 1;
      }
      blocks.push({ type: 'list', ordered: true, items });
      continue;
    }

    const quote = trimmed.match(/^>\s+(.+)$/);
    if (quote) {
      const quoteLines: string[] = [];
      while (lineIndex < lines.length) {
        const item = lines[lineIndex].trim().match(/^>\s+(.+)$/);
        if (!item) break;
        quoteLines.push(item[1]);
        lineIndex += 1;
      }
      blocks.push({ type: 'quote', text: quoteLines.join('\n') });
      continue;
    }

    const paragraphLines: string[] = [];
    while (lineIndex < lines.length && lines[lineIndex].trim() && !isMarkdownBlockStart(lines[lineIndex])) {
      paragraphLines.push(lines[lineIndex].trim());
      lineIndex += 1;
    }
    blocks.push({ type: 'paragraph', text: paragraphLines.join('\n') });
  }

  return blocks;
}

function isMarkdownBlockStart(line: string): boolean {
  const trimmed = line.trim();
  return /^```/.test(trimmed)
    || /^#{1,3}\s+/.test(trimmed)
    || /^[-*]\s+/.test(trimmed)
    || /^\d+[.)]\s+/.test(trimmed)
    || /^>\s+/.test(trimmed);
}

function renderInline(text: string, keyPrefix: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const pattern = /(`[^`]+`|\*\*[^*]+\*\*|\[[^\]]+\]\([^)]+\))/g;
  let cursor = 0;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(text)) !== null) {
    if (match.index > cursor) {
      nodes.push(...renderPlainText(text.slice(cursor, match.index), `${keyPrefix}-text-${nodes.length}`));
    }
    const token = match[0];
    if (token.startsWith('`')) {
      nodes.push(<code className="inline-code" key={`${keyPrefix}-code-${nodes.length}`}>{token.slice(1, -1)}</code>);
    } else if (token.startsWith('**')) {
      nodes.push(<strong key={`${keyPrefix}-strong-${nodes.length}`}>{token.slice(2, -2)}</strong>);
    } else {
      const link = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      if (link) {
        nodes.push(
          <a key={`${keyPrefix}-link-${nodes.length}`} href={link[2]} target="_blank" rel="noreferrer">
            {link[1]}
          </a>,
        );
      } else {
        nodes.push(token);
      }
    }
    cursor = match.index + token.length;
  }

  if (cursor < text.length) {
    nodes.push(...renderPlainText(text.slice(cursor), `${keyPrefix}-tail-${nodes.length}`));
  }
  return nodes;
}

function renderPlainText(text: string, keyPrefix: string): ReactNode[] {
  const parts = text.split('\n');
  return parts.flatMap((part, partIndex) => {
    if (partIndex === 0) return [part];
    return [<br key={`${keyPrefix}-br-${partIndex}`} />, part];
  });
}

function highlightCode(code: string, language: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const pattern = /(\/\*[\s\S]*?\*\/|\/\/[^\n]*|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b(?:async|await|break|case|catch|class|const|continue|default|do|else|export|for|from|function|if|import|in|interface|let|new|return|switch|throw|try|type|var|while)\b|\b(?:true|false|null|undefined)\b|\b\d+(?:\.\d+)?\b|--?[A-Za-z][A-Za-z0-9-]*)/g;
  let cursor = 0;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(code)) !== null) {
    if (match.index > cursor) nodes.push(code.slice(cursor, match.index));
    const token = match[0];
    nodes.push(
      <span className={syntaxClass(token, language)} key={`syntax-${match.index}-${nodes.length}`}>
        {token}
      </span>,
    );
    cursor = match.index + token.length;
  }

  if (cursor < code.length) nodes.push(code.slice(cursor));
  return nodes;
}

function syntaxClass(token: string, language: string): string {
  const normalizedLanguage = language.toLowerCase();
  if (/^(\/\*|\/\/|#)/.test(token)) return 'syntax-comment';
  if (/^["'`]/.test(token)) return normalizedLanguage === 'json' && /^"\w/.test(token) ? 'syntax-string' : 'syntax-string';
  if (/^\d/.test(token)) return 'syntax-number';
  if (/^(true|false|null|undefined)$/.test(token)) return 'syntax-literal';
  if (/^--?/.test(token)) return 'syntax-flag';
  return 'syntax-keyword';
}

function safeLanguageClass(language: string): string {
  return language.toLowerCase().replace(/[^a-z0-9_-]/g, '') || 'text';
}
