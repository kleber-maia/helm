import { EditorState, RangeSetBuilder, StateField, Compartment } from "@codemirror/state";
import {
  EditorView,
  Decoration,
  WidgetType,
  GutterMarker,
  gutter,
  lineNumbers,
  highlightSpecialChars,
  drawSelection,
} from "@codemirror/view";
import { LanguageDescription } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { search, highlightSelectionMatches } from "@codemirror/search";

// ── Theme imports ───────────────────────────────────────────────────

import {
  xcodeLightInit, xcodeDarkInit,
} from "@uiw/codemirror-theme-xcode";
import { githubLight, githubDark } from "@uiw/codemirror-theme-github";
import { vscodeDark, vscodeLight } from "@uiw/codemirror-theme-vscode";
import { dracula } from "@uiw/codemirror-theme-dracula";
import { tokyoNight } from "@uiw/codemirror-theme-tokyo-night";
import { tokyoNightDay } from "@uiw/codemirror-theme-tokyo-night-day";
import { nord } from "@uiw/codemirror-theme-nord";
import { solarizedLight, solarizedDark } from "@uiw/codemirror-theme-solarized";
import { sublime } from "@uiw/codemirror-theme-sublime";
import { monokai } from "@uiw/codemirror-theme-monokai";
import { atomone } from "@uiw/codemirror-theme-atomone";

// Override the default Xcode backgrounds with colours that match
// macOS `NSColor.windowBackgroundColor`, so the editor blends into
// the surrounding app chrome instead of standing out as a darker
// (or lighter) panel.
const helmXcodeLight = xcodeLightInit({
  settings: { background: "#ECECEC", gutterBackground: "#ECECEC" },
});
const helmXcodeDark = xcodeDarkInit({
  settings: { background: "#1E1E1E", gutterBackground: "#1E1E1E" },
});

const themeMap = {
  "xcode-light": helmXcodeLight,
  "xcode-dark": helmXcodeDark,
  "github-light": githubLight,
  "github-dark": githubDark,
  "vscode-light": vscodeLight,
  "vscode-dark": vscodeDark,
  "dracula": dracula,
  "tokyo-night": tokyoNight,
  "tokyo-night-day": tokyoNightDay,
  "nord": nord,
  "solarized-light": solarizedLight,
  "solarized-dark": solarizedDark,
  "sublime": sublime,
  "monokai": monokai,
  "atomone": atomone,
};

// Themes grouped by light/dark for the picker
const themeList = [
  { id: "xcode-light", name: "Xcode Light", dark: false },
  { id: "xcode-dark", name: "Xcode Dark", dark: true },
  { id: "github-light", name: "GitHub Light", dark: false },
  { id: "github-dark", name: "GitHub Dark", dark: true },
  { id: "vscode-light", name: "VS Code Light", dark: false },
  { id: "vscode-dark", name: "VS Code Dark", dark: true },
  { id: "solarized-light", name: "Solarized Light", dark: false },
  { id: "solarized-dark", name: "Solarized Dark", dark: true },
  { id: "tokyo-night-day", name: "Tokyo Night Day", dark: false },
  { id: "tokyo-night", name: "Tokyo Night", dark: true },
  { id: "nord", name: "Nord", dark: true },
  { id: "dracula", name: "Dracula", dark: true },
  { id: "sublime", name: "Sublime", dark: true },
  { id: "monokai", name: "Monokai", dark: true },
  { id: "atomone", name: "Atom One", dark: true },
];

// ── Theme state ─────────────────────────────────────────────────────

const themeCompartment = new Compartment();
let selectedLightTheme = "xcode-light";
let selectedDarkTheme = "xcode-dark";

const isDark = () =>
  window.matchMedia("(prefers-color-scheme: dark)").matches;

function currentThemeExtension() {
  const id = isDark() ? selectedDarkTheme : selectedLightTheme;
  return themeMap[id] || helmXcodeLight;
}

const readOnly = EditorState.readOnly.of(true);

const fontTheme = EditorView.theme({
  "&": {
    fontFamily: "'SF Mono', SFMono-Regular, ui-monospace, monospace",
    fontSize: "12px",
    fontWeight: "300",
  },
  ".cm-gutters": {
    fontFamily: "'SF Mono', SFMono-Regular, ui-monospace, monospace",
    fontSize: "12px",
    fontWeight: "300",
  },
});

function baseExtensions() {
  return [
    lineNumbers(),
    highlightSpecialChars(),
    drawSelection(),
    highlightSelectionMatches(),
    search({ top: true }),
    readOnly,
    themeCompartment.of(currentThemeExtension()),
    fontTheme,
  ];
}

// ── Detect language from file extension ─────────────────────────────

async function languageFromExt(ext) {
  if (!ext) return [];
  const filename = "file." + ext.replace(/^\./, "");
  const desc = LanguageDescription.matchFilename(languages, filename);
  if (!desc) return [];
  const lang = await desc.load();
  return [lang];
}

// ── State ───────────────────────────────────────────────────────────

let currentView = null;
const mountEl = () => document.getElementById("editor");

function clearMountPoint() {
  const el = mountEl();
  if (!el) return;
  while (el.firstChild) {
    el.removeChild(el.firstChild);
  }
}

function destroyCurrent() {
  if (currentView) {
    currentView.destroy();
    currentView = null;
  }
  clearMountPoint();
}

/// Creates an empty themed editor so the background color always
/// matches the active theme even when no file is loaded.
function createEmptyEditor() {
  destroyCurrent();
  currentView = new EditorView({
    state: EditorState.create({
      doc: "",
      extensions: baseExtensions(),
    }),
    parent: mountEl(),
  });
}

// ── Hunk-staging button widget ──────────────────────────────────────

class HunkButtonWidget extends WidgetType {
  constructor(label, action, index) {
    super();
    this.label = label;
    this.action = action;
    this.index = index;
  }

  toDOM() {
    const btn = document.createElement("span");
    btn.className = "hunk-button";
    btn.textContent = this.label;
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      window.webkit.messageHandlers.controller.postMessage({
        action: this.action,
        index: this.index,
      });
    });
    return btn;
  }

  ignoreEvent() {
    return false;
  }
}

// ── Diff view ───────────────────────────────────────────────────────

const addLineDecoration = Decoration.line({ class: "cm-diff-add" });
const delLineDecoration = Decoration.line({ class: "cm-diff-del" });
const hunkSepDecoration = Decoration.line({ class: "cm-diff-hunk-sep" });

// Custom gutter marker that shows a line number or blank
class DiffLineNumber extends GutterMarker {
  constructor(num) {
    super();
    this.num = num;
  }

  toDOM() {
    const el = document.createElement("span");
    el.textContent = this.num > 0 ? String(this.num) : "";
    return el;
  }
}

function buildDiffGutters(oldNums, newNums) {
  // oldNums/newNums: arrays indexed by 1-based editor line number.
  // Value > 0 means show that number, 0 or undefined means blank.

  const oldGutter = gutter({
    class: "cm-diff-old-gutter",
    lineMarker(view, line) {
      const lineNo = view.state.doc.lineAt(line.from).number;
      const n = oldNums[lineNo];
      return n > 0 ? new DiffLineNumber(n) : new DiffLineNumber(0);
    },
    initialSpacer() { return new DiffLineNumber(9999); },
  });

  const newGutter = gutter({
    class: "cm-diff-new-gutter",
    lineMarker(view, line) {
      const lineNo = view.state.doc.lineAt(line.from).number;
      const n = newNums[lineNo];
      return n > 0 ? new DiffLineNumber(n) : new DiffLineNumber(0);
    },
    initialSpacer() { return new DiffLineNumber(9999); },
  });

  return [oldGutter, newGutter];
}

function diffBaseExtensions() {
  // Like baseExtensions() but without lineNumbers() — diff uses
  // custom gutters instead.
  return [
    highlightSpecialChars(),
    drawSelection(),
    highlightSelectionMatches(),
    search({ top: true }),
    readOnly,
    themeCompartment.of(currentThemeExtension()),
    fontTheme,
  ];
}

async function loadDiff(hunksInput, stagingType, fileExtension) {
  destroyCurrent();

  const hunks = typeof hunksInput === "string"
    ? JSON.parse(hunksInput)
    : hunksInput;

  const docLines = [];
  const lineDecorations = [];
  const hunkWidgets = [];
  // 1-indexed: oldNums[editorLine] = old file line number (0 = blank)
  const oldNums = [0]; // index 0 unused
  const newNums = [0];

  let lineNum = 0;

  for (let hunkIdx = 0; hunkIdx < hunks.length; hunkIdx++) {
    const hunk = hunks[hunkIdx];

    // Hunk separator line — no line numbers
    const hunkLabel =
      `@@ -${hunk.oldStart},${hunk.oldLines}` +
      ` +${hunk.newStart},${hunk.newLines} @@`;
    docLines.push(hunkLabel);
    lineNum++;
    lineDecorations.push({ line: lineNum, deco: hunkSepDecoration });
    oldNums.push(0);
    newNums.push(0);

    const buttons = [];
    if (stagingType === "index") {
      if (hunk.canApply !== false) {
        buttons.push(
          new HunkButtonWidget("Unstage", "unstageHunk", hunkIdx)
        );
      }
    } else if (stagingType === "workspace") {
      if (hunk.canApply !== false) {
        buttons.push(
          new HunkButtonWidget("Discard", "discardHunk", hunkIdx)
        );
        buttons.push(
          new HunkButtonWidget("Stage", "stageHunk", hunkIdx)
        );
      }
    }
    if (buttons.length > 0) {
      hunkWidgets.push({ line: lineNum, widgets: buttons });
    }

    for (const dl of hunk.lines) {
      docLines.push(dl.text);
      lineNum++;

      if (dl.type === "addition") {
        lineDecorations.push({ line: lineNum, deco: addLineDecoration });
        oldNums.push(0);            // no old line
        newNums.push(dl.newLine);
      } else if (dl.type === "deletion") {
        lineDecorations.push({ line: lineNum, deco: delLineDecoration });
        oldNums.push(dl.oldLine);
        newNums.push(0);            // no new line
      } else {
        // context
        oldNums.push(dl.oldLine);
        newNums.push(dl.newLine);
      }
    }
  }

  const doc = docLines.join("\n");
  const sortedDecos = lineDecorations.sort((a, b) => a.line - b.line);
  const sortedWidgets = hunkWidgets.sort((a, b) => a.line - b.line);

  const staticLineDecos = StateField.define({
    create(state) {
      const builder = new RangeSetBuilder();
      for (const { line, deco } of sortedDecos) {
        if (line <= state.doc.lines) {
          const lineObj = state.doc.line(line);
          builder.add(lineObj.from, lineObj.from, deco);
        }
      }
      return builder.finish();
    },
    update(value) { return value; },
    provide: (f) => EditorView.decorations.from(f),
  });

  const staticWidgetDecos = StateField.define({
    create(state) {
      const builder = new RangeSetBuilder();
      for (const { line, widgets } of sortedWidgets) {
        if (line <= state.doc.lines) {
          const lineObj = state.doc.line(line);
          for (const widget of widgets) {
            builder.add(
              lineObj.to, lineObj.to,
              Decoration.widget({ widget, side: 1 })
            );
          }
        }
      }
      return builder.finish();
    },
    update(value) { return value; },
    provide: (f) => EditorView.decorations.from(f),
  });

  const langExt = await languageFromExt(fileExtension);
  const gutters = buildDiffGutters(oldNums, newNums);

  currentView = new EditorView({
    state: EditorState.create({
      doc,
      extensions: [
        ...diffBaseExtensions(),
        ...gutters,
        ...langExt,
        staticLineDecos,
        staticWidgetDecos,
        diffTheme,
      ],
    }),
    parent: mountEl(),
  });
}

// ── Diff theme ──────────────────────────────────────────────────────

const diffTheme = EditorView.baseTheme({
  ".cm-diff-add": {
    backgroundColor: "rgba(40, 167, 69, 0.15)",
  },
  ".cm-diff-del": {
    backgroundColor: "rgba(215, 58, 73, 0.15)",
  },
  ".cm-diff-hunk-sep": {
    backgroundColor: "rgba(130, 130, 140, 0.12)",
    fontStyle: "italic",
    color: "#888",
  },
  ".cm-diff-old-gutter .cm-gutterElement, .cm-diff-new-gutter .cm-gutterElement": {
    textAlign: "right",
    paddingRight: "4px",
    minWidth: "3ch",
    opacity: "0.5",
    fontSize: "inherit",
  },
  ".cm-diff-old-gutter": {
    borderRight: "1px solid rgba(128,128,128,0.15)",
  },
  ".cm-diff-new-gutter": {
    borderRight: "1px solid rgba(128,128,128,0.15)",
    marginRight: "4px",
  },
  ".hunk-button": {
    float: "right",
    border: "1px solid rgba(128,128,128,0.3)",
    borderRadius: "4px",
    padding: "1px 8px",
    margin: "0 2px",
    fontSize: "12px",
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
    cursor: "pointer",
    userSelect: "none",
    backgroundColor: "rgba(128,128,128,0.08)",
    lineHeight: "1.6",
  },
  ".hunk-button:hover": {
    backgroundColor: "rgba(128,128,128,0.2)",
  },
  ".hunk-button:active": {
    backgroundColor: "rgba(128,128,128,0.3)",
  },
});

// ── Text-mode change gutter ─────────────────────────────────────────

class ColorGutterMarker extends GutterMarker {
  constructor(color) {
    super();
    this.color = color;
  }
  toDOM() {
    const el = document.createElement("div");
    el.style.backgroundColor = this.color;
    el.style.width = "3px";
    el.style.height = "100%";
    el.style.borderRadius = "1.5px";
    return el;
  }
}

const addGutterMarker = new ColorGutterMarker("rgba(40, 167, 69, 0.8)");
const delGutterMarker = new ColorGutterMarker("rgba(215, 58, 73, 0.8)");
const modGutterMarker = new ColorGutterMarker("rgba(30, 120, 220, 0.8)");

const textDiffTheme = EditorView.baseTheme({
  ".cm-change-gutter": {
    width: "6px",
    marginRight: "2px",
  },
  ".cm-change-gutter .cm-gutterElement": {
    padding: "0 1px",
  },
});

// ── Text view (full file) ───────────────────────────────────────────

async function loadText(content, fileExtension,
                        added, deleted, modified) {
  destroyCurrent();

  const langExt = await languageFromExt(fileExtension);
  const extras = [];
  const toSet = (a) => Array.isArray(a) && a.length > 0
    ? new Set(a) : new Set();
  const addSet = toSet(added);
  const delSet = toSet(deleted);
  const modSet = toSet(modified);
  const hasChanges = addSet.size > 0 || delSet.size > 0
    || modSet.size > 0;

  if (hasChanges) {
    // Background highlights for added and modified lines
    const highlightSet = new Set([...addSet, ...modSet]);
    if (highlightSet.size > 0) {
      const decos = StateField.define({
        create(state) {
          const builder = new RangeSetBuilder();
          for (let n = 1; n <= state.doc.lines; n++) {
            if (highlightSet.has(n)) {
              const line = state.doc.line(n);
              builder.add(line.from, line.from,
                addLineDecoration);
            }
          }
          return builder.finish();
        },
        update(value) { return value; },
        provide: (f) => EditorView.decorations.from(f),
      });
      extras.push(decos);
    }

    // Change gutter: green=added, blue=modified, red=deleted
    const changeGutter = gutter({
      class: "cm-change-gutter",
      lineMarker(view, line) {
        const n = view.state.doc.lineAt(line.from).number;
        if (modSet.has(n)) return modGutterMarker;
        if (addSet.has(n)) return addGutterMarker;
        if (delSet.has(n)) return delGutterMarker;
        return null;
      },
    });
    extras.push(changeGutter, textDiffTheme, diffTheme);
  }

  currentView = new EditorView({
    state: EditorState.create({
      doc: content,
      extensions: [...baseExtensions(), ...langExt, ...extras],
    }),
    parent: mountEl(),
  });
}

// ── Notice view ─────────────────────────────────────────────────────

function loadNotice(message) {
  createEmptyEditor();
  const el = mountEl();
  if (!el) return;
  const div = document.createElement("div");
  div.className = "cm-notice";
  div.textContent = message;
  el.appendChild(div);
}

// ── Clear ───────────────────────────────────────────────────────────

function clear() {
  createEmptyEditor();
}

// ── Settings ────────────────────────────────────────────────────────

function setTabWidth(n) {
  if (currentView) {
    currentView.dispatch({
      effects: EditorState.tabSize.reconfigure(
        EditorState.tabSize.of(n)
      ),
    });
  }
}

function setWrapping(mode) {
  const el = mountEl();
  if (!el) return;
  if (mode === "none") {
    el.style.maxWidth = "";
    el.classList.remove("cm-wrap");
  } else if (mode === "window") {
    el.style.maxWidth = "100%";
    el.classList.add("cm-wrap");
  } else {
    el.style.maxWidth = mode + "ch";
    el.classList.add("cm-wrap");
  }
}

// ── Theme API ───────────────────────────────────────────────────────

function setTheme(lightThemeId, darkThemeId) {
  if (lightThemeId) selectedLightTheme = lightThemeId;
  if (darkThemeId) selectedDarkTheme = darkThemeId;

  if (currentView) {
    currentView.dispatch({
      effects: themeCompartment.reconfigure(currentThemeExtension()),
    });
  }
}

function getThemes() {
  return JSON.stringify(themeList);
}

function getCurrentThemes() {
  return JSON.stringify({
    light: selectedLightTheme,
    dark: selectedDarkTheme,
  });
}

// ── Theme switching on appearance change ────────────────────────────

window
  .matchMedia("(prefers-color-scheme: dark)")
  .addEventListener("change", () => {
    // Reconfigure theme in-place (no page reload needed)
    if (currentView) {
      currentView.dispatch({
        effects: themeCompartment.reconfigure(currentThemeExtension()),
      });
    }
  });

// ── Public API ──────────────────────────────────────────────────────

window.HelmEditor = {
  loadText,
  loadDiff,
  loadNotice,
  clear,
  setTabWidth,
  setWrapping,
  setTheme,
  getThemes,
  getCurrentThemes,
};

// Create an empty themed editor on startup so the background
// always matches the theme instead of showing a white page.
createEmptyEditor();

// Signal readiness
if (window.webkit && window.webkit.messageHandlers.controller) {
  window.webkit.messageHandlers.controller.postMessage({
    action: "pageReady",
  });
}
