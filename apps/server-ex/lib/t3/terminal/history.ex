defmodule T3.Terminal.History do
  @moduledoc """
  A terminal's scrollback: the last `max_lines` lines and `max_bytes` bytes of its
  output, replayed to a client that attaches.

  Output is stored without the escape sequences that only query the terminal (cursor
  position, device attributes, colour queries and the like, and their replies).
  Replaying a stored query makes the client's terminal answer it again, and the
  shell then echoes the answer as junk at the prompt. A sequence split across two
  chunks is held back until it is complete.
  """

  defstruct chunks: :queue.new(),
            bytes: 0,
            lines: 0,
            pending: "",
            max_lines: 5_000,
            max_bytes: 8 * 1024 * 1024

  @type t :: %__MODULE__{}

  # An unterminated sequence longer than this is kept as text rather than held forever.
  @max_pending 64 * 1024

  @doc "A history holding `text` (already sanitized, e.g. read back from disk)."
  def new(text \\ "", opts \\ []) do
    history = struct!(__MODULE__, opts)
    if text == "", do: history, else: push(history, text)
  end

  @doc "Appends raw terminal output."
  def append(%__MODULE__{} = history, data) do
    {visible, pending} = sanitize(history.pending, data)

    {visible, pending} =
      if byte_size(pending) > @max_pending, do: {visible <> pending, ""}, else: {visible, pending}

    push(%{history | pending: pending}, visible)
  end

  @doc "Empties the history."
  def clear(%__MODULE__{} = history),
    do: %{history | chunks: :queue.new(), bytes: 0, lines: 0, pending: ""}

  @doc "The history as one string."
  def value(%__MODULE__{chunks: chunks}), do: IO.iodata_to_binary(:queue.to_list(chunks))

  defp push(history, ""), do: history

  defp push(history, text) do
    %{
      history
      | chunks: :queue.in(text, history.chunks),
        bytes: history.bytes + byte_size(text),
        lines: history.lines + count_newlines(text)
    }
    |> trim_lines()
    |> trim_bytes()
  end

  # A trailing partial line counts as a line.
  defp excess_lines(history) do
    partial =
      case :queue.peek_r(history.chunks) do
        {:value, last} -> if :binary.last(last) == ?\n, do: 0, else: 1
        :empty -> 0
      end

    history.lines + partial - history.max_lines
  end

  defp trim_lines(history) do
    case excess_lines(history) do
      drop when drop > 0 ->
        {{:value, first}, rest} = :queue.out(history.chunks)
        in_first = count_newlines(first)

        if in_first <= drop do
          trim_lines(%{
            history
            | chunks: rest,
              bytes: history.bytes - byte_size(first),
              lines: history.lines - in_first
          })
        else
          offset = nth_newline_end(first, drop)
          kept = binary_part(first, offset, byte_size(first) - offset)

          %{
            history
            | chunks: :queue.in_r(kept, rest),
              bytes: history.bytes - offset,
              lines: history.lines - drop
          }
        end

      _ ->
        history
    end
  end

  defp trim_bytes(%{bytes: bytes, max_bytes: max} = history) when bytes <= max, do: history

  defp trim_bytes(history) do
    {{:value, first}, rest} = :queue.out(history.chunks)
    excess = history.bytes - history.max_bytes

    if byte_size(first) <= excess do
      trim_bytes(%{
        history
        | chunks: rest,
          bytes: history.bytes - byte_size(first),
          lines: history.lines - count_newlines(first)
      })
    else
      # Cut at a character boundary: skip UTF-8 continuation bytes after the cut.
      offset = char_boundary(first, excess)
      cut = binary_part(first, 0, offset)
      kept = binary_part(first, offset, byte_size(first) - offset)

      %{
        history
        | chunks: :queue.in_r(kept, rest),
          bytes: history.bytes - offset,
          lines: history.lines - count_newlines(cut)
      }
    end
  end

  defp char_boundary(binary, offset) when offset >= byte_size(binary), do: byte_size(binary)

  defp char_boundary(binary, offset) do
    case :binary.at(binary, offset) do
      byte when byte in 0x80..0xBF -> char_boundary(binary, offset + 1)
      _ -> offset
    end
  end

  defp count_newlines(text), do: length(:binary.matches(text, "\n"))

  defp nth_newline_end(text, n) do
    {pos, 1} = :binary.matches(text, "\n") |> Enum.at(n - 1)
    pos + 1
  end

  @doc """
  Splits `pending <> data` into the text to keep and an incomplete trailing escape
  sequence to hold for the next chunk, dropping terminal queries and replies.
  """
  def sanitize(pending, data), do: scan(pending <> data, [])

  defp scan(<<>>, acc), do: {IO.iodata_to_binary(acc), ""}

  defp scan(<<0x1B, ?[, rest::binary>> = all, acc) do
    case final_byte(rest, 0) do
      nil ->
        {IO.iodata_to_binary(acc), all}

      n ->
        <<body::binary-size(^n), final, tail::binary>> = rest
        seq = binary_part(all, 0, n + 3)
        scan(tail, if(strip_csi?(body, final), do: acc, else: [acc, seq]))
    end
  end

  # OSC, DCS, PM and APC run to a string terminator (BEL or ESC \).
  defp scan(<<0x1B, kind, rest::binary>> = all, acc) when kind in [?], ?P, ?^, ?_] do
    case terminator(rest, 0) do
      nil ->
        {IO.iodata_to_binary(acc), all}

      {content_len, total} ->
        content = binary_part(rest, 0, content_len)
        seq = binary_part(all, 0, total + 2)
        tail = binary_part(rest, total, byte_size(rest) - total)

        strip =
          (kind == ?] and Regex.match?(~r/^(10|11|12);(\?|rgb:)/, content)) or
            (kind == ?P and Regex.match?(~r/^[01]?[$+][qr]/, content))

        scan(tail, if(strip, do: acc, else: [acc, seq]))
    end
  end

  defp scan(<<0x1B>> = all, acc), do: {IO.iodata_to_binary(acc), all}

  # Other escape sequences: intermediates (0x20-0x2F) then a final byte.
  defp scan(<<0x1B, rest::binary>> = all, acc) do
    case escape_end(rest, 0) do
      nil -> {IO.iodata_to_binary(acc), all}
      n -> scan(binary_part(rest, n, byte_size(rest) - n), [acc, binary_part(all, 0, n + 1)])
    end
  end

  defp scan(input, acc) do
    case :binary.match(input, <<0x1B>>) do
      :nomatch ->
        {IO.iodata_to_binary([acc, input]), ""}

      {pos, 1} ->
        <<text::binary-size(^pos), rest::binary>> = input
        scan(rest, [acc, text])
    end
  end

  defp final_byte(bin, i) when i >= byte_size(bin), do: nil

  defp final_byte(bin, i) do
    if :binary.at(bin, i) in 0x40..0x7E, do: i, else: final_byte(bin, i + 1)
  end

  # Returns {content length, length including the terminator}.
  defp terminator(bin, i) when i >= byte_size(bin), do: nil

  defp terminator(bin, i) do
    case bin do
      <<_::binary-size(^i), 0x07, _::binary>> -> {i, i + 1}
      <<_::binary-size(^i), 0x1B, ?\\, _::binary>> -> {i, i + 2}
      <<_::binary-size(^i), 0x1B>> -> nil
      _ -> terminator(bin, i + 1)
    end
  end

  # Length of the sequence after ESC, or nil while incomplete. A byte that cannot
  # end the sequence leaves ESC on its own.
  defp escape_end(bin, i) when i >= byte_size(bin), do: nil

  defp escape_end(bin, i) do
    case :binary.at(bin, i) do
      b when b in 0x20..0x2F -> escape_end(bin, i + 1)
      b when b in 0x30..0x7E -> i + 1
      _ -> 0
    end
  end

  defp strip_csi?(_body, ?n), do: true
  defp strip_csi?(body, ?R), do: Regex.match?(~r/^[0-9;?]*$/, body)
  defp strip_csi?(body, ?c), do: Regex.match?(~r/^[>0-9;?]*$/, body)
  # DECRQM queries ($p) and DECRPM replies ($y); DECSTR (!p) and DECSCL ("p) stay.
  defp strip_csi?(body, final) when final in [?p, ?y], do: Regex.match?(~r/^[0-9;?]*\$$/, body)
  # XTVERSION (>q); DECSCUSR (space q) stays.
  defp strip_csi?(body, ?q), do: Regex.match?(~r/^>[0-9;]*$/, body)
  # Kitty keyboard queries (?u); restore-cursor (bare u) stays.
  defp strip_csi?(body, ?u), do: String.starts_with?(body, "?")
  defp strip_csi?(_body, _final), do: false

  @doc """
  Splits PTY bytes into complete UTF-8 text and an incomplete trailing character
  to prepend to the next read. Invalid bytes become U+FFFD.
  """
  def utf8(carry, data) do
    bin = carry <> data
    keep = incomplete_tail(bin)
    text = binary_part(bin, 0, byte_size(bin) - keep)
    {String.replace_invalid(text), binary_part(bin, byte_size(bin) - keep, keep)}
  end

  # Bytes at the end that start a multi-byte character not yet complete.
  defp incomplete_tail(bin) do
    size = byte_size(bin)

    Enum.find_value(1..min(3, size)//1, 0, fn back ->
      byte = :binary.at(bin, size - back)

      cond do
        byte in 0x80..0xBF -> nil
        byte in 0xC0..0xDF -> if back < 2, do: back, else: 0
        byte in 0xE0..0xEF -> if back < 3, do: back, else: 0
        byte in 0xF0..0xF7 -> if back < 4, do: back, else: 0
        true -> 0
      end
    end)
  end
end
