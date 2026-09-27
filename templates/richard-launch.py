"""Richard launcher: start claude-code-telegram with the Telegram bot token masked in output.

python-telegram-bot talks to https://api.telegram.org/bot<TOKEN>/..., and httpx logs
every request URL at INFO. claude-code-telegram sends all logging to stdout, which the
systemd unit forwards to journald, so without this launcher the bot token lands in
the system journal in clear text (thousands of lines a day from getUpdates polling).

The fix lives here, outside the package's site-packages, so a pip upgrade of
claude-code-telegram does not undo it:
  * sys.stdout and sys.stderr are wrapped before the package starts, so every
    Python-level write is masked at the output boundary: logging handlers
    (basicConfig binds the wrapped stream), print(), sys.excepthook,
    threading.excepthook, sys.unraisablehook, sys.exit(<message>),
    sys.__stdout__ / sys.__stderr__, and the binary sys.stdout.buffer /
    sys.stderr.buffer (write, write1, raw, detach);
  * the configured token (TELEGRAM_BOT_TOKEN) is replaced exactly, and anything
    shaped like a bot token is replaced by pattern as a second line of defence;
  * httpx/httpcore request logging is lowered to WARNING (volume, not secrecy).

Not covered: bytes written straight to file descriptors 1/2 (C extensions, child
processes that inherit the descriptors). The package's Claude CLI child runs on
pipes, not on the unit's stdout.
"""

import atexit
import codecs
import logging
import os
import re
import sys

TOKEN_RE = re.compile(r"\d+:[A-Za-z0-9_-]{30,40}")  # bounded: glued text must not eat the next token
MASK = "<TOKEN>"


def _secrets() -> list[str]:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        return []
    found = [token]
    secret = token.split(":", 1)[-1]
    if len(secret) >= 20 and secret != token:
        found.append(secret)
    return found


def mask(text: str, secrets: list[str] | None = None) -> str:
    for secret in _secrets() if secrets is None else secrets:
        text = text.replace(secret, MASK)
    return TOKEN_RE.sub(MASK, text)


class MaskingStream:
    """Text stream proxy that masks tokens line by line.

    Output is held until a newline so a token split across write() calls -- even
    with a flush() in between -- is still seen whole. An unterminated tail is
    released at exit (atexit); past PENDING_CAP all but its last KEEP chars go out. The binary
    .buffer goes through the same masking.
    """

    PENDING_CAP = 65536
    KEEP = 256  # longer than any bot token

    def __init__(self, stream, secrets: list[str]) -> None:  # type: ignore[no-untyped-def]
        self._stream = stream
        self._secrets = secrets
        self._pending = ""
        self.buffer = _MaskingBuffer(self)

    def write(self, text: str) -> int:
        self._pending += text
        head, sep, tail = self._pending.rpartition("\n")
        if sep:
            self._stream.write(mask(head + sep, self._secrets))
            self._pending = tail
        if len(self._pending) > self.PENDING_CAP:
            # Release all but the last KEEP chars and hold those RAW: a token cut at
            # the end is completed and masked whole later. A whole token spanning the
            # cut moves the cut to its start.
            pending = self._pending
            cut = len(pending) - self.KEEP
            spans = [m.span() for m in TOKEN_RE.finditer(pending, max(0, cut - self.KEEP))]
            for secret in self._secrets:
                at = pending.find(secret, max(0, cut - len(secret)))
                if at != -1:
                    spans.append((at, at + len(secret)))
            for start, end in spans:
                if start < cut < end:
                    cut = min(cut, start)
            self._stream.write(mask(pending[:cut], self._secrets))
            self._pending = pending[cut:]
        return len(text)

    def writelines(self, lines) -> None:  # type: ignore[no-untyped-def]
        for line in lines:
            self.write(line)

    def flush(self) -> None:
        # The unterminated tail stays held: it may be the first half of a token.
        self._stream.flush()

    def detach(self) -> "_MaskingBuffer":
        # Detaching must not hand out the unmasked binary stream.
        return self.buffer

    def release(self) -> None:
        if self._pending:
            self._stream.write(mask(self._pending, self._secrets))
            self._pending = ""
        self._stream.flush()

    def __getattr__(self, name: str):  # type: ignore[no-untyped-def]
        return getattr(self._stream, name)


class _MaskingBuffer:
    """Binary side of MaskingStream: bytes are decoded and masked with the text."""

    def __init__(self, owner: MaskingStream) -> None:
        self._owner = owner
        encoding = getattr(owner._stream, "encoding", None) or "utf-8"
        # Incremental: a multibyte character split across write() calls stays intact.
        self._decoder = codecs.getincrementaldecoder(encoding)(errors="replace")

    def write(self, data) -> int:  # type: ignore[no-untyped-def]
        self._owner.write(self._decoder.decode(bytes(data)))
        return len(data)

    write1 = write  # BufferedWriter.write1 must not reach the raw stream unmasked

    def detach(self) -> "_MaskingBuffer":
        return self

    @property
    def raw(self) -> "_MaskingBuffer":
        return self

    def writelines(self, lines) -> None:  # type: ignore[no-untyped-def]
        for line in lines:
            self.write(line)

    def flush(self) -> None:
        self._owner.flush()

    def __getattr__(self, name: str):  # type: ignore[no-untyped-def]
        return getattr(self._owner._stream.buffer, name)


def install() -> None:
    secrets = _secrets()
    sys.stdout = MaskingStream(sys.stdout, secrets)
    sys.stderr = MaskingStream(sys.stderr, secrets)
    # print(..., file=sys.__stderr__) is Python-level output too.
    sys.__stdout__ = sys.stdout
    sys.__stderr__ = sys.stderr
    atexit.register(sys.stderr.release)
    atexit.register(sys.stdout.release)
    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)


if __name__ == "__main__":
    install()
    from src.main import run

    run()
