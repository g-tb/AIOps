#!/usr/bin/env bash
# Network chaos on ONE pod of a deployment, with tc netem from an ephemeral container.
#   loss  -> 100 % packet loss: the pod is cut off from the network (interruption).
#   delay -> DELAY_MS of latency on every outgoing packet (degradation).
# The rule lives in the pod's network namespace, so it survives container restarts
# (the liveness probe will restart the container in loss mode) until it is removed.
# Usage: bash network-chaos.sh [deployment] [loss|delay] [seconds]
#        bash network-chaos.sh --restore <pod>
set -Eeuo pipefail

if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash network-chaos.sh [deployment=pharmago-pharmacy-service] [loss|delay] [segundos=120]'
    echo '     bash network-chaos.sh --restore <pod>   (borra la regla de red de ese pod)'
    echo 'Variables: DELAY_MS (modo delay, por defecto 300), PHARMAGO_CONTEXT (por defecto minikube).'
    exit 0
fi

# Git Bash would turn container paths into Windows paths.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
NS=pharmago
IMAGE=nicolaka/netshoot:v0.13
CONTEXTO=${PHARMAGO_CONTEXT:-minikube}
[[ $(kubectl config current-context) == "$CONTEXTO" ]] || { echo "Selecciona el contexto $CONTEXTO o define PHARMAGO_CONTEXT."; exit 1; }

# Runs a tc command in a new ephemeral container of $1 and waits for its exit code.
run_tc() {
    local pod=$1 name=$2 code=""
    shift 2
    kubectl debug -n "$NS" "$pod" --profile=netadmin --image="$IMAGE" --container="$name" -- "$@" >/dev/null
    for _ in $(seq 1 60); do
        code=$(kubectl get pod -n "$NS" "$pod" \
            -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$name\")].state.terminated.exitCode}" 2>/dev/null || true)
        [[ -n $code ]] && break
        sleep 2
    done
    [[ -n $code ]] || { echo "El contenedor $name no terminó en 120 s."; return 1; }
    if [[ $code != 0 ]]; then
        kubectl logs -n "$NS" "$pod" -c "$name" 2>/dev/null || true
        return "$code"
    fi
}

restore() {
    local pod=$1
    echo "Borrando la regla de red de $pod..."
    if run_tc "$pod" "caos-red-del-$(date +%s)" tc qdisc del dev eth0 root; then
        echo "Regla borrada. El pod vuelve a responder en unos segundos (readiness cada 2 s)."
    else
        echo "No se pudo borrar la regla: se borra el pod y el Deployment crea otro con red nueva."
        kubectl delete pod -n "$NS" "$pod" --wait=false
    fi
    echo "Los contenedores efímeros terminados quedan en el pod hasta que se borre (no se pueden quitar)."
}

if [[ ${1:-} == --restore ]]; then
    [[ -n ${2:-} ]] || { echo 'Indica el pod: bash network-chaos.sh --restore <pod>'; exit 1; }
    restore "$2"
    exit
fi

DEPLOY=${1:-pharmago-pharmacy-service}
MODE=${2:-loss}
SECONDS_TO_WAIT=${3:-120}
DELAY_MS=${DELAY_MS:-300}
case $MODE in
    loss) NETEM=(loss 100%) ;;
    delay) NETEM=(delay "${DELAY_MS}ms") ;;
    *) echo "Modo desconocido: $MODE (loss o delay)."; exit 1 ;;
esac
[[ $SECONDS_TO_WAIT =~ ^[0-9]+$ ]] || { echo 'Los segundos deben ser un número.'; exit 1; }

POD=$(kubectl get pods -n "$NS" -l "app=$DEPLOY" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')
[[ -n $POD ]] || { echo "No hay pods Running de $DEPLOY."; exit 1; }

echo "Pod objetivo: $POD (modo $MODE: ${NETEM[*]}, $SECONDS_TO_WAIT s)."
if ! run_tc "$POD" "caos-red-add-$(date +%s)" tc qdisc add dev eth0 root netem "${NETEM[@]}"; then
    echo "No se pudo aplicar netem. Si el error dice 'Specified qdisc kind is unknown' o similar,"
    echo "el kernel del nodo no trae el módulo sch_netem y este script no funciona en esta máquina."
    exit 1
fi

trap 'restore "$POD"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Regla aplicada. Esperando $SECONDS_TO_WAIT s; Ctrl+C la borra antes."
echo "Mirar: War room -> fila 'Interrupción de red' y 'Endpoints listos por Service'; kubectl get pods -n $NS -w."
sleep "$SECONDS_TO_WAIT"
