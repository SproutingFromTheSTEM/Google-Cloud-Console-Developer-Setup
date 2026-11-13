# dev.ps1: use Gemini from your own terminal without ever handling the API key (Windows PowerShell).
#
#   .\dev.ps1 setup                       one-time setup (installs what's missing, signs you in, tests)
#   .\dev.ps1 status                      who you're signed in as, the app URL, and a connection test
#   .\dev.ps1 models                      models you're allowed to use
#   .\dev.ps1 ask "PROMPT" [MODEL]        send one prompt from the terminal
#   .\dev.ps1 apis                        other APIs your admin added (use them with api("NAME"))
#   .\dev.ps1 login                       sign in again or switch accounts
#   .\dev.ps1 set-url URL                 save the gemini-app URL your admin gave you
#
# If Windows blocks the script, run it as:  powershell -ExecutionPolicy Bypass -File .\dev.ps1 setup
# In your own Python code:  from gemini_access import get_client, get_model, api

param([Parameter(Position = 0)][string]$Command = "help",
      [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest)

# "Continue": gcloud writes normal status messages to stderr, which "Stop" would treat as fatal
# in Windows PowerShell 5.1. Each step checks $LASTEXITCODE instead.
$ErrorActionPreference = "Continue"
Set-Location -Path $PSScriptRoot
$DefaultModel = "gemini-3.5-flash-lite"
$Script:Py = $null

function Say($m)  { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [!] $m" -ForegroundColor Yellow }
function Stop-Dev($m) { Write-Host "`nStopped: $m" -ForegroundColor Red; exit 1 }

function Update-PathFromSystem {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
    foreach ($dir in @(
        "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin",
        "${env:ProgramFiles(x86)}\Google\Cloud SDK\google-cloud-sdk\bin",
        "$env:ProgramFiles\Google\Cloud SDK\google-cloud-sdk\bin")) {
        if ($dir -and (Test-Path $dir) -and ($env:Path -notlike "*$dir*")) { $env:Path += ";$dir" }
    }
}

function Find-Python {
    foreach ($cmd in @("py", "python", "python3")) {
        $c = Get-Command $cmd -ErrorAction SilentlyContinue
        if (-not $c) { continue }
        if ($c.Source -like "*WindowsApps*") { continue }   # Microsoft Store stub
        $extra = @(); if ($cmd -eq "py") { $extra = @("-3") }
        & $c.Source @extra -c "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)" 2>$null
        if ($LASTEXITCODE -eq 0) { $Script:Py = [pscustomobject]@{ Exe = $c.Source; Args = $extra }; return $true }
    }
    return $false
}

# No param() block on purpose, so flags like -c and --version pass straight through to Python.
function Invoke-Py { $pa = @($Script:Py.Args); & $Script:Py.Exe @pa @args }

function Install-WithWinget($id, $name) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return }
    Warn "$name not found; installing with winget (a few minutes)"
    winget install --id $id -e --accept-package-agreements --accept-source-agreements --silent | Out-Host
    Update-PathFromSystem
}

function Ensure-Python {
    if (Find-Python) { return }
    Install-WithWinget "Python.Python.3.12" "Python"
    if (-not (Find-Python)) { Stop-Dev "Python 3.9+ isn't installed. Install it from https://www.python.org/downloads/ (check 'Add Python to PATH'), open a new PowerShell window, and run this again." }
}

function Ensure-Gcloud {
    Update-PathFromSystem
    if (Get-Command gcloud -ErrorAction SilentlyContinue) { return }
    Install-WithWinget "Google.CloudSDK" "Google Cloud CLI"
    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
        Warn "Opening the Google Cloud CLI installer. Keep the default options and click through to Finish."
        $exe = Join-Path $env:TEMP "GoogleCloudSDKInstaller.exe"
        try {
            Invoke-WebRequest "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe" -OutFile $exe
            Start-Process -FilePath $exe -Wait
        } catch { Stop-Dev "Couldn't download the installer. Install it from https://cloud.google.com/sdk/docs/install#windows, then run this again." }
        Update-PathFromSystem
    }
    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) { Stop-Dev "gcloud still isn't available. Open a new PowerShell window and run this again." }
}

function Test-SignedIn { gcloud auth print-identity-token *> $null; return ($LASTEXITCODE -eq 0) }
function Get-Account   { (gcloud config get-value account 2>$null) }

function Invoke-Login {
    Write-Host "    A browser window will open. Sign in with the account your admin gave access to."
    gcloud auth login
    if ($LASTEXITCODE -ne 0) { Stop-Dev "Sign-in didn't finish. Run .\dev.ps1 login to retry." }
    Ok "Signed in as $(Get-Account)"
}

$AccessFile = Join-Path $PSScriptRoot "gemini_access.py"
function Test-UrlSet { return ($env:GEMINI_APP_URL -or -not (Get-Content $AccessFile -Raw).Contains("PASTE_GEMINI_APP_URL")) }

function Save-Url($url) {
    $url = "$url".Trim().TrimEnd("/")
    if (-not $url.StartsWith("https://")) { Stop-Dev "The URL should start with https:// (it ends in .run.app)." }
    $text = Get-Content $AccessFile -Raw
    $text = [regex]::Replace($text, '(os\.environ\.get\("GEMINI_APP_URL",\s*")[^"]*(")',
        { param($m) $m.Groups[1].Value + $url + $m.Groups[2].Value }, 1)
    [IO.File]::WriteAllText($AccessFile, $text)
    Ok "Saved the URL in gemini_access.py"
}

function Test-Connection-Gemini {
    $out = Invoke-Py -c "from gemini_access import list_models; print(', '.join(list_models()))" 2>&1
    if ($LASTEXITCODE -eq 0) { Ok "Connected. Models you can use: $out"; return $true }
    Warn "The connection test failed:"
    Write-Host "      $(($out | Select-Object -Last 1))"
    Write-Host "    - 403 Forbidden: ask your admin to run  ./admin.sh add-developer $(Get-Account)"
    Write-Host "    - 401: run  .\dev.ps1 login"
    Write-Host "    - 404 or connection error: the URL is wrong. Fix it with  .\dev.ps1 set-url https://..."
    return $false
}

function Assert-Ready {
    if (-not (Find-Python)) { Stop-Dev "Python isn't set up. Run .\dev.ps1 setup first." }
    Update-PathFromSystem
    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) { Stop-Dev "gcloud isn't installed. Run .\dev.ps1 setup first." }
    if (-not (Test-SignedIn)) { Stop-Dev "You're not signed in. Run .\dev.ps1 login" }
    if (-not (Test-UrlSet)) { Stop-Dev "The gemini-app URL isn't set. Run .\dev.ps1 set-url https://... (your admin has it)." }
}

switch ($Command) {
    "setup" {
        Say "Python";           Ensure-Python; Ok (Invoke-Py --version 2>&1)
        Say "Google Cloud CLI"; Ensure-Gcloud; Ok ((gcloud --version 2>$null | Select-Object -First 1))
        Say "Python packages"
        Invoke-Py -m pip install -q -r requirements.txt
        if ($LASTEXITCODE -ne 0) { Invoke-Py -m pip install -q --user -r requirements.txt }
        if ($LASTEXITCODE -ne 0) { Stop-Dev "pip couldn't install requirements.txt." }
        Ok "Python packages installed"
        Say "Sign in"
        if (Test-SignedIn) {
            Ok "Signed in as $(Get-Account)"
            $a = Read-Host "    Is that the account your admin gave access to? [Y/n]"
            if ($a -match '^[Nn]') { Invoke-Login }
        } else { Invoke-Login }
        Say "gemini-app URL"
        if (Test-UrlSet) { Ok "Already set" } else { Save-Url (Read-Host "    Paste the gemini-app URL from your admin") }
        Say "Testing the connection"
        if (Test-Connection-Gemini) {
            Write-Host "`nSetup complete. Try:  .\dev.ps1 ask `"Say hi`"" -ForegroundColor Green
            Write-Host "In your code:`n    from gemini_access import get_model`n    model = get_model(`"$DefaultModel`")`n    response = model.generate_content(YOUR_PROMPT)`n"
            Write-Host "Every Gemini feature (images, files, chat, streaming), as in Google's docs:`n    from gemini_access import get_client`n    client = get_client()`n"
        } else { exit 1 }
    }
    "status" {
        if (-not (Find-Python)) { Stop-Dev "Python isn't set up. Run .\dev.ps1 setup first." }
        Update-PathFromSystem
        Say "Status"
        $signed = Test-SignedIn
        if ($signed) { Ok "Signed in as $(Get-Account)" } else { Warn "Not signed in (.\dev.ps1 login)" }
        $urlSet = Test-UrlSet
        if ($urlSet) {
            $u = $env:GEMINI_APP_URL
            if (-not $u) { $u = ([regex]::Match((Get-Content $AccessFile -Raw), 'GEMINI_APP_URL",\s*"([^"]*)"')).Groups[1].Value }
            Ok "gemini-app URL: $u"
        } else { Warn "gemini-app URL not set (.\dev.ps1 set-url https://...)" }
        if ($signed -and $urlSet) { Test-Connection-Gemini | Out-Null }
    }
    "models" {
        Assert-Ready
        Invoke-Py -c "from gemini_access import list_models; print('\n'.join(list_models()))"
    }
    "ask" {
        if (-not $Rest -or $Rest.Count -lt 1) { Stop-Dev 'Usage: .\dev.ps1 ask "PROMPT" [MODEL]' }
        Assert-Ready
        $model = $DefaultModel; if ($Rest.Count -ge 2) { $model = $Rest[1] }
        $code = "import sys`nfrom gemini_access import get_model`ntry:`n    print(get_model(sys.argv[2]).generate_content(sys.argv[1]))`nexcept RuntimeError as e:`n    sys.exit('Error: %s' % e)"
        Invoke-Py -c $code $Rest[0] $model
    }
    "apis" {
        Assert-Ready
        $out = Invoke-Py -c "from gemini_access import list_apis; print('\n'.join(list_apis()))" 2>&1
        if ($LASTEXITCODE -ne 0) { Stop-Dev "$(($out | Select-Object -Last 1))" }
        $names = @($out | Where-Object { "$_".Trim() -ne "" })
        if ($names.Count -eq 0) { Write-Host "No other APIs yet. Your admin adds them with ./admin.sh add-key NAME." }
        else {
            $names | ForEach-Object { Write-Host $_ }
            Write-Host "`nIn your code:  from gemini_access import api"
            Write-Host "               r = api(`"$($names[0])`").post(`"/path/from/the/api/docs`", json={...})"
        }
    }
    "login"   { Ensure-Gcloud; Invoke-Login }
    "set-url" {
        if (-not $Rest -or $Rest.Count -ne 1) { Stop-Dev "Usage: .\dev.ps1 set-url https://gemini-app-....run.app" }
        Save-Url $Rest[0]
    }
    default {
        Get-Content $PSCommandPath | Select-Object -First 13 | ForEach-Object { $_ -replace '^# ?', '' }
    }
}
