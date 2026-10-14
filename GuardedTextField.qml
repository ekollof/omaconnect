import QtQuick
import Quickshell.Io
import qs.Ui as Ui

// Qt's editable TextInput reads the clipboard on every dataChanged signal,
// even while hidden. Never make the native control writable. Programmatic
// insert/remove still work; keyboard edits below do not touch QClipboard.
Ui.TextField {
  id: root
  readOnly: true
  cursorVisible: activeFocus
  maximumLength: 16384

  property var _undo: []
  property var _redo: []
  property string _pasteOutput: ""
  property string _pasteText: ""
  property int _pasteStart: 0
  property int _pasteEnd: 0
  property string pasteError: ""
  readonly property string helperBin: {
    var path = String(Qt.resolvedUrl("bin/omaconnect-exec")).slice(7)
    try { return decodeURIComponent(path) } catch (e) { return path }
  }

  function snapshot() { return { text: text, cursor: cursorPosition } }

  function replaceSelection(value) {
    var start = selectionStart
    var end = selectionEnd
    var room = maximumLength - (text.length - (end - start))
    value = String(value).replace(/[\r\n\u2028\u2029]/g, " ").slice(0, Math.max(0, room))
    // Do not split an astral character at the length limit.
    if (value.length && /[\uD800-\uDBFF]/.test(value.charAt(value.length - 1))) value = value.slice(0, -1)
    if (start === end && !value.length) return
    _undo = _undo.concat([snapshot()]).slice(-32)
    _redo = []
    remove(start, end)
    insert(start, value)
    cursorPosition = start + value.length
  }

  function undoEdit(redo) {
    var source = redo ? _redo : _undo
    if (!source.length) return
    var state = source[source.length - 1]
    if (redo) {
      _undo = _undo.concat([snapshot()]).slice(-32)
      _redo = source.slice(0, -1)
    } else {
      _redo = _redo.concat([snapshot()]).slice(-32)
      _undo = source.slice(0, -1)
    }
    text = state.text
    cursorPosition = state.cursor
  }

  function pasteBounded() {
    if (pasteProc.running) return
    pasteError = ""
    _pasteOutput = ""
    _pasteText = text
    _pasteStart = selectionStart
    _pasteEnd = selectionEnd
    pasteProc.running = true
  }

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (event.matches(StandardKey.Paste)) {
      pasteBounded()
    } else if (event.matches(StandardKey.Cut)) {
      copy()
      replaceSelection("")
    } else if (event.matches(StandardKey.Undo)) {
      undoEdit(false)
    } else if (event.matches(StandardKey.Redo)) {
      undoEdit(true)
    } else if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
      if (selectionStart === selectionEnd) {
        let start = cursorPosition
        let end = start
        if (event.key === Qt.Key_Backspace && start > 0) {
          start--
          if (start > 0 && /[\uDC00-\uDFFF]/.test(text.charAt(start))) start--
        } else if (event.key === Qt.Key_Delete && end < text.length) {
          end++
          if (end < text.length && /[\uD800-\uDBFF]/.test(text.charAt(end - 1))) end++
        }
        select(start, end)
      }
      replaceSelection("")
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      accepted()
    } else if (!(event.modifiers & Qt.MetaModifier)
               && (!(event.modifiers & Qt.ControlModifier) || (event.modifiers & Qt.AltModifier))
               && event.text.length && !/[\x00-\x1f\x7f]/.test(event.text)) {
      replaceSelection(event.text)
    } else {
      // Read-only native navigation, selection and copy are safe. Native
      // paste and middle-click insertion cannot edit this control.
      event.accepted = false
      return
    }
    event.accepted = true
  }

  Process {
    id: pasteProc
    command: [root.helperBin, "run", "16384", "--", "timeout", "--kill-after=1s", "2s",
      "wl-paste", "--no-newline", "--type", "text/plain"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._pasteOutput = text
    }
    onExited: function(code) {
      if (code !== 0) {
        root.pasteError = "Paste failed: clipboard unavailable, too large, or timed out"
      } else if (root.activeFocus && root.text === root._pasteText
                 && root.selectionStart === root._pasteStart && root.selectionEnd === root._pasteEnd) {
        root.replaceSelection(root._pasteOutput)
      }
      root._pasteOutput = ""
      root._pasteText = ""
    }
  }
}
