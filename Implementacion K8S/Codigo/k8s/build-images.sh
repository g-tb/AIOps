#!/bin/bash
# Construye y carga imágenes Docker en Minikube.
# Compatible con Linux, macOS y Git Bash en Windows.
# Uso: bash build-images.sh

set -e

echo "=== Construyendo y cargando imágenes Docker en Minikube ==="

if ! command -v docker &> /dev/null; then
    echo "Error: Docker no está instalado o no está en el PATH"
    exit 1
fi

if ! command -v minikube &> /dev/null; then
    echo "Error: Minikube no está instalado o no está en el PATH"
    exit 1
fi

if ! minikube status &> /dev/null; then
    echo "Error: Minikube no está corriendo. Ejecuta: minikube start"
    exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CODE_DIR="$(dirname "$SCRIPT_DIR")"

echo ""
echo "Construyendo imágenes de backend..."
cd "$CODE_DIR/Backend"

echo "  - pharmago-users-service..."
docker build -f PharmaGo.UsersService/Dockerfile \
    -t pharmago-users-service:latest .
minikube image load pharmago-users-service:latest

echo "  - pharmago-pharmacy-service..."
docker build -f PharmaGo.PharmacyService/Dockerfile \
    -t pharmago-pharmacy-service:latest .
minikube image load pharmago-pharmacy-service:latest

echo "  - pharmago-api-gateway..."
docker build -f PharmaGo.ApiGateway/Dockerfile \
    -t pharmago-api-gateway:latest \
    -t pharmago-api-gateway:deploy-v3 .

minikube image load pharmago-api-gateway:latest
minikube image load pharmago-api-gateway:deploy-v3

echo ""
echo "Construyendo imagen de frontend..."
cd "$CODE_DIR/Frontend"

echo "  - pharmago-ui..."
docker build -f Dockerfile -t pharmago-ui:latest .
minikube image load pharmago-ui:latest

echo ""
echo "=== Imágenes construidas y cargadas exitosamente ==="
echo ""
echo "Verificando imágenes en Minikube..."
minikube image ls | grep pharmago

cd "$SCRIPT_DIR"