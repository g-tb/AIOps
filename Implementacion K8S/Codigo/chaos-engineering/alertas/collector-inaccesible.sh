#!/usr/bin/env bash
# Detiene el Collector OTLP por 120s y luego restablece su replica original.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash collector-inaccesible.sh [--restore]. Requiere el Collector original de una replica.'
    exit 0
fi
[[ $# == 0 || ( $# == 1 && $1 == --restore ) ]] || exit 1
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
[[ $(kubectl config current-context) == minikube ]] || { echo 'Selecciona el contexto minikube.'; exit 1; }
limpiar() {
    kubectl scale deployment/otlp-collector -n pharmago --current-replicas=0 --replicas=1
    kubectl rollout status deployment/otlp-collector -n pharmago --timeout=120s
}
if [[ ${1:-} == --restore ]]; then
    if [[ $(kubectl get deploy otlp-collector -n pharmago -o jsonpath='{.spec.replicas}') == 0 ]]; then limpiar; fi
    exit
fi
[[ -z $(kubectl get pods -n pharmago -l caos=alertas -o name) ]] || { echo 'Termina la otra prueba primero.'; exit 1; }
[[ $(kubectl get deploy otlp-collector -n pharmago -o jsonpath='{.spec.replicas}') == 1 ]] || { echo 'Requiere una replica original.'; exit 1; }
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
kubectl scale deployment/otlp-collector -n pharmago --current-replicas=1 --replicas=0
kubectl wait -n pharmago --for=delete pod -l app=otlp-collector --timeout=90s
echo 'Collector detenido por 120 segundos. Otras metricas OTLP tendran No Data temporalmente.'
sleep 120
