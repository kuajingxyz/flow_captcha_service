@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

title flow_captcha_service - 一键启动脚本 (standalone 模式)

cd /d "%~dp0"

echo.
echo ============================================================
echo  flow_captcha_service - 一键启动脚本 (standalone 模式)
echo ============================================================
echo.

:: ============================================================
:: 步骤 1：检查并安装 uv
:: ============================================================
echo [1/5] 检查 uv 工具...

set "UV_CMD="

:: 先检查 PATH 中是否已有 uv
where uv >nul 2>&1
if %errorlevel% equ 0 (
    set "UV_CMD=uv"
    echo       uv 已在 PATH 中，跳过安装。
    goto :uv_ready
)

:: 检查常见默认安装路径
if exist "%USERPROFILE%\.local\bin\uv.exe" (
    set "UV_CMD=%USERPROFILE%\.local\bin\uv.exe"
    echo       找到 uv: %USERPROFILE%\.local\bin\uv.exe
    goto :uv_ready
)
if exist "%USERPROFILE%\.cargo\bin\uv.exe" (
    set "UV_CMD=%USERPROFILE%\.cargo\bin\uv.exe"
    echo       找到 uv: %USERPROFILE%\.cargo\bin\uv.exe
    goto :uv_ready
)

:: 未找到 uv，通过 PowerShell 下载安装
echo       uv 未找到，正在自动下载安装 uv...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression"
if %errorlevel% neq 0 (
    echo.
    echo [错误] uv 安装失败，请检查网络连接后重试。
    pause
    exit /b 1
)

:: 安装后再次检测
if exist "%USERPROFILE%\.local\bin\uv.exe" (
    set "UV_CMD=%USERPROFILE%\.local\bin\uv.exe"
    echo       uv 安装成功。
    goto :uv_ready
)
if exist "%USERPROFILE%\.cargo\bin\uv.exe" (
    set "UV_CMD=%USERPROFILE%\.cargo\bin\uv.exe"
    echo       uv 安装成功。
    goto :uv_ready
)
where uv >nul 2>&1
if %errorlevel% equ 0 (
    set "UV_CMD=uv"
    echo       uv 安装成功。
    goto :uv_ready
)

echo.
echo [错误] uv 安装后仍无法找到，请关闭此窗口后重新运行脚本，
echo        或手动访问 https://docs.astral.sh/uv/ 安装 uv。
pause
exit /b 1

:uv_ready

:: ============================================================
:: 步骤 2：创建 Python 3.11 虚拟环境
:: ============================================================
echo.
echo [2/5] 检查 Python 虚拟环境...

if not exist ".venv\Scripts\python.exe" (
    echo       正在使用 uv 创建 Python 3.11 虚拟环境（首次需要下载 Python，请耐心等待）...
    "%UV_CMD%" venv .venv --python 3.11
    if %errorlevel% neq 0 (
        echo.
        echo [错误] 虚拟环境创建失败。请检查网络连接并重试。
        pause
        exit /b 1
    )
    echo       Python 3.11 虚拟环境创建成功。
) else (
    echo       虚拟环境已存在，跳过创建。
)

set "VENV_PYTHON=.venv\Scripts\python.exe"
set "VENV_PIP=.venv\Scripts\pip.exe"

:: ============================================================
:: 步骤 3：安装项目依赖
:: ============================================================
echo.
echo [3/5] 安装项目依赖...
echo       （已安装的包会自动跳过，首次运行需要一段时间）

"%UV_CMD%" pip install --python "%VENV_PYTHON%" -r requirements.txt
if %errorlevel% neq 0 (
    echo.
    echo [错误] 项目依赖安装失败，请检查网络连接后重试。
    pause
    exit /b 1
)
echo       项目依赖安装完成。

:: ============================================================
:: 步骤 4：安装 Playwright Chromium 浏览器
:: ============================================================
echo.
echo [4/5] 检查 Playwright Chromium 浏览器...

:: 项目使用 PLAYWRIGHT_BROWSERS_PATH=0（浏览器存放于 playwright 包目录内），
:: 与服务运行时保持相同设置，确保安装路径一致
set "PLAYWRIGHT_BROWSERS_PATH=0"

echo       正在检查/安装 Playwright Chromium（已安装则跳过下载）...
"%VENV_PYTHON%" -m playwright install chromium
if %errorlevel% neq 0 (
    echo.
    echo [警告] Playwright Chromium 安装失败，服务启动时会尝试自动重装。
) else (
    echo       Playwright Chromium 就绪。
)

:: ============================================================
:: 步骤 5：准备配置文件与数据目录
:: ============================================================
echo.
echo [5/5] 检查配置文件与数据目录...

if not exist "data" (
    mkdir data
    echo       已创建 data 目录。
)

if not exist "data\setting.toml" (
    if exist "config\setting_example.toml" (
        copy "config\setting_example.toml" "data\setting.toml" >nul
        echo       已从模板创建配置文件: data\setting.toml
        echo       如需自定义，请编辑 data\setting.toml
    ) else (
        echo       [警告] 未找到配置模板 config\setting_example.toml，跳过。
    )
) else (
    echo       配置文件已存在，跳过。
)

:: ============================================================
:: 启动服务
:: ============================================================
echo.
echo ============================================================
echo  所有依赖就绪，正在启动 flow_captcha_service...
echo.
echo  用户门户：http://127.0.0.1:8060/
echo  管理后台：http://127.0.0.1:8060/admin
echo  健康检查：http://127.0.0.1:8060/api/v1/health
echo.
echo  按 Ctrl+C 可停止服务
echo ============================================================
echo.

"%VENV_PYTHON%" main.py

if %errorlevel% neq 0 (
    echo.
    echo [错误] 服务启动失败，退出码: %errorlevel%
    echo        请检查上方错误信息。
    pause
    exit /b 1
)

pause
