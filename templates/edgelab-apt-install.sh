#!/usr/bin/env bash
# edgelab-apt-install -- the ONLY apt entry point 'edgelab' may run via sudo.
#
# Installed by edgelab-install as /usr/local/sbin/edgelab-apt-install (root, 0755).
# A sudoers rule for plain apt/apt-get with arguments is full root: options
# such as `-o APT::Update::Pre-Invoke::=<cmd>` or a local .deb run anything.
# This wrapper accepts only package names from the configured repositories.
#
#   sudo edgelab-apt-install update
#   sudo edgelab-apt-install install <pkg> [<pkg>...]
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
unset APT_CONFIG

readonly PKG_RE='^[a-z0-9][a-z0-9+.-]*$'

usage() {
    echo "usage: edgelab-apt-install update | edgelab-apt-install install <package>..." >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
cmd=$1
shift

case "$cmd" in
    update)
        [[ $# -eq 0 ]] || usage
        exec /usr/bin/apt-get update
        ;;
    install)
        [[ $# -ge 1 ]] || usage
        for pkg in "$@"; do
            if [[ "$pkg" == -* || ! "$pkg" =~ $PKG_RE ]]; then
                echo "edgelab-apt-install: rejected '${pkg}': only plain package names (${PKG_RE})" >&2
                exit 2
            fi
        done
        exec /usr/bin/apt-get install -y --no-install-recommends -- "$@"
        ;;
    *)
        usage
        ;;
esac
