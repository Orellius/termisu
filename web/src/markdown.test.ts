import { describe, expect, test } from "bun:test";
import { renderMarkdown, resolveLink } from "./markdown";

describe("renderMarkdown", () => {
  test("renders ordinary markdown", () => {
    const html = renderMarkdown("# Title\n\nSome **bold** and `code`.");
    expect(html).toContain('<h1 dir="auto">Title</h1>');
    expect(html).toContain("<strong>bold</strong>");
    expect(html).toContain("<code>code</code>");
  });

  test("block html shows its text only", () => {
    const html = renderMarkdown('<div onclick="x()">hi</div>');
    expect(html).not.toContain("<div");
    expect(html).not.toContain("onclick");
    expect(html).toContain('<p dir="auto">hi</p>');
  });

  test("inline html shows its text only, the onerror shape included", () => {
    const html = renderMarkdown('text <img src=x onerror="alert(1)"> more');
    expect(html).not.toContain("<img");
    expect(html).not.toContain("onerror");
    expect(html).toContain("text");
    expect(html).toContain("more");
  });

  test("a README's centred header reads as its words", () => {
    const html = renderMarkdown('<p align="center">\n  <img src="icon.png" alt="icon" />\n</p>\n<h1 align="center">Termisu</h1>');
    expect(html).not.toContain("align");
    expect(html).not.toContain("<img");
    expect(html).toContain("Termisu");
  });

  test("script and malformed tags leave only escaped characters", () => {
    const html = renderMarkdown('<script>alert("x")</script>\n\na <img src=x onerror=alert(1)//');
    expect(html).not.toContain("<script");
    expect(html).not.toContain("<img");
    expect(html).toContain("alert(&quot;x&quot;)");
  });

  test("a link carries no live href", () => {
    const html = renderMarkdown("[go](javascript:alert(1)) [doc](docs/a.md)");
    expect(html).not.toContain(" href=");
    expect(html).toContain('data-href="javascript:alert(1)"');
    expect(html).toContain('data-href="docs/a.md"');
  });

  test("an image renders as its alt text and is never fetched", () => {
    const html = renderMarkdown("![diagram](https://example.com/x.png)");
    expect(html).not.toContain("<img");
    expect(html).toContain("[diagram]");
  });

  test("each block takes its own direction, lists and tables included", () => {
    const html = renderMarkdown("# כותרת\n\nפסקה\n\n- אחד\n\n| א | ב |\n| - | - |\n| 1 | 2 |");
    expect(html).toContain('<h1 dir="auto">');
    expect(html).toContain('<p dir="auto">');
    expect(html).toContain('<ul dir="auto">');
    expect(html).toContain('<table dir="auto">');
    // Items and cells inherit; a `dir` of their own would hide their text from the
    // container's auto resolution.
    expect(html).toContain("<li>");
    expect(html).not.toContain('<td dir=');
  });

  test("direction is never added inside text the document wrote", () => {
    const html = renderMarkdown("`<p>` and <p>raw</p>");
    expect(html).not.toContain('&lt;p dir="auto"');
    expect(html.match(/dir="auto"/g)?.length).toBe(1);
  });

  test("code blocks keep their text escaped", () => {
    const html = renderMarkdown("```html\n<script>x</script>\n```");
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
  });
});

describe("resolveLink", () => {
  test("relative to the file's own directory", () => {
    expect(resolveLink("docs/guide/a.md", "b.md")).toEqual({ kind: "file", path: "docs/guide/b.md" });
    expect(resolveLink("docs/guide/a.md", "../c.md#part")).toEqual({ kind: "file", path: "docs/c.md" });
  });

  test("a leading slash is the root", () => {
    expect(resolveLink("docs/a.md", "/src/main.rs")).toEqual({ kind: "file", path: "src/main.rs" });
  });

  test("climbing above the root is refused", () => {
    expect(resolveLink("a.md", "../outside.md")).toEqual({ kind: "refused" });
    expect(resolveLink("docs/a.md", "../../etc/passwd")).toEqual({ kind: "refused" });
  });

  test("schemes: web and mail are external, everything else refused", () => {
    expect(resolveLink("a.md", "https://example.com")).toEqual({ kind: "external", url: "https://example.com" });
    expect(resolveLink("a.md", "mailto:x@example.com").kind).toBe("external");
    expect(resolveLink("a.md", "javascript:alert(1)")).toEqual({ kind: "refused" });
    expect(resolveLink("a.md", "file:///etc/passwd")).toEqual({ kind: "refused" });
    expect(resolveLink("a.md", "data:text/html,x")).toEqual({ kind: "refused" });
  });

  test("anchors and malformed escapes", () => {
    expect(resolveLink("a.md", "#section")).toEqual({ kind: "anchor" });
    expect(resolveLink("a.md", "%E0%A4%A.md")).toEqual({ kind: "refused" });
    expect(resolveLink("a.md", "my%20notes.md")).toEqual({ kind: "file", path: "my notes.md" });
  });
});
