# ---------------------------------------------------------
# 程序名称：AI 喝水提醒助手 (OpenAI 兼容版)
# 功能：定时调用 API 生成动态提醒语
# GitHub: https://github.com/ilovn/some_thing_funny
# 
# 【如何设置开机自动启动】：
# 1. 按下快捷键 [Win + R]，输入 shell:startup 并回车。
# 2. 在打开的文件夹窗口中，右键点击 -> 新建 -> 快捷方式。
# 3. 在“对象位置”输入：powershell.exe -WindowStyle Minimized -File "C:\你的路径\SmartWaterTips.ps1"
#    （请将上面的路径替换为你脚本实际存放的完整路径）。
# 4. 点击下一步并命名，之后每次开机程序就会自动最小化启动。
#
# 注意：保存时请务必选择 "UTF-8 with BOM" 编码
# ---------------------------------------------------------

# === 配置区域 (更换为你的大模型参数) ===
# 提醒间隔（分钟）
$IntervalMinutes = 3
# 大模型接入点
$ApiBaseUrl = "https://coding.dashscope.aliyuncs.com/v1/chat/completions"
# API Key
$ApiKey = "sk-sp-xxx"
# 模型名称
$ModelName = "qwen3.6-plus"

# [控制开关] 启动时是否自动清理旧的本脚本进程 (True/False)
# 开启此项可以有效防止因为多次运行导致的托盘图标残留堆积
$AutoKillOldSessions = $true

# [控制开关] 启动时是否强制重启资源管理器以清理所有残留图标 (True/False)
$ForceRestartExplorer = $false

# [控制开关] 是否在通知结束后尝试常规刷新托盘以确保图标消失 (True/False)
$AutoClearOldIcons = $true

# === 核心逻辑 ===

# 预先加载程序集
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 函数：暴力清理残留托盘图标
function Invoke-ForceClearTray {
    param([switch]$Silent)

    if ($ForceRestartExplorer -and -not $Silent) {
        Write-Host "[系统] 正在强制重启资源管理器以清理残留图标..." -ForegroundColor Yellow
        Stop-Process -Name explorer -Force
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        Write-Host "[系统] 资源管理器已重启，托盘已强制刷新。" -ForegroundColor Gray
        return
    }

    if ($AutoClearOldIcons) {
        try {
            $code = @"
                using System;
                using System.Runtime.InteropServices;
                public class TrayCleaner {
                    [DllImport("user32.dll")]
                    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
                    [DllImport("user32.dll")]
                    public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
                    [DllImport("user32.dll")]
                    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
                    [DllImport("user32.dll")]
                    public static extern bool SendMessage(IntPtr hWnd, uint Msg, int wParam, int lParam);
                    [StructLayout(LayoutKind.Sequential)]
                    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
                    
                    public static void RefreshWindow(string windowClass) {
                        IntPtr hWnd = FindWindow(windowClass, null);
                        if (windowClass == "Shell_TrayWnd") {
                            IntPtr notify = FindWindowEx(hWnd, IntPtr.Zero, "TrayNotifyWnd", null);
                            IntPtr pager = FindWindowEx(notify, IntPtr.Zero, "SysPager", null);
                            hWnd = FindWindowEx(pager, IntPtr.Zero, "ToolbarWindow32", null);
                        } else if (windowClass == "NotifyIconOverflowWindow") {
                            hWnd = FindWindowEx(hWnd, IntPtr.Zero, "ToolbarWindow32", null);
                        }

                        RECT rect;
                        if (GetWindowRect(hWnd, out rect)) {
                            for (int x = 1; x < (rect.Right - rect.Left); x += 8)
                                for (int y = 1; y < (rect.Bottom - rect.Top); y += 8)
                                    SendMessage(hWnd, 0x0200, 0, (y << 16) | x);
                        }
                    }
                }
"@
            Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
            [TrayCleaner]::RefreshWindow("Shell_TrayWnd")
            [TrayCleaner]::RefreshWindow("NotifyIconOverflowWindow")
        } catch {}
    }
}

# 函数：清理本实例的托盘图标 (增强版)
function Clear-TrayIcon {
    if ($global:notification) {
        try {
            $global:notification.Visible = $false
            # 强制 UI 线程处理隐藏消息
            [System.Windows.Forms.Application]::DoEvents()
            $global:notification.Icon = $null
            $global:notification.Dispose()
        } finally {
            $global:notification = $null
            # 运行垃圾回收强制系统回收句柄
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }
        # 配合一次模拟鼠标刷新，确保图标位图被系统移除
        Invoke-ForceClearTray -Silent
    }
}

# 函数：生成 AI 提示语
function Get-AIReminderWithSpinner {
    param([string]$StatusMessage)

    $headers = @{ "Authorization" = "Bearer $ApiKey"; "Content-Type" = "application/json" }
    $bodyObj = @{
        model = $ModelName
        messages = @(
            @{ role = "system"; content = "你是一个贴心的健康助手。请生成一句短小、幽默且富有创意的喝水提醒语。20字以内。" },
            @{ role = "user"; content = "请给我一句新的喝水提醒语" }
        )
        temperature = 0.8
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

    $job = Start-Job -ScriptBlock {
        param($url, $headers, $bodyBytes)
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $bodyBytes -UseBasicParsing -TimeoutSec 30
            return [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        } catch { return "ERROR: " + $_.Exception.Message }
    } -ArgumentList $ApiBaseUrl, $headers, $bytes

    $spinner = @('|', '/', '-', '\')
    $i = 0
    Write-Host -NoNewline "$StatusMessage "
    while ($job.State -eq "Running") {
        Write-Host -NoNewline "`r$StatusMessage $($spinner[$i % $spinner.Length])"
        $i++; Start-Sleep -Milliseconds 200
    }

    $resultRaw = Receive-Job -Job $job
    Remove-Job -Job $job
    
    Write-Host "`r$StatusMessage [完成]    " -ForegroundColor Gray
    if ($resultRaw -and $resultRaw -notlike "ERROR:*") {
        try {
            $jsonResponse = $resultRaw | ConvertFrom-Json
            return $jsonResponse.choices[0].message.content.Trim()
        } catch { return $null }
    }
    return $null
}

# 函数：发送系统通知
function Show-Notification ($message) {
    try {
        Clear-TrayIcon
        $global:notification = New-Object System.Windows.Forms.NotifyIcon
        $global:notification.Icon = [System.Drawing.SystemIcons]::Information
        $global:notification.BalloonTipTitle = "喝水时间到！"
        $global:notification.BalloonTipText = $message
        $global:notification.Visible = $true
        $global:notification.ShowBalloonTip(30000)
    }
    catch {
        Write-Host "[Error] 无法显示通知: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- 启动前检查 ---
if ($AutoKillOldSessions) {
    $currentPid = $PID
    # 查找所有正在运行的 powershell 进程，排除当前进程，并尝试找到运行本脚本的进程
    Get-Process -Name powershell, pwsh -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $currentPid } | ForEach-Object {
        $cmdLine = (Get-WmiObject Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
        if ($cmdLine -like "*SmartWaterTips.ps1*") {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            Write-Host "[系统] 已清理残留的旧版喝水助手进程 (PID: $($_.Id))" -ForegroundColor Gray
        }
    }
}

# --- 启动 ---
Clear-Host
Invoke-ForceClearTray

# --- 启动信息与初始化实例 ---
Clear-Host
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "          AI 智能喝水助手 已启动" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "   当前模型: $ModelName"
Write-Host "   提醒频率: 每 $IntervalMinutes 分钟"
Write-Host "------------------------------------------------"
Write-Host ""

try {
    $firstExample = Get-AIReminderWithSpinner -StatusMessage "[系统] 正在连接 AI 获取提醒示例"
    if (-not $firstExample) { $firstExample = "该喝水啦！记得补水哦。" }

    Write-Host ""
    Write-Host ">>> 提醒示例：""$firstExample""" -ForegroundColor Green
    Write-Host "------------------------------------------------"

    Show-Notification "助手已启动，我会在这里守护你的水分平衡。"

    while ($true) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 正在待机..." -ForegroundColor Gray
        Start-Sleep -Seconds ($IntervalMinutes * 60)

        $aiText = Get-AIReminderWithSpinner -StatusMessage "[系统] 正在请求新文案"
        if (-not $aiText) { $aiText = "虽然 AI 罢工了，但你的肾脏还在努力工作哦，快喝水！" }
        
        Write-Host "[AI 提醒]: $aiText" -ForegroundColor Green
        Show-Notification $aiText
        
        # 保持显示 20 秒后清理，避免图标堆积
        for ($wait = 20; $wait -gt 0; $wait--) {
            Write-Host -NoNewline "`r[系统] 图标展示中，倒计时 $wait 秒后自动强制移除..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
        }
        Write-Host ""
        Clear-TrayIcon
    }
}
finally {
    Clear-TrayIcon
}