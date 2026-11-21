#!/bin/sh
# Checks a built image the way it runs in production: read-only root filesystem, no capabilities, an arbitrary
# user, one volume for the database. Both services must answer /healthz with the version the image was built as.
# Usage: server/image_test.sh <image> <version>
set -eu
image=$1 version=$2
volume=$(docker volume create)
ids=""
trap 'docker rm -f $ids >/dev/null 2>&1; docker volume rm "$volume" >/dev/null' EXIT
# The volume belongs to root when new: hand it to the user the services run as, as a cluster's fsGroup does.
docker run --rm --user 0 --entrypoint chown -v "$volume":/app/data "$image" 1000:1000 /app/data
run() {
    docker run -d --read-only --cap-drop ALL --security-opt no-new-privileges -v "$volume":/app/data "$@"
}
ingest=$(run -p 127.0.0.1::8787 "$image" server/ledger_ingest.py)
ids="$ingest"
api=$(run -p 127.0.0.1::8788 "$image")
ids="$ids $api"
for service in "$ingest 8787" "$api 8788"; do
    set -- $service
    address=$(docker port "$1" "$2" | head -n 1)
    tries=0
    until answer=$(curl -fs "http://$address/healthz"); do
        tries=$((tries + 1))
        if [ "$tries" -ge 20 ]; then docker logs "$1"; exit 1; fi
        sleep 0.5
    done
    echo "port $2: $answer"
    [ "$answer" = "{\"status\":\"ok\",\"version\":\"$version\"}" ]
done
# A stop is obeyed at once (SIGTERM), not after the runtime's wait and a kill.
docker stop -t 5 $ids >/dev/null
for id in $ids; do
    [ "$(docker inspect -f '{{.State.ExitCode}}' "$id")" = 0 ] || { echo "$id did not stop by itself"; exit 1; }
done
echo ok
