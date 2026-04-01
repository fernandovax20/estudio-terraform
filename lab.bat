@echo off
REM ============================================================
REM SCRIPT HELPER PARA TERRAFORM LAB
REM Uso: lab.bat [comando] [modulo]
REM Ejemplos:
REM   lab.bat start          - Levantar LocalStack
REM   lab.bat stop           - Detener LocalStack
REM   lab.bat health         - Verificar estado de LocalStack
REM   lab.bat run 01         - Init + Apply del modulo 01
REM   lab.bat plan 02        - Plan del modulo 02
REM   lab.bat destroy 03     - Destroy del modulo 03
REM   lab.bat list           - Listar servicios AWS simulados
REM   lab.bat console 01     - Abrir consola terraform en modulo 01
REM   lab.bat reset          - Destruir todo y reiniciar
REM ============================================================

setlocal enabledelayedexpansion

set COMANDO=%1
set MODULO=%2
set ENDPOINT=http://localhost:4566

REM Mapeo de numero a directorio
if "%MODULO%"=="01" set MODULO_DIR=modulo-01-fundamentos
if "%MODULO%"=="02" set MODULO_DIR=modulo-02-s3
if "%MODULO%"=="03" set MODULO_DIR=modulo-03-dynamodb
if "%MODULO%"=="04" set MODULO_DIR=modulo-04-iam
if "%MODULO%"=="05" set MODULO_DIR=modulo-05-lambda
if "%MODULO%"=="06" set MODULO_DIR=modulo-06-sqs
if "%MODULO%"=="07" set MODULO_DIR=modulo-07-sns
if "%MODULO%"=="08" set MODULO_DIR=modulo-08-vpc
if "%MODULO%"=="09" set MODULO_DIR=modulo-09-modulos-reutilizables
if "%MODULO%"=="10" set MODULO_DIR=modulo-10-state
if "%MODULO%"=="11" set MODULO_DIR=modulo-11-escalamiento-vertical
if "%MODULO%"=="12" set MODULO_DIR=modulo-12-escalamiento-horizontal
if "%MODULO%"=="13" set MODULO_DIR=modulo-13-cache
if "%MODULO%"=="14" set MODULO_DIR=modulo-14-segmentacion-redes
if "%MODULO%"=="15" set MODULO_DIR=modulo-15-cicd-gitops
if "%MODULO%"=="16" set MODULO_DIR=modulo-16-backup-dr
if "%MODULO%"=="17" set MODULO_DIR=modulo-17-costos-tagging

if "%COMANDO%"=="" goto :help
if "%COMANDO%"=="help" goto :help
if "%COMANDO%"=="start" goto :start
if "%COMANDO%"=="stop" goto :stop
if "%COMANDO%"=="health" goto :health
if "%COMANDO%"=="run" goto :run
if "%COMANDO%"=="plan" goto :plan
if "%COMANDO%"=="destroy" goto :destroy
if "%COMANDO%"=="list" goto :list
if "%COMANDO%"=="console" goto :console
if "%COMANDO%"=="reset" goto :reset
if "%COMANDO%"=="fmt" goto :fmt

echo Comando desconocido: %COMANDO%
goto :help

:help
echo.
echo  USO: lab.bat [comando] [modulo]
echo.
echo  COMANDOS:
echo    start         Levantar LocalStack con Docker
echo    stop          Detener LocalStack
echo    health        Verificar estado de LocalStack
echo    run XX        Init + Apply del modulo (ej: lab run 01)
echo    plan XX       Solo plan del modulo
echo    destroy XX    Destruir recursos del modulo
echo    console XX    Consola interactiva en el modulo
echo    list          Listar recursos AWS simulados
echo    fmt           Formatear todos los archivos .tf
echo    reset         Reiniciar LocalStack (pierde todo)
echo    help          Mostrar esta ayuda
echo.
echo  MODULOS: 01-17 (ej: lab run 03)
echo.
goto :eof

:start
echo [*] Levantando LocalStack...
docker-compose up -d
echo [*] Esperando a que inicie...
timeout /t 5 /nobreak >nul
curl -s %ENDPOINT%/_localstack/health
echo.
echo [OK] LocalStack listo en %ENDPOINT%
goto :eof

:stop
echo [*] Deteniendo LocalStack...
docker-compose down
echo [OK] LocalStack detenido
goto :eof

:health
echo [*] Estado de LocalStack:
curl -s %ENDPOINT%/_localstack/health
echo.
goto :eof

:run
if "%MODULO_DIR%"=="" (
    echo ERROR: Especifica un modulo (01-17^)
    goto :eof
)
echo [*] Ejecutando modulo %MODULO%: %MODULO_DIR%
pushd %MODULO_DIR%
terraform init
terraform apply -auto-approve
echo.
echo [*] Outputs:
terraform output
popd
echo [OK] Modulo %MODULO% aplicado
goto :eof

:plan
if "%MODULO_DIR%"=="" (
    echo ERROR: Especifica un modulo (01-17^)
    goto :eof
)
echo [*] Plan del modulo %MODULO%: %MODULO_DIR%
pushd %MODULO_DIR%
terraform init -input=false
terraform plan
popd
goto :eof

:destroy
if "%MODULO_DIR%"=="" (
    echo ERROR: Especifica un modulo (01-17^)
    goto :eof
)
echo [*] Destruyendo modulo %MODULO%: %MODULO_DIR%
pushd %MODULO_DIR%
terraform destroy -auto-approve
popd
echo [OK] Modulo %MODULO% destruido
goto :eof

:console
if "%MODULO_DIR%"=="" (
    echo ERROR: Especifica un modulo (01-17^)
    goto :eof
)
echo [*] Abriendo consola en modulo %MODULO%...
pushd %MODULO_DIR%
terraform console
popd
goto :eof

:list
echo.
echo === BUCKETS S3 ===
aws --endpoint-url=%ENDPOINT% s3 ls 2>nul
echo.
echo === TABLAS DYNAMODB ===
aws --endpoint-url=%ENDPOINT% dynamodb list-tables 2>nul
echo.
echo === COLAS SQS ===
aws --endpoint-url=%ENDPOINT% sqs list-queues 2>nul
echo.
echo === TOPICS SNS ===
aws --endpoint-url=%ENDPOINT% sns list-topics 2>nul
echo.
echo === FUNCIONES LAMBDA ===
aws --endpoint-url=%ENDPOINT% lambda list-functions --query "Functions[].FunctionName" 2>nul
echo.
goto :eof

:fmt
echo [*] Formateando archivos Terraform...
for /d %%d in (modulo-*) do (
    echo   Formateando %%d...
    terraform fmt %%d
)
echo [OK] Archivos formateados
goto :eof

:reset
echo [!] Esto destruira TODOS los datos de LocalStack
set /p CONFIRMAR="Continuar? (s/n): "
if /i not "%CONFIRMAR%"=="s" (
    echo Cancelado
    goto :eof
)
docker-compose down -v
docker-compose up -d
timeout /t 5 /nobreak >nul
echo [OK] LocalStack reiniciado
goto :eof
