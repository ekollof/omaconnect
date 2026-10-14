// Run in an isolated offscreen Quickshell (no access to the real clipboard):
// Link the shell's Ui and Commons directories here before running:
// QT_QPA_PLATFORM=offscreen qs -p GuardedTextFieldTest.qml
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import "." as Plugin

Window {
  id: window
  visible: true
  width: 400
  height: 100
  Plugin.GuardedTextField { id: field; width: 350 }
  TestEvent { id: events }
  function check(condition, message) {
    if (!condition) throw new Error(message)
  }
  Timer {
    interval: 100
    running: true
    onTriggered: {
      try {
        window.requestActivate()
        field.forceActiveFocus()
        events.keyClickChar("h", 0, -1)
        events.keyClickChar("i", 0, -1)
        window.check(field.text === "hi", "typing")
        events.keyClick(Qt.Key_Backspace, 0, -1)
        window.check(field.text === "h", "backspace")
        events.keyClick(Qt.Key_Z, Qt.ControlModifier, -1)
        window.check(field.text === "hi", "undo")
        events.keyClick(Qt.Key_A, Qt.ControlModifier, -1)
        events.keyClickChar("x", 0, -1)
        window.check(field.text === "x", "selection replacement")
        field.selectAll()
        field.replaceSelection("a😀")
        events.keyClick(Qt.Key_Backspace, 0, -1)
        window.check(field.text === "a", "Unicode deletion")
        field.selectAll()
        field.replaceSelection("x".repeat(20000))
        window.check(field.text.length === 16384, "length bound")
        field.selectAll()
        field.replaceSelection("line1\nline2")
        window.check(field.text === "line1 line2", "single line")
        field.visible = false
        for (var i = 0; i < 10; i++) {
          Quickshell.clipboardText = "x".repeat(20000)
          window.check(field.readOnly && !field.canPaste, "hidden clipboard guard")
        }
        field.visible = true
        field.forceActiveFocus()
        window.check(field.readOnly && !field.canPaste, "focused clipboard guard")
        field.paste() // Native paste must remain inert.
        window.check(field.text === "line1 line2", "native paste bypass")
        console.log("PASS: guarded typing, undo, selection, Unicode, limits, clipboard changes and native paste")
        Qt.quit()
      } catch (error) {
        console.error("FAIL: " + error)
        Qt.exit(1)
      }
    }
  }
}
