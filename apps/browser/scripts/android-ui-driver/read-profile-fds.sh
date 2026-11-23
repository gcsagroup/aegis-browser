#!/bin/sh
set -eu

case ${1:-} in ''|*[!0-9]*) exit 2 ;; esac
directory=/proc/$1/fd
for fd in "$directory"/*; do
    # Keep trailing newlines in the target and reject an FD that changed during the read.
    target=$(readlink -n "$fd" && printf .) || exit 1
    mode=$(stat -L -c %f "$fd") || exit 1
    again=$(readlink -n "$fd" && printf .) || exit 1
    [ "$target" = "$again" ] || exit 1
    printf '%s\000%s\000' "$mode" "${target%.}"
done
printf 'end\000'
