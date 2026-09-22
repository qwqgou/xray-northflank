#!/usr/bin/env bash
# Kill any processes left over from a previous test run (NOT part of the image).
pkill -f 'xnf-test/bin/xray' 2>/dev/null
pkill -f 'nginxroot/usr/sbin/nginx' 2>/dev/null
sleep 1
echo "--- remaining xray/nginx processes ---"
ps -eo pid,comm,args 2>/dev/null | grep -E 'xray|nginx' | grep -v grep | head -20
echo "--- done ---"
