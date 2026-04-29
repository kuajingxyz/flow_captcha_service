@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

cd /d "%~dp0"

echo.
echo ============================================================
echo  flow_captcha_service - 子节点启动脚本 (subnode 模式)
echo ============================================================
echo.
echo  subnode 模式在本机运行浏览器实例，并向 master 注册心跳。
echo.

:: ============================================================
:: 读取子节点配置 sub_node.env（首次运行自动生成模板）
:: ============================================================
set "SUB_ENV_FILE=sub_node.env"

if not exist "%SUB_ENV_FILE%" (
    echo [提示] 未找到配置文件，正在生成模板...
    echo.

    (
        echo # flow_captcha_service 子节点配置文件
        echo # 填写完毕后保存，再次运行 sub_start.bat 即可启动
        echo.
        echo # 主节点地址（例：http://192.168.1.100:8060）
        echo FCS_CLUSTER_MASTER_BASE_URL=http://MASTER_IP:8060
        echo.
        echo # 集群密钥（见 master data\master\setting.toml 中的 master_cluster_key）
        echo FCS_CLUSTER_MASTER_CLUSTER_KEY=your-cluster-key
        echo.
        echo # 本节点对外地址（勿填 127.0.0.1/localhost）
        echo FCS_CLUSTER_NODE_PUBLIC_BASE_URL=http://THIS_NODE_IP:8061
        echo.
        echo # 节点 API Key（用于 master 认证本节点）
        echo FCS_CLUSTER_NODE_API_KEY=your-node-api-key
        echo.
        echo # 可选：节点名称
        echo FCS_NODE_NAME=subnode-1
        echo.
        echo # 可选：服务端口（默认 8061）
        echo FCS_SERVER_PORT=8061
        echo.
        echo # 可选：浏览器实例数量
        echo FCS_BROWSER_COUNT=2
    ) > "%SUB_ENV_FILE%"

    echo  模板已生成：sub_node.env
    echo.
    echo  ======================================================
    echo  请按以下步骤操作：
    echo.
    echo   1. 用文本编辑器打开 sub_node.env
    echo   2. 填写以下 4 项必填字段：
    echo      FCS_CLUSTER_MASTER_BASE_URL      主节点地址
    echo      FCS_CLUSTER_MASTER_CLUSTER_KEY   集群密钥
    echo      FCS_CLUSTER_NODE_PUBLIC_BASE_URL  本节点对外地址
    echo      FCS_CLUSTER_NODE_API_KEY          节点认证 Key
    echo   3. 保存后重新运行本脚本
    echo  ======================================================
    echo.
    pause
    exit /b 0
)

:: ============================================================
:: 解析配置文件键值对
:: ============================================================
echo [读取] 加载配置文件: %SUB_ENV_FILE%

for /f "usebackq tokens=1,* delims==" %%A in ("%SUB_ENV_FILE%") do (
    set "raw_line=%%A"
    if not "!raw_line:~0,1!"=="#" (
        if not "%%A"=="" (
            if not "%%B"=="" (
                set "%%A=%%B"
            )
        )
    )
)

:: ============================================================
:: 校验必填配置
:: ============================================================
set "CONFIG_VALID=1"

if not defined FCS_CLUSTER_MASTER_BASE_URL (
    echo [错误] FCS_CLUSTER_MASTER_BASE_URL 未设置
    set "CONFIG_VALID=0"
)
if "%FCS_CLUSTER_MASTER_BASE_URL%"=="http://MASTER_IP:8060" (
    echo [错误] FCS_CLUSTER_MASTER_BASE_URL 仍为示例值，请修改
    set "CONFIG_VALID=0"
)
if not defined FCS_CLUSTER_MASTER_CLUSTER_KEY (
    echo [错误] FCS_CLUSTER_MASTER_CLUSTER_KEY 未设置
    set "CONFIG_VALID=0"
)
if "%FCS_CLUSTER_MASTER_CLUSTER_KEY%"=="your-cluster-key" (
    echo [错误] FCS_CLUSTER_MASTER_CLUSTER_KEY 仍为示例值，请修改
    set "CONFIG_VALID=0"
)
if not defined FCS_CLUSTER_NODE_PUBLIC_BASE_URL (
    echo [错误] FCS_CLUSTER_NODE_PUBLIC_BASE_URL 未设置
    set "CONFIG_VALID=0"
)
if "%FCS_CLUSTER_NODE_PUBLIC_BASE_URL%"=="http://THIS_NODE_IP:8061" (
    echo [错误] FCS_CLUSTER_NODE_PUBLIC_BASE_URL 仍为示例值，请修改
    set "CONFIG_VALID=0"
)
if not defined FCS_CLUSTER_NODE_API_KEY (
    echo [错误] FCS_CLUSTER_NODE_API_KEY 未设置
    set "CONFIG_VALID=0"
)
if "%FCS_CLUSTER_NODE_API_KEY%"=="your-node-api-key" (
    echo [错误] FCS_CLUSTER_NODE_API_KEY 仍为示例值，请修改
    set "CONFIG_VALID=0"
)

if "%CONFIG_VALID%"=="0" (
    echo.
    echo [错误] 配置校验失败，请修改 %SUB_ENV_FILE% 后重试
    pause
    exit /b 1
)

echo       配置加载成功
echo  Master: %FCS_CLUSTER_MASTER_BASE_URL%
echo  Node  : %FCS_CLUSTER_NODE_PUBLIC_BASE_URL%

:: ============================================================
:: 步骤 1：检测并安装 uv
:: ============================================================
echo.
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
:: 步骤 2：创建 Python 虚拟环境
:: ============================================================
echo.
echo [2/5] 准备 Python 虚拟环境...

if not exist ".venv\Scripts\python.exe" (
    echo       正在使用 uv 创建 Python 3.11 虚拟环境...
    "%UV_CMD%" venv .venv --python 3.11
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

set "VENV_PYTHON=.venv\Scripts\python.exe"

:: ============================================================
:: 步骤 3：安装项目依赖（含 Playwright 与 nodriver）
:: ============================================================
echo.
echo [3/5] 安装项目依赖 (requirements.txt)...
echo       包含 Playwright 与 nodriver，首次下载可能较慢

"%UV_CMD%" pip install --python "%VENV_PYTHON%" -r requirements.txt
if %errorlevel% neq 0 (
    echo.
    echo [错误] 依赖安装失败，请检查网络或 pip 源设置。
    pause
    exit /b 1
)
echo       依赖安装完成

:: ============================================================
:: 步骤 4：安装 Playwright Chromium
:: ============================================================
echo.
echo [4/5] 检查/安装 Playwright Chromium...

set "PLAYWRIGHT_BROWSERS_PATH=0"
"%VENV_PYTHON%" -m playwright install chromium
if %errorlevel% neq 0 (
    echo.
    echo [警告] Playwright Chromium 安装失败，可稍后手动运行：
    echo        .venv\Scripts\python.exe -m playwright install chromium
) else (
    echo       Playwright Chromium 安装完成
)

:: ============================================================
:: 步骤 5：准备配置文件与数据目录
:: ============================================================
echo.
echo [5/5] 检查配置文件与数据目录...

if not exist "data" (
    mkdir data
    echo       已创建 data 目录
)

if not exist "data\setting.toml" (
    if exist "config\setting_example.toml" (
        copy "config\setting_example.toml" "data\setting.toml" >nul
        echo       已生成配置文件: data\setting.toml
    ) else (
        echo       [错误] 未找到配置模板 config\setting_example.toml
    )
) else (
    echo       配置文件已存在，跳过生成
)

:: ============================================================
:: 设置环境变量
:: ============================================================
set "FCS_CLUSTER_ROLE=subnode"

if not defined FCS_SERVER_PORT (
    set "FCS_SERVER_PORT=8061"
)
if not defined FCS_NODE_NAME (
    set "FCS_NODE_NAME=subnode-1"
)

:: ============================================================
:: 启动服务
:: ============================================================
echo.
echo ============================================================
echo  正在以 subnode 模式启动 flow_captcha_service...
echo.
echo  节点地址：http://127.0.0.1:%FCS_SERVER_PORT%/
echo  管理后台：http://127.0.0.1:%FCS_SERVER_PORT%/admin
echo  健康检查：http://127.0.0.1:%FCS_SERVER_PORT%/api/v1/health
echo.
echo  Role  : subnode
echo  Name  : %FCS_NODE_NAME%
echo  Master: %FCS_CLUSTER_MASTER_BASE_URL%
echo  Node  : %FCS_CLUSTER_NODE_PUBLIC_BASE_URL%
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
