"""Richard launcher: start claude-code-telegram with httpx request logging silenced.

python-telegram-bot talks to https://api.telegram.org/bot<TOKEN>/..., and httpx logs
every request URL at INFO. claude-code-telegram sends all logging to stdout, which the
systemd unit forwards to journald, so without this launcher the bot token lands in
the system journal in clear text (thousands of lines a day from getUpdates polling).

The package's setup_logging() only calls logging.basicConfig(level=INFO) on the root
logger; it never touches the httpx/httpcore logger levels, so lowering them here,
before the package starts, holds for the whole run. The fix lives outside the
package's site-packages, so a pip upgrade of claude-code-telegram does not undo it.
"""

import logging

for _name in ("httpx", "httpcore"):
    logging.getLogger(_name).setLevel(logging.WARNING)

if __name__ == "__main__":
    from src.main import run

    run()
