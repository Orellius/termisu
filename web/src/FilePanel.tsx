import { type MouseEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { send, subscribe } from "./bridge";
import { renderMarkdown, resolveLink } from "./markdown";
import { applyEditorTheme, languageFor, monaco, probeIcons, probeWorker, tokenizedLineCount } from "./monaco";
import type { DirEntry } from "./protocol";

interface Listing {
  readonly entries: readonly DirEntry[];
  readonly error: string | null;
}

interface Content {
  readonly path: string;
  readonly text: string;
  readonly error: string | null;
  /** The line to reveal, when the host opened this file at one. */
  readonly line: number | null;
}

/** One visible tree row, flattened so the arrow keys can walk what is on screen. */
interface VisibleRow {
  readonly path: string;
  readonly name: string;
  readonly depth: number;
  readonly isDirectory: boolean;
  readonly ignored: boolean;
}

const MARKDOWN = /\.(md|markdown|mdx)$/i;

function join(directory: string, name: string): string {
  return directory === "" ? name : `${directory}/${name}`;
}

function flatten(
  listings: ReadonlyMap<string, Listing>,
  expanded: ReadonlySet<string>,
  directory: string,
  depth: number,
  out: VisibleRow[],
): void {
  for (const entry of listings.get(directory)?.entries ?? []) {
    const path = join(directory, entry.name);
    out.push({ path, name: entry.name, depth, isDirectory: entry.isDirectory, ignored: entry.ignored });
    if (entry.isDirectory && expanded.has(path)) flatten(listings, expanded, path, depth + 1, out);
  }
}

/** Read-only Monaco. One editor for the panel's lifetime; each file is a fresh model. */
function CodeView({ content }: { content: Content }) {
  const host = useRef<HTMLDivElement>(null);
  const editor = useRef<monaco.editor.IStandaloneCodeEditor | null>(null);

  useEffect(() => {
    if (host.current === null) return;
    editor.current = monaco.editor.create(host.current, {
      readOnly: true,
      domReadOnly: true,
      theme: applyEditorTheme(),
      automaticLayout: true,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
      fontSize: 12,
      lineHeight: 18,
      renderLineHighlight: "none",
      // Hebrew in a comment is text, not a lookalike attack. Invisible characters
      // still are, so that half stays on.
      unicodeHighlight: { ambiguousCharacters: false, nonBasicASCII: false, invisibleCharacters: true },
      contextmenu: false,
    });
    return () => {
      editor.current?.getModel()?.dispose();
      editor.current?.dispose();
      editor.current = null;
    };
  }, []);

  useEffect(() => {
    const view = editor.current;
    if (view === null) return;
    const language = languageFor(content.path);
    const previous = view.getModel();
    const model = monaco.editor.createModel(content.text, language);
    view.setModel(model);
    previous?.dispose();
    // A line past the end means the file changed since it was printed; the last line is
    // the nearest honest place, and nothing jumps to a line that is not there.
    const line = content.line === null ? null : Math.min(content.line, model.getLineCount());
    if (line === null) {
      view.setScrollTop(0);
    } else {
      view.revealLineInCenter(line);
      view.setSelection(new monaco.Range(line, 1, line, model.getLineMaxColumn(line)));
    }
    // Paints the rows now rather than on the next animation frame. In the app that is a
    // frame sooner; where WebKit gives the page no frames (the review shot's window) it
    // is the difference between rows and a blank editor. Colours still arrive on a frame,
    // so the shot shows them uncoloured; `tokenizedLines` is the evidence for colour.
    view.render(true);
    // What the editor says it is on, not what was asked: the smoke checks the jump happened.
    reportState(content, language, line === null ? null : (view.getPosition()?.lineNumber ?? null));
  }, [content]);

  return <div className="code" ref={host} />;
}

function MarkdownView({
  content,
  onOpen,
}: {
  content: Content;
  onOpen: (path: string) => void;
}) {
  const html = useMemo(() => renderMarkdown(content.text), [content.text]);

  useEffect(() => {
    reportState(content, "markdown", null);
  }, [content]);

  const onClick = (event: MouseEvent<HTMLDivElement>) => {
    const anchor = (event.target as Element).closest("a.md-link");
    if (anchor === null) return;
    event.preventDefault();
    const target = resolveLink(content.path, anchor.getAttribute("data-href") ?? "");
    if (target.kind === "file") onOpen(target.path);
  };

  return (
    // The HTML is built by renderMarkdown, which escapes raw HTML and strips every live
    // href; see markdown.ts for why that is the whole safety argument.
    <div className="markdown" onClick={onClick} dangerouslySetInnerHTML={{ __html: html }} />
  );
}

/** Tells the host what is on screen. Only the headless smoke reads it. */
function reportState(content: Content, language: string, line: number | null): void {
  void Promise.all([tokenizedLineCount(content.text, language), probeWorker(), probeIcons()]).then(
    ([tokenizedLines, worker, icons]) =>
      send({
        kind: "viewerState",
        path: content.path,
        language,
        lines: content.text === "" ? 0 : content.text.split("\n").length,
        tokenizedLines,
        worker,
        icons,
        line,
      }),
  );
}

export function FilePanel() {
  const [root, setRoot] = useState<string | null>(null);
  const [rootError, setRootError] = useState<string | null>(null);
  const [listings, setListings] = useState<ReadonlyMap<string, Listing>>(new Map());
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());
  const [selected, setSelected] = useState<string | null>(null);
  const [content, setContent] = useState<Content | null>(null);
  const [source, setSource] = useState(false);
  const selectedRef = useRef<string | null>(null);
  const lineRef = useRef<number | null>(null);
  // Read by `reveal`, which runs from the subscription and must see the listings as they
  // are now rather than as they were when the subscription was made.
  const listingsRef = useRef(listings);
  listingsRef.current = listings;

  const open = useCallback((path: string, line: number | null = null) => {
    selectedRef.current = path;
    lineRef.current = line;
    setSelected(path);
    setContent(null);
    // A markdown file opened AT a line opens as source: a line number means nothing in the
    // rendered document.
    setSource(line !== null);
    send({ kind: "openFile", path });
  }, []);

  /** Expands every folder above `path`, asking for the listings not yet held. */
  const reveal = useCallback((path: string) => {
    const segments = path.split("/").slice(0, -1);
    const ancestors = segments.map((_, index) => segments.slice(0, index + 1).join("/"));
    if (ancestors.length === 0) return;
    setExpanded((current) => new Set([...current, ...ancestors]));
    for (const ancestor of ancestors) {
      if (!listingsRef.current.has(ancestor)) send({ kind: "listDirectory", path: ancestor });
    }
  }, []);

  const toggle = useCallback(
    (path: string) => {
      const opening = !expanded.has(path);
      setExpanded((current) => {
        const next = new Set(current);
        if (opening) next.add(path);
        else next.delete(path);
        return next;
      });
      // Outside the updater: React may run an updater twice, and a request is not
      // something to send twice.
      if (opening && !listings.has(path)) send({ kind: "listDirectory", path });
    },
    [expanded, listings],
  );

  useEffect(() => {
    return subscribe((message) => {
      switch (message.kind) {
        case "tree":
          setRoot(message.root);
          setRootError(message.error);
          break;
        case "directory":
          setListings((current) =>
            new Map(current).set(message.path, { entries: message.entries, error: message.error }),
          );
          break;
        case "select":
          // From the host, so the file may be anywhere: open it and show where it lives.
          reveal(message.path);
          open(message.path, message.line);
          break;
        case "fileContent":
          // A late reply for a file already navigated away from must not replace the
          // one on screen.
          if (message.path === selectedRef.current) {
            setContent({
              path: message.path,
              text: message.text,
              error: message.error,
              line: lineRef.current,
            });
          }
          break;
      }
    });
  }, [open, reveal]);

  const rows = useMemo(() => {
    const out: VisibleRow[] = [];
    flatten(listings, expanded, "", 0, out);
    return out;
  }, [listings, expanded]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        send({ kind: "dismiss" });
        return;
      }
      // The editor keeps its own keys; the tree only answers when it has focus.
      if ((event.target as Element | null)?.closest(".tree") === null) return;
      const at = rows.findIndex((row) => row.path === selected);
      const row = rows[at];
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const next = rows[Math.min(rows.length - 1, Math.max(0, at + (event.key === "ArrowDown" ? 1 : -1)))];
        if (next === undefined) return;
        if (next.isDirectory) {
          selectedRef.current = next.path;
          setSelected(next.path);
        } else {
          open(next.path);
        }
        document.querySelector(`[data-path="${CSS.escape(next.path)}"]`)?.scrollIntoView({ block: "nearest" });
      } else if ((event.key === "Enter" || event.key === "ArrowRight") && row?.isDirectory) {
        event.preventDefault();
        if (!expanded.has(row.path) || event.key === "Enter") toggle(row.path);
      } else if (event.key === "ArrowLeft" && row?.isDirectory && expanded.has(row.path)) {
        event.preventDefault();
        toggle(row.path);
      }
    };
    // Capture phase: Monaco stops propagation of keys it handles, and Escape has to
    // close the panel from anywhere in it.
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [rows, selected, expanded, open, toggle]);

  const rootListing = listings.get("");
  const isMarkdown = content !== null && MARKDOWN.test(content.path);

  return (
    <div className="panel">
      <div className="head">
        <span className="title">Files</span>
        {/* Isolated for the same reason as the diff panel's repo path: `.repo` is RTL so
            it truncates from the left, and a bare leading "/" would jump to the end. */}
        <span className="repo">&#x2068;{root ?? "no directory"}&#x2069;</span>
        {isMarkdown && (
          <button type="button" onClick={() => setSource((current) => !current)}>
            {source ? "Preview" : "Source"}
          </button>
        )}
        <button type="button" onClick={() => send({ kind: "refresh" })}>
          Refresh
        </button>
        <button type="button" onClick={() => send({ kind: "dismiss" })}>
          Close
        </button>
      </div>
      {rootError !== null && <p className="error">{rootError}</p>}
      <div className="body">
        <div className="files tree" tabIndex={0}>
          {rootListing?.error != null && <div className="empty">{rootListing.error}</div>}
          {rows.map((row) => (
            <button
              key={row.path}
              data-path={row.path}
              className={`file node${row.ignored ? " ignored" : ""}`}
              aria-selected={row.path === selected}
              aria-expanded={row.isDirectory ? expanded.has(row.path) : undefined}
              style={{ paddingLeft: 8 + row.depth * 14 }}
              onClick={() => (row.isDirectory ? toggle(row.path) : open(row.path))}
              title={row.path}
              type="button"
              tabIndex={-1}
            >
              <span className="twisty">
                {row.isDirectory && (
                  // Drawn rather than a ▸ glyph, which the UI font renders as a speck at
                  // this size. Rotated by CSS from aria-expanded.
                  <svg viewBox="0 0 8 8" width="8" height="8" aria-hidden="true">
                    <path d="M2.5 1 L5.5 4 L2.5 7" fill="none" stroke="currentColor" strokeWidth="1.4" />
                  </svg>
                )}
              </span>
              {/* Isolated left to right, so a Hebrew name keeps its extension at the end
                  (סיכום.md, not md.סיכום) and cannot reorder the row around it. */}
              <span className="name">&#x2066;{row.name}&#x2069;</span>
            </button>
          ))}
          {rootListing !== undefined && rootListing.entries.length === 0 && rootListing.error === null && (
            <div className="empty">empty directory</div>
          )}
        </div>
        <div className="viewer">
          {content === null ? (
            <div className="empty">{selected === null ? "pick a file" : "loading"}</div>
          ) : content.error !== null ? (
            <div className="empty">{content.error}</div>
          ) : isMarkdown && !source ? (
            <MarkdownView content={content} onOpen={open} />
          ) : (
            <CodeView content={content} />
          )}
        </div>
      </div>
    </div>
  );
}
