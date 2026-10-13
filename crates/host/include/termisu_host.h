/* termisu_host.h -- the embedder surface of libtermisu-vt-host.a.
 *
 * This is NOT part of the ghostty ABI mirror. The 13 `ghostty_*` entry points ride in the
 * same archive unchanged; this header is the small surface a GUI host needs on top of them:
 * spawn a shell on a pty, poll rendered pixels, send input bytes, resize. One handle wraps
 * the whole Rust pipeline (pty host -> frame channel -> GPU renderer).
 *
 * Threading contract: a TermisuHost is NOT thread-safe. Every call on one handle must come
 * from the same thread (in practice: the UI thread that polls and forwards key input).
 */

#ifndef TERMISU_HOST_H
#define TERMISU_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque. Create with termisu_host_spawn, destroy with termisu_host_free. */
typedef struct TermisuHost TermisuHost;

/* Opaque. Create with termisu_config_load, destroy with termisu_config_free. */
typedef struct TermisuConfig TermisuConfig;

typedef enum {
  TERMISU_HOST_SUCCESS = 0,
  /* A NULL pointer, a zero geometry, or an otherwise malformed argument. */
  TERMISU_HOST_INVALID_VALUE = 1,
  /* Opening the pty or starting the child failed. */
  TERMISU_HOST_SPAWN_FAILED = 2,
  /* The requested geometry exceeds the frame channel's fixed capacity. */
  TERMISU_HOST_RESIZE_REFUSED = 3,
  /* The renderer could not be built or could not draw (e.g. no GPU adapter, no fonts). */
  TERMISU_HOST_RENDER_FAILED = 4,
  /* Writing to the child failed (typically: the child is gone). */
  TERMISU_HOST_SEND_FAILED = 5,
  /* The call was valid but the protocol produced nothing: mouse reporting off, motion
   * deduplicated, or a wheel left to the embedder's viewport scroll. Not an error --
   * the embedder's own handling of the event is next. */
  TERMISU_HOST_IGNORED = 6,
  /* The argv carried a flag that turns an agent's approvals off. Nothing was spawned and
   * nothing was stripped: termisu_agent_screen on the same argv names the flag and its
   * position. */
  TERMISU_HOST_REFUSED = 7,
} TermisuHostResult;

/* termisu_host_mouse vocabularies. */
#define TERMISU_MOUSE_PRESS 0u
#define TERMISU_MOUSE_RELEASE 1u
#define TERMISU_MOUSE_MOTION 2u
#define TERMISU_MOUSE_BUTTON_NONE 0u
#define TERMISU_MOUSE_BUTTON_LEFT 1u
#define TERMISU_MOUSE_BUTTON_MIDDLE 2u
#define TERMISU_MOUSE_BUTTON_RIGHT 3u
#define TERMISU_MOUSE_MODS_SHIFT 1u
#define TERMISU_MOUSE_MODS_CTRL 2u
#define TERMISU_MOUSE_MODS_ALT 4u

typedef struct {
  uint16_t cols;
  uint16_t rows;
  /* Font size in pixels. 0 means the default (16). */
  float font_size;
  /* Shell command line, run via `/bin/sh -c`. NULL means an interactive $SHELL. */
  const char *command;
  /* When true, each row's base direction is detected from its own text (Hebrew-first
   * rows flow right-to-left; rows that resolve LTR are laid out exactly as with false).
   * False keeps the terminal default: left-to-right base, RTL runs reordered in place. */
  bool auto_direction;
  /* Contributes ONLY the theme palette; NULL keeps the built-in scheme. Read during the
   * spawn call and not retained -- freeing the config afterwards is legal. The scalar
   * settings are read through the termisu_config_* getters instead, because the embedder
   * owns their precedence (CLI flags, Retina scaling). */
  const TermisuConfig *config;
  /* Working directory for the child, or NULL for the default (home for an interactive
   * shell, the caller's cwd for an explicit command). A path that does not exist is
   * IGNORED rather than fatal: a bad cwd surfaces from exec as a bare ENOENT that looks
   * exactly like a missing shell, and a workspace whose directory vanished should still
   * open somewhere usable. S5 workspaces set this to a worktree. */
  const char *cwd;
} TermisuHostOptions;

/* One rendered frame, filled by termisu_host_poll. */
typedef struct {
  /* RGBA8, row-major, width*height*4 bytes. Borrowed: valid until the next poll, resize,
   * or free on the same handle. Never NULL after the first poll that drew. */
  const uint8_t *pixels;
  uint32_t width;
  uint32_t height;
  /* The frame channel generation the pixels were drawn from. */
  uint64_t generation;
  /* True when this poll drew new content. False means pixels/width/height still describe
   * the previous draw (or nothing yet, if no poll has drawn -- then pixels is NULL). */
  bool drew;
  /* True once the child has exited. Frames already published remain readable. */
  bool child_exited;
  /* The background the grid currently shows at its edge, RGBA -- the top-left cell's
   * resolved style, falling back to the renderer default before any frame. Painting
   * window margins with it makes the terminal read as continuing into the frame, and
   * it follows program backgrounds (vim themes, BCE clears) and future palette themes
   * alike. Never pixel-sampled: the corner pixel is the caret when the cursor is home. */
  uint8_t background[4];
  /* One byte per grid row (row_count of them): the row's shell-semantic class per
   * OSC 133 -- TERMISU_ROW_OUTPUT, TERMISU_ROW_PROMPT or TERMISU_ROW_INPUT. What a block
   * gutter draws from. Borrowed with the same lifetime as pixels: valid until the next
   * poll, resize, or free. NULL before the first drawn frame. */
  const uint8_t *row_semantics;
  uint32_t row_count;
  /* Rows the displayed view is scrolled up into history; 0 is the live bottom. Set by
   * the pump after clamping, so it reports where the view actually IS -- draw scroll
   * indicators from this, never from accumulated deltas. */
  uint32_t viewport_offset;
  /* The caret's cell in this frame, and whether it is shown. Ghost-suggestion
   * overlays anchor here; never re-derive the caret from pixels. */
  uint16_t cursor_col;
  uint16_t cursor_row;
  bool cursor_visible;
} TermisuHostFrame;

/* TermisuHostFrame.row_semantics values, and termisu_host_row_text filters. */
#define TERMISU_ROW_OUTPUT 0
#define TERMISU_ROW_PROMPT 1
#define TERMISU_ROW_INPUT 2
/* termisu_host_row_text only: take every cell regardless of its OSC 133 mark. */
#define TERMISU_TEXT_ALL 255

/* Spawns the command on a fresh pty and starts the parse/publish pipeline.
 *
 * options and out must be non-NULL. On success writes the new handle to *out and returns
 * TERMISU_HOST_SUCCESS; on any failure writes NULL to *out. */
TermisuHostResult termisu_host_spawn(const TermisuHostOptions *options, TermisuHost **out);

/* Reads the latest published frame and, if it is new, draws it.
 *
 * host and out must be non-NULL and host must be live. Cheap when nothing changed. */
TermisuHostResult termisu_host_poll(TermisuHost *host, TermisuHostFrame *out);

/* The strip behind the tab band (option 2 of the top blur, 2026-10-02): the history rows
 * directly above the viewport, then the viewport's own first `overlap` pixel rows, drawn with
 * the session's font and palette and box-blurred by `radius` pixels as one image. The GUI lays
 * the overlap exactly over the sharp rows and fades it out, so blur never meets text at an
 * edge. RGBA, width * height * 4 bytes, borrowed until the next call, resize, font change or
 * free; NULL before the first strip. generation rises only when the pixels changed.
 * alternate_screen is set when the child is on the alternate screen, which keeps no history. */
typedef struct {
  const uint8_t *pixels;
  uint32_t width;
  uint32_t height;
  uint32_t overlap;
  uint64_t generation;
  bool alternate_screen;
} TermisuHostStrip;

TermisuHostResult termisu_host_strip(TermisuHost *host, uint32_t radius, TermisuHostStrip *out);

/* The caret as a one-cell RGBA image (the block with the cell's glyph, exactly as the grid
 * paints it) and the cell it belongs on (visual column, viewport row), from the last polled
 * frame. pixels are borrowed until the next call, resize, font change or free; NULL before
 * the first. visible is false when the child hid the cursor. generation rises on any change. */
typedef struct {
  const uint8_t *pixels;
  uint32_t width;
  uint32_t height;
  uint16_t column;
  uint16_t row;
  bool visible;
  uint64_t generation;
} TermisuHostCaret;

TermisuHostResult termisu_host_caret(TermisuHost *host, TermisuHostCaret *out);

/* Whether the grid paints its own caret (the default). Pass false when the GUI draws the
 * caret from termisu_host_caret; the next poll repaints everything without it. */
TermisuHostResult termisu_host_set_caret(TermisuHost *host, bool painted);

/* The history rows directly above the viewport, drawn sharp, for pixel scrolling: the rows
 * a view shifted down by part of a row shows in the gap at its top. rows rows, newest at the
 * bottom; the bottom `above` of them are real history, the rest blank padding. viewport is the
 * offset they sit above, so a GUI pairs them only with a grid frame of the same offset.
 * pixels are borrowed until the next call, resize, font change or free; NULL before the
 * first. generation rises on any change. */
typedef struct {
  const uint8_t *pixels;
  uint32_t width;
  uint32_t height;
  uint16_t rows;
  uint16_t above;
  uint32_t viewport;
  uint64_t generation;
} TermisuHostLead;

TermisuHostResult termisu_host_lead(TermisuHost *host, TermisuHostLead *out);

/* Writes bytes to the child's input. This is the Host::send seam: key encodings from the
 * GUI and (in slice 9) DSR/DA replies both travel through it.
 *
 * bytes may be NULL only when len is 0. */
TermisuHostResult termisu_host_send(TermisuHost *host, const uint8_t *bytes, size_t len);

/* Encodes clipboard bytes for the child and writes them to the pty. Pass raw clipboard
 * bytes: unsafe control bytes become spaces (xterm's strip set), and the data is wrapped
 * in the bracketed-paste fenceposts when the child enabled mode 2004, or has newlines
 * folded to carriage returns when it did not. The mode rides the last polled frame, so
 * poll at least once after the child enables it -- a rendering host does continuously.
 *
 * bytes may be NULL only when len is 0. */
TermisuHostResult termisu_host_paste(TermisuHost *host, const uint8_t *bytes, size_t len);

/* Sets the view geometry mouse encoding converts through: surface size and content
 * insets, in the same backing-pixel space the frame's pixels use. Call after layout
 * changes (resize, zoom, inset change); until the first call, pointer events answer
 * TERMISU_HOST_IGNORED. */
TermisuHostResult termisu_host_mouse_geometry(TermisuHost *host, uint32_t screen_width,
                                          uint32_t screen_height, uint32_t padding_left,
                                          uint32_t padding_top, uint32_t padding_right,
                                          uint32_t padding_bottom);

/* Feeds one pointer event to mouse reporting. action/button/mods use the TERMISU_MOUSE_*
 * constants (buttons 4..9 are the protocol's wheel/aux codes); x/y are surface pixels
 * from the view's top-left. Success means a report was written to the pty; IGNORED
 * means the protocol produced nothing and the event is the embedder's again
 * (selection, menus). Send press/release pairs even while reporting is off -- held-
 * button bookkeeping happens on every call. Modes ride the last polled frame. */
TermisuHostResult termisu_host_mouse(TermisuHost *host, uint32_t action, uint32_t button,
                                 uint32_t mods, float x, float y);

/* Feeds one keyboard event to the key encoder and writes the result to the pty.
 * action: 0 release, 1 press, 2 repeat. key: the GhosttyKey C enum value
 * (KeyMap.swift). mods/consumed_mods: GhosttyMods bits (shift 1, ctrl 2, alt 4,
 * super 8, caps 16, num 32); consumed = mods spent producing text (macOS: mods
 * minus control and command). text: the event's translated UTF-8 (NULL/0 = none);
 * unshifted_codepoint: the key with no modifiers, 0 if none. Encoding modes --
 * DECCKM, keypad, 1035/1036, modifyOtherKeys, the kitty flags -- ride the last
 * polled frame. Success = bytes written; IGNORED = the event encodes to nothing. */
TermisuHostResult termisu_host_key(TermisuHost *host, uint32_t action, uint32_t key,
                               uint32_t mods, uint32_t consumed_mods,
                               const uint8_t *text, size_t text_len,
                               uint32_t unshifted_codepoint);

/* Routes a wheel gesture through the terminal's precedence: active mouse mode ->
 * wheel-button reports; else alternate screen + alternate scroll (1007, default on)
 * -> arrow keys (ESC O form under DECCKM); else IGNORED, and the embedder scrolls its
 * viewport. ticks is whole notches, positive up; the embedder owns fractional
 * banking. Success includes a consumed wheel that encoded to nothing (X10 event mode
 * cannot name wheel buttons) -- a program holding the mouse must not also have the
 * view scrolled under it. */
TermisuHostResult termisu_host_wheel(TermisuHost *host, float x, float y, int32_t ticks,
                                 uint32_t mods);

/* Whether a wheel tick with mods would scroll the viewport (termisu_host_wheel would answer
 * IGNORED) rather than reach the child, from the last polled frame. A GUI asks before it
 * shifts the view by part of a row. */
bool termisu_host_wheel_scrolls_viewport(TermisuHost *host, uint32_t mods);

/* Workflow templates (~/.ruuah/workflows/*.toml, the cmd+K palette's data). All
 * string getters use the row_text buffer protocol: NULL out sizes the value into
 * out_len, a short buffer refuses with the needed length, no NUL is written.
 * Field selectors: 0 name, 1 description, 2 command (or 2 default for args). */
typedef struct TermisuWorkflows TermisuWorkflows;

#define TERMISU_WORKFLOW_NAME 0u
#define TERMISU_WORKFLOW_DESCRIPTION 1u
#define TERMISU_WORKFLOW_COMMAND 2u
#define TERMISU_WORKFLOW_ARG_DEFAULT 2u

/* dir NULL = ~/.ruuah/workflows. Broken files are skipped, their errors kept on the
 * handle; a missing directory is a valid empty handle. */
TermisuHostResult termisu_workflows_load(const char *dir, TermisuWorkflows **out);
void termisu_workflows_free(TermisuWorkflows *handle);
uint32_t termisu_workflows_count(const TermisuWorkflows *handle);
/* Loader error lines, newline-joined; empty when every file parsed. Show loudly. */
TermisuHostResult termisu_workflows_errors(const TermisuWorkflows *handle, uint8_t *out,
                                       size_t cap, size_t *out_len);
TermisuHostResult termisu_workflow_field(const TermisuWorkflows *handle, uint32_t index,
                                     uint32_t field, uint8_t *out, size_t cap,
                                     size_t *out_len);
uint32_t termisu_workflow_arg_count(const TermisuWorkflows *handle, uint32_t index);
/* A missing default answers TERMISU_HOST_IGNORED with length 0 -- distinct from an
 * empty-string default, so the palette prefills one and prompts bare for the other. */
TermisuHostResult termisu_workflow_arg(const TermisuWorkflows *handle, uint32_t index,
                                   uint32_t arg_index, uint32_t field, uint8_t *out,
                                   size_t cap, size_t *out_len);
/* args_blob: pairs of NUL-terminated strings (name, value, ...), blob_len total
 * bytes. An unresolved placeholder refuses with INVALID_VALUE -- a command with a
 * hole in it must never reach the paste path. */
TermisuHostResult termisu_workflow_render(const TermisuWorkflows *handle, uint32_t index,
                                      const uint8_t *args_blob, size_t blob_len,
                                      uint8_t *out, size_t cap, size_t *out_len);

/* Command history for S4's ghost suggestions. path NULL = ~/.ruuah/history. Append
 * records one EXECUTED command and persists (blank/multiline/consecutive-duplicate
 * are dropped, answering IGNORED); suggest returns the most recent entry input is a
 * PROPER prefix of via the buffer protocol, IGNORED with length 0 when none. */
typedef struct TermisuHistory TermisuHistory;
TermisuHostResult termisu_history_load(const char *path, TermisuHistory **out);
void termisu_history_free(TermisuHistory *handle);
/* `cwd` is the RAW OSC 7 report (event kind 7), or NULL. The host normalizes it --
 * percent-escapes and the file:// host -- so an embedder passes the bytes through
 * untouched. A command is recorded against the directory it ran in, and a suggestion
 * PREFERS a match made in the current one, falling back to the newest match anywhere. */
TermisuHostResult termisu_history_append(TermisuHistory *handle, const uint8_t *command,
                                     size_t len, const uint8_t *cwd, size_t cwd_len);
TermisuHostResult termisu_history_suggest(const TermisuHistory *handle, const uint8_t *input,
                                      size_t len, const uint8_t *cwd, size_t cwd_len,
                                      uint8_t *out, size_t cap, size_t *out_len);

/* The filesystem path a RAW OSC 7 report names, written into `out` as UTF-8.
 *
 * The same normalizer the history calls use. Exposed so an embedder that needs the
 * decoded directory (running a command in it, say) does not write a second
 * percent-decoder in another language -- there is exactly one, and it is here.
 *
 * Returns Ignored with *out_len = 0 when the report names no directory, which is
 * distinguishable from a buffer that was too small. Pass out = NULL to size first. */
TermisuHostResult termisu_cwd_path(const uint8_t *raw, size_t len, uint8_t *out, size_t cap,
                               size_t *out_len);

/* Scrolls the displayed view through scrollback: positive rows climbs into history,
 * negative returns toward the live bottom, INT32_MIN snaps straight to it. Deltas
 * accumulate on the pump thread and are clamped against what history actually holds;
 * the landed position comes back in the next polled frame's viewport_offset. Typing
 * does not snap the view -- apply that policy in the embedder, via INT32_MIN. */
TermisuHostResult termisu_host_scroll(TermisuHost *host, int32_t rows);

/* Resizes the pty, the terminal and the render target. Refused (with no state change)
 * when the geometry exceeds the frame channel's capacity or either dimension is 0. */
TermisuHostResult termisu_host_resize(TermisuHost *host, uint16_t cols, uint16_t rows);

/* Reports the pixel cell size a renderer would use at font_size, without a host. The
 * zoom flow needs this BEFORE the new renderer exists: window pixels stay fixed, the
 * grid that fits them moves with the metrics. Pure query. */
TermisuHostResult termisu_host_cell_metrics(
    float font_size, const char *font_family, uint32_t *out_width, uint32_t *out_height);

/* Changes the font size live: pty resize to the new grid plus render-target rebuild at
 * the new metrics, in one call. Derive cols/rows from termisu_host_cell_metrics and the
 * window's fixed pixel size. Refusal rules match termisu_host_resize. */
TermisuHostResult termisu_host_set_font_size(
    TermisuHost *host, float font_size, uint16_t cols, uint16_t rows);

/* Copies one grid row's text as UTF-8 into out, trailing blanks trimmed. `semantic`
 * filters by the per-cell OSC 133 mark: TERMISU_TEXT_ALL takes every cell, the TERMISU_ROW_*
 * values take only cells wearing that mark -- the input filter on a prompt row is what
 * makes "copy command" return `ls -la` out of `$ ls -la`. Reads the last POLLED frame --
 * poll at least once first. Writes at most cap bytes (no NUL added; a truncated copy
 * backs off to a UTF-8 boundary), stores the row's full byte length in *len, and fails
 * with INVALID_VALUE when the row is out of range or nothing has been polled. Size cap
 * from a first call's *len, then call again. The copy-command / copy-output seam for
 * blocks: group rows with row_semantics, then read the text. */
TermisuHostResult termisu_host_row_text(
    TermisuHost *host, uint16_t row, uint8_t semantic, uint8_t *out, size_t cap, size_t *len);

/* Copies the OSC 8 URI under one cell (last POLLED frame). No link = SUCCESS with *len
 * 0 -- clicking plain text is not an error. Truncation contract as termisu_host_row_text. */
TermisuHostResult termisu_host_link_at(
    TermisuHost *host, uint16_t col, uint16_t row, uint8_t *out, size_t cap, size_t *len);

/* Copies the absolute path of the FILE a cmd+click at one cell means (last POLLED frame):
 * an OSC 8 file:// link under the cell, or else path-like text joined across soft wraps,
 * resolved against cwd_raw (the pane's raw OSC 7 report; NULL with 0 when it has none) and
 * $HOME, kept only if it is a regular file. *line and *column are the 1-based location the
 * text named (src/main.rs:42:7), 0 when absent. No file = SUCCESS with *len 0. Truncation
 * contract as termisu_host_row_text. */
TermisuHostResult termisu_host_path_at(
    TermisuHost *host, uint16_t col, uint16_t row, const uint8_t *cwd_raw, size_t cwd_len,
    uint8_t *out, size_t cap, size_t *len, uint32_t *line, uint32_t *column);

/* One row's share of what a cmd+click at a cell would act on: cells start..end of row,
 * end exclusive, a wide glyph's spacer included. */
typedef struct {
  uint16_t row;
  uint16_t start;
  uint16_t end;
} TermisuHostCellRun;

/* The cells a cmd+click at one cell would act on (last POLLED frame), so the embedder can
 * mark them before the click: the run of an OSC 8 link (a file:// one only when it names a
 * regular file), or else the printed text termisu_host_path_at would open, one run per row
 * it crosses. Up to cap runs are copied into out; *count is the total. Nothing a click would
 * open = SUCCESS with *count 0. cwd_raw as termisu_host_path_at. */
TermisuHostResult termisu_host_link_span_at(
    TermisuHost *host, uint16_t col, uint16_t row, const uint8_t *cwd_raw, size_t cwd_len,
    TermisuHostCellRun *out, size_t cap, size_t *count);

/* SELECTION. Cell coordinates, viewport-relative, the same space termisu_host_link_at
 * uses -- the embedder owns pixels because it owns the view, and termisu_host_cell_metrics
 * is how it converts. Reads the last POLLED frame; poll at least once first.
 *
 * *found is false when there was nothing selectable there, which is an ORDINARY answer:
 * a double-click on blank space selects nothing. INVALID_VALUE is reserved for a cell
 * outside the grid or a host that has never polled. Setting a selection also forces the
 * next poll to repaint, because a highlight changes no terminal state and would otherwise
 * appear only when the child next wrote something. */
TermisuHostResult termisu_host_select_word_at(
    TermisuHost *host, uint16_t col, uint16_t row, bool *found);
TermisuHostResult termisu_host_select_line_at(
    TermisuHost *host, uint16_t col, uint16_t row, bool *found);

/* Extends a drag from anchor to the cell under the pointer. The anchor is the embedder's
 * to remember: a drag is a press, a stream of moves and a release, and only the view knows
 * which press started this one. Endpoint order is the GESTURE's, not reading order. */
TermisuHostResult termisu_host_select_to(
    TermisuHost *host, uint16_t anchor_col, uint16_t anchor_row, uint16_t col, uint16_t row,
    bool *found);

/* Selects the VISIBLE grid. Not the scrollback: a frame is a viewport and history is not
 * in it. */
TermisuHostResult termisu_host_select_all(TermisuHost *host, bool *found);

/* Drops the highlight. Clearing nothing is success. */
TermisuHostResult termisu_host_select_clear(TermisuHost *host);

/* Copies the clipboard text for the current highlight. Nothing selected = SUCCESS with
 * *len 0. Truncation contract as termisu_host_row_text. The text comes from the same
 * formatter the differential corpus measures against libghostty-vt -- soft-wrap joining
 * and trailing whitespace included -- so an embedder must not walk the grid itself. */
TermisuHostResult termisu_host_selection_text(
    TermisuHost *host, uint8_t *out, size_t cap, size_t *len);

/* Pops the next host-facing event, oldest first. *kind: 0 = none, 1 = set clipboard to
 * payload, 2 = notification (payload = title, '\n', body), 3 = bell. An event is
 * 4 = title (payload = UTF-8), 5 = progress (payload = state,value), 6 = command
 * started (OSC 133;C, no payload -- read the input cells for the text),
 * 7 = working directory (OSC 7; payload is the RAW report, usually a file:// URI, and
 * is NOT percent-decoded -- an empty payload means the child cleared it). An event is
 * consumed only when cap held its whole payload; a smaller cap reports kind + *len and
 * leaves it queued (size-then-fetch never loses an event). */
TermisuHostResult termisu_host_next_event(
    TermisuHost *host, uint32_t *kind, uint8_t *out, size_t cap, size_t *len);

/* Tears down the child, the pump thread and the renderer. NULL is a no-op. Any pixels
 * pointer previously returned for this handle is dead after this call. */
void termisu_host_free(TermisuHost *host);

/* -- Settings (S1): dir/config.toml plus dir/themes/<name>.toml. --------------------------
 *
 * config.toml keys (all optional; unknown keys are an error, not ignored):
 *   font-size = 16.0          logical pixels; the embedder applies scale and defaults
 *   auto-direction = true     per-row Hebrew-first layout
 *   shell = "/bin/bash"       command line for new sessions, run via /bin/sh -c
 *   theme = "name"            themes/name.toml
 *
 * themes/<name>.toml keys (all optional):
 *   foreground = "#rrggbb"
 *   background = "#rrggbb"
 *   palette = ["#rrggbb", x16]   the named system colors; the cube/ramp stay absolute
 *
 * Loading never fails into an unusable state: a missing file is the defaults, and a file
 * that could not be honoured is the defaults plus termisu_config_error -- which a GUI must
 * show loudly. A bad theme applies NOTHING (never a half-theme). */

/* Loads dir/config.toml into a new handle. dir NULL means ~/.ruuah. Fails only on a NULL
 * out-param or a non-UTF-8 dir; on failure writes NULL to *out. */
TermisuHostResult termisu_config_load(const char *dir, TermisuConfig **out);

/* Font size in logical pixels, 0 when the config does not set one. */
float termisu_config_font_size(const TermisuConfig *config);

/* The configured auto-direction, or `fallback` when the config does not say. */
bool termisu_config_auto_direction(const TermisuConfig *config, bool fallback);

/* The configured shell command line, or NULL when unset. Borrowed: valid until
 * termisu_config_free on the same handle. */
const char *termisu_config_shell(const TermisuConfig *config);

/* Whether the operator granted screen-inspection replies -- DECRQCRA checksums and
 * the WINOPS 18 size report (config `reports = true`). FALSE by default and for a
 * NULL handle: these let a program read back what is on screen, the same posture
 * question as OSC 52 clipboard reads. The grant itself travels through
 * TermisuHostOptions.config at spawn; this is for showing the posture. */
bool termisu_config_reports(const TermisuConfig *config);

/* Whether the embedder may show web-rendered panels (config panels = true).
 * False for a NULL handle, and false unless the config says otherwise. */
bool termisu_config_panels(const TermisuConfig *config);

/* The configured lead font family (config font-family), or NULL when unset.
 * Borrowed: valid until termisu_config_free. */
const char *termisu_config_font_family(const TermisuConfig *config);

/* Everything that went wrong while loading, newline-joined; NULL when clean. Borrowed:
 * valid until termisu_config_free on the same handle. */
const char *termisu_config_error(const TermisuConfig *config);

/* Frees a config handle. NULL is a no-op. Strings lent by the getters die here. */
void termisu_config_free(TermisuConfig *config);

/* ---- Presenting into a window (macOS) -------------------------------------------
 *
 * Without a layer attached, termisu_host_poll copies the finished frame back across the
 * bus and lends it through TermisuHostFrame.pixels, and the embedder draws it. That copy
 * is a whole frame - 12.5 MB at 2240x1400 - on every draw.
 *
 * With a layer attached the frame is drawn straight into the window's swapchain on the
 * GPU and NEVER crosses to the CPU: TermisuHostFrame.pixels stays NULL, and the embedder
 * calls termisu_host_present instead of building an image. Detaching restores the old
 * behaviour on the next poll, so the two paths can be compared against each other.
 *
 * All sizes here are PHYSICAL pixels (layer.drawableSize), never points. Passing points
 * on a Retina display configures a half-resolution swapchain, which looks soft rather
 * than broken. */

/* Attaches a CAMetalLayer. The layer must outlive the host or be removed with
 * termisu_host_detach_layer first. Returns RENDER_FAILED rather than degrading when the
 * rasterizing adapter cannot drive that window or the window offers no usable format. */
TermisuHostResult termisu_host_attach_layer(
    TermisuHost *host, void *layer, uint32_t width, uint32_t height);

/* Drops the window. The next poll fills TermisuHostFrame.pixels again. */
TermisuHostResult termisu_host_detach_layer(TermisuHost *host);

/* Reconfigures the swapchain after the layer's drawableSize changed. */
TermisuHostResult termisu_host_resize_layer(TermisuHost *host, uint32_t width, uint32_t height);

/* Draws the current frame into the window and presents it. Separate from poll on
 * purpose: poll advances the terminal, present puts a frame on screen, and an embedder
 * drives them at different rates - a resize presents without polling, and a quiet
 * terminal polls without needing to present. INVALID_VALUE when no layer is attached. */
TermisuHostResult termisu_host_present(TermisuHost *host);

/* ---- Agents ---------------------------------------------------------------------
 *
 * Which coding-agent CLIs a pane can launch, whether this machine actually has them, and
 * the one policy that must not live in the embedder: an approval-bypassing flag is the
 * operator's to type and never ours to add.
 *
 * Four calls, deliberately not one. The registry is DATA (count/info), what is installed
 * is the machine's answer and not the registry's (resolve), the guard is a QUESTION the UI
 * can ask before it even enables a button (screen), and the spawn asks the guard again
 * itself (spawn_agent) -- a check the caller may forget is not a guard. */

/* One agent CLI as the embedder needs it. Every string is a borrowed static, valid for the
 * life of the process and never freed by the caller. */
typedef struct {
  /* The stable id termisu_agent_resolve and termisu_host_spawn_agent take. */
  const char *id;
  /* For a menu. */
  const char *name;
  /* What to tell an operator who does not have it, instead of a disabled row. */
  const char *install_hint;
  /* How long this agent may sit silent after launch before the silence means failure.
   * Agents differ by more than 2x, which is why it is data rather than a constant. */
  uint32_t spawn_grace_ms;
  /* True for agents that IGNORE a prompt passed as argv and must be typed into once they
   * are up. Getting this wrong is silent: the prompt is taken as a filename. */
  bool type_after_launch;
} TermisuAgentInfo;

/* How many agents the registry knows; indices below this are valid for termisu_agent_info. */
uint32_t termisu_agent_count(void);

/* Describes the agent at index. INVALID_VALUE for an out-of-range index or a NULL out.
 * Says nothing about whether it is INSTALLED -- that is termisu_agent_resolve. */
TermisuHostResult termisu_agent_info(uint32_t index, TermisuAgentInfo *out);

/* Where id's binary lives on THIS machine, written to out as UTF-8 with no terminator.
 *
 * SUCCESS with the path, or IGNORED with *out_len 0 when the agent is not installed --
 * a fact about the machine rather than an error, so it can be told apart from a bad call
 * and answered with the install hint. INVALID_VALUE for an unknown id. Call with out NULL
 * and cap 0 to size the buffer first.
 *
 * Cached: a hit stays fresh for five minutes and a miss is re-checked after ten seconds,
 * so an agent installed mid-session appears without a restart. */
TermisuHostResult termisu_agent_resolve(const char *id, uint8_t *out, size_t cap,
                                      size_t *out_len);

/* Asks whether an argv is ours to send. SUCCESS when it is; REFUSED when it carries a flag
 * that turns the agent's approvals off, with the offending flag written to out and its argv
 * position to at -- the operator has to be told WHICH word to remove.
 *
 * Whole argv tokens are matched, never substrings: `--auto` is Factory's auto-approve and
 * `--autosave` is not, and a guard that refuses the second teaches the operator to route
 * around the first. at may be NULL; out may be NULL with cap 0 to size. */
TermisuHostResult termisu_agent_screen(const char *const *argv, size_t argc, uint32_t *at,
                                     uint8_t *out, size_t cap, size_t *out_len);

/* Spawns a registry agent into a pane: the same pty, pump and renderer as
 * termisu_host_spawn, with the agent's binary as the child.
 *
 * options.command is IGNORED -- the child is the agent named by agent_id. Everything else
 * in options applies unchanged, cwd included.
 *
 * REFUSED when argv carries an approval bypass; nothing is spawned and nothing is
 * stripped, and termisu_agent_screen on the same argv names the flag. IGNORED when the agent
 * is not installed here. INVALID_VALUE for an unknown id or a malformed argv.
 *
 * The child gets HOME as its working directory unless options.cwd says otherwise, a
 * DECLARED TERM (an app launched from Finder inherits none, and a child with an empty TERM
 * finds no terminfo entry and exits before drawing a cell), and the Claude Code session
 * markers scrubbed so an agent in a pane is its own session rather than a child of whatever
 * launched Termisu.
 *
 * NOT here: the first prompt. TermisuAgentInfo.type_after_launch says which agents need it
 * typed rather than passed; sending it is termisu_host_send once the pane is up. */
TermisuHostResult termisu_host_spawn_agent(const TermisuHostOptions *options,
                                         const char *agent_id, const char *const *argv,
                                         size_t argc, TermisuHost **out);

#ifdef __cplusplus
}
#endif

#endif /* TERMISU_HOST_H */
