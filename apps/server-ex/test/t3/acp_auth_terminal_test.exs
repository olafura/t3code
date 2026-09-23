defmodule T3.Acp.AuthTerminalTest do
  use ExUnit.Case, async: true

  alias T3.Acp.Auth

  test "login output is counted as clients count it, and split characters wait" do
    box = "╭─╮"
    # Box drawing is 3 bytes a character in UTF-8, 1 unit in UTF-16.
    assert Auth.utf16_length("\e[?25l" <> box) == 9
    assert Auth.utf16_length("😀") == 2

    <<first::binary-size(4), rest::binary>> = "ab" <> box
    assert Auth.complete_utf8(first) == {"ab", <<0xE2, 0x95>>}
    assert Auth.complete_utf8(<<0xE2, 0x95>> <> rest) == {box, ""}
    assert Auth.complete_utf8("plain") == {"plain", ""}
  end
end
