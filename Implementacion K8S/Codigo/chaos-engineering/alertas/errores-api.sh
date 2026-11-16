#!/usr/bin/env bash
# GET a una ruta inexistente: genera 404 reales sin escribir datos ni hacer login.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash errores-api.sh [--restore]. Genera errores 404 por 600 segundos.'
    exit 0
fi
[[ $# == 0 || ( $# == 1 && $1 == --restore ) ]] || exit 1
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
CONTEXTO=${PHARMAGO_CONTEXT:-minikube}
[[ $(kubectl config current-context) == "$CONTEXTO" ]] || { echo "Selecciona el contexto $CONTEXTO o define PHARMAGO_CONTEXT."; exit 1; }
POD=caos-alerta-errores
limpiar() { kubectl delete pod "$POD" -n pharmago --ignore-not-found --wait=true; }
if [[ ${1:-} == --restore ]]; then limpiar; exit; fi
[[ -z $(kubectl get pods -n pharmago -l caos=alertas -o name) ]] || { echo 'Termina la otra prueba primero.'; exit 1; }
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kubectl run "$POD" -n pharmago --image=python:3.12-alpine --restart=Never \
    --labels=caos=alertas --overrides='{"spec":{"activeDeadlineSeconds":780,"terminationGracePeriodSeconds":5}}' \
    --command -- python -u -c '
import time, urllib.request, urllib.error
fin = time.monotonic() + 600
url = "http://pharmago-users-service/api/caos-alerta-no-existe"
while time.monotonic() < fin:
    try:
        with urllib.request.urlopen(url, timeout=5) as respuesta:
            print("HTTP", respuesta.status, flush=True)
    except urllib.error.HTTPError as error:
        print("HTTP", error.code, flush=True)
        error.close()
    except Exception as error:  # timeout o conexion cortada: se sigue generando
        print("Error", type(error).__name__, flush=True)
    time.sleep(0.5)
'
kubectl logs -n pharmago -f "$POD" --pod-running-timeout=120s
kubectl wait -n pharmago --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=15s
