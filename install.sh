#!/bin/sh

cd $(dirname $0)
VER=0.5.3

(
 cd src/slackware-live-$VER
  patch -p1 < ../patches.patch 
)

install -d -m 755 $DESTDIR/usr/doc/slackware-live-$VER
install -d -m 755 $DESTDIR/install
install -d -m 755 $DESTDIR/usr/sbin
install -d -m 755 $DESTDIR/usr/share/slackware-live
install -d -m 755 $DESTDIR/usr/src/slackware-live-$VER

install -m 755 src/slackware-live-$VER/scripts/build-slackware-live.sh \
$DESTDIR/usr/sbin/
install -m 644 src/slackware-live-$VER/scripts/init \
$DESTDIR/usr/share/slackware-live
install -m 644 src/keymaps \
$DESTDIR/usr/share/slackware-live
install -m 644 src/patches.patch \
$DESTDIR/usr/src/slackware-live-$VER
install -m 644 src/keymaps \
$DESTDIR/usr/src/slackware-live-$VER

for i in `ls src/slackware-live-$VER/doc`; do
install -m 644 src/slackware-live-$VER/doc/${i} \
$DESTDIR/usr/doc/slackware-live-$VER/
done
