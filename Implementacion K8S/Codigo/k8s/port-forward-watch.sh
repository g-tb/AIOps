#!/bin/bash
# Same port-forwards as port-forward.sh, but each one is relaunched 2 s after it dies.
# A port-forward to a Service is bound to one pod: deleting that pod (chaos, rollouts)
# kills it. This version reconnects on its own, which is what chaos tests and the
# war-room need. port-forward.sh stays as the simple option.
# Usage: bash port-forward-watch.sh
# Stop:  bash port-forward-watch.sh --stop
#
# Do not run it together with port-forward.sh: both use the same local ports.
# If 9200 is taken: ES_LOCAL_PORT=19200 bash port-forward-watch.sh

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PID_FILE="$SCRIPT_DIR/.port-forward-watch.pids"
LOG_FILE="$SCRIPT_DIR/.port-forward-watch.log"
NAMESPACE=pharmago

stop_forwards() {
    if [ -f "$PID_FILE" ]; then
        echo "Deteniendo port-forwards con reconexión..."
        while read -r pid; do
            kill "$pid" 2>/dev/null && echo "  Detenido PID $pid" || true
        done < "$PID_FILE"
        rm -f "$PID_FILE"
        echo "Listo."
    else
        echo "No hay port-forwards con reconexión en ejecución (o ya fueron detenidos)."
    fi
    exit 0
}

[ "$1" = "--stop" ] && stop_forwards

if [ -f "$PID_FILE" ]; then
    echo "Ya hay port-forwards con reconexión ($PID_FILE). Para relanzar:"
    echo "  bash port-forward-watch.sh --stop && bash port-forward-watch.sh"
    exit 1
fi
if [ -f "$SCRIPT_DIR/.port-forward.pids" ]; then
    echo "Hay port-forwards de port-forward.sh activos y usan los mismos puertos. Primero:"
    echo "  bash port-forward.sh --stop"
    exit 1
fi

# One loop per Service, in a subshell: when kubectl port-forward exits (its pod was
# deleted), it waits 2 s and starts it again. TERM from --stop kills the current kubectl.
watch_forward() {
    local target=$1 ports=$2
    (
        child=""
        trap 'kill $child 2>/dev/null; exit 0' TERM INT
        while true; do
            kubectl port-forward "$target" "$ports" -n "$NAMESPACE" >>"$LOG_FILE" 2>&1 &
            child=$!
            wait "$child"
            echo "[$(date +%H:%M:%S)] $target $ports terminó; se relanza en 2 s" >>"$LOG_FILE"
            sleep 2
        done
    ) &
    echo $! >> "$PID_FILE"
}

echo "=== Iniciando port-forwards con reconexión automática ==="
echo ""
: > "$PID_FILE"
: > "$LOG_FILE"

ES_LOCAL_PORT="${ES_LOCAL_PORT:-9200}"

watch_forward svc/pharmago-ui 4200:80
echo "  Frontend:      http://127.0.0.1:4200"
watch_forward svc/pharmago-api-gateway 5000:80
echo "  API Gateway:   http://127.0.0.1:5000"
watch_forward svc/pharmago-users-service 5001:80
echo "  Users:         http://127.0.0.1:5001"
watch_forward svc/pharmago-pharmacy-service 5002:80
echo "  Pharmacy:      http://127.0.0.1:5002"
watch_forward svc/pharmago-db 11433:1433
echo "  BD:            127.0.0.1,11433 (sa / Str0ngP@ssword!)"
watch_forward svc/prometheus 9090:9090
echo "  Prometheus:    http://127.0.0.1:9090"
watch_forward svc/grafana 3000:3000
echo "  Grafana:       http://127.0.0.1:3000 (admin/admin)"
watch_forward svc/kibana 5601:5601
echo "  Kibana:        http://127.0.0.1:5601"
watch_forward svc/elasticsearch "${ES_LOCAL_PORT}:9200"
echo "  Elasticsearch: http://127.0.0.1:${ES_LOCAL_PORT}"
watch_forward svc/jaeger 16686:16686
echo "  Jaeger:        http://127.0.0.1:16686"

echo ""
echo "Se relanzan solos 2 s después de cortarse. Registro: $LOG_FILE"
echo "Para detener: bash port-forward-watch.sh --stop"
echo ""
