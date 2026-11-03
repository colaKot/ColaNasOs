# ColaNasOs GPU 探针（Windows）
#
# 单进程常驻，每 3 秒输出一行 JSON，内核只在请求里读缓存 —— 绝不在请求路径上采样。
#
# 为什么不用 Get-Counter / typeperf：
#   - Get-Counter 每次固定 1.6~1.9s（内部要等两次 PDH 采样），放请求里会卡死接口；
#   - typeperf 只认本地化计数器名，中文系统上拿到的是「GPU 引擎」「利用率」，拼不出来；
#   - 逐实例 new PerformanceCounter（本机 421 个实例）实测 35% 单核 / 83MB，太贵。
# 这里用 PerformanceCounterCategory.ReadCategory 批量读一次 + 自己用 RawValue 差分算百分比：
#   实测 6 次采样共 0.06s CPU（约 2% 单核），显存另用 3~6 个常驻对象读 NextValue。
#
# 输出：
#   {"t":"statics","adapters":[{"name":"...","driverVersion":"...","memTotal":8589934592}]}
#   {"t":"sample","usage":23.4,"luid":"luid_0x..._phys_0","memUsed":2559...}
# 任何一步失败都不退出循环，只跳过该轮 —— 探针挂掉不能拖垮监控。

$ErrorActionPreference = 'SilentlyContinue'

function Write-Json($obj) {
  # 中文适配器名在 GBK 代码页下会被 Node 按 UTF-8 解码成乱码，直接写标准输出字节
  $json = $obj | ConvertTo-Json -Compress -Depth 4
  $bytes = [Text.Encoding]::UTF8.GetBytes($json + "`n")
  $stdout = [Console]::OpenStandardOutput()
  $stdout.Write($bytes, 0, $bytes.Length)
  $stdout.Flush()
}

# ---- 静态信息：显卡注册表（名称 / 驱动 / 显存），只在启动时读一次 ----
$base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$adapters = @()
foreach ($k in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
  if ($k.PSChildName -notmatch '^\d{4}$') { continue }
  $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
  if (-not $p -or -not $p.DriverDesc) { continue }
  $qw = $p.'HardwareInformation.qwMemorySize'
  $adapters += [pscustomobject]@{
    name          = [string]$p.DriverDesc
    driverVersion = [string]$p.DriverVersion
    memTotal      = if ($qw) { [double]$qw } else { 0 }
  }
}
Write-Json @{ t = 'statics'; adapters = $adapters }

# ---- 计数器准备 ----
$engineCat = [Diagnostics.PerformanceCounterCategory]::new('GPU Engine')
$memCat = [Diagnostics.PerformanceCounterCategory]::new('GPU Adapter Memory')

$memCounters = @()
function Refresh-MemCounters {
  $script:memCounters = @()
  foreach ($i in $memCat.GetInstanceNames()) {
    $d = [Diagnostics.PerformanceCounter]::new('GPU Adapter Memory', 'Dedicated Usage', $i)
    $s = [Diagnostics.PerformanceCounter]::new('GPU Adapter Memory', 'Shared Usage', $i)
    # 首次 NextValue 只是建立基准，值没有意义
    $null = $d.NextValue()
    $null = $s.NextValue()
    $script:memCounters += [pscustomobject]@{ instance = $i; dedicated = $d; shared = $s }
  }
}
Refresh-MemCounters

# GPU Engine 的 Utilization 是累计型（PERF_100NSEC_TIMER），必须用两次 RawValue 差分算百分比；
# ReadCategory 每次都是新查询，CookedValue 恒为 0，所以只能自己算。
$prev = @{}
foreach ($e in $engineCat.ReadCategory()['Utilization Percentage'].Values) {
  $prev[$e.InstanceName] = [double]$e.Sample.RawValue
}

$intervalMs = 1000
$lastTicks = [DateTime]::UtcNow.Ticks
$tick = 0

while ($true) {
  Start-Sleep -Milliseconds $intervalMs
  # 首轮只等 1s（尽快让界面出数），之后回到 3s 的稳态间隔
  $intervalMs = 3000
  $tick++
  try {
    $nowTicks = [DateTime]::UtcNow.Ticks
    $elapsed = [double]($nowTicks - $lastTicks)
    $lastTicks = $nowTicks
    if ($elapsed -le 0) { continue }

    # 按 (luid, engtype) 取组内最大值：同一引擎有多个进程实例，累加会超过 100%
    $cur = @{}
    $group = @{}
    foreach ($e in $engineCat.ReadCategory()['Utilization Percentage'].Values) {
      $name = $e.InstanceName
      $raw = [double]$e.Sample.RawValue
      $cur[$name] = $raw
      if ($prev.ContainsKey($name)) {
        $delta = $raw - $prev[$name]
        if ($delta -gt 0 -and $name -match 'luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+).*engtype_([A-Za-z0-9 ]+)$') {
          $key = $Matches[1] + '|' + $Matches[2].Trim()
          $pct = $delta / $elapsed * 100
          if (-not $group.ContainsKey($key) -or $group[$key] -lt $pct) { $group[$key] = $pct }
        }
      }
    }
    $prev = $cur

    $usage = 0.0
    $busyLuid = ''
    foreach ($k in $group.Keys) {
      if ($group[$k] -gt $usage) {
        $usage = $group[$k]
        $busyLuid = $k.Split('|')[0]
      }
    }

    # 显存：专用 + 共享（核显专用显存为 0，只看 Dedicated 会永远显示 0）
    $memUsed = 0.0
    $memLuid = ''
    foreach ($m in $memCounters) {
      $used = [double]$m.dedicated.NextValue() + [double]$m.shared.NextValue()
      if ($used -gt $memUsed) {
        $memUsed = $used
        $memLuid = $m.instance
      }
    }

    # 显存占用最大的适配器就是主 GPU；引擎最忙的那个只在没显存数据时兜底
    $luid = if ($memLuid) { $memLuid } else { $busyLuid }
    Write-Json @{
      t       = 'sample'
      usage   = [math]::Round($usage, 1)
      luid    = $luid
      busyLuid = $busyLuid
      memUsed = [math]::Round($memUsed)
    }
  } catch {
    # 忽略本轮（虚拟显示器热插拔、计数器被重置等），下一轮继续
  }

  # 适配器列表会随虚拟显示器/热插拔变化，每 100 秒重建一次显存计数器
  if ($tick % 33 -eq 0) {
    try { Refresh-MemCounters } catch { }
  }
}