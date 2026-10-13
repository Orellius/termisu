// Monaco, set up once for the file viewer: read only, every Monarch grammar, and its
// editor worker inlined so nothing is fetched.
//
// The worker is a blob: URL built from inlined source, which is why the panel CSP
// carries `worker-src blob:` (docs/decisions/2026-09-29-agent-workspace-scope.md,
// measured in P0). Without it Monaco falls back to running worker code on the main
// thread, with a console warning and a UI that can stall on a large file.

import * as monaco from "monaco-editor/editor/editor.api";
import "monaco-editor/languages/definitions/register.all";
// editor.api alone is a bare text surface: no find, no folding, no copy action, no
// icons. These are the features a read-only viewer uses; editing, language services,
// hover and link-following are deliberately absent (a followed link is a navigation,
// and the panel allows exactly one).
import "monaco-editor/features/codicon/register";
import "monaco-editor/features/find/register";
import "monaco-editor/features/folding/register";
import "monaco-editor/features/bracketMatching/register";
import "monaco-editor/features/clipboard/register";
import "monaco-editor/features/gotoLine/register";
import "monaco-editor/features/wordHighlighter/register";
import "monaco-editor/features/readOnlyMessage/register";
import "monaco-editor/features/multicursor/register";
import "monaco-editor/features/smartSelect/register";
import "monaco-editor/features/lineSelection/register";
import "monaco-editor/features/unicodeHighlighter/register";
import EditorWorker from "monaco-editor/editor/editor.worker?worker&inline";

(self as unknown as { MonacoEnvironment: monaco.Environment }).MonacoEnvironment = {
  getWorker: () => new EditorWorker(),
};

export { monaco };

const THEME = "termisu";

/** Defines the editor theme from the panel's CSS variables, which the host set at init. */
export function applyEditorTheme(): string {
  const css = getComputedStyle(document.documentElement);
  // `--panel` is a color-mix() expression, which Monaco cannot read. The resolved
  // background of an element that uses it can, so the editor takes the colour the
  // panel actually painted rather than a second copy of the arithmetic.
  const probe = document.createElement("div");
  probe.style.background = "var(--panel)";
  document.body.append(probe);
  const panel = toHex(getComputedStyle(probe).backgroundColor) ?? "#1e1e1e";
  probe.remove();
  const foreground = toHex(css.getPropertyValue("--fg").trim()) ?? "#e6e6e6";
  const dim = toHex(css.getPropertyValue("--dim").trim()) ?? "#8b8b96";
  monaco.editor.defineTheme(THEME, {
    base: "vs-dark",
    inherit: true,
    rules: [],
    colors: {
      "editor.background": panel,
      "editor.foreground": foreground,
      "editorLineNumber.foreground": dim,
      "editorGutter.background": panel,
    },
  });
  return THEME;
}

/**
 * `#rrggbb`, `rgb(r, g, b)` or `color(srgb r g b)` to `#rrggbb`, or null for anything
 * else. The last form is how WebKit reports a resolved color-mix(), which is what
 * `--panel` is.
 */
function toHex(value: string): string | null {
  if (/^#[0-9a-f]{6}$/i.test(value)) return value;
  const hex = (channel: number) =>
    Math.round(Math.min(255, Math.max(0, channel))).toString(16).padStart(2, "0");
  const rgb = /^rgba?\((\d+),\s*(\d+),\s*(\d+)/i.exec(value);
  if (rgb !== null) return `#${hex(Number(rgb[1]))}${hex(Number(rgb[2]))}${hex(Number(rgb[3]))}`;
  const srgb = /^color\(srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/i.exec(value);
  if (srgb !== null) {
    return `#${hex(Number(srgb[1]) * 255)}${hex(Number(srgb[2]) * 255)}${hex(Number(srgb[3]) * 255)}`;
  }
  return null;
}

/** The Monaco language for a path, from the extensions and filenames grammars declare. */
export function languageFor(path: string): string {
  const name = path.slice(path.lastIndexOf("/") + 1).toLowerCase();
  const dot = name.lastIndexOf(".");
  const extension = dot > 0 ? name.slice(dot) : "";
  for (const language of monaco.languages.getLanguages()) {
    if ((language.filenames ?? []).some((candidate) => candidate.toLowerCase() === name)) {
      return language.id;
    }
    if (extension !== "" && (language.extensions ?? []).some((e) => e.toLowerCase() === extension)) {
      return language.id;
    }
  }
  return "plaintext";
}

/**
 * How many lines a grammar actually coloured.
 *
 * `monaco.editor.tokenize` runs the Monarch tokenizer synchronously and needs no frame,
 * which is what lets a headless smoke prove highlighting: a window that is never shown
 * gets no requestAnimationFrame, so the rendered rows of an editor cannot be the
 * evidence there (measured in P0).
 */
export async function tokenizedLineCount(text: string, language: string): Promise<number> {
  // tokenize throws on a language nobody registered, and a throw here would lose the
  // whole viewerState report rather than say "nothing was coloured".
  if (language === "plaintext" || !monaco.languages.getLanguages().some((l) => l.id === language)) {
    return 0;
  }
  // Grammars register lazily: the first tokenize of a language only triggers loading
  // its tokenizer and answers with plain tokens. There is no public "loaded" event, so
  // this asks again until colour appears or the budget runs out, and a grammar that
  // never loads reports 0 rather than hanging the caller.
  const count = () =>
    monaco.editor
      .tokenize(text, language)
      .filter((line) => line.some((token) => token.type !== "" && !token.type.startsWith("white")))
      .length;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const lines = count();
    if (lines > 0) return lines;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return count();
}

/**
 * Whether the codicon font loads here. Asked explicitly: a font nothing has drawn with
 * yet reads "unloaded" whether or not the CSP would admit it (measured in P1).
 */
export function probeIcons(): Promise<"ok" | "blocked"> {
  return document.fonts.load("16px codicon").then(
    (faces) => (faces.length > 0 ? "ok" : "blocked"),
    () => "blocked",
  );
}

/** Whether a blob worker can start and answer here, which is what Monaco's worker needs. */
export function probeWorker(): Promise<"ok" | "blocked"> {
  return new Promise((resolve) => {
    let worker: Worker;
    try {
      const source = URL.createObjectURL(
        new Blob(["onmessage = (e) => postMessage(e.data)"], { type: "text/javascript" }),
      );
      worker = new Worker(source);
    } catch {
      resolve("blocked");
      return;
    }
    const timer = setTimeout(() => {
      worker.terminate();
      resolve("blocked");
    }, 3000);
    worker.onmessage = () => {
      clearTimeout(timer);
      worker.terminate();
      resolve("ok");
    };
    worker.onerror = () => {
      clearTimeout(timer);
      worker.terminate();
      resolve("blocked");
    };
    worker.postMessage("ping");
  });
}
