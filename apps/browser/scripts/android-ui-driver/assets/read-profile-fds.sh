#!/bin/sh
set -eu

case ${1:-} in ''|*[!0-9]*) exit 2 ;; esac
directory=/proc/$1/fd
set -- "$directory"/*
initial=$*
count=$#
metadata=$(stat -L -c '%f:%d:%i' "$@") || exit 1
for fd do
    # Keep trailing newlines in the target. Positional parameters preserve the bytes until recheck.
    target=$(readlink -n "$fd" && printf .) || exit 1
    set -- "$@" "$fd" "$target"
done
shift "$count"

newline='
'
remaining=$metadata
while [ "$#" -ne 0 ]; do
    fd=$1
    target=$2
    current=$(readlink -n "$fd" && printf .) || exit 1
    [ "$target" = "$current" ] || exit 1
    entry=${remaining%%"$newline"*}
    [ -n "$entry" ] || exit 1
    case $remaining in
        *"$newline"*) remaining=${remaining#*"$newline"} ;;
        *) remaining= ;;
    esac
    printf '%s\000%s\000' "${entry%%:*}" "${target%.}"
    shift 2
done
[ -z "$remaining" ] || exit 1
set -- "$directory"/*
[ "$initial" = "$*" ] || exit 1
current=$(stat -L -c '%f:%d:%i' "$@") || exit 1
[ "$metadata" = "$current" ] || exit 1
printf 'end\000'
