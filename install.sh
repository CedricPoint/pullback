#!/bin/sh
#
# pullback — install from a clone.
#
#   git clone https://github.com/CedricPoint/pullback.git
#   cd pullback && sudo ./install.sh
#
# Deliberately not a `curl … | sh` one-liner: handing an unread script to a
# root shell is the habit this account has another tool for refusing.

set -eu

PREFIX="${PREFIX:-/usr/local}"
CONFDIR="${CONFDIR:-/etc/pullback}"
DEST="${DEST:-/srv/backups}"

here=$(cd "$(dirname "$0")" && pwd)

[ -f "$here/bin/pullback" ] || { echo "run this from inside the clone" >&2; exit 1; }

if [ "$(id -u)" != 0 ]; then
  echo "this writes to $PREFIX and $CONFDIR — run it with sudo" >&2
  exit 1
fi

echo "installing into $PREFIX"
install -d "$PREFIX/lib/pullback/lib" "$PREFIX/lib/pullback/share" "$PREFIX/bin"
install -m 0755 "$here/bin/pullback" "$PREFIX/bin/pullback"
install -m 0644 "$here"/lib/*.sh "$PREFIX/lib/pullback/lib/"
install -m 0644 "$here"/share/* "$PREFIX/lib/pullback/share/"
chmod 0755 "$PREFIX/lib/pullback/share/pullback-notify.example"

install -d -m 0700 "$CONFDIR"
install -d -m 0700 "$DEST"

if [ -f "$CONFDIR/pullback.conf" ]; then
  echo "keeping the configuration you already have at $CONFDIR/pullback.conf"
else
  install -m 0600 "$here/share/pullback.conf.example" "$CONFDIR/pullback.conf"
  echo "wrote $CONFDIR/pullback.conf"
fi

cat <<TEXT

  Installed.

    1.  edit $CONFDIR/pullback.conf        one 'server' line per machine
    2.  pullback doctor                      checks ssh, tools and paths
    3.  pullback run                         the first snapshot
    4.  every night, pick one:
          cp $PREFIX/lib/pullback/share/pullback.{service,timer} /etc/systemd/system/
          systemctl enable --now pullback.timer
        or
          cp $PREFIX/lib/pullback/share/crontab.example /etc/cron.d/pullback

  Backups go to $DEST. Point your monitoring at 'pullback status',
  which exits non-zero as soon as a server falls behind.

TEXT
