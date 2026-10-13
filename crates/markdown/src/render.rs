//! Purpose: turn a markdown document into styled terminal text for a given width.
//! Public surface: `render`.
//! Why it is shaped this way: pulldown-cmark does the parsing (CommonMark plus GFM tables,
//!   task lists and strikethrough) and this module only lays the events out. Output is SGR
//!   styles, OSC 8 hyperlinks and the box-drawing tables from `layout`, wrapped here to the
//!   width in display columns, so the terminal never re-wraps a styled line. The terminal does
//!   bidi, so a Hebrew paragraph needs nothing beyond width-correct wrapping.
//! Safety: the document is data. Every control byte it carries is printed as its visible
//!   Control Pictures stand-in, raw HTML is shown as its text, and only http, https and mailto
//!   targets become hyperlinks, so no document can send an escape sequence to the terminal.
//! Look: quotes are an indent plus dim italic, with no bar down the side.

use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::{layout, Align, Table};

/// Colours for inline code and code blocks. Both are set, so the shade reads on a light
/// theme as well as a dark one.
const CODE: &str = "38;5;252;48;5;236";
/// Text colours from the terminal's own palette, so they follow its theme. Weight and slant
/// alone are not enough: many terminals, Termisu among them, draw neither, so every kind of
/// emphasis also gets a colour.
const LINK: &str = "34";
const HEADING: &str = "95";
const STRONG: &str = "97";
const EMPHASIS: &str = "33";
const TAB: usize = 4;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Style {
    bold: bool,
    dim: bool,
    italic: bool,
    underline: bool,
    strike: bool,
    /// An SGR foreground, ignored under `code`, which sets its own.
    fg: Option<&'static str>,
    code: bool,
    /// The OSC 8 target, only when it passed `link_target`.
    link: Option<String>,
}

impl Style {
    fn sgr(&self) -> String {
        let mut codes = Vec::new();
        for (on, code) in [
            (self.bold, "1"),
            (self.dim, "2"),
            (self.italic, "3"),
            (self.underline, "4"),
            (self.strike, "9"),
            (!self.code && self.fg.is_some(), self.fg.unwrap_or("")),
            (self.code, CODE),
        ] {
            if on {
                codes.push(code);
            }
        }
        codes.join(";")
    }
}

/// A run of text in one style. A lone `"\n"` is a hard line break.
struct Span {
    text: String,
    style: Style,
}

enum Container {
    Quote,
    Item { marker: String, used: bool },
}

#[derive(Default)]
struct TableBuild {
    aligns: Vec<Align>,
    header: Vec<String>,
    rows: Vec<Vec<String>>,
    row: Vec<String>,
    cell: String,
}

struct Renderer {
    width: usize,
    out: Vec<String>,
    /// A blank line goes before the next block.
    gap: bool,
    containers: Vec<Container>,
    inline: Vec<Span>,
    bold: u32,
    italic: u32,
    strike: u32,
    faint: u32,
    quote: u32,
    links: Vec<Option<String>>,
    heading: Option<HeadingLevel>,
    lists: Vec<Option<u64>>,
    code: Option<(String, String)>,
    table: Option<TableBuild>,
}

/// Renders `markdown` as terminal text no wider than `width` columns. Every line ends in
/// `\n`; an empty document renders as an empty string.
pub fn render(markdown: &str, width: usize) -> String {
    let mut r = Renderer {
        width: width.max(1),
        out: Vec::new(),
        gap: false,
        containers: Vec::new(),
        inline: Vec::new(),
        bold: 0,
        italic: 0,
        strike: 0,
        faint: 0,
        quote: 0,
        links: Vec::new(),
        heading: None,
        lists: Vec::new(),
        code: None,
        table: None,
    };
    let options = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    for event in Parser::new_ext(markdown, options) {
        r.event(event);
    }
    r.flush_inline();
    let mut text = r.out.join("\n");
    if !text.is_empty() {
        text.push('\n');
    }
    text
}

impl Renderer {
    fn event(&mut self, event: Event) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(t) | Event::InlineMath(t) | Event::DisplayMath(t) => self.text(&t),
            Event::Code(t) => self.inline_code(&t),
            Event::Html(t) | Event::InlineHtml(t) => self.html(&t),
            Event::FootnoteReference(t) => self.text(&format!("[^{t}]")),
            Event::SoftBreak => self.text(" "),
            Event::HardBreak => {
                if self.table.is_some() {
                    self.text(" ");
                } else {
                    self.inline.push(Span { text: "\n".into(), style: Style::default() });
                }
            }
            Event::Rule => {
                self.flush_inline();
                let rule = paint(&[("─".repeat(self.avail()), Style { dim: true, ..Style::default() })]);
                self.emit(vec![rule], true);
            }
            Event::TaskListMarker(done) => {
                if let Some(Container::Item { marker, .. }) = self.containers.last_mut() {
                    *marker = if done { "[✓] " } else { "[ ] " }.into();
                }
            }
        }
    }

    fn start(&mut self, tag: Tag) {
        match tag {
            Tag::Heading { level, .. } => {
                self.flush_inline();
                self.heading = Some(level);
            }
            Tag::BlockQuote(_) => {
                self.flush_inline();
                self.containers.push(Container::Quote);
                self.quote += 1;
            }
            Tag::CodeBlock(kind) => {
                self.flush_inline();
                let lang = match kind {
                    CodeBlockKind::Fenced(info) => info.split_whitespace().next().unwrap_or("").to_string(),
                    CodeBlockKind::Indented => String::new(),
                };
                self.code = Some((lang, String::new()));
            }
            Tag::HtmlBlock => {
                self.flush_inline();
            }
            Tag::List(first) => {
                self.flush_inline();
                self.lists.push(first);
            }
            Tag::Item => {
                self.flush_inline();
                let depth = self.lists.len();
                let marker = match self.lists.last_mut() {
                    Some(Some(n)) => {
                        let marker = format!("{n}. ");
                        *n += 1;
                        marker
                    }
                    _ => format!("{} ", ["•", "◦", "▪"][depth.saturating_sub(1).min(2)]),
                };
                self.containers.push(Container::Item { marker, used: false });
            }
            Tag::Table(aligns) => {
                self.flush_inline();
                let aligns = aligns
                    .iter()
                    .map(|a| match a {
                        pulldown_cmark::Alignment::Right => Align::Right,
                        pulldown_cmark::Alignment::Center => Align::Center,
                        _ => Align::Left,
                    })
                    .collect();
                self.table = Some(TableBuild { aligns, ..TableBuild::default() });
            }
            Tag::TableCell => {
                if let Some(t) = self.table.as_mut() {
                    t.cell.clear();
                }
            }
            Tag::Emphasis => self.italic += 1,
            Tag::Strong => self.bold += 1,
            Tag::Strikethrough => self.strike += 1,
            Tag::Link { dest_url, .. } => self.links.push(link_target(&dest_url)),
            Tag::Image { .. } => self.faint += 1,
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => self.flush_block(),
            TagEnd::Heading(_) => {
                self.flush_block();
                self.heading = None;
            }
            TagEnd::BlockQuote(_) => {
                self.flush_inline();
                self.containers.pop();
                self.quote -= 1;
                self.gap = true;
            }
            TagEnd::CodeBlock => {
                if let Some((lang, body)) = self.code.take() {
                    self.code_block(&lang, &body);
                }
            }
            TagEnd::HtmlBlock => self.flush_block(),
            TagEnd::List(_) => {
                self.flush_inline();
                self.lists.pop();
                // A nested list ending inside a tight item must not open a gap before the
                // next item; only the outermost list ends a block.
                if self.lists.is_empty() {
                    self.gap = true;
                }
            }
            TagEnd::Item => {
                self.flush_inline();
                self.containers.pop();
            }
            TagEnd::Table => {
                if let Some(t) = self.table.take() {
                    self.table_block(t);
                }
            }
            TagEnd::TableHead => {
                if let Some(t) = self.table.as_mut() {
                    t.header = std::mem::take(&mut t.row);
                }
            }
            TagEnd::TableRow => {
                if let Some(t) = self.table.as_mut() {
                    let row = std::mem::take(&mut t.row);
                    t.rows.push(row);
                }
            }
            TagEnd::TableCell => {
                if let Some(t) = self.table.as_mut() {
                    let cell = t.cell.trim().to_string();
                    t.row.push(cell);
                }
            }
            TagEnd::Emphasis => self.italic -= 1,
            TagEnd::Strong => self.bold -= 1,
            TagEnd::Strikethrough => self.strike -= 1,
            TagEnd::Link => {
                self.links.pop();
            }
            TagEnd::Image => self.faint -= 1,
            _ => {}
        }
    }

    fn style(&self) -> Style {
        let heading = self.heading.map(|h| match h {
            HeadingLevel::H1 => 1,
            HeadingLevel::H2 => 2,
            _ => 3,
        });
        let fg = if !self.links.is_empty() {
            Some(LINK)
        } else if matches!(heading, Some(1 | 2)) {
            Some(HEADING)
        } else if heading.is_some() || self.bold > 0 {
            Some(STRONG)
        } else if self.italic > 0 {
            Some(EMPHASIS)
        } else {
            None
        };
        Style {
            bold: self.bold > 0 || heading.is_some(),
            dim: self.quote > 0 || self.faint > 0,
            italic: self.italic > 0 || self.quote > 0,
            underline: !self.links.is_empty() || heading == Some(1),
            strike: self.strike > 0,
            fg,
            code: false,
            link: self.links.last().cloned().flatten(),
        }
    }

    fn text(&mut self, text: &str) {
        if let Some(t) = self.table.as_mut() {
            t.cell.push_str(&inert(text));
        } else if let Some((_, body)) = self.code.as_mut() {
            body.push_str(text);
        } else {
            let style = self.style();
            self.inline.push(Span { text: inert(text), style });
        }
    }

    fn inline_code(&mut self, text: &str) {
        if let Some(t) = self.table.as_mut() {
            t.cell.push_str(&inert(text));
        } else {
            let style = Style { code: true, ..self.style() };
            self.inline.push(Span { text: inert(text), style });
        }
    }

    /// Raw HTML is shown as its own text, dim, line for line. A block arrives one event per
    /// source line, each ending in `\n`, which closes that line.
    fn html(&mut self, text: &str) {
        if self.table.is_some() {
            self.text(text);
            return;
        }
        self.faint += 1;
        for piece in text.split_inclusive('\n') {
            let line = piece.strip_suffix('\n');
            self.text(line.unwrap_or(piece));
            if line.is_some() {
                self.inline.push(Span { text: "\n".into(), style: Style::default() });
            }
        }
        self.faint -= 1;
    }

    /// Columns the containers take on the left.
    fn indent(&self) -> usize {
        self.containers
            .iter()
            .map(|c| match c {
                Container::Quote => 2,
                Container::Item { marker, .. } => marker.width(),
            })
            .sum()
    }

    fn avail(&self) -> usize {
        self.width.saturating_sub(self.indent()).max(1)
    }

    /// The left margin for the next line. An item shows its marker on its first line only.
    fn prefix(&mut self) -> String {
        let mut prefix = String::new();
        for c in &mut self.containers {
            match c {
                Container::Quote => prefix.push_str("  "),
                Container::Item { marker, used } => {
                    if *used {
                        prefix.push_str(&" ".repeat(marker.width()));
                    } else {
                        prefix.push_str(marker);
                        *used = true;
                    }
                }
            }
        }
        prefix
    }

    fn emit(&mut self, lines: Vec<String>, gap_after: bool) {
        if lines.is_empty() {
            return;
        }
        if self.gap && !self.out.is_empty() {
            self.out.push(String::new());
        }
        for line in lines {
            let prefix = self.prefix();
            self.out.push(prefix + &line);
        }
        self.gap = gap_after;
    }

    /// Text of a tight list item: no gap after it, so the next item follows directly.
    fn flush_inline(&mut self) {
        if !self.inline.is_empty() {
            let spans = std::mem::take(&mut self.inline);
            let lines = wrap(&spans, self.avail());
            self.emit(lines, false);
        }
    }

    fn flush_block(&mut self) {
        let spans = std::mem::take(&mut self.inline);
        let lines = wrap(&spans, self.avail());
        self.emit(lines, true);
    }

    fn code_block(&mut self, lang: &str, body: &str) {
        let avail = self.avail();
        let inner = avail.saturating_sub(2).max(1);
        let band = Style { code: true, ..Style::default() };
        let mut lines = Vec::new();
        if !lang.is_empty() {
            lines.push(paint(&[(inert(lang), Style { dim: true, ..Style::default() })]));
        }
        let mut rows = Vec::new();
        for raw in body.lines() {
            rows.extend(chunks(&inert(&expand_tabs(raw)), inner));
        }
        if rows.is_empty() {
            rows.push(String::new());
        }
        for row in rows {
            let pad = inner.saturating_sub(row.width());
            lines.push(paint(&[(format!(" {row}{} ", " ".repeat(pad)), band.clone())]));
        }
        self.emit(lines, true);
    }

    fn table_block(&mut self, t: TableBuild) {
        let table = Table { header: t.header, aligns: t.aligns, rows: t.rows, line_count: 0 };
        let laid = layout(&table, self.avail());
        let last = laid.len().saturating_sub(1);
        let lines = laid
            .iter()
            .enumerate()
            .map(|(i, line)| match i {
                1 => paint_row(line, true),
                0 | 2 => paint(&[(line.clone(), Style { dim: true, ..Style::default() })]),
                i if i == last => paint(&[(line.clone(), Style { dim: true, ..Style::default() })]),
                _ => paint_row(line, false),
            })
            .collect();
        self.emit(lines, true);
    }
}

/// A data row of a laid-out table: dim rules, bold text for the header.
fn paint_row(line: &str, header: bool) -> String {
    let rule = Style { dim: true, ..Style::default() };
    let text = Style { bold: header, fg: header.then_some(STRONG), ..Style::default() };
    let mut segs = Vec::new();
    for (i, part) in line.split('│').enumerate() {
        if i > 0 {
            segs.push(("│".to_string(), rule.clone()));
        }
        if !part.is_empty() {
            segs.push((part.to_string(), text.clone()));
        }
    }
    paint(&segs)
}

/// Only web and mail targets become hyperlinks. A relative path or any other scheme keeps
/// its link styling but opens nothing, because a document should not choose what a click
/// launches on this machine.
fn link_target(url: &str) -> Option<String> {
    if url.chars().any(|c| c.is_control()) {
        return None;
    }
    let lower = url.to_ascii_lowercase();
    ["http://", "https://", "mailto:"]
        .iter()
        .any(|scheme| lower.starts_with(scheme))
        .then(|| url.to_string())
}

/// Makes document text safe to print: a C0 control shows as its Control Pictures glyph
/// (ESC as `␛`), DEL as `␡`, a C1 control as U+FFFD, and a tab as a space.
fn inert(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            '\t' => ' ',
            '\u{7f}' => '\u{2421}',
            c if (c as u32) < 0x20 => char::from_u32(0x2400 + c as u32).unwrap_or('\u{fffd}'),
            '\u{80}'..='\u{9f}' => '\u{fffd}',
            c => c,
        })
        .collect()
}

fn expand_tabs(line: &str) -> String {
    let mut out = String::new();
    let mut col = 0;
    for c in line.chars() {
        if c == '\t' {
            let n = TAB - col % TAB;
            out.push_str(&" ".repeat(n));
            col += n;
        } else {
            out.push(c);
            col += c.width().unwrap_or(0);
        }
    }
    out
}

/// Splits `text` into pieces no wider than `width` columns. A zero-width mark stays with
/// the character before it, and a character wider than `width` still gets a piece.
fn chunks(text: &str, width: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut w = 0;
    for c in text.chars() {
        let cw = c.width().unwrap_or(0);
        if cw > 0 && w > 0 && w + cw > width {
            out.push(std::mem::take(&mut cur));
            w = 0;
        }
        cur.push(c);
        w += cw;
    }
    if !cur.is_empty() || out.is_empty() {
        out.push(cur);
    }
    out
}

enum Atom {
    Word(Vec<(String, Style)>, usize),
    Space(Style),
    Break,
}

fn push_seg(segs: &mut Vec<(String, Style)>, text: &str, style: &Style) {
    match segs.last_mut() {
        Some((t, s)) if s == style => t.push_str(text),
        _ => segs.push((text.to_string(), style.clone())),
    }
}

/// Greedy word wrap of styled spans to `width` display columns. Runs of spaces collapse to
/// one, a space at the start of a line is dropped, and a word wider than the line is broken.
fn wrap(spans: &[Span], width: usize) -> Vec<String> {
    let mut atoms = Vec::new();
    let mut word = Vec::new();
    let mut word_w = 0;
    for span in spans {
        if span.text == "\n" {
            if !word.is_empty() {
                atoms.push(Atom::Word(std::mem::take(&mut word), word_w));
                word_w = 0;
            }
            atoms.push(Atom::Break);
            continue;
        }
        for c in span.text.chars() {
            if c == ' ' {
                if !word.is_empty() {
                    atoms.push(Atom::Word(std::mem::take(&mut word), word_w));
                    word_w = 0;
                }
                atoms.push(Atom::Space(span.style.clone()));
            } else {
                push_seg(&mut word, c.encode_utf8(&mut [0; 4]), &span.style);
                word_w += c.width().unwrap_or(0);
            }
        }
    }
    if !word.is_empty() {
        atoms.push(Atom::Word(word, word_w));
    }

    let mut lines = Vec::new();
    let mut line: Vec<(String, Style)> = Vec::new();
    let mut w = 0;
    let mut space: Option<Style> = None;
    for atom in atoms {
        match atom {
            Atom::Break => {
                lines.push(paint(&std::mem::take(&mut line)));
                w = 0;
                space = None;
            }
            Atom::Space(style) => {
                if w > 0 {
                    space = Some(style);
                }
            }
            Atom::Word(segs, ww) => {
                let sw = usize::from(space.is_some());
                if w > 0 && w + sw + ww > width {
                    lines.push(paint(&std::mem::take(&mut line)));
                    w = 0;
                    space = None;
                }
                if let Some(style) = space.take() {
                    push_seg(&mut line, " ", &style);
                    w += 1;
                }
                if w + ww <= width {
                    for (text, style) in &segs {
                        push_seg(&mut line, text, style);
                    }
                    w += ww;
                } else {
                    for (text, style) in &segs {
                        for c in text.chars() {
                            let cw = c.width().unwrap_or(0);
                            if cw > 0 && w > 0 && w + cw > width {
                                lines.push(paint(&std::mem::take(&mut line)));
                                w = 0;
                            }
                            push_seg(&mut line, c.encode_utf8(&mut [0; 4]), style);
                            w += cw;
                        }
                    }
                }
            }
        }
    }
    if !line.is_empty() {
        lines.push(paint(&line));
    }
    lines
}

/// Writes styled segments as escape sequences. Each segment opens and closes its own style
/// and link, so nothing leaks past the end of a line.
fn paint(segs: &[(String, Style)]) -> String {
    let mut out = String::new();
    for (text, style) in segs {
        let sgr = style.sgr();
        if let Some(url) = &style.link {
            out.push_str(&format!("\x1b]8;;{url}\x1b\\"));
        }
        if sgr.is_empty() {
            out.push_str(text);
        } else {
            out.push_str(&format!("\x1b[{sgr}m{text}\x1b[0m"));
        }
        if style.link.is_some() {
            out.push_str("\x1b]8;;\x1b\\");
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Makes escapes readable: `<1;4>` for an SGR, `</>` for a reset, `<a url>` and `</a>`
    /// for OSC 8.
    fn show(s: &str) -> String {
        let mut out = String::new();
        let mut rest = s;
        while let Some(i) = rest.find('\x1b') {
            out.push_str(&rest[..i]);
            rest = &rest[i..];
            if let Some(body) = rest.strip_prefix("\x1b[") {
                let end = body.find('m').expect("SGR ends in m");
                let codes = &body[..end];
                out.push_str(&if codes == "0" { "</>".to_string() } else { format!("<{codes}>") });
                rest = &body[end + 1..];
            } else if let Some(body) = rest.strip_prefix("\x1b]8;;") {
                let end = body.find("\x1b\\").expect("OSC 8 ends in ST");
                let url = &body[..end];
                out.push_str(&if url.is_empty() { "</a>".to_string() } else { format!("<a {url}>") });
                rest = &body[end + 2..];
            } else {
                panic!("unexpected escape in {s:?}");
            }
        }
        out.push_str(rest);
        out
    }

    fn md(text: &str, width: usize) -> String {
        show(&render(text, width))
    }

    const C: &str = "<38;5;252;48;5;236>";

    #[test]
    fn an_empty_document_prints_nothing() {
        assert_eq!(render("", 80), "");
    }

    #[test]
    fn a_paragraph_wraps_between_words_at_the_width() {
        assert_eq!(render("one two three four", 9), "one two\nthree\nfour\n");
    }

    #[test]
    fn a_word_wider_than_the_line_is_broken_not_overflowed() {
        assert_eq!(render("abcdefgh", 3), "abc\ndef\ngh\n");
    }

    #[test]
    fn hebrew_vowel_marks_take_no_width_when_wrapping() {
        // שָׁלוֹם is seven chars but four columns, so two of them fit a nine column line.
        assert_eq!(render("שָׁלוֹם שָׁלוֹם עולם", 9), "שָׁלוֹם שָׁלוֹם\nעולם\n");
    }

    #[test]
    fn soft_breaks_join_and_hard_breaks_split() {
        assert_eq!(render("a\nb", 80), "a b\n");
        assert_eq!(render("a  \nb", 80), "a\nb\n");
    }

    #[test]
    fn inline_styles_map_to_their_sgr() {
        assert_eq!(md("a **b** *c* ~~d~~ `e`", 80), format!("a <1;97>b</> <3;33>c</> <9>d</> {C}e</>\n"));
        // Code keeps its own colours inside bold, and a link's colour wins over emphasis.
        assert_eq!(md("**`x`** *[y](README.md)*", 80), format!("<1;{}>x</> <3;4;34>y</>\n", &C[1..C.len() - 1]));
    }

    #[test]
    fn headings_step_down_from_underlined_to_plain_bold() {
        assert_eq!(
            md("# Title\n\npara\n\n## Sub\n\n### Low", 80),
            "<1;4;95>Title</>\n\npara\n\n<1;95>Sub</>\n\n<1;97>Low</>\n"
        );
        // A link in a heading keeps the link colour, so it still reads as a link.
        assert_eq!(md("## see [x](README.md)", 80), "<1;95>see </><1;4;34>x</>\n");
    }

    #[test]
    fn a_web_link_is_an_osc8_hyperlink_in_exact_bytes() {
        assert_eq!(
            render("[x](https://e.com)", 80),
            "\x1b]8;;https://e.com\x1b\\\x1b[4;34mx\x1b[0m\x1b]8;;\x1b\\\n"
        );
    }

    #[test]
    fn only_web_and_mail_targets_become_hyperlinks() {
        assert_eq!(
            md("[a](mailto:x@e.com) [b](README.md) [c](javascript:alert(1))", 80),
            "<a mailto:x@e.com><4;34>a</></a> <4;34>b</> <4;34>c</>\n"
        );
    }

    #[test]
    fn a_link_that_wraps_carries_its_hyperlink_onto_both_lines() {
        assert_eq!(
            md("[aa bb](https://e.com)", 3),
            "<a https://e.com><4;34>aa</></a>\n<a https://e.com><4;34>bb</></a>\n"
        );
    }

    #[test]
    fn escape_bytes_in_the_document_print_as_visible_glyphs() {
        assert_eq!(render("a\x1b[31mb\x07 \u{9b}2J", 80), "a␛[31mb␇ \u{fffd}2J\n");
        assert_eq!(render("a\tb", 80), "a b\n");
        // CommonMark lets ESC into a link target through angle brackets and through a
        // character reference; neither may become an OSC 8 sequence.
        for doc in ["[x](<https://e.com/\x1b]8;;evil>)", "[x](https://e.com/&#27;]8;;evil)"] {
            let out = render(doc, 80);
            assert!(!out.contains("\x1b]8"), "{doc:?} gave {out:?}");
            assert_eq!(show(&out), "<4;34>x</>\n");
        }
        let code = render("```\n\x1b]0;title\x07\n```", 80);
        assert!(code.contains("␛]0;title␇"), "{code:?}");
        assert!(!code.contains("\x1b]"), "{code:?}");
        let table = render("| \x1b[2J |\n|---|", 80);
        assert!(table.contains("␛[2J") && !table.contains("\x1b[2J"), "{table:?}");
    }

    #[test]
    fn raw_html_is_shown_as_dim_text() {
        assert_eq!(md("<script>x</script>", 80), "<2><script>x</script></>\n");
        assert_eq!(md("a <b>x</b>", 80), "a <2><b></>x<2></b></>\n");
        assert_eq!(
            md("<div>\n<p>x y</p>\n</div>", 80),
            "<2><div></>\n<2><p>x y</p></>\n<2></div></>\n"
        );
    }

    #[test]
    fn an_image_shows_its_alt_text() {
        assert_eq!(md("![alt text](x.png)", 80), "<2>alt text</>\n");
        // An image with no alt text prints nothing, and leaves one blank line, not two.
        assert_eq!(md("a\n\n![](x.png)\n\nb", 80), "a\n\nb\n");
    }

    #[test]
    fn bullets_change_with_depth_and_tight_items_have_no_gap() {
        assert_eq!(
            md("- a\n- b\n  - c\n- d\n\n3. x\n4. y", 80),
            "• a\n• b\n  ◦ c\n• d\n\n3. x\n4. y\n"
        );
    }

    #[test]
    fn a_loose_list_keeps_its_blank_lines() {
        assert_eq!(md("- a\n\n- b", 80), "• a\n\n• b\n");
    }

    #[test]
    fn a_wrapped_item_continues_under_its_text() {
        assert_eq!(md("- aaa bbb", 7), "• aaa\n  bbb\n");
    }

    #[test]
    fn task_items_show_their_box() {
        assert_eq!(md("- [ ] todo\n- [x] done", 80), "[ ] todo\n[✓] done\n");
    }

    #[test]
    fn a_quote_is_an_indent_and_dim_italic_with_no_bar() {
        assert_eq!(md("> quoted text\n\nafter", 80), "  <2;3>quoted text</>\n\nafter\n");
    }

    #[test]
    fn a_code_block_is_a_shaded_band_under_its_language() {
        assert_eq!(
            md("```rust\nfn x() {}\n\tlet\n```", 20),
            format!("<2>rust</>\n{C} {:<18} </>\n{C} {:<18} </>\n", "fn x() {}", "    let")
        );
    }

    #[test]
    fn a_long_code_line_wraps_inside_the_band() {
        assert_eq!(md("```\nabcdefg\n```", 6), format!("{C} abcd </>\n{C} efg  </>\n"));
    }

    #[test]
    fn a_rule_spans_the_width() {
        assert_eq!(md("a\n\n---\n\nb", 5), "a\n\n<2>─────</>\n\nb\n");
    }

    #[test]
    fn a_table_has_dim_rules_and_a_bold_header() {
        assert_eq!(
            md("| a | b |\n|---|--:|\n| x | 10 |", 80),
            "<2>┌───┬────┐</>\n\
             <2>│</><1;97> a </><2>│</><1;97>  b </><2>│</>\n\
             <2>├───┼────┤</>\n\
             <2>│</> x <2>│</> 10 <2>│</>\n\
             <2>└───┴────┘</>\n"
        );
    }
}
