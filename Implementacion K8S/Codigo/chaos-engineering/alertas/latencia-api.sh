#!/usr/bin/env bash
# Intercala un proxy de 2 segundos delante de Users; mide la demora real del Gateway.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash latencia-api.sh [--restore]. Proxy lento y GET por 600 segundos.'
    exit 0
fi
[[ $# == 0 || ( $# == 1 && $1 == --restore ) ]] || exit 1
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
CONTEXTO=${PHARMAGO_CONTEXT:-minikube}
[[ $(kubectl config current-context) == "$CONTEXTO" ]] || { echo "Selecciona el contexto $CONTEXTO o define PHARMAGO_CONTEXT."; exit 1; }
POD=caos-alerta-latencia
SERVICE=pharmago-users-service
selector() { kubectl get service "$SERVICE" -n pharmago -o go-template='{{len .spec.selector}} {{index .spec.selector "app"}}'; }
limpiar() {
    # Primero se restaura el trafico y despues se elimina el proxy.
    local actual
    actual=$(selector) || { echo 'No se pudo leer el selector de Users: corre de nuevo con --restore.'; return 1; }
    if [[ $actual == '1 caos-alerta-latencia' ]]; then
        kubectl patch service "$SERVICE" -n pharmago --type=json \
            -p='[{"op":"replace","path":"/spec/selector","value":{"app":"pharmago-users-service"}}]' || return 1
    fi
    kubectl delete pod "$POD" -n pharmago --ignore-not-found --wait=true
}
if [[ ${1:-} == --restore ]]; then limpiar; exit; fi
[[ $(selector) == "1 $SERVICE" ]] || { echo 'El selector no coincide con el original; no se modifica.'; exit 1; }
[[ -z $(kubectl get pods -n pharmago -l caos=alertas -o name) ]] || { echo 'Termina la otra prueba primero.'; exit 1; }
kubectl rollout status deployment/pharmago-users-service -n pharmago --timeout=120s
UPSTREAM=$(kubectl get pods -n pharmago -l app=pharmago-users-service \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].status.podIP}')
[[ -n $UPSTREAM ]] || { echo 'No hay un pod de Users disponible.'; exit 1; }
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kubectl run "$POD" -n pharmago --image=python:3.12-alpine --restart=Never \
    --labels=caos=alertas,app=caos-alerta-latencia --env="UPSTREAM=$UPSTREAM" \
    --override-type=strategic \
    --overrides='{"spec":{"activeDeadlineSeconds":900,"terminationGracePeriodSeconds":5,"containers":[{"name":"caos-alerta-latencia","image":"python:3.12-alpine","readinessProbe":{"tcpSocket":{"port":80},"periodSeconds":2}}]}}' \
    --command -- python -u -c '
import http.server, os, time, urllib.request, urllib.error

class Proxy(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/"):
            time.sleep(2)
        # Se reenvian los headers del cliente (Authorization incluido), salvo los de conexion.
        cabeceras = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")}
        pedido = urllib.request.Request("http://" + os.environ["UPSTREAM"] + self.path, headers=cabeceras)
        try:
            respuesta = urllib.request.urlopen(pedido, timeout=10)
        except urllib.error.HTTPError as error:
            respuesta = error
        except Exception:
            self.send_error(502)
            return
        with respuesta:
            cuerpo = respuesta.read()
            self.send_response(respuesta.status)
            self.send_header("Content-Type", respuesta.headers.get("Content-Type", "text/plain"))
            self.send_header("Content-Length", str(len(cuerpo)))
            self.end_headers()
            self.wfile.write(cuerpo)
    def do_POST(self):
        self.send_error(503, "Prueba de latencia activa: solo GET")
    do_PUT = do_DELETE = do_PATCH = do_POST

http.server.ThreadingHTTPServer(("0.0.0.0", 80), Proxy).serve_forever()
'
kubectl wait -n pharmago --for=condition=Ready "pod/$POD" --timeout=120s
kubectl patch service "$SERVICE" -n pharmago --type=json \
    -p='[{"op":"replace","path":"/spec/selector","value":{"app":"caos-alerta-latencia"}}]'
# No se tocan puertos. El Service conserva su puerto 80.
kubectl exec -n pharmago "$POD" -- python -u -c '
import time, urllib.request
fin = time.monotonic() + 600
while time.monotonic() < fin:
    inicio = time.monotonic()
    try:
        with urllib.request.urlopen("http://pharmago-api-gateway/api/roles/ping", timeout=15) as respuesta:
            print("HTTP", respuesta.status, "segundos", round(time.monotonic() - inicio, 2), flush=True)
    except Exception as error:  # 429, 5xx o timeout: se sigue generando
        print("Error", type(error).__name__, "segundos", round(time.monotonic() - inicio, 2), flush=True)
    time.sleep(1)
'
