# Construye y carga imágenes Docker en Minikube.
# Compatible con Windows PowerShell.
# Uso: .\build-images.ps1

$ErrorActionPreference = "Stop"

Write-Host "=== Construyendo y cargando imágenes Docker en Minikube ===" `
    -ForegroundColor Green

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker no está instalado o no está en el PATH."
}

if (-not (Get-Command minikube -ErrorAction SilentlyContinue)) {
    throw "Minikube no está instalado o no está en el PATH."
}

minikube status
if ($LASTEXITCODE -ne 0) {
    throw "Minikube no está corriendo. Ejecuta: minikube start"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$codeDir = Split-Path -Parent $scriptDir

Push-Location $scriptDir

try {
    Write-Host "`nConstruyendo imágenes de backend..." `
        -ForegroundColor Yellow

    Set-Location (Join-Path $codeDir "Backend")

    Write-Host "  - pharmago-users-service..." -ForegroundColor Cyan
    docker build -f PharmaGo.UsersService/Dockerfile `
        -t pharmago-users-service:latest .
    if ($LASTEXITCODE -ne 0) {
        throw "Error construyendo pharmago-users-service."
    }

    minikube image load pharmago-users-service:latest
    if ($LASTEXITCODE -ne 0) {
        throw "Error cargando pharmago-users-service en Minikube."
    }

    Write-Host "  - pharmago-pharmacy-service..." -ForegroundColor Cyan
    docker build -f PharmaGo.PharmacyService/Dockerfile `
        -t pharmago-pharmacy-service:latest .
    if ($LASTEXITCODE -ne 0) {
        throw "Error construyendo pharmago-pharmacy-service."
    }

    minikube image load pharmago-pharmacy-service:latest
    if ($LASTEXITCODE -ne 0) {
        throw "Error cargando pharmago-pharmacy-service en Minikube."
    }

    Write-Host "  - pharmago-api-gateway..." -ForegroundColor Cyan
    docker build -f PharmaGo.ApiGateway/Dockerfile `
        -t pharmago-api-gateway:latest `
        -t pharmago-api-gateway:deploy-v2 .
    if ($LASTEXITCODE -ne 0) {
        throw "Error construyendo pharmago-api-gateway."
    }

    minikube image load pharmago-api-gateway:latest
    if ($LASTEXITCODE -ne 0) {
        throw "Error cargando pharmago-api-gateway:latest en Minikube."
    }

    minikube image load pharmago-api-gateway:deploy-v2
    if ($LASTEXITCODE -ne 0) {
        throw "Error cargando pharmago-api-gateway:deploy-v2 en Minikube."
    }

    Write-Host "`nConstruyendo imagen de frontend..." `
        -ForegroundColor Yellow

    Set-Location (Join-Path $codeDir "Frontend")

    Write-Host "  - pharmago-ui..." -ForegroundColor Cyan
    docker build -f Dockerfile -t pharmago-ui:latest .
    if ($LASTEXITCODE -ne 0) {
        throw "Error construyendo pharmago-ui."
    }

    minikube image load pharmago-ui:latest
    if ($LASTEXITCODE -ne 0) {
        throw "Error cargando pharmago-ui en Minikube."
    }

    Write-Host "`n=== Imágenes construidas y cargadas exitosamente ===" `
        -ForegroundColor Green

    Write-Host "`nVerificando imágenes en Minikube..."
    $imageList = minikube image ls
    if ($LASTEXITCODE -ne 0) {
        throw "Error consultando las imágenes de Minikube."
    }

    $imageList | Select-String "pharmago"
}
finally {
    Pop-Location
}