require "test_helper"

class ImageProjects::InlineTextParserTest < ActiveSupport::TestCase
  test "plain text returns one plain run" do
    assert_equal(
      [ { text: "DESIGN HIGHLIGHTS", bold: false, italic: false } ],
      ImageProjects::InlineTextParser.parse("DESIGN HIGHLIGHTS")
    )
  end

  test "bold markup returns bold run then regular run" do
    assert_equal(
      [
        { text: "DESIGN", bold: true, italic: false },
        { text: " HIGHLIGHTS", bold: false, italic: false }
      ],
      ImageProjects::InlineTextParser.parse("**DESIGN** HIGHLIGHTS")
    )
  end

  test "italic markup returns italic run" do
    assert_equal(
      [
        { text: "This is ", bold: false, italic: false },
        { text: "important", bold: false, italic: true }
      ],
      ImageProjects::InlineTextParser.parse("This is *important*")
    )
  end

  test "user html is preserved as text" do
    assert_equal(
      [ { text: "<script>alert(1)</script>", bold: false, italic: false } ],
      ImageProjects::InlineTextParser.parse("<script>alert(1)</script>")
    )
  end

  test "unmatched markers fall back as literal text" do
    assert_equal(
      [ { text: "This is **not closed", bold: false, italic: false } ],
      ImageProjects::InlineTextParser.parse("This is **not closed")
    )
  end

  test "plain text strips supported markup" do
    assert_equal "DESIGN HIGHLIGHTS", ImageProjects::InlineTextParser.plain_text("**DESIGN** HIGHLIGHTS")
  end
end
