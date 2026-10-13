// Markdown for the file viewer: a repository's own .md files, rendered as a document.
//
// The input is UNTRUSTED. A README can carry raw HTML, and this panel runs under a CSP
// that must allow inline script (the bundle IS inline), so an `<img onerror=...>` that
// reached the DOM would execute inside the terminal's process with the bridge in reach.
// Three rules close that, and each is enforced here rather than by a later pass:
//
//   1. Raw HTML is never emitted. Its tags are dropped and only its text is shown,
//      escaped, so a README's centred header reads as its words (the maintainer's call,
//      2026-09-29) and no tag or attribute the document wrote reaches the DOM.
//   2. A link carries no live href. Its target sits in `data-href` and the panel decides
//      what a click means (`resolveLink`); the anchor itself cannot navigate anywhere.
//   3. Images are not fetched. The CSP would refuse anything but data: anyway, so an
//      image renders as its alt text rather than as a broken frame.

import { Marked, type Tokens } from "marked";

export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * The text of a raw HTML fragment: tags and comments dropped, whitespace collapsed.
 *
 * A string pass, not a parser, and that is enough because its output is escaped before
 * it is emitted: whatever a malformed tag leaves behind shows as characters, never as
 * markup. Entities stay as written; decoding them is the one step that could turn text
 * back into a tag.
 */
function htmlText(fragment: string): string {
  return fragment
    .replace(/<!--[\s\S]*?(-->|$)/g, " ")
    .replace(/<[^>]*>?/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const marked = new Marked({
  gfm: true,
  renderer: {
    html(token: Tokens.HTML | Tokens.Tag): string {
      const words = htmlText(token.text);
      if (words === "") return "";
      return "block" in token && token.block ? `<p>${escapeHtml(words)}</p>\n` : escapeHtml(words);
    },
    link({ href, title, tokens }: Tokens.Link): string {
      const label = this.parser.parseInline(tokens);
      const titleAttr = title ? ` title="${escapeHtml(title)}"` : "";
      return `<a class="md-link" data-href="${escapeHtml(href)}"${titleAttr}>${label}</a>`;
    },
    image({ text }: Tokens.Image): string {
      return `<span class="md-image">[${escapeHtml(text || "image")}]</span>`;
    },
  },
});

/**
 * Block tags that take their direction from their own first strong character, so a
 * Hebrew paragraph reads right to left inside an English document and the other way
 * round. A list and a table turn as a whole, bullets and columns with the text, and
 * their items and cells inherit: `dir="auto"` skips every descendant that has a `dir`
 * of its own, so directing the items too left the list with nothing to read and it
 * stayed left to right (measured in the review shot).
 */
const DIRECTED_BLOCK = /<(p|h[1-6]|ul|ol|table)(?=[\s>])/g;

/** Markdown source to HTML that is safe to assign to innerHTML under the rules above. */
export function renderMarkdown(source: string): string {
  // `async: false` makes the return type a string; the parse is synchronous either way.
  const html = marked.parse(source, { async: false });
  // Safe as a string pass because rule 1 already ran: every `<` the document wrote is
  // `&lt;` by now, so each tag this matches is one marked generated.
  return html.replace(DIRECTED_BLOCK, '<$1 dir="auto"');
}

/** What clicking a markdown link should do. */
export type LinkTarget =
  | { readonly kind: "file"; readonly path: string }
  | { readonly kind: "external"; readonly url: string }
  | { readonly kind: "anchor" }
  | { readonly kind: "refused" };

const SCHEME = /^[a-z][a-z0-9+.-]*:/i;

/**
 * Resolves a link found in the file at `fromFile` (relative to the panel root).
 *
 * A relative path resolves against that file's directory, a leading `/` against the
 * root, and anything that climbs above the root is refused here as well as by the host:
 * the host is the boundary, but a panel that asks for paths it cannot have is a panel
 * that shows an error where it should have shown nothing.
 */
export function resolveLink(fromFile: string, href: string): LinkTarget {
  const trimmed = href.trim();
  if (trimmed === "" || trimmed.startsWith("#")) return { kind: "anchor" };
  if (SCHEME.test(trimmed)) {
    return /^(https?|mailto):/i.test(trimmed)
      ? { kind: "external", url: trimmed }
      : { kind: "refused" };
  }
  const bare = trimmed.split("#")[0]?.split("?")[0] ?? "";
  let decoded: string;
  try {
    decoded = decodeURIComponent(bare);
  } catch {
    // A malformed escape is a broken link in the document, not an error in the panel.
    return { kind: "refused" };
  }
  const base = decoded.startsWith("/") ? [] : fromFile.split("/").slice(0, -1);
  const parts = [...base];
  for (const segment of decoded.split("/")) {
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      if (parts.length === 0) return { kind: "refused" };
      parts.pop();
      continue;
    }
    parts.push(segment);
  }
  return parts.length === 0 ? { kind: "refused" } : { kind: "file", path: parts.join("/") };
}
