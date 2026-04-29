@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

cd /d "%~dp0"

echo.
echo ============================================================
echo  flow_captcha_service - 主节点启动脚本 (master 模式)
echo ============================================================
echo.
echo  master 模式仅运行集群管理与调度，不会在本机运行浏览器实例。
echo.

:: ============================================================
:: 步骤 1：检测并安装 uv
:: ============================================================
echo [1/5] 检查 uv 工具...

set "UV_CMD="

where uv >nul 2>&1
if %errorlevel% equ 0 (
    set "UV_CMD=uv"
    echo       uv 已在 PATH 中，跳过安装
    goto :uv_ready
)

if exist "%USERPROFILE%\.local\bin\uv.exe" (
    set "UV_CMD=%USERPROFILE%\.local\bin\uv.exe"
    echo       找到 uv
    goto :uv_ready
)
if exist "%USERPROFILE%\.cargo\bin\uv.exe" (
    set "UV_CMD=%USERPROFILE%\.cargo\bin\uv.exe"
    echo       找到 uv
    goto :uv_ready
)

echo       未检测到 uv，尝试自动安装...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression"
if %errorlevel% neq 0 (
    echo.
    echo [错误] uv 安装失败，请手动安装 uv 后重试。
    pause
    exit /b 1
)

if exist "%USERPROFILE%\.local\bin\uv.exe" (
    set "UV_CMD=%USERPROFILE%\.local\bin\uv.exe"
    echo       uv 安装成功
    goto :uv_ready
)
if exist "%USERPROFILE%\.cargo\bin\uv.exe" (
    set "UV_CMD=%USERPROFILE%\.cargo\bin\uv.exe"
    echo       uv 安装成功
    goto :uv_ready
)
where uv >nul 2>&1
if %errorlevel% equ 0 (
    set "UV_CMD=uv"
    echo       uv 安装成功
    goto :uv_ready
)

echo.
echo [错误] 未能安装 uv，请参考 https://docs.astral.sh/uv/ 手动安装。
pause
exit /b 1

:uv_ready

:: ============================================================
:: 步骤 2：创建或复用 Python 虚拟环境
:: ============================================================
echo.
echo [2/5] 准备 Python 虚拟环境...

:: master 使用独立虚拟环境，避免与 standalone/subnode 冲突
set "VENV_DIR=.venv-master"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo       正在使用 uv 创建 Python 3.11 虚拟环境...
    "%UV_CMD%" venv "%VENV_DIR%" --python 3.11
    if %errorlevel% neq 0 (
        echo.
        echo [错误] 创建虚拟环境失败，请检查 Python 与 uv 配置。
        pause
        exit /b 1
    )
    echo       Python 3.11 虚拟环境创建成功
) else (
    echo       虚拟环境已存在，跳过创建
)

set "VENV_PYTHON=%VENV_DIR%\Scripts\python.exe"

:: ============================================================
:: 步骤 3：安装主节点依赖（轻量版，不含浏览器）
:: ============================================================
echo.
echo [3/5] 安装主节点依赖 (requirements.master.txt)...
echo       轻量版本，不含 Playwright 与 nodriver，首次需下载依赖

"%UV_CMD%" pip install --python "%VENV_PYTHON%" -r requirements.master.txt
if %errorlevel% neq 0 (
    echo.
    echo [错误] 依赖安装失败，请检查网络或 pip 源设置。
    pause
    exit /b 1
)
echo       依赖安装完成

:: ============================================================
:: 步骤 4：主节点无需本地浏览器，跳过 Playwright 安装
:: ============================================================
echo.
echo [4/5] 主节点无需 Chromium，跳过浏览器安装

:: ============================================================
:: 步骤 5：准备配置文件与数据目录
:: ============================================================
echo.
echo [5/5] 检查配置文件与数据目录...

if not exist "data" (
    mkdir data
    echo       已创建 data 目录
)

if not exist "data\master" (
    mkdir data\master
    echo       已创建 data\master 目录
)

if not exist "data\master\setting.toml" (
    if exist "config\setting_example.toml" (
        copy "config\setting_example.toml" "data\master\setting.toml" >nul
        echo       已生成配置文件: data\master\setting.toml
        echo.
        echo  ======================================================
        echo  [提示] 请编辑 data\master\setting.toml，重点确认：
        echo.
        echo   [cluster]
        echo   role = "master"
        echo   master_cluster_key = "your-cluster-key"
        echo.
        echo   [admin]
        echo   password = "your-admin-password"
        echo  ======================================================
        echo.
        pause
    ) else (
        echo       [错误] 未找到配置模板 config\setting_example.toml
    )
) else (
    echo       配置文件已存在，跳过生成
)

:: ============================================================
:: 设置环境变量（优先级高于配置文件）
:: ============================================================
set "FCS_CLUSTER_ROLE=master"
set "FCS_DB_PATH=data/master/captcha_service.db"
set "FCS_CONFIG_FILE=data/master/setting.toml"

if not defined FCS_SERVER_PORT (
    set "FCS_SERVER_PORT=8060"
)
if not defined FCS_NODE_NAME (
    set "FCS_NODE_NAME=master-1"
)

:: ============================================================
:: 启动服务
:: ============================================================
echo.
echo ============================================================
echo  正在以 master 模式启动 flow_captcha_service...
echo.
echo  用户界面：http://127.0.0.1:%FCS_SERVER_PORT%/
echo  管理后台：http://127.0.0.1:%FCS_SERVER_PORT%/admin
echo  健康检查：http://127.0.0.1:%FCS_SERVER_PORT%/api/v1/health
echo.
echo  Role   : master
echo  Name   : %FCS_NODE_NAME%
echo  Config : data\master\setting.toml
echo.
echo  按 Ctrl+C 可停止服务
echo ============================================================
echo.

"%VENV_PYTHON%" main.py

if %errorlevel% neq 0 (
    echo.
    echo [错误] 服务异常退出，错误码: %errorlevel%
    echo        请查看日志获取详情
    pause
    exit /b 1
)

pause
