#!/usr/bin/env bash
# Deja Users sin endpoints de Service durante 150s. Conserva pods y replicas.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash servicio-inaccesible.sh [--restore]. Aisla temporalmente el Service de Users.'
    exit 0
fi
[[ $# == 0 || ( $# == 1 && $1 == --restore ) ]] || exit 1
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
CONTEXTO=${PHARMAGO_CONTEXT:-minikube}
[[ $(kubectl config current-context) == "$CONTEXTO" ]] || { echo "Selecciona el contexto $CONTEXTO o define PHARMAGO_CONTEXT."; exit 1; }
SERVICE=pharmago-users-service
selector() { kubectl get service "$SERVICE" -n pharmago -o go-template='{{len .spec.selector}} {{index .spec.selector "app"}}'; }
limpiar() {
    local actual
    actual=$(selector) || { echo 'No se pudo leer el selector de Users: corre de nuevo con --restore.'; return 1; }
    if [[ $actual == '1 caos-alerta-servicio' ]]; then
        kubectl patch service "$SERVICE" -n pharmago --type=json \
            -p='[{"op":"replace","path":"/spec/selector","value":{"app":"pharmago-users-service"}}]'
    fi
}
if [[ ${1:-} == --restore ]]; then limpiar; exit; fi
[[ $(selector) == "1 $SERVICE" ]] || { echo 'El selector no coincide con el original; no se modifica.'; exit 1; }
[[ -z $(kubectl get pods -n pharmago -l caos=alertas -o name) ]] || { echo 'Termina la otra prueba primero.'; exit 1; }
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
kubectl patch service "$SERVICE" -n pharmago --type=json \
    -p='[{"op":"replace","path":"/spec/selector","value":{"app":"caos-alerta-servicio"}}]'
echo 'Users no tiene endpoints accesibles por Service. Esperando 150 segundos; Ctrl+C restaura.'
sleep 150
