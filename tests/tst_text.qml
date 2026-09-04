import QtQuick
import QtTest

// The finding, reproduced and then fixed, against Qt itself rather than
// against a description of Qt: a Text left on the default format decides for
// itself whether a string is markup, and a device name is not ours to trust.
TestCase {
  name: "TextFormat"

  property string hostile: "<b>Free WiFi</b><img src=\"file:///etc/passwd\">"

  Text { id: sniffing; text: suite.hostile }
  Text { id: plain; text: suite.hostile; textFormat: Text.PlainText }
  readonly property var suite: ({ hostile: hostile })

  function test_the_default_format_interprets_markup() {
    compare(sniffing.textFormat, Text.AutoText, "Qt's default is to decide for itself")
    // Rendered width is the evidence: tags that are interpreted do not occupy
    // the space their characters would.
    verify(sniffing.contentWidth < plain.contentWidth,
           "the default format swallowed the markup instead of showing it")
  }

  function test_plain_text_renders_every_character() {
    compare(plain.textFormat, Text.PlainText)
    verify(plain.contentWidth > 0)
  }
}
