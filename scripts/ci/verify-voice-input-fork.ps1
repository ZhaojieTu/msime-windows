param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$Certificate
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:GITHUB_REPOSITORY -ne 'ZhaojieTu/msime-windows') {
    throw 'This smoke test only runs on the disposable Windows runner for the requested fork.'
}

$proof = Join-Path $env:RUNNER_TEMP 'msime-voice-proof'
$fixture = Join-Path $env:RUNNER_TEMP 'msime-voice-fixture'
New-Item -ItemType Directory -Path $proof,$fixture -Force | Out-Null
$progress = Join-Path $proof 'acceptance.txt'
$installerLog = Join-Path $proof 'installer.log'
$expected = '水杉输入框验收，中文已上屏。'
$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$certificatePath = (Resolve-Path -LiteralPath $Certificate).Path
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
foreach ($store in 'Root','TrustedPublisher') {
    $certStore = [Security.Cryptography.X509Certificates.X509Store]::new($store,'LocalMachine')
    try {
        $certStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $certStore.Add($cert)
    } finally { $certStore.Dispose() }
}
$signature = Get-AuthenticodeSignature -LiteralPath $installerPath
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $cert.Thumbprint) {
    throw "Test installer signature verification failed: $($signature.Status)"
}
$installation = Start-Process -FilePath $installerPath -ArgumentList @(
    '/VERYSILENT','/NORESTART','/SP-',('/LOG="{0}"' -f $installerLog)
) -WindowStyle Hidden -Wait -PassThru
if ($installation.ExitCode -ne 0) { throw "Test install failed: $($installation.ExitCode)" }
$data = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Metasequoia\MetasequoiaIME' -Name DataDir).DataDir
if (-not $data -or -not (Test-Path -LiteralPath (Join-Path $data 'config.toml'))) {
    throw 'Cannot find the data directory registered by the installer'
}
'INSTALLER_OK=1','INSTALLED_CONFIG_OK=1' | Add-Content -LiteralPath $progress
foreach ($processName in 'MetasequoiaImeWatchdog','MetasequoiaImeServer') {
    Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
}

$tip = '0804:{E3062E9A-D834-4637-8958-ED8CFA427D01}{4D59B1B4-D503-44AE-9259-BAD9BB2778AB}'
$settings = Join-Path $env:ProgramFiles 'metasequoiaime\server\MetasequoiaImeSettings.exe'
$register = Start-Process -FilePath $settings -ArgumentList '--register-profile' -WindowStyle Hidden -Wait -PassThru
if ($register.ExitCode -ne 0) { throw "Test IME profile registration failed: $($register.ExitCode)" }
$list = Get-WinUserLanguageList
if (-not ($list | Where-Object { $_.InputMethodTips -contains $tip })) {
    $zh = $list | Where-Object LanguageTag -eq 'zh-Hans-CN'
    if (-not $zh) {
        $zh = (New-WinUserLanguageList 'zh-Hans-CN')[0]
        $list.Add($zh)
    }
    $zh.InputMethodTips.Add($tip)
    Set-WinUserLanguageList -LanguageList $list -Force
}
$profilePresent = [bool](Get-WinUserLanguageList | Where-Object { $_.InputMethodTips -contains $tip })
if (-not $profilePresent) { throw 'Water Fir did not appear in the Windows keyboard list' }
"PROFILE_OK=$([int]$profilePresent)" | Add-Content -LiteralPath $progress

$provider = Join-Path $fixture 'provider.py'
@'
import json
import hashlib
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

root = pathlib.Path(sys.argv[1])
text = sys.argv[2]

class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        start = raw.find(b"RIFF")
        if self.path != "/transcribe" or start < 0 or raw[start + 8:start + 12] != b"WAVE":
            self.send_error(400)
            return
        end = start + 8 + int.from_bytes(raw[start + 4:start + 8], "little")
        if end > len(raw):
            self.send_error(400)
            return
        with (root / "requests.txt").open("a", encoding="ascii") as log:
            log.write(hashlib.sha256(raw[start:end]).hexdigest() + "\n")
        response = json.dumps({"text": text}, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

server = HTTPServer(("127.0.0.1", 0), Provider)
(root / "port.txt").write_text(str(server.server_port), encoding="ascii")
server.serve_forever()
'@ | Set-Content -LiteralPath $provider
$python = (Get-Command python.exe).Source
$backend = Start-Process -FilePath $python -ArgumentList @(
    ('"{0}"' -f $provider),('"{0}"' -f $fixture),('"{0}"' -f $expected)
) -WindowStyle Hidden -PassThru
$server = $null
try {
    $portPath = Join-Path $fixture 'port.txt'
    for ($i=0; $i -lt 40 -and -not (Test-Path -LiteralPath $portPath); ++$i) {
        if ($backend.HasExited) { throw "Fixture backend exited: $($backend.ExitCode)" }
        Start-Sleep -Milliseconds 100
    }
    $port = Get-Content -LiteralPath $portPath -Raw
    $config = Join-Path $data 'config.toml'
    $before = Get-Content -LiteralPath $config -Raw
    $match = [regex]::Match($before,'(?ms)^\[voice_input\]\r?$\n.*?(?=^\[|\z)')
    if (-not $match.Success) { throw 'Installed voice configuration missing' }
    $section = $match.Value
    $values = [ordered]@{
        voice_input='true'; save_history='true'; hotkey_ctrl_f9='true'
        hotkey_ctrl_win='false'; hotkey_ralt='false'; start_sound='false'; end_sound='false'
        mute_system_audio='false'; asr_provider='"custom"'; asr_token_custom='"smoke-only-token"'
        asr_endpoint=('"http://127.0.0.1:{0}/transcribe"' -f $port)
        asr_model='"fork-smoke"'; polish_text='false'; commit_mode='"tsf"'
    }
    foreach ($pair in $values.GetEnumerator()) {
        $pattern = '(?m)^('+[regex]::Escape($pair.Key)+'[ \t]*=[ \t]*)[^\r\n]*'
        if ([regex]::Matches($section,$pattern).Count -ne 1) { throw "Unexpected voice key $($pair.Key)" }
        $value = [string]$pair.Value
        $section = [regex]::Replace($section,$pattern,{param($m) $m.Groups[1].Value+$value})
    }
    $after=$before.Substring(0,$match.Index)+$section+$before.Substring($match.Index+$match.Length)
    $after=$after -replace '(?m)^cloud_candidates[ \t]*=[ \t]*true','cloud_candidates = false'
    [IO.File]::WriteAllText($config,$after,[Text.UTF8Encoding]::new($false))
    $env:METASEQUOIA_IME_DATA_DIR=$data
    $env:METASEQUOIA_IME_CONFIG_DIR=$data
    $exe = Join-Path $env:ProgramFiles 'metasequoiaime\server\MetasequoiaImeServer.exe'
    $server = Start-Process -FilePath $exe -ArgumentList '--watchdog-managed' -WorkingDirectory (Split-Path -Parent $exe) -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    if ($server.HasExited) { throw "Installed server exited: $($server.ExitCode)" }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VoiceSmoke
{
    private static readonly UIntPtr Zero = UIntPtr.Zero;
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    private static void Down(byte key) { keybd_event(key, 0, 0, Zero); }
    private static void Up(byte key) { keybd_event(key, 0, 2, Zero); }
    public static void Press(byte key) { Down(key); Up(key); }
    public static void Switch() { Down(91); Press(32); Up(91); }
    public static void Toggle() { Down(162); Press(120); Up(162); }

    [StructLayout(LayoutKind.Sequential)]
    public struct Profile
    {
        public uint Type;
        public ushort Language;
        public Guid Clsid, Id, Category;
        public IntPtr HklSubstitution;
        public uint Capabilities;
        public IntPtr Hkl;
        public uint Flags;
    }
    [ComImport, Guid("71C6E74C-0F28-11D8-A82A-00065B84435C"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IProfiles
    {
        void Activate(); void Deactivate(); void Get(); void Enum(); void Release(); void Register(); void Unregister();
        [PreserveSig] int GetActiveProfile(ref Guid category, out Profile profile);
    }
    public static string Active()
    {
        var cls = new Guid("33C53A50-F456-4884-B049-85FD643ECFED");
        var cat = new Guid("34745C63-B2F0-4784-8B67-5E12C8701A31");
        var manager = (IProfiles)Activator.CreateInstance(Type.GetTypeFromCLSID(cls));
        try {
            Profile profile;
            return manager.GetActiveProfile(ref cat, out profile) == 0 ? profile.Clsid.ToString("D") : "";
        } finally { Marshal.ReleaseComObject(manager); }
    }
}
'@
    $form=[Windows.Forms.Form]::new()
    $form.Text='Water Fir PR #1 native voice fixture'
    $form.Size=[Drawing.Size]::new(650,260)
    $form.StartPosition='CenterScreen'
    $form.TopMost=$true
    $editor=[Windows.Forms.TextBox]::new()
    $editor.Multiline=$true
    $editor.Dock='Fill'
    $form.Controls.Add($editor)
    $form.Add_Shown({$form.Activate(); [void][VoiceSmoke]::SetForegroundWindow($form.Handle); [void]$editor.Focus()})
    $timer=[Windows.Forms.Timer]::new()
    $script:stage='select'
    $script:ticks=0
    $script:passed=$false
    $script:why=''
    $timer.Interval=550
    $timer.Add_Tick({
        try {
            if (++$script:ticks -gt 50) { throw "Timed out in stage $script:stage" }
            if ([VoiceSmoke]::GetForegroundWindow() -ne $form.Handle -or -not $editor.Focused) {
                if ($script:stage -eq 'select') {
                    $form.Activate(); [void][VoiceSmoke]::SetForegroundWindow($form.Handle); [void]$editor.Focus()
                    return
                }
                throw "Native input lost focus in stage $script:stage"
            }
            switch ($script:stage) {
                'select' {
                    $active=[VoiceSmoke]::Active()
                    if ($active -ne 'e3062e9a-d834-4637-8958-ed8cfa427d01') { [VoiceSmoke]::Switch(); return }
                    'TSF_PROFILE_ACTIVE=1' | Add-Content -LiteralPath $progress
                    $script:stage='canary'
                }
                'canary' {
                    foreach($key in 78,73,72,65,79){ [VoiceSmoke]::Press($key); Start-Sleep -Milliseconds 65 }
                    $script:stage='commit-canary'
                }
                'commit-canary' { [VoiceSmoke]::Press(32); $script:stage='verify-canary' }
                'verify-canary' {
                    if($editor.Text -cne '你好'){ throw "Typing canary did not insert 你好. Length=$($editor.TextLength)" }
                    'TYPING_CANARY=1' | Add-Content -LiteralPath $progress
                    $editor.Clear()
                    [VoiceSmoke]::Toggle()
                    $script:stage='stop'
                }
                'stop' { [VoiceSmoke]::Toggle(); $script:stage='verify' }
                'verify' {
                    if ($editor.Text -ceq $expected) { $script:passed=$true; $form.Close() }
                    elseif ($editor.TextLength -gt $expected.Length) { throw "Unexpected extra text in the native editor" }
                }
            }
        } catch {
            $script:why=$_.Exception.Message
            $form.Close()
        }
    })
    try {
        $timer.Start()
        [void]$form.ShowDialog()
        "HOST_TEXT_LENGTH=$($editor.TextLength)" | Add-Content -LiteralPath $progress
    } finally { $timer.Dispose(); $form.Dispose() }
    if (-not $script:passed) { throw "Native Edit commit not verified: $script:why" }
    $requests = @(Get-Content -LiteralPath (Join-Path $fixture 'requests.txt'))
    if ($requests.Count -ne 1) {throw 'Unexpected fixture upload count'}
    $history = Join-Path $data 'voice-history'
    $texts = @(Get-ChildItem -LiteralPath $history -Recurse -File -Filter 'transcript.txt')
    if ($texts.Count -ne 1 -or [IO.File]::ReadAllText($texts[0].FullName) -cne $expected) {throw 'Original transcript recovery mismatch'}
    'NATIVE_EDIT_COMMIT=1','ASR_UPLOAD=1','ORIGINAL_TRANSCRIPT=1' | Add-Content -LiteralPath $progress
    $wavPath = Join-Path $texts[0].DirectoryName 'recording.wav'
    $meta = & $python -c 'import json,sys,wave; w=wave.open(sys.argv[1],"rb"); print(json.dumps(dict(channels=w.getnchannels(),width=w.getsampwidth(),rate=w.getframerate(),frames=w.getnframes()),separators=(",",":")))' $wavPath
    if($LASTEXITCODE -ne 0){throw 'Cannot parse saved WAV'}
    "ORIGINAL_WAV_METADATA=$meta" | Add-Content -LiteralPath $progress
    $wav = $meta | ConvertFrom-Json
    if ($wav.channels -ne 1 -or $wav.width -ne 2 -or $wav.rate -ne 16000 -or $wav.frames -lt 4000) {
        throw "Unexpected short-recording PCM WAV format: $meta"
    }
    if ((Get-FileHash -LiteralPath $wavPath -Algorithm SHA256).Hash -ne $requests[0]) {
        throw 'The saved original WAV differs from the WAV sent for recognition'
    }
    'ORIGINAL_WAV=1','ORIGINAL_WAV_MATCHES_UPLOAD=1' | Add-Content -LiteralPath $progress
} finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -ErrorAction SilentlyContinue }
    if ($backend -and -not $backend.HasExited) { Stop-Process -Id $backend.Id -ErrorAction SilentlyContinue }
    Get-Content -LiteralPath $progress
}
