#!/usr/bin/env bash
# Print the LD_LIBRARY_PATH QEMU should run with.
#
# prepare-qemu-macos.sh bundles EVERY library the Debian-built QEMU links
# (~100, in /opt/layerosx/lib). Pointing LD_LIBRARY_PATH at all of them also
# forces the Debian copies of libdrm, libdrm_amdgpu, libelf, libexpat, libzstd,
# libxcb, libX11, libwayland, libgbm, ... onto everything QEMU loads -- including
# the host's Vulkan driver. The Arch Mesa driver (RADV, AMD) needs its own,
# newer versions, so on hardware it failed with
#   vk_init_create_instance vk_result=Unable_to_find_a_Vulkan_driver
# while NVIDIA's self-contained driver still worked.
#
# So: link only the bundled libraries the SYSTEM doesn't have (by soname, via
# ldconfig -p) into a private directory and use that. System libraries with the
# same soname are the same ABI, just newer. Safety net: if `ldd` then reports
# anything missing or a symbol version not found, fall back to the whole bundle.
#
#   qemu-libdir.sh <bundle dir> <qemu binary>   -> prints the directory to use
set -u
BUNDLE="${1:-/opt/layerosx/lib}"
QEMU="${2:-/opt/layerosx/bin/qemu-system-x86_64}"
OUT="${XDG_RUNTIME_DIR:-/tmp}/layerosx-qemu-libs-$(id -u)"
[ -d "$BUNDLE" ] || { echo ""; exit 0; }
BUNDLE="$(cd "$BUNDLE" && pwd)"       # absolute: the links below must not dangle
rm -rf "$OUT"; mkdir -p "$OUT"
SYS="$(/sbin/ldconfig -p 2>/dev/null || ldconfig -p 2>/dev/null)"
for f in "$BUNDLE"/*.so*; do
    name="$(basename "$f")"
    if printf '%s\n' "$SYS" | grep -q "^[[:space:]]*$name "; then
        continue                       # the system has it: use the system's
    fi
    ln -sf "$f" "$OUT/$name"
done
# A system library that's too OLD for QEMU (ldd: "version `X' not found",
# or "=> not found") gets its bundled copy back -- only that one -- and we
# re-check; a few rounds settle it. Only if it still doesn't resolve (e.g.
# glibc itself is too old, which can't be bundled) fall back to everything.
for _ in 1 2 3 4 5 6 7 8; do
    check="$(LD_LIBRARY_PATH="$OUT" ldd "$QEMU" 2>&1)"
    missing="$(printf '%s\n' "$check" | sed -nE "s#^.*: (/[^:]+/)?([^/: ]+): version .* not found.*#\2#p; s#^[[:space:]]*([^ ]+) => not found#\1#p" | sort -u)"
    [ -n "$missing" ] || break
    added=0
    for name in $missing; do
        if [ -e "$BUNDLE/$name" ] && [ ! -e "$OUT/$name" ]; then ln -sf "$BUNDLE/$name" "$OUT/$name"; added=1; fi
    done
    [ "$added" = 1 ] || break
done
if printf '%s\n' "$check" | grep -qE 'not found'; then
    echo "qemu-libdir: system libraries don't satisfy QEMU -- using the whole bundle:" >&2
    printf '%s\n' "$check" | grep -E 'not found' | head -5 >&2
    echo "$BUNDLE"
else
    echo "qemu-libdir: $(ls "$OUT" | wc -l) of $(ls "$BUNDLE" | wc -l) bundled libraries used (the rest from the system)" >&2
    echo "$OUT"
fi
