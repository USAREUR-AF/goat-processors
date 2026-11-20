# From `objdump --dwarf=decodedline`: one line "<file> <line> <address>" per
# source line of the engine (paths relative to src/), the line's lowest
# statement address. Standard library and files outside src/ are left out.
/^.*:(\[\+\+\])?$/ {
    f = $0
    sub(/:(\[\+\+\])?$/, "", f)
    if (f ~ /^\.\//) { sub(/^\.\//, "", f); cur = f }
    else if (f ~ /\/engines\/zig\/src\//) { sub(/^.*\/engines\/zig\/src\//, "", f); cur = f }
    else cur = ""
    next
}
cur != "" && NF >= 4 && $NF == "x" && $2 ~ /^[0-9]+$/ && $3 ~ /^0x/ {
    key = cur " " $2
    a = hex($3)
    if (!(key in best) || a < best[key]) { best[key] = a; addr[key] = $3 }
}
END { for (k in addr) print k, addr[k] }

# A hexadecimal address as a number (POSIX awk has no strtonum).
function hex(s,    i, n, c) {
    n = 0
    s = tolower(substr(s, 3))
    for (i = 1; i <= length(s); i++) {
        c = index("0123456789abcdef", substr(s, i, 1)) - 1
        n = n * 16 + c
    }
    return n
}
