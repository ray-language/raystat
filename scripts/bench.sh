#!/bin/sh
# raystat under load: for each number of receivers, a raystat on free ports and `raystat blast`
# from another process at increasing rates; how many lines arrived (from /metrics) and the
# merge time. Usage: scripts/bench.sh [RECEIVERS...]   (needs ./raystat: make build)
set -eu
RS="${*:-1 2 4 8}"
BIN="$(cd "$(dirname "$0")/.." && pwd)/raystat"
LINES=2000000
SERIES="${SERIES:-100}"

lines_in() {
    curl -s -m 5 "http://127.0.0.1:$1/metrics" | awk '/^raystat_lines_total /{print $2}'
}

printf "%-10s %-22s %12s %12s %8s %10s\n" receivers "load (4 senders)" "sent/s" "received" "lost" "max merge"
for r in $RS; do
    for rate in 5000 20000 0; do
        UP=$((40000 + $(od -An -N2 -tu2 /dev/urandom) % 10000))
        HP=$((50000 + $(od -An -N2 -tu2 /dev/urandom) % 10000))
        "$BIN" serve --udp 127.0.0.1:$UP --http 127.0.0.1:$HP --flush 1s --receivers "$r" 2>/dev/null &
        SRV=$!
        sleep 1
        before=$(lines_in $HP)
        out=$("$BIN" blast 127.0.0.1:$UP -n $LINES -s 4 -b 10 --rate $rate --series $SERIES)
        sleep 2
        after=$(curl -s -m 5 "http://127.0.0.1:$HP/metrics")
        got=$(echo "$after" | awk '/^raystat_lines_total /{print $2}')
        merge=$(echo "$after" | awk '/^raystat_merge_seconds_max /{printf "%.1f ms", $2 * 1000}')
        kill -TERM "$SRV"; wait "$SRV" || true
        persec=$(echo "$out" | sed -E 's/.* ([0-9]+) lines\/s/\1/')
        label=$([ "$rate" = 0 ] && echo "unpaced" || echo "$rate dgram/s/sender")
        got=$((got - before))
        printf "%-10s %-22s %12s %12s %7s%% %10s\n" "$r" "$label" "$persec" "$got" "$(( (LINES - got) * 100 / LINES ))" "$merge"
    done
done
