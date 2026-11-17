[CmdletBinding()]
param(
    [switch]$Integration
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }
$ScriptPath = Join-Path $here 'play.ps1'          

$script:Passed  = 0
$script:Failed  = 0
$script:Skipped = 0

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Microsoft.PowerShell.Utility\Write-Host $Text -ForegroundColor $Color
}

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    Say "FAIL: target script not found: $ScriptPath" 'Red'
    exit 2
}
# ---------------------------------------------------------------------------
# Parse the target
# ---------------------------------------------------------------------------
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Say "FAIL: PowerShell parser reported errors in play.ps1:" 'Red'
    foreach ($e in $parseErrors) { Say ("  Line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) 'Red' }
    exit 2
}
$scriptText = [System.IO.File]::ReadAllText($ScriptPath)

$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)

$functionAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))
$functionNames = @($functionAsts | ForEach-Object { $_.Name })

function Get-FunctionAst { param([string]$Name) $functionAsts | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }

$requiredFunctions = @(
    'Show-Notification', 'Remove-NotifyIcon', 'Get-MediaFiles', 'Test-NameMatch', 'Get-MediaKind',
    'Resolve-MediaPath', 'Start-VideoMode', 'Start-AudioMode', 'Invoke-DirectPlay',
    'Get-PlayablePath', 'Remove-TempAudio', 'Shuffle-Queue', 'Show-Queue', 'Open-Navigator',
    'Get-TrackDuration', 'Get-TrackPosition', 'Format-Time', 'Show-Progress', 'Set-PlayerVolume',
    'Play-Current', 'Stop-Current', 'Toggle-Pause', 'Update-KeyBuffer', 'Get-PriorityKey',
    'Seek-Relative', 'Toggle-Loop', 'Toggle-Repeat', 'Next-Track', 'Prev-Track',
    'Resume-IfWasPlaying', 'Search-And-Play', 'Exit-SearchMode', 'Start-EndOfQueueCountdown'
)
$missing = @($requiredFunctions | Where-Object { $functionNames -notcontains $_ })
if ($missing.Count -gt 0) {
    Say "FAIL: missing required functions: $($missing -join ', ')" 'Red'
    exit 2
}

# Embedded C# source ($mfSource here-string)
$csSource = $null
$mfAssign = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -eq 'mfSource'
}, $true) | Select-Object -First 1
if ($mfAssign -and $mfAssign.Right.Expression) { $csSource = [string]$mfAssign.Right.Expression.Value }
if ([string]::IsNullOrWhiteSpace($csSource)) {
    Say 'FAIL: could not extract the embedded C# source ($mfSource) from play.ps1' 'Red'
    exit 2
}

# Extension lists come straight from the script so the tests never drift from it.
foreach ($stmt in $ast.EndBlock.Statements) {
    if ($stmt -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $stmt.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        @('AudioExt', 'VideoExt', 'AllExt') -contains $stmt.Left.VariablePath.UserPath) {
        . ([scriptblock]::Create($stmt.Extent.Text))
    }
}
if (-not $AudioExt -or -not $VideoExt -or -not $AllExt) {
    Say 'FAIL: $AudioExt / $VideoExt / $AllExt were not found in play.ps1' 'Red'
    exit 2
}

# Lift every function (including the ones nested inside Start-AudioMode).
foreach ($functionAst in $functionAsts) {
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

# ---------------------------------------------------------------------------
# Test doubles
# ---------------------------------------------------------------------------
if ($onWindows) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}
else {
    Add-Type -TypeDefinition 'namespace System.Windows.Forms { public static class Application { public static void DoEvents() { } } }' -Language CSharp
}

$stubSource = @'
using System;
using System.Collections.Generic;

public static class NativeMfAudioEngine
{
    public static List<string> Calls = new List<string>();
    public static string OpenedPath = null;
    public static long DurationMs = 0;
    public static long PositionMs = 0;
    public static long LastSeekMs = -1;
    public static int State = 0;
    public static int Volume = 100;
    public static int FailNextOpens = 0;
    public static bool ThrowOnPause = false;

    public static void Reset()
    {
        Calls.Clear(); OpenedPath = null; DurationMs = 0; PositionMs = 0; LastSeekMs = -1;
        State = 0; Volume = 100; FailNextOpens = 0; ThrowOnPause = false;
    }
    public static void Open(string path)
    {
        Calls.Add("Open");
        if (FailNextOpens > 0) { FailNextOpens--; throw new InvalidOperationException("stub open failure"); }
        OpenedPath = path; State = 2;
    }
    public static void Play()  { Calls.Add("Play");  State = 2; }
    public static void Pause()
    {
        Calls.Add("Pause");
        if (ThrowOnPause) throw new InvalidOperationException("stub pause failure");
        State = 3;
    }
    public static void Stop()  { Calls.Add("Stop");  State = 1; }
    public static void Close() { Calls.Add("Close"); State = 0; }
    public static long GetDurationMilliseconds() { return DurationMs; }
    public static long GetPositionMilliseconds() { return PositionMs; }
    public static void SetPositionMilliseconds(long milliseconds) { Calls.Add("Seek"); LastSeekMs = milliseconds; PositionMs = milliseconds; }
    public static bool SetVolume(int percent) { Calls.Add("SetVolume"); Volume = Math.Max(0, Math.Min(100, percent)); return true; }
    public static int GetState() { return State; }
}

public class NativeMfPlayer
{
    public static List<string> Started = new List<string>();
    public static bool ThrowOnStart = false;
    public static void Start(string path)
    {
        if (ThrowOnStart) throw new InvalidOperationException("stub video failure");
        Started.Add(path);
    }
}
'@
$stubOk = $true
try { Add-Type -TypeDefinition $stubSource -Language CSharp }
catch { $stubOk = $false; $stubError = $_.Exception.Message }

# The REAL WavFloatConverter (pure C#, runs on any OS) lifted out of play.ps1.
$converterOk = $true
$converterError = ''
try {
    $idx = $csSource.IndexOf('public static class WavFloatConverter')
    if ($idx -lt 0) { throw 'WavFloatConverter class not found in the embedded C#' }
    $converterSrc = $converterSrc = "using System;`nusing System.Collections.Generic;`nusing System.IO;`nusing System.Text;`nusing System.Runtime.InteropServices;`n" + $csSource.Substring($idx)
    Add-Type -TypeDefinition $converterSrc -Language CSharp
}
catch { $converterOk = $false; $converterError = $_.Exception.Message }

# Mock host interaction ------------------------------------------------------
$script:HostLog = New-Object 'System.Collections.Generic.List[string]'
$script:ReadHostQueue = New-Object 'System.Collections.Generic.Queue[string]'
$script:Notifications = New-Object 'System.Collections.Generic.List[string]'
$script:AudioCalls = New-Object 'System.Collections.Generic.List[string]'

function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
        [object]$ForegroundColor, [object]$BackgroundColor, [switch]$NoNewline, [object]$Separator
    )
    [void]$script:HostLog.Add((($Object | ForEach-Object { "$_" }) -join ' '))
}

function Read-Host {
    param([string]$Prompt)
    if ($script:ReadHostQueue.Count -eq 0) { throw "Unexpected Read-Host call ('$Prompt'); no mocked response remains." }
    return $script:ReadHostQueue.Dequeue()
}

function Set-Responses { param([string[]]$Values) foreach ($v in $Values) { $script:ReadHostQueue.Enqueue($v) } }
function Test-Logged { param([string]$Pattern) return (@($script:HostLog | Where-Object { $_ -match $Pattern }).Count -gt 0) }

# Swappable implementations: wrappers are what the lifted functions call.
$script:Real = @{}
foreach ($n in 'Play-Current', 'Stop-Current', 'Update-KeyBuffer', 'Show-Notification', 'Start-AudioMode') {
    $script:Real[$n] = (Get-Item "Function:\$n").ScriptBlock
}
$script:Impl = @{}
function Play-Current       { & $script:Impl['Play-Current'] @args }
function Stop-Current       { & $script:Impl['Stop-Current'] @args }
function Update-KeyBuffer   { & $script:Impl['Update-KeyBuffer'] @args }
function Show-Notification  { & $script:Impl['Show-Notification'] @args }
function Start-AudioMode    { & $script:Impl['Start-AudioMode'] @args }
function Use-Real { param([string]$Name) $script:Impl[$Name] = $script:Real[$Name] }

function Reset-State {
    $global:Songs = @(); $global:Queue = @(); $global:Index = 0; $global:CursorIndex = 0
    $global:LastPlayedIndex = 0; $global:LoopMode = $false; $global:RepeatOne = $false
    $global:SearchMode = $false; $global:Paused = $false; $global:Alias = $null; $global:Volume = 100
    $global:SeekEnabled = $false; $global:ArrowSteps = 0; $global:PendingSeekMs = 0
    $global:LetterQueue = New-Object System.Collections.Queue
    $global:PreSearchQueue = $null; $global:PreSearchIndex = 0; $global:PreSearchFile = $null
    $global:TempAudioDir = Join-Path $script:Tmp 'tempaudio'; $global:TempAudioFile = $null
    $global:AudioHasPlayed = $false; $global:WaitingForLoop = $false; $global:Running = $true
    $global:QueueOpen = $false; $global:AudioDirectFile = $null; $global:AudioSearchArg = $null
    $global:NotifyIcon = $null
    $global:MockLastStartedFile = $null; $global:MockStopCalled = $false
    $script:MusicDir = $script:Tmp
    $script:HostLog.Clear(); $script:ReadHostQueue.Clear(); $script:Notifications.Clear(); $script:AudioCalls.Clear()
    if ($stubOk) { [NativeMfAudioEngine]::Reset(); [NativeMfPlayer]::Started.Clear(); [NativeMfPlayer]::ThrowOnStart = $false }

    $script:Impl['Play-Current']      = { $global:MockLastStartedFile = $global:Queue[$global:Index] }
    $script:Impl['Stop-Current']      = { $global:MockStopCalled = $true }
    $script:Impl['Update-KeyBuffer']  = { }
    $script:Impl['Show-Notification'] = { param($t, $x) [void]$script:Notifications.Add("$t|$x") }
    $script:Impl['Start-AudioMode']   = $script:Real['Start-AudioMode']
}

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
$script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("test_play_" + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($script:Tmp)

function Register-Result {
    param([string]$Status, [string]$Name, [string]$Message = '')
    switch ($Status) {
        'PASS' { $script:Passed++;  Say "PASS: $Name" 'Green' }
        'SKIP' { $script:Skipped++; Say "SKIP: $Name  ($Message)" 'Yellow' }
        default {
            $script:Failed++
            Say "FAIL: $Name" 'Red'
            if ($Message) { Say ("      " + $Message) 'DarkRed' }
        }
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Test)
    try {
        Reset-State
        & $Test
        Register-Result 'PASS' $Name
    }
    catch { Register-Result 'FAIL' $Name $_.Exception.Message }
}

function Skip-Case { param([string]$Name, [string]$Reason) Register-Result 'SKIP' $Name $Reason }

function Assert-True  { param($Condition, [string]$Message = 'Expected true')  if (-not $Condition) { throw $Message } }
function Assert-False { param($Condition, [string]$Message = 'Expected false') if ($Condition)      { throw $Message } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Message = 'Values differ')
    if ($Expected -ne $Actual) { throw ("{0}. Expected [{1}], actual [{2}]" -f $Message, $Expected, $Actual) }
}
function Assert-SequenceEqual {
    param([object[]]$Expected, [object[]]$Actual, [string]$Message = 'Sequences differ')
    if (@($Expected).Count -ne @($Actual).Count) {
        throw ("{0}. Expected count {1}, actual {2}" -f $Message, @($Expected).Count, @($Actual).Count)
    }
    for ($i = 0; $i -lt @($Expected).Count; $i++) {
        if ($Expected[$i] -ne $Actual[$i]) {
            throw ("{0} at index {1}: expected [{2}], actual [{3}]" -f $Message, $i, $Expected[$i], $Actual[$i])
        }
    }
}
function Assert-Logged    { param([string]$Pattern) if (-not (Test-Logged $Pattern)) { throw "Expected output matching '$Pattern'. Output was: $($script:HostLog -join ' | ')" } }
function Assert-NotLogged { param([string]$Pattern) if (Test-Logged $Pattern)      { throw "Unexpected output matching '$Pattern'" } }
function Assert-Bytes {
    param([byte[]]$Expected, [byte[]]$Actual, [string]$Message = 'Byte content differs')
    if ([Convert]::ToBase64String($Expected) -ne [Convert]::ToBase64String($Actual)) { throw $Message }
}

# File builders --------------------------------------------------------------
function Add-Le16 { param($List, [int]$Value)  $List.AddRange([System.BitConverter]::GetBytes([uint16]$Value)) }
function Add-Le32 { param($List, [long]$Value) $List.AddRange([System.BitConverter]::GetBytes([uint32]$Value)) }
function Add-Ascii { param($List, [string]$Text) $List.AddRange([System.Text.Encoding]::ASCII.GetBytes($Text)) }
function New-Junk { param($List, [int]$Count) for ($i = 0; $i -lt $Count; $i++) { $List.Add([byte](0x20 + ($i % 40))) } }

function New-WavFile {
    param(
        [string]$Path,
        [ValidateSet('pcm16', 'float32', 'float64', 'float32ext')][string]$Kind = 'pcm16',
        [double[]]$Samples = @(0.0, 0.5, -0.5, 1.0),
        [int]$Rate = 8000, [int]$Channels = 1, [int]$JunkPrefix = 0, [int]$RiffSizeDelta = 0
    )
    $bits = switch ($Kind) { 'pcm16' { 16 } 'float64' { 64 } default { 32 } }
    $bytesPer = $bits / 8
    $data = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($s in $Samples) {
        switch ($Kind) {
            'pcm16'   { $data.AddRange([System.BitConverter]::GetBytes([int16][Math]::Round($s * 32767))) }
            'float64' { $data.AddRange([System.BitConverter]::GetBytes([double]$s)) }
            default   { $data.AddRange([System.BitConverter]::GetBytes([single]$s)) }
        }
    }
    $fmtSize = if ($Kind -eq 'float32ext') { 40 } else { 16 }
    $tag = switch ($Kind) { 'pcm16' { 1 } 'float32ext' { 0xFFFE } default { 3 } }

    $f = New-Object 'System.Collections.Generic.List[byte]'
    New-Junk $f $JunkPrefix
    Add-Ascii $f 'RIFF'
    Add-Le32 $f (4 + 8 + $fmtSize + 8 + $data.Count + $RiffSizeDelta)
    Add-Ascii $f 'WAVE'
    Add-Ascii $f 'fmt '
    Add-Le32 $f $fmtSize
    Add-Le16 $f $tag
    Add-Le16 $f $Channels
    Add-Le32 $f $Rate
    Add-Le32 $f ($Rate * $Channels * $bytesPer)
    Add-Le16 $f ($Channels * $bytesPer)
    Add-Le16 $f $bits
    if ($Kind -eq 'float32ext') {
        Add-Le16 $f 22
        Add-Le16 $f $bits
        Add-Le32 $f 4
        $f.AddRange([byte[]](0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71))
    }
    Add-Ascii $f 'data'
    Add-Le32 $f $data.Count
    $f.AddRange($data.ToArray())
    [System.IO.File]::WriteAllBytes($Path, $f.ToArray())
}

# MPEG-1 Layer III, 128 kbps, 44.1 kHz -> every frame is exactly 417 bytes.
function New-Mp3File {
    param([string]$Path, [int]$Frames = 5, [int]$JunkPrefix = 0, [int]$Id3Size = -1, [switch]$FakeSyncInJunk)
    $f = New-Object 'System.Collections.Generic.List[byte]'
    if ($Id3Size -ge 0) {
        Add-Ascii $f 'ID3'
        $f.AddRange([byte[]](3, 0, 0))
        #$f.AddRange([byte[]](($Id3Size -shr 21) -band 0x7F, ($Id3Size -shr 14) -band 0x7F, ($Id3Size -shr 7) -band 0x7F, $Id3Size -band 0x7F))
		$b1 = [byte](($Id3Size -shr 21) -band 0x7F)
		$b2 = [byte](($Id3Size -shr 14) -band 0x7F)
		$b3 = [byte](($Id3Size -shr  7) -band 0x7F)
		$b4 = [byte]( $Id3Size          -band 0x7F)
		$f.AddRange([byte[]]@($b1, $b2, $b3, $b4))
        for ($i = 0; $i -lt $Id3Size; $i++) { $f.Add(0) }
    }
    if ($FakeSyncInJunk) {
        New-Junk $f 20
        $f.AddRange([byte[]](0xFF, 0xFB, 0x90, 0x00))
        for ($i = 0; $i -lt 30; $i++) { $f.Add(0) }
    }
    New-Junk $f $JunkPrefix
    for ($n = 0; $n -lt $Frames; $n++) {
        $frame = New-Object byte[] 417
        $frame[0] = 0xFF; $frame[1] = 0xFB; $frame[2] = 0x90; $frame[3] = 0x00
        $f.AddRange($frame)
    }
    [System.IO.File]::WriteAllBytes($Path, $f.ToArray())
}

function Read-All { param([string]$Path) return , [System.IO.File]::ReadAllBytes($Path) }
function New-Fixture {
    param([string]$Name)
    $dir = Join-Path $script:Tmp $Name
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    [void][System.IO.Directory]::CreateDirectory($dir)
    return $dir
}
function Touch { param([string]$Path) [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)); [System.IO.File]::WriteAllBytes($Path, [byte[]](0)) }

try {

# ===========================================================================
# 1. Structure and source hygiene
# ===========================================================================
Say ''
Say '== Structure ==' 'Cyan'

Test-Case 'Target script parses without syntax errors' {
    Assert-Equal 0 $parseErrors.Count
}
Test-Case 'Required functions are present' {
    foreach ($n in $requiredFunctions) { Assert-True ($functionNames -contains $n) "Missing function: $n" }
}
Test-Case 'Test doubles compiled (stub engine/player)' {
    Assert-True $stubOk "Stub compile failed: $stubError"
}
Test-Case 'Param block accepts the media name as remaining arguments' {
    $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'MediaArgs' }
    Assert-True ($null -ne $p) 'No $MediaArgs parameter'
    $attr = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } | Select-Object -First 1
    $named = $attr.NamedArguments | Where-Object { $_.ArgumentName -eq 'ValueFromRemainingArguments' }
    Assert-True ($null -ne $named) 'ValueFromRemainingArguments missing (unquoted names with spaces would break)'
}
# ===========================================================================
# 2. Pure helpers: matching, classification, discovery, path resolution
# ===========================================================================
Say ''
Say '== Matching, discovery and path resolution ==' 'Cyan'

Test-Case 'Test-NameMatch: case-insensitive partial match on the file name' {
    Assert-True (Test-NameMatch 'C:\Music\Blue Sky.mp3' 'blue')
    Assert-True (Test-NameMatch 'C:\Music\Blue Sky.mp3' 'SKY.MP')
    Assert-False (Test-NameMatch 'C:\Music\Blue Sky.mp3' 'night')
}
Test-Case 'Test-NameMatch: [ ] * ? are matched literally, not as wildcards' {
    Assert-True (Test-NameMatch 'C:\Music\Clip [live].mp4' '[live]')
    Assert-False (Test-NameMatch 'C:\Music\Clip live.mp4' '[live]') 'bracket text matched as a character class'
    Assert-False (Test-NameMatch 'C:\Music\Blue Sky.mp3' '*') '* must not match everything'
    Assert-False (Test-NameMatch 'C:\Music\Blue Sky.mp3' '?')
    Assert-True (Test-NameMatch 'C:\Music\what?.mp3' 'what?')
}
Test-Case 'Test-NameMatch: only the file name is searched, not the folder' {
    Assert-False (Test-NameMatch 'C:\Rock Hits\Song.mp3' 'rock')
}
Test-Case 'Get-MediaKind: audio, video, uppercase and unknown extensions' {
    foreach ($e in '.mp3', '.wav', '.flac', '.m4a', '.aac', '.wma') { Assert-Equal 'audio' (Get-MediaKind "x$e") $e }
    foreach ($e in '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.m4v') { Assert-Equal 'video' (Get-MediaKind "x$e") $e }
    Assert-Equal 'audio' (Get-MediaKind 'LOUD.MP3')
    Assert-Equal 'video' (Get-MediaKind 'clip.MKV')
    Assert-Equal 'video' (Get-MediaKind 'mystery.xyz') 'unknown types go to the GUI player'
    Assert-Equal 'video' (Get-MediaKind 'noextension')
}
Test-Case 'Extension lists are disjoint and AllExt is their union' {
    foreach ($e in $AudioExt) { Assert-False ($VideoExt -contains $e) "$e is in both lists" }
    Assert-Equal ($AudioExt.Count + $VideoExt.Count) $AllExt.Count
    foreach ($e in ($AudioExt + $VideoExt)) { Assert-True ($e.StartsWith('.') -and $e -ceq $e.ToLowerInvariant()) "bad extension entry: $e" }
}
Test-Case 'Get-MediaFiles: finds files by extension, recursively and case-insensitively' {
    $d = New-Fixture 'media1'
    foreach ($f in 'a.mp3', 'B.WAV', 'c.flac', 'd.mp4', 'e.txt', 'sub\f.m4a', 'sub\deeper\g.MKV') { Touch (Join-Path $d $f) }
    $script:MusicDir = $d
    $audio = @(Get-MediaFiles $AudioExt | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object)
    Assert-SequenceEqual @('a.mp3', 'B.WAV', 'c.flac', 'f.m4a') @($audio | Sort-Object)
    Assert-Equal 4 $audio.Count 'audio count'
    Assert-Equal 2 @(Get-MediaFiles $VideoExt).Count 'video count'
    Assert-Equal 6 @(Get-MediaFiles $AllExt).Count 'all count'
}
Test-Case 'Get-MediaFiles: directories named like media files are excluded' {
    $d = New-Fixture 'media2'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $d 'folder.mp3'))
    Touch (Join-Path $d 'real.mp3')
    $script:MusicDir = $d
    $r = @(Get-MediaFiles $AudioExt)
    Assert-Equal 1 $r.Count
    Assert-Equal 'real.mp3' (Split-Path $r[0] -Leaf)
}
Test-Case 'Get-MediaFiles: works in folders whose names contain wildcard characters' {
    $d = New-Fixture 'media [wild] (x)'
    Touch (Join-Path $d 'song.mp3')
    Touch (Join-Path $d 'sub [1]\other.flac')
    $script:MusicDir = $d
    Assert-Equal 2 @(Get-MediaFiles $AudioExt).Count
}
Test-Case 'Get-MediaFiles: empty folder gives an empty array' {
    $d = New-Fixture 'media4'
    $script:MusicDir = $d
    Assert-Equal 0 @(Get-MediaFiles $AllExt).Count
}

$rf = New-Fixture 'resolve'
foreach ($f in 'Blue Sky.mp3', 'Night Drive.mp3', 'Night Moves.flac', 'Clip [live].mp4', 'Clip live.mp4', 'notes.txt', 'sub\Rain.wav') { Touch (Join-Path $rf $f) }

Test-Case 'Resolve-MediaPath: full path is returned as-is' {
    $script:MusicDir = $rf
    $p = Join-Path $rf 'Blue Sky.mp3'
    Assert-Equal (Get-Item -LiteralPath $p).FullName (Resolve-MediaPath $p $AllExt)
}
Test-Case 'Resolve-MediaPath: file name relative to the media folder' {
    $script:MusicDir = $rf
    Assert-Equal (Join-Path $rf 'Blue Sky.mp3') (Resolve-MediaPath 'Blue Sky.mp3' $AllExt)
}
Test-Case 'Resolve-MediaPath: partial name (single match, incl. sub-folders)' {
    $script:MusicDir = $rf
    Assert-Equal (Join-Path $rf 'Blue Sky.mp3') (Resolve-MediaPath 'blue' $AllExt)
    Assert-Equal (Join-Path (Join-Path $rf 'sub') 'Rain.wav') (Resolve-MediaPath 'rain' $AllExt)
}
Test-Case 'Resolve-MediaPath: surrounding quotes and spaces are trimmed' {
    $script:MusicDir = $rf
    Assert-Equal (Join-Path $rf 'Blue Sky.mp3') (Resolve-MediaPath '  "Blue Sky.mp3"  ' $AllExt)
}
Test-Case 'Resolve-MediaPath: blank input returns null' {
    $script:MusicDir = $rf
    Assert-Equal $null (Resolve-MediaPath '   ' $AllExt)
}
Test-Case 'Resolve-MediaPath: no match throws a clear error' {
    $script:MusicDir = $rf
    $threw = $false
    try { [void](Resolve-MediaPath 'zzz-not-here' $AllExt) } catch { $threw = $true; Assert-True ($_.Exception.Message -match 'No media found') }
    Assert-True $threw 'Expected an exception'
}
Test-Case 'Resolve-MediaPath: several matches -> picker returns the chosen entry' {
    $script:MusicDir = $rf
    Set-Responses '2'
    Assert-Equal (Join-Path $rf 'Night Moves.flac') (Resolve-MediaPath 'Night' $AllExt)
    Set-Responses '1'
    Assert-Equal (Join-Path $rf 'Night Drive.mp3') (Resolve-MediaPath 'Night' $AllExt)
    Assert-Logged 'did you mean'
}
Test-Case 'Resolve-MediaPath: picker cancel (0), out-of-range and non-numeric return null' {
    $script:MusicDir = $rf
    foreach ($answer in '0', '9', 'abc', '') {
        Set-Responses $answer
        Assert-Equal $null (Resolve-MediaPath 'Night' $AllExt) "answer '$answer'"
    }
}
Test-Case 'Resolve-MediaPath: [brackets] in the typed name are literal' {
    $script:MusicDir = $rf
    Assert-Equal (Join-Path $rf 'Clip [live].mp4') (Resolve-MediaPath '[live]' $AllExt)
}
Test-Case 'Resolve-MediaPath: the extension filter limits the name search' {
    $script:MusicDir = $rf
    $threw = $false
    try { [void](Resolve-MediaPath 'clip' $AudioExt) } catch { $threw = $true }
    Assert-True $threw 'video files must not match an audio-only search'
}
Test-Case 'Resolve-MediaPath: an existing file with any extension is accepted by path' {
    $script:MusicDir = $rf
    $p = Join-Path $rf 'notes.txt'
    Assert-Equal (Get-Item -LiteralPath $p).FullName (Resolve-MediaPath $p $AllExt)
}

# ===========================================================================
# 3. Direct play / video launcher (video part, unit level)
# ===========================================================================
Say ''
Say '== Direct play and video launcher ==' 'Cyan'

Test-Case 'Invoke-DirectPlay: audio file -> audio mode with that file; GUI not used' {
    $script:MusicDir = $rf
    $script:Impl['Start-AudioMode'] = { [void]$script:AudioCalls.Add("$($global:AudioDirectFile)") }
    Invoke-DirectPlay 'Blue Sky.mp3'
    Assert-Equal 1 $script:AudioCalls.Count
    Assert-Equal (Join-Path $rf 'Blue Sky.mp3') $script:AudioCalls[0]
    Assert-Equal 0 ([NativeMfPlayer]::Started.Count)
    Assert-Equal $null $global:AudioSearchArg
}
Test-Case 'Invoke-DirectPlay: video file -> GUI player with the resolved path' {
    $script:MusicDir = $rf
    $script:Impl['Start-AudioMode'] = { [void]$script:AudioCalls.Add('called') }
    Invoke-DirectPlay 'live]'
    Assert-Equal 0 $script:AudioCalls.Count
    Assert-Equal 1 ([NativeMfPlayer]::Started.Count)
    Assert-Equal (Join-Path $rf 'Clip [live].mp4') ([NativeMfPlayer]::Started[0])
}
Test-Case 'Invoke-DirectPlay: every audio extension routes to audio, every video extension to the GUI' {
    $d = New-Fixture 'direct'
    $script:MusicDir = $d
    $script:Impl['Start-AudioMode'] = { [void]$script:AudioCalls.Add("$($global:AudioDirectFile)") }
    foreach ($e in $AudioExt) { Touch (Join-Path $d "a$e"); Invoke-DirectPlay (Join-Path $d "a$e") }
    foreach ($e in $VideoExt) { Touch (Join-Path $d "v$e"); Invoke-DirectPlay (Join-Path $d "v$e") }
    Assert-Equal $AudioExt.Count $script:AudioCalls.Count 'audio calls'
    Assert-Equal $VideoExt.Count ([NativeMfPlayer]::Started.Count) 'video calls'
}
Test-Case 'Invoke-DirectPlay: unknown extension that exists goes to the GUI player' {
    $script:MusicDir = $rf
    $script:Impl['Start-AudioMode'] = { [void]$script:AudioCalls.Add('called') }
    Invoke-DirectPlay (Join-Path $rf 'notes.txt')
    Assert-Equal 0 $script:AudioCalls.Count
    Assert-Equal 1 ([NativeMfPlayer]::Started.Count)
}
Test-Case 'Invoke-DirectPlay: unknown name prints an error and starts nothing' {
    $script:MusicDir = $rf
    $script:Impl['Start-AudioMode'] = { [void]$script:AudioCalls.Add('called') }
    Invoke-DirectPlay 'zzz-not-here'
    Assert-Logged '\[ERROR\].*No media found'
    Assert-Equal 0 $script:AudioCalls.Count
    Assert-Equal 0 ([NativeMfPlayer]::Started.Count)
}
Test-Case 'Invoke-DirectPlay: cancelled picker starts nothing' {
    $script:MusicDir = $rf
    $script:Impl['Start-AudioMode'] = { [void]$script:AudioCalls.Add('called') }
    Set-Responses '0'
    Invoke-DirectPlay 'Night'
    Assert-Logged 'Cancelled'
    Assert-Equal 0 $script:AudioCalls.Count
    Assert-Equal 0 ([NativeMfPlayer]::Started.Count)
}
Test-Case 'Invoke-DirectPlay: a failing GUI player is reported, not thrown' {
    $script:MusicDir = $rf
    [NativeMfPlayer]::ThrowOnStart = $true
    Invoke-DirectPlay (Join-Path $rf 'Clip live.mp4')
    Assert-Logged '\[ERROR\].*stub video failure'
}
Test-Case 'Start-VideoMode: path typed at the prompt opens the GUI player' {
    $script:MusicDir = $rf
    Set-Responses (Join-Path $rf 'Clip live.mp4')
    Start-VideoMode
    Assert-Equal 1 ([NativeMfPlayer]::Started.Count)
    Assert-Equal (Join-Path $rf 'Clip live.mp4') ([NativeMfPlayer]::Started[0])
}
Test-Case 'Start-VideoMode: a partial name also finds audio files (GUI plays audio too)' {
    $script:MusicDir = $rf
    Set-Responses 'rain'
    Start-VideoMode
    Assert-Equal (Join-Path (Join-Path $rf 'sub') 'Rain.wav') ([NativeMfPlayer]::Started[0])
}
Test-Case 'Start-VideoMode: blank input does nothing' {
    $script:MusicDir = $rf
    Set-Responses ''
    Start-VideoMode
    Assert-Equal 0 ([NativeMfPlayer]::Started.Count)
}
Test-Case 'Start-VideoMode: unknown name shows [VIDEO ERROR]' {
    $script:MusicDir = $rf
    Set-Responses 'zzz-not-here'
    Start-VideoMode
    Assert-Logged '\[VIDEO ERROR\]'
    Assert-Equal 0 ([NativeMfPlayer]::Started.Count)
}

# ===========================================================================
# 4. Start-AudioMode early exits (the playback loop itself is not run)
# ===========================================================================
Say ''
Say '== Start-AudioMode (startup paths) ==' 'Cyan'

Test-Case 'Start-AudioMode: empty library reports "No audio files" and returns' {
    $script:MusicDir = New-Fixture 'empty'
    Start-AudioMode
    Assert-Logged 'No audio files found'
}
Test-Case 'Start-AudioMode: video-only library counts as empty for audio' {
    $d = New-Fixture 'videoonly'
    Touch (Join-Path $d 'clip.mp4')
    $script:MusicDir = $d
    Start-AudioMode
    Assert-Logged 'No audio files found'
}
Test-Case 'Start-AudioMode: song-name search with no match returns' {
    $d = New-Fixture 'lib1'
    Touch (Join-Path $d 'Blue Sky.mp3')
    $script:MusicDir = $d
    $global:AudioSearchArg = 'zzz'
    Start-AudioMode
    Assert-Logged "No songs found matching 'zzz'"
}
Test-Case 'Start-AudioMode: ambiguous search -> cancel / invalid choice return cleanly' {
    $d = New-Fixture 'lib2'
    Touch (Join-Path $d 'Night Drive.mp3'); Touch (Join-Path $d 'Night Moves.flac')
    $script:MusicDir = $d
    $global:AudioSearchArg = 'night'
    Set-Responses '0'
    Start-AudioMode
    Assert-Logged 'did you mean'
    Assert-Logged 'Cancelled'
    $script:HostLog.Clear()
    Set-Responses '7'
    Start-AudioMode
    Assert-Logged 'Invalid selection'
}

# ===========================================================================
# 5. Queue logic
# ===========================================================================
Say ''
Say '== Queue, shuffle, loop and search ==' 'Cyan'

Test-Case 'Format-Time formats zero, sub-second, minutes and hours' {
    Assert-Equal '0:00' (Format-Time 0)
    Assert-Equal '0:00' (Format-Time 999)
    Assert-Equal '1:00' (Format-Time 60000)
    Assert-Equal '2:05' (Format-Time 125000)
    Assert-Equal '60:00' (Format-Time 3600000)
}
Test-Case 'Shuffle-Queue keeps every song exactly once and resets the cursor' {
    $global:Songs = @('a.mp3', 'b.mp3', 'c.mp3', 'd.mp3')
    Shuffle-Queue
    Assert-Equal 4 $global:Queue.Count
    foreach ($s in $global:Songs) { Assert-Equal 1 (@($global:Queue | Where-Object { $_ -eq $s }).Count) "song $s" }
    Assert-Equal 0 $global:Index
    Assert-Equal 0 $global:CursorIndex
}
Test-Case 'Shuffle-Queue: the previously playing song becomes the highlighted one' {
    $global:Songs = @('a.mp3', 'b.mp3', 'c.mp3', 'd.mp3')
    $global:Queue = @('a.mp3', 'b.mp3', 'c.mp3', 'd.mp3'); $global:Index = 2
    Shuffle-Queue
    Assert-Equal 'c.mp3' $global:Queue[$global:LastPlayedIndex]
}
Test-Case 'Shuffle-Queue: PreSearchFile wins and is consumed' {
    $global:Songs = @('a.mp3', 'b.mp3', 'c.mp3', 'd.mp3')
    $global:Queue = @('a.mp3', 'b.mp3'); $global:Index = 1; $global:PreSearchFile = 'd.mp3'
    Shuffle-Queue
    Assert-Equal 'd.mp3' $global:Queue[$global:LastPlayedIndex]
    Assert-Equal $null $global:PreSearchFile
}
Test-Case 'Shuffle-Queue: a one-song library stays an array' {
    $global:Songs = @('only.mp3')
    Shuffle-Queue
    Assert-True ($global:Queue -is [array]) 'Queue was unwrapped into a string'
    Assert-Equal 1 $global:Queue.Count
}
Test-Case 'Shuffle-Queue: a current song outside the library falls back to index 0' {
    $global:Songs = @('a.mp3', 'b.mp3')
    $global:Queue = @('elsewhere.mp3'); $global:Index = 0
    Shuffle-Queue
    Assert-Equal 0 $global:LastPlayedIndex
}
Test-Case 'Toggle-Loop and Toggle-Repeat flip their flags' {
    Toggle-Loop; Assert-True $global:LoopMode; Toggle-Loop; Assert-False $global:LoopMode
    Toggle-Repeat; Assert-True $global:RepeatOne; Toggle-Repeat; Assert-False $global:RepeatOne
    Assert-Logged 'Loop mode'
}
Test-Case 'Next-Track advances and wraps to the start' {
    $global:Queue = @('a', 'b', 'c'); $global:Index = 1
    Next-Track
    Assert-Equal 2 $global:Index; Assert-Equal 1 $global:LastPlayedIndex; Assert-Equal 'c' $global:MockLastStartedFile
    Next-Track
    Assert-Equal 0 $global:Index; Assert-Equal 'a' $global:MockLastStartedFile
    Assert-True $global:MockStopCalled
}
Test-Case 'Prev-Track goes back and wraps to the end' {
    $global:Queue = @('a', 'b', 'c'); $global:Index = 1
    Prev-Track
    Assert-Equal 0 $global:Index
    Prev-Track
    Assert-Equal 2 $global:Index; Assert-Equal 'c' $global:MockLastStartedFile
}
Test-Case 'Show-Queue marks current (>>), last played (*) and shows the status line' {
    $global:Queue = @('C:\m\a.mp3', 'C:\m\b.mp3', 'C:\m\c.mp3'); $global:Index = 1; $global:LastPlayedIndex = 0
    $global:LoopMode = $true; $global:Volume = 70; $global:SearchMode = $true
    Show-Queue
    Assert-Logged '^  \*  a\.mp3$'
    Assert-Logged '^>>   b\.mp3$'
    Assert-Logged '^     c\.mp3$'
    Assert-Logged 'Loop: ON.*Repeat: OFF.*Vol: 70%.*SEARCH MODE'
}
Test-Case 'Show-Queue: current song that was also the last played shows >> *' {
    $global:Queue = @('x.mp3'); $global:Index = 0; $global:LastPlayedIndex = 0
    Show-Queue
    Assert-Logged '^>> \* x\.mp3$'
}

$lib = @('C:\Music\Blue Sky.mp3', 'C:\Music\Night Drive.mp3', 'C:\Music\Rain.wav')

Test-Case 'Search-And-Play plays the chosen song as a single-song queue' {
    $global:Songs = $lib; $global:Queue = @($lib[0], $lib[2]); $global:Index = 1
    $global:LoopMode = $true; $global:RepeatOne = $true; $global:Alias = 'x'
    Set-Responses 'Night', '1'
    Search-And-Play
    Assert-True $global:SearchMode
    Assert-SequenceEqual @($lib[1]) $global:Queue
    Assert-Equal 0 $global:Index
    Assert-False $global:LoopMode; Assert-False $global:RepeatOne
    Assert-True $global:MockStopCalled
    Assert-Equal $lib[1] $global:MockLastStartedFile
    Assert-Equal $lib[2] $global:PreSearchQueue[1]
    Assert-Equal 1 $global:PreSearchIndex
}
Test-Case 'Search-And-Play: partial name is literal (brackets / wildcard characters)' {
    $global:Songs = @('C:\M\Clip [live].mp3', 'C:\M\Clip live.mp3'); $global:Queue = @('C:\M\Clip live.mp3'); $global:Alias = 'x'
    Set-Responses '[live]', '1'
    Search-And-Play
    Assert-SequenceEqual @('C:\M\Clip [live].mp3') $global:Queue
}
Test-Case 'Search-And-Play: no match leaves the queue alone and resumes playback' {
    $global:Songs = $lib; $global:Queue = @($lib[0]); $global:Alias = 'x'
    Set-Responses 'not-found'
    Search-And-Play
    Assert-False $global:Paused
    Assert-Equal 1 $global:Queue.Count
    Assert-False $global:SearchMode
    Assert-Logged 'No matches'
    Assert-True (@([NativeMfAudioEngine]::Calls) -contains 'Pause')
    Assert-Equal 'Play' ([NativeMfAudioEngine]::Calls[[NativeMfAudioEngine]::Calls.Count - 1])
}
Test-Case 'Search-And-Play: empty query is a cancel and resumes' {
    $global:Songs = $lib; $global:Queue = @($lib[0]); $global:Alias = 'x'
    Set-Responses ''
    Search-And-Play
    Assert-False $global:Paused
    Assert-Logged 'Search cancelled'
}
Test-Case 'Search-And-Play: choosing 0 cancels and resumes' {
    $global:Songs = $lib; $global:Queue = @($lib[0]); $global:Alias = 'x'
    Set-Responses 'Blue', '0'
    Search-And-Play
    Assert-False $global:Paused
    Assert-False $global:SearchMode
    Assert-Logged 'Cancelled'
}
Test-Case 'Search-And-Play: out-of-range / junk selection is rejected and playback resumes' {
    foreach ($bad in '2', 'x', '-1') {
        Reset-State
        $global:Songs = $lib; $global:Queue = @($lib[0]); $global:Alias = 'x'
        Set-Responses 'Blue', $bad
        Search-And-Play
        Assert-Equal 1 $global:Queue.Count "answer '$bad'"
        Assert-False $global:SearchMode "answer '$bad'"
        Assert-False $global:Paused "answer '$bad'"
        Assert-Logged 'Invalid selection'
    }
}
Test-Case 'Search-And-Play: "1a" appends to the queue without interrupting playback' {
    $global:Songs = $lib; $global:Queue = @($lib[0], $lib[2]); $global:Index = 0; $global:Alias = 'x'
    Set-Responses 'Night', '1a'
    Search-And-Play
    Assert-SequenceEqual @($lib[0], $lib[2], $lib[1]) $global:Queue
    Assert-Equal 0 $global:Index
    Assert-False $global:SearchMode
    Assert-False $global:MockStopCalled 'playback must not be stopped'
    Assert-Equal $null $global:MockLastStartedFile
    Assert-False $global:Paused
    Assert-Logged 'Added to queue'
}
Test-Case 'Search-And-Play: upper-case "1A" works and a duplicate is not added twice' {
    $global:Songs = $lib; $global:Queue = @($lib[0]); $global:Alias = 'x'
    Set-Responses 'Night', '1A'
    Search-And-Play
    Assert-Equal 2 $global:Queue.Count
    Set-Responses 'Night', '1a'
    Search-And-Play
    Assert-Equal 2 $global:Queue.Count 'duplicate was added'
    Assert-Logged 'already in queue'
}
Test-Case 'Search-And-Play: a second search keeps the ORIGINAL queue for Exit-SearchMode' {
    $global:Songs = $lib
    $global:SearchMode = $true; $global:PreSearchQueue = @($lib[0], $lib[1], $lib[2]); $global:PreSearchIndex = 2
    $global:Queue = @($lib[0]); $global:Alias = 'x'
    Set-Responses 'Night', '1'
    Search-And-Play
    Assert-Equal 3 $global:PreSearchQueue.Count 'original queue was overwritten'
    Assert-Equal 2 $global:PreSearchIndex
    Assert-SequenceEqual @($lib[1]) $global:Queue
}
Test-Case 'Resume-IfWasPlaying resumes only when it was playing' {
    $global:Paused = $true
    Resume-IfWasPlaying $false
    Assert-True $global:Paused
    Assert-Equal 0 ([NativeMfAudioEngine]::Calls.Count)
    Resume-IfWasPlaying $true
    Assert-False $global:Paused
    Assert-Equal 'Play' ([NativeMfAudioEngine]::Calls[0])
}
Test-Case 'Exit-SearchMode restores the original queue and index' {
    $global:Queue = @($lib[1]); $global:Index = 0
    $global:PreSearchQueue = @($lib[0], $lib[2]); $global:PreSearchIndex = 1
    $global:LoopMode = $true; $global:RepeatOne = $true; $global:SearchMode = $true
    Exit-SearchMode
    Assert-SequenceEqual @($lib[0], $lib[2]) $global:Queue
    Assert-Equal 1 $global:Index
    Assert-Equal $lib[1] $global:PreSearchFile
    Assert-False $global:LoopMode; Assert-False $global:RepeatOne; Assert-False $global:SearchMode
}
Test-Case 'Exit-SearchMode keeps a one-item queue an array' {
    $global:Queue = @('x'); $global:PreSearchQueue = @('only.mp3'); $global:PreSearchIndex = 0
    Exit-SearchMode
    Assert-True ($global:Queue -is [array])
}

# ===========================================================================
# 6. Playback control against the stub engine
# ===========================================================================
Say ''
Say '== Playback control (stub engine) ==' 'Cyan'

Test-Case 'Get-TrackDuration / Get-TrackPosition return the engine values as long' {
    [NativeMfAudioEngine]::DurationMs = 180000; [NativeMfAudioEngine]::PositionMs = 60000
    Assert-Equal 180000 (Get-TrackDuration)
    Assert-Equal 60000 (Get-TrackPosition)
    Assert-True ((Get-TrackDuration) -is [long])
}
Test-Case 'Set-PlayerVolume clamps to 0..100 and talks to the engine' {
    Set-PlayerVolume 150; Assert-Equal 100 $global:Volume; Assert-Equal 100 ([NativeMfAudioEngine]::Volume)
    Set-PlayerVolume -20; Assert-Equal 0 $global:Volume;   Assert-Equal 0 ([NativeMfAudioEngine]::Volume)
    Set-PlayerVolume 35;  Assert-Equal 35 $global:Volume;  Assert-Equal 35 ([NativeMfAudioEngine]::Volume)
}
Test-Case 'Set-PlayerVolume: quiet mode prints nothing, normal mode prints the level' {
    Set-PlayerVolume 60 $true
    Assert-NotLogged 'Volume'
    Set-PlayerVolume 60
    Assert-Logged 'Volume: 60%'
}
Test-Case 'Show-Progress renders state, bar and times' {
    $global:Alias = 'x'; [NativeMfAudioEngine]::DurationMs = 100000; [NativeMfAudioEngine]::PositionMs = 50000
    Show-Progress
    Assert-Logged 'PLAYING\s+\[#{15}-{15}\]\s+0:50 / 1:40'
    $script:HostLog.Clear(); $global:Paused = $true
    Show-Progress
    Assert-Logged 'PAUSED'
}
Test-Case 'Show-Progress prints nothing without a track or before the duration is known' {
    Show-Progress
    $global:Alias = 'x'; [NativeMfAudioEngine]::DurationMs = 0
    Show-Progress
    Assert-Equal 0 $script:HostLog.Count
}
Test-Case 'Show-Progress: position past the end never overflows the bar' {
    $global:Alias = 'x'; [NativeMfAudioEngine]::DurationMs = 1000; [NativeMfAudioEngine]::PositionMs = 5000
    Show-Progress
    Assert-Logged '\[#{30}\]'
}
Test-Case 'Toggle-Pause: no track -> no engine calls' {
    Toggle-Pause
    Assert-Equal 0 ([NativeMfAudioEngine]::Calls.Count)
    Assert-False $global:Paused
}
Test-Case 'Toggle-Pause pauses, then resumes' {
    $global:Alias = 'x'
    Toggle-Pause
    Assert-True $global:Paused; Assert-Equal 'Pause' ([NativeMfAudioEngine]::Calls[0])
    Toggle-Pause
    Assert-False $global:Paused; Assert-Equal 'Play' ([NativeMfAudioEngine]::Calls[1])
}
Test-Case 'Toggle-Pause: an engine failure is reported, not thrown' {
    $global:Alias = 'x'; [NativeMfAudioEngine]::ThrowOnPause = $true
    Toggle-Pause
    Assert-Logged 'Playback control error'
}
Test-Case 'Seek-Relative: +5 s and -5 s from the current position' {
    $global:Alias = 'x'; $global:SeekEnabled = $true
    [NativeMfAudioEngine]::DurationMs = 180000; [NativeMfAudioEngine]::PositionMs = 60000
    Seek-Relative 5000;  Assert-Equal 65000 ([NativeMfAudioEngine]::LastSeekMs)
    Seek-Relative -5000; Assert-Equal 60000 ([NativeMfAudioEngine]::LastSeekMs)
}
Test-Case 'Seek-Relative: clamps at the start and at the end' {
    $global:Alias = 'x'; $global:SeekEnabled = $true
    [NativeMfAudioEngine]::DurationMs = 180000; [NativeMfAudioEngine]::PositionMs = 2000
    Seek-Relative -15000; Assert-Equal 0 ([NativeMfAudioEngine]::LastSeekMs)
    [NativeMfAudioEngine]::PositionMs = 178000
    Seek-Relative 15000; Assert-Equal 180000 ([NativeMfAudioEngine]::LastSeekMs)
}
Test-Case 'Seek-Relative works while paused' {
    $global:Alias = 'x'; $global:SeekEnabled = $true; $global:Paused = $true
    [NativeMfAudioEngine]::DurationMs = 180000; [NativeMfAudioEngine]::PositionMs = 30000
    Seek-Relative 5000
    Assert-Equal 35000 ([NativeMfAudioEngine]::LastSeekMs)
}
Test-Case 'Seek-Relative does nothing when seeking is disabled, no track, or duration unknown' {
    [NativeMfAudioEngine]::DurationMs = 180000; [NativeMfAudioEngine]::PositionMs = 1000
    $global:Alias = 'x'; $global:SeekEnabled = $false; Seek-Relative 5000
    $global:Alias = $null; $global:SeekEnabled = $true; Seek-Relative 5000
    $global:Alias = 'x'; [NativeMfAudioEngine]::DurationMs = 0; Seek-Relative 5000
    Assert-Equal -1 ([NativeMfAudioEngine]::LastSeekMs)
}
Test-Case 'Get-PriorityKey: letters take priority over pending seeks' {
    $global:LetterQueue.Enqueue('N'); $global:ArrowSteps = 2; $global:SeekEnabled = $true
    Assert-Equal 'N' (Get-PriorityKey)
    Assert-Equal 0 $global:ArrowSteps
}
Test-Case 'Get-PriorityKey: arrow steps become 5-second seeks, capped at 3 steps' {
    $global:SeekEnabled = $true
    $global:ArrowSteps = 2;  Assert-Equal 'Seek' (Get-PriorityKey); Assert-Equal 10000 $global:PendingSeekMs
    $global:ArrowSteps = -1; Assert-Equal 'Seek' (Get-PriorityKey); Assert-Equal -5000 $global:PendingSeekMs
    $global:ArrowSteps = 9;  Assert-Equal 'Seek' (Get-PriorityKey); Assert-Equal 15000 $global:PendingSeekMs
    $global:ArrowSteps = -9; Assert-Equal 'Seek' (Get-PriorityKey); Assert-Equal -15000 $global:PendingSeekMs
}
Test-Case 'Get-PriorityKey: no key and seeking disabled -> null and steps are discarded' {
    $global:SeekEnabled = $false; $global:ArrowSteps = 3
    Assert-Equal $null (Get-PriorityKey)
    Assert-Equal 0 $global:ArrowSteps
    $global:SeekEnabled = $true
    Assert-Equal $null (Get-PriorityKey)
}
Test-Case 'Get-PriorityKey: queued letters come out in order' {
    $global:LetterQueue.Enqueue('P'); $global:LetterQueue.Enqueue('S')
    Assert-Equal 'P' (Get-PriorityKey); Assert-Equal 'S' (Get-PriorityKey)
}
Test-Case 'Remove-NotifyIcon disposes the tray icon and clears it' {
    $fake = New-Object psobject -Property @{ Visible = $true; Disposed = $false }
    $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
    $global:NotifyIcon = $fake
    Remove-NotifyIcon
    Assert-True $fake.Disposed; Assert-False $fake.Visible; Assert-Equal $null $global:NotifyIcon
    Remove-NotifyIcon   # second call with nothing to remove must not throw
}

# Real Play-Current / Stop-Current against the stub engine ---------------------
$pf = New-Fixture 'play'
Test-Case 'Play-Current (real): opens the file, applies volume, sets state' {
    Use-Real 'Play-Current'; Use-Real 'Stop-Current'
    $song = Join-Path $pf 'track.flac'; Touch $song
    $global:Queue = @($song); $global:Index = 0; $global:Volume = 40
    Play-Current
    Assert-Equal $song ([NativeMfAudioEngine]::OpenedPath)
    Assert-Equal 'MFPlayAudio' $global:Alias
    Assert-Equal 40 ([NativeMfAudioEngine]::Volume)
    Assert-False $global:Paused; Assert-False $global:AudioHasPlayed
    Assert-True $global:SeekEnabled
    Assert-Logged 'Now playing: track.flac'
    Assert-Equal 1 $script:Notifications.Count
}
Test-Case 'Play-Current (real): starting a track stops the previous one first' {
    Use-Real 'Play-Current'; Use-Real 'Stop-Current'
    $song = Join-Path $pf 'track2.flac'; Touch $song
    $global:Queue = @($song); $global:Alias = 'old'
    Play-Current
    $calls = @([NativeMfAudioEngine]::Calls)
    Assert-True ($calls.IndexOf('Close') -lt $calls.IndexOf('Open')) 'previous player was not closed before opening'
}
Test-Case 'Play-Current (real): open failure is reported and leaves no active track' {
    Use-Real 'Play-Current'; Use-Real 'Stop-Current'
    $song = Join-Path $pf 'bad.flac'; Touch $song
    $global:Queue = @($song)
    [NativeMfAudioEngine]::FailNextOpens = 1
    Play-Current
    Assert-Logged 'Could not open audio'
    Assert-Equal $null $global:Alias
}
Test-Case 'Stop-Current (real): stops and closes the engine, clears state, deletes the temp file' {
    Use-Real 'Stop-Current'
    [void][System.IO.Directory]::CreateDirectory($global:TempAudioDir)
    $tmp = Join-Path $global:TempAudioDir 'x.wav'; Touch $tmp
    $global:TempAudioFile = $tmp; $global:Alias = 'x'; $global:SeekEnabled = $true
    Stop-Current
    Assert-Equal $null $global:Alias; Assert-False $global:SeekEnabled
    Assert-False (Test-Path -LiteralPath $tmp) 'temp file was not removed'
    Assert-Equal $null $global:TempAudioFile
    Assert-True (@([NativeMfAudioEngine]::Calls) -contains 'Stop'); Assert-True (@([NativeMfAudioEngine]::Calls) -contains 'Close')
}
Test-Case 'Stop-Current (real): safe when nothing is playing' {
    Use-Real 'Stop-Current'
    Stop-Current
    Assert-Equal 0 ([NativeMfAudioEngine]::Calls.Count)
}

# ===========================================================================
# 7. Audio preparation: IEEE-float WAV and leading junk (real C# converter)
# ===========================================================================
Say ''
Say '== Audio preparation (real C# code) ==' 'Cyan'

if (-not $converterOk) {
    Test-Case 'WavFloatConverter compiles' { throw $converterError }
}
else {
    $af = New-Fixture 'audioprep'
    function P { param([string]$n) return (Join-Path $af $n) }

    function Read-Pcm16Bytes {
        param([byte[]]$Bytes)
        $r = @()
        for ($i = 0; $i + 1 -lt $Bytes.Length; $i += 2) {
            $r += [System.BitConverter]::ToInt16($Bytes, $i)
        }
        return $r
    }

    function Read-Pcm16 {
        param([string]$Path)
        $b = [System.IO.File]::ReadAllBytes($Path)
        $r = @()
        for ($i = 44; $i + 1 -lt $b.Length; $i += 2) {
            $r += [System.BitConverter]::ToInt16($b, $i)
        }
        return $r
    }	
	Test-Case 'Float32 WAV decodes to PCM16 with correct sample values' {
		$in = P 'f32.wav'
		New-WavFile -Path $in -Kind float32 -Samples 0.0, 0.5, -0.5, 1.0, -1.0, 2.5

		$before = Read-All $in
		$pcm = $null; $channels = 0; $rate = 0

		Assert-True ([WavFloatConverter]::TryDecodeToPcm($in, [ref]$pcm, [ref]$channels, [ref]$rate))
		Assert-SequenceEqual @(0, 16384, -16384, 32767, -32768, 32767) (Read-Pcm16Bytes $pcm)
		Assert-Equal 1 $channels
		Assert-Equal 8000 $rate
		Assert-Bytes $before (Read-All $in) 'original file was modified'
	}
	Test-Case 'Float64 WAV decodes to PCM16' {
		$in = P 'f64.wav'
		New-WavFile -Path $in -Kind float64 -Samples 0.0, 0.25

		$pcm = $null; $channels = 0; $rate = 0
		Assert-True ([WavFloatConverter]::TryDecodeToPcm($in, [ref]$pcm, [ref]$channels, [ref]$rate))
		Assert-SequenceEqual @(0, 8192) (Read-Pcm16Bytes $pcm)
	}
	Test-Case 'WAVE_FORMAT_EXTENSIBLE float WAV decodes' {
		$in = P 'ext.wav'
		New-WavFile -Path $in -Kind float32ext -Samples 0.0, -0.5

		$pcm = $null; $channels = 0; $rate = 0
		Assert-True ([WavFloatConverter]::TryDecodeToPcm($in, [ref]$pcm, [ref]$channels, [ref]$rate))
		Assert-SequenceEqual @(0, -16384) (Read-Pcm16Bytes $pcm)
	}
	Test-Case 'Float WAV: NaN becomes silence and stereo layout is preserved' {
		$in = P 'nan.wav'
		New-WavFile -Path $in -Kind float32 -Channels 2 -Rate 44100 -Samples ([double]::NaN), 0.5, -0.5, 0.0

		$pcm = $null; $channels = 0; $rate = 0
		Assert-True ([WavFloatConverter]::TryDecodeToPcm($in, [ref]$pcm, [ref]$channels, [ref]$rate))
		Assert-Equal 2 $channels
		Assert-Equal 44100 $rate
		Assert-SequenceEqual @(0, 16384, -16384, 0) (Read-Pcm16Bytes $pcm)
	}
	Test-Case 'Float WAV behind junk bytes decodes directly' {
		$in = P 'fjunk.wav'
		New-WavFile -Path $in -Kind float32 -Samples 0.0, 0.5 -JunkPrefix 100

		$pcm = $null; $channels = 0; $rate = 0
		Assert-True ([WavFloatConverter]::TryDecodeToPcm($in, [ref]$pcm, [ref]$channels, [ref]$rate))
		Assert-SequenceEqual @(0, 16384) (Read-Pcm16Bytes $pcm)
	}
	Test-Case 'PCM WAV is not decoded as float' {
		$in = P 'pcm.wav'
		New-WavFile -Path $in -Kind pcm16

		$pcm = $null; $channels = 0; $rate = 0
		Assert-False ([WavFloatConverter]::TryDecodeToPcm($in, [ref]$pcm, [ref]$channels, [ref]$rate))
	}
	Test-Case 'Truncated or invalid float WAV is rejected' {
		$in = P 'trunc.wav'
		New-WavFile -Path $in -Kind float32 -Samples 0.0, 0.5, 0.25, 0.1

		$bytes = [System.IO.File]::ReadAllBytes($in)
		[System.IO.File]::WriteAllBytes($in, $bytes[0..($bytes.Length - 6)])

		$pcm = $null; $channels = 0; $rate = 0
		Assert-False ([WavFloatConverter]::TryDecodeToPcm($in, [ref]$pcm, [ref]$channels, [ref]$rate))
	}
	Test-Case 'Float WAV with inconsistent byte rate is rejected' {
		$in = P 'badrate.wav'
		New-WavFile -Path $in -Kind float32 -Samples 0.0, 0.5

		$b = [System.IO.File]::ReadAllBytes($in)
		$b[28] = 1; $b[29] = 0; $b[30] = 0; $b[31] = 0
		[System.IO.File]::WriteAllBytes($in, $b)

		$pcm = $null; $channels = 0; $rate = 0
		Assert-False ([WavFloatConverter]::TryDecodeToPcm($in, [ref]$pcm, [ref]$channels, [ref]$rate))
	}

    # TryPrepare: junk handling ------------------------------------------------
    Test-Case 'TryPrepare(WAV): clean PCM WAV needs no copy' {
        $in = P 'clean.wav'; $out = P 'clean.prep.wav'
        New-WavFile -Path $in -Kind pcm16
        Assert-False ([WavFloatConverter]::TryPrepare($in, $out, $true))
        Assert-False (Test-Path -LiteralPath $out)
    }
    Test-Case 'TryPrepare(WAV): junk before RIFF is stripped into a copy; original untouched' {
        $in = P 'junk.wav'; $out = P 'junk.prep.wav'; $clean = P 'junk.clean.wav'
        New-WavFile -Path $in -Kind pcm16 -JunkPrefix 77
        New-WavFile -Path $clean -Kind pcm16
        $before = Read-All $in
        Assert-True ([WavFloatConverter]::TryPrepare($in, $out, $true))
        Assert-Bytes (Read-All $clean) (Read-All $out) 'stripped copy differs from the clean WAV'
        Assert-Bytes $before (Read-All $in) 'the original file was modified'
    }
    Test-Case 'TryPrepare(WAV): a damaged container behind junk is left alone (known limit)' {
        $in = P 'dmg.wav'; $out = P 'dmg.prep.wav'
        New-WavFile -Path $in -Kind pcm16 -JunkPrefix 40 -RiffSizeDelta 5000
        Assert-False ([WavFloatConverter]::TryPrepare($in, $out, $true))
        Assert-False (Test-Path -LiteralPath $out)
    }
    Test-Case 'TryPrepare(MP3): clean frames need no copy' {
        $in = P 'clean.mp3'; $out = P 'clean.prep.mp3'
        New-Mp3File -Path $in -Frames 5
        Assert-False ([WavFloatConverter]::TryPrepare($in, $out, $false))
        Assert-False (Test-Path -LiteralPath $out)
    }
    Test-Case 'TryPrepare(MP3): an ID3v2 tag alone is left to MFPlay (no copy)' {
        $in = P 'id3.mp3'; $out = P 'id3.prep.mp3'
        New-Mp3File -Path $in -Frames 5 -Id3Size 300
        Assert-False ([WavFloatConverter]::TryPrepare($in, $out, $false))
        Assert-False (Test-Path -LiteralPath $out)
    }
    Test-Case 'TryPrepare(MP3): junk before the first frame is stripped; original untouched' {
        $in = P 'junk.mp3'; $out = P 'junk.prep.mp3'
        New-Mp3File -Path $in -Frames 5 -JunkPrefix 53
        $before = Read-All $in
        Assert-True ([WavFloatConverter]::TryPrepare($in, $out, $false))
        $o = Read-All $out
        Assert-Equal (5 * 417) $o.Length 'only the audio frames should remain'
        Assert-Equal 0xFF $o[0]; Assert-Equal 0xFB $o[1]
        Assert-Bytes $before (Read-All $in) 'the original file was modified'
    }
    Test-Case 'TryPrepare(MP3): ID3 tag followed by junk -> copy starts at the first frame' {
        $in = P 'id3junk.mp3'; $out = P 'id3junk.prep.mp3'
        New-Mp3File -Path $in -Frames 5 -Id3Size 200 -JunkPrefix 31
        Assert-True ([WavFloatConverter]::TryPrepare($in, $out, $false))
        Assert-Equal (5 * 417) (Read-All $out).Length
    }
    Test-Case 'TryPrepare(MP3): a false sync pattern inside the junk is skipped' {
        $in = P 'fake.mp3'; $out = P 'fake.prep.mp3'
        New-Mp3File -Path $in -Frames 5 -FakeSyncInJunk -JunkPrefix 4
        Assert-True ([WavFloatConverter]::TryPrepare($in, $out, $false))
        Assert-Equal (5 * 417) (Read-All $out).Length 'decoder would have started in the middle of the junk'
    }
    Test-Case 'TryPrepare(MP3): fewer than three frames is not trusted (original kept)' {
        $in = P 'short.mp3'; $out = P 'short.prep.mp3'
        New-Mp3File -Path $in -Frames 2 -JunkPrefix 20
        Assert-False ([WavFloatConverter]::TryPrepare($in, $out, $false))
    }
    Test-Case 'TryPrepare(MP3): a file with no audio at all is left alone' {
        $in = P 'noise.mp3'; $out = P 'noise.prep.mp3'
        [System.IO.File]::WriteAllBytes($in, (New-Object byte[] 5000))
        Assert-False ([WavFloatConverter]::TryPrepare($in, $out, $false))
    }

    # Get-PlayablePath (PowerShell wrapper) --------------------------------------
    Test-Case 'Get-PlayablePath: only .wav and .mp3 are ever preprocessed' {
        foreach ($e in '.flac', '.m4a', '.aac', '.wma', '.mp4') {
            $p = P "x$e"; Touch $p
            Assert-Equal $p (Get-PlayablePath $p) $e
        }
    }
    Test-Case 'Get-PlayablePath: clean files are returned unchanged' {
        $w = P 'gp.clean.wav'; $m = P 'gp.clean.mp3'
        New-WavFile -Path $w -Kind pcm16; New-Mp3File -Path $m -Frames 4 -Id3Size 64
        Assert-Equal $w (Get-PlayablePath $w)
        Assert-Equal $m (Get-PlayablePath $m)
        Assert-Equal $null $global:TempAudioFile
    }
    Test-Case 'Get-PlayablePath: WAV and MP3 with junk -> temporary stripped copies' {
        $w = P 'gp.junk.wav'; $m = P 'gp.junk.mp3'
        New-WavFile -Path $w -Kind pcm16 -JunkPrefix 30; New-Mp3File -Path $m -Frames 5 -JunkPrefix 30
        $rw = Get-PlayablePath $w
        Assert-True ($rw -ne $w); Assert-Equal 'RIFF' ([System.Text.Encoding]::ASCII.GetString((Read-All $rw), 0, 4))
        $rm = Get-PlayablePath $m
        Assert-True ($rm -ne $m); Assert-True ($rm.EndsWith('.mp3'))
        Assert-Equal 0xFF (Read-All $rm)[0]
    }
    Test-Case 'Get-PlayablePath: an unreadable / missing file falls back to the original path' {
        $missing = P 'gp.missing.wav'
        Assert-Equal $missing (Get-PlayablePath $missing)
    }
    Test-Case 'Play-Current (real): float WAV plays through DirectPCM without a temporary copy' {
        Use-Real 'Play-Current'; Use-Real 'Stop-Current'
        $w = P 'pc.float.wav'
        New-WavFile -Path $w -Kind float32 -Samples 0.0, 0.5
        $global:Queue = @($w)
        Play-Current
		Assert-Equal 'DirectPCM' $global:Alias 'float WAV should use DirectPCM'
		Assert-Equal $null $global:TempAudioFile 'no temporary WAV should be created'
        Stop-Current
    }
	Test-Case 'Play-Current (real): DirectPCM success does not open MFPlay' {
		Use-Real 'Play-Current'; Use-Real 'Stop-Current'
		$w = P 'pc.directpcm.wav'
		New-WavFile -Path $w -Kind float32 -Samples 0.0, 0.5
		$global:Queue = @($w)

		Play-Current

		Assert-Equal 'DirectPCM' $global:Alias
		Assert-Equal $null $global:TempAudioFile
		Assert-False ([NativeMfAudioEngine]::OpenedPath -eq $w) 'MFPlay should not receive the float WAV'
		Stop-Current
	}
	Test-Case 'Stop-Current (real): closes DirectPCM and resets playback state' {
		Use-Real 'Play-Current'; Use-Real 'Stop-Current'
		$w = P 'pc.directpcm-stop.wav'
		New-WavFile -Path $w -Kind float32 -Samples 0.0, 0.5
		$global:Queue = @($w)

		Play-Current
		Assert-Equal 'DirectPCM' $global:Alias

		Stop-Current

		Assert-Equal $null $global:Alias
		Assert-False $global:Paused
	}
	if ($testExt -eq '.ogg') {
		T 'Play-Current: DirectPCM open failure falls back to original OGG' {
			Use-Real 'Play-Current'; Use-Real 'Stop-Current'

			$global:Queue = @($testFixture)
			[DirectPcmAudioEngine]::FailNextOpens = 1

			Play-Current

			Need ([NativeMfAudioEngine]::OpenedPath -eq $testFixture) 'MFPlay did not receive the original OGG'
			Need ($global:Alias -eq 'MFPlayAudio') 'MFPlay fallback was not activated'

			Stop-Current
		}
	}	
    Test-Case 'Play-Current (real): unsupported float WAV falls back to the original' {
        Use-Real 'Play-Current'; Use-Real 'Stop-Current'
        $w = P 'pc.unsupported-float.wav'
        New-WavFile -Path $w -Kind float32 -Samples 0.0, 0.5
		$bytes = [System.IO.File]::ReadAllBytes($w)
		[System.BitConverter]::GetBytes([uint16]24).CopyTo($bytes, 34)
		[System.IO.File]::WriteAllBytes($w, $bytes)
        $global:Queue = @($w)
        Play-Current
        Assert-Equal $w ([NativeMfAudioEngine]::OpenedPath) 'MFPlay should receive the original WAV'
        Assert-Equal 'MFPlayAudio' $global:Alias 'unsupported float WAV should fall back to MFPlay'
		Assert-Equal $null $global:TempAudioFile 'no temporary WAV should be created'
        Stop-Current
    }
    Test-Case 'Play-Current (real): a junk-prefixed MP3 is opened from a stripped copy' {
        Use-Real 'Play-Current'; Use-Real 'Stop-Current'
        $m = P 'pc.junk.mp3'
        New-Mp3File -Path $m -Frames 5 -JunkPrefix 25
        $global:Queue = @($m)
        Play-Current
        $played = [NativeMfAudioEngine]::OpenedPath
        Assert-True ($played -ne $m)
        Assert-Equal (5 * 417) (Read-All $played).Length
        Stop-Current
        Assert-False (Test-Path -LiteralPath $played) 'temporary copy was not deleted by Stop-Current'
    }
}

# ===========================================================================
# 8. Real C# (child process, Windows only): compile + COM layout + video player
# ===========================================================================
Say ''
Say '== Embedded C# and video player (child process) ==' 'Cyan'

$childScript = @'
param([string]$CsPath, [string]$TargetPath, [switch]$Integration)
$ErrorActionPreference = 'Stop'

function Report {
    param([string]$Status, [string]$Name, [string]$Msg = '')
    $m = ([string]$Msg) -replace '[\r\n|]+', ' '
    [Console]::Out.WriteLine("RESULT|$Status|$Name|$m")
}
function T {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Report 'PASS' $Name } catch { Report 'FAIL' $Name $_.Exception.Message }
}
function Need { param($Cond, [string]$Msg) if (-not $Cond) { throw $Msg } }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$src = [System.IO.File]::ReadAllText($CsPath)
try {
    Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies @('System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll')
    Report 'PASS' 'Embedded C# compiles as a whole'
}
catch { Report 'FAIL' 'Embedded C# compiles as a whole' $_.Exception.Message; exit 0 }

$NP_I = [System.Reflection.BindingFlags]'NonPublic,Instance'
$NP_S = [System.Reflection.BindingFlags]'NonPublic,Static'

# ---- COM interface layout ---------------------------------------------------
$expectedOrder = 'Play,Pause,Stop,FrameStep,SetPosition,GetPosition,GetDuration,SetRate,GetRate,GetSupportedRates,GetState,CreateMediaItemFromURL,CreateMediaItemFromObject,SetMediaItem,ClearMediaItem,GetMediaItem,GetVolume,SetVolume,GetBalance,SetBalance,GetMute,SetMute,GetNativeVideoSize,GetIdealVideoSize,SetVideoSourceRect,GetVideoSourceRect,SetAspectRatioMode,GetAspectRatioMode,GetVideoWindow,UpdateVideo,SetBorderColor,GetBorderColor,InsertEffect,RemoveEffect,RemoveAllEffects,Shutdown'
T 'IMFPMediaPlayer: ComImport with the documented IID and IUnknown base' {
    $t = [IMFPMediaPlayer]
    Need $t.IsInterface 'not an interface'
    Need $t.IsImport 'not marked ComImport'
    Need ($t.GUID -eq [guid]'A714590A-58AF-430A-85BF-44F5EC838D85') "IID is $($t.GUID)"
    $it = $t.GetCustomAttributes([System.Runtime.InteropServices.InterfaceTypeAttribute], $false)[0]
    Need ($it.Value -eq [System.Runtime.InteropServices.ComInterfaceType]::InterfaceIsIUnknown) 'wrong InterfaceType'
}
T 'IMFPMediaPlayer: 36 methods declared in the exact MFPlay vtable order' {
    $actual = ([System.Linq.Enumerable]::ToArray([System.Linq.Enumerable]::OrderBy([System.Reflection.MethodInfo[]][IMFPMediaPlayer].GetMethods(), [Func[System.Reflection.MethodInfo, int]] { param($m) $m.MetadataToken }))) | ForEach-Object { $_.Name }
    Need ($actual.Count -eq 36) "method count is $($actual.Count)"
    Need (($actual -join ',') -eq $expectedOrder) "order differs: $($actual -join ',')"
}
T 'IMFPMediaPlayer: every method is PreserveSig (HRESULTs are returned, not thrown)' {
    foreach ($m in [IMFPMediaPlayer].GetMethods()) {
        Need (($m.GetMethodImplementationFlags() -band [System.Reflection.MethodImplAttributes]::PreserveSig) -ne 0) "$($m.Name) is not PreserveSig"
    }
}

# ---- Audio engine (no player open) -------------------------------------------
T 'NativeMfAudioEngine exposes the API the script uses' {
    $names = [NativeMfAudioEngine].GetMethods('Public,Static') | ForEach-Object Name
    foreach ($n in 'Open', 'Play', 'Pause', 'Stop', 'Close', 'GetDurationMilliseconds', 'GetPositionMilliseconds', 'SetPositionMilliseconds', 'SetVolume', 'GetState') {
        Need ($names -contains $n) "missing $n"
    }
}
T 'NativeMfAudioEngine without a player is a safe no-op' {
    [NativeMfAudioEngine]::Play(); [NativeMfAudioEngine]::Pause(); [NativeMfAudioEngine]::Stop(); [NativeMfAudioEngine]::Close()
    [NativeMfAudioEngine]::SetPositionMilliseconds(5000)
    Need ([NativeMfAudioEngine]::GetState() -eq 0) 'state should be EMPTY (0)'
    Need ([NativeMfAudioEngine]::GetDurationMilliseconds() -eq 0) 'duration'
    Need ([NativeMfAudioEngine]::GetPositionMilliseconds() -eq 0) 'position'
}
# ---- Video player internals (no window needed) ---------------------------------
$player = New-Object NativeMfPlayer
function Invoke-Private { param([string]$Name, [object[]]$Args2 = @()) [NativeMfPlayer].GetMethod($Name, $NP_I).Invoke($player, [object[]]$Args2) }
function Fmt { param([double]$Seconds) Invoke-Private 'FormatTime' @([long]($Seconds * 10000000)) }

T 'NativeMfPlayer.Start is public static Start(string)' {
    $m = [NativeMfPlayer].GetMethod('Start', [Type[]]@([string]))
    Need ($m -ne $null -and $m.IsStatic) 'missing public static Start(string)'
}
T 'Video player FormatTime: mm:ss under an hour, h:mm:ss above, never negative' {
    Need ((Fmt 0) -eq '00:00') (Fmt 0)
    Need ((Fmt 5) -eq '00:05') (Fmt 5)
    Need ((Fmt 65) -eq '01:05') (Fmt 65)
    Need ((Fmt 600) -eq '10:00') (Fmt 600)
    Need ((Fmt 3600) -eq '1:00:00') (Fmt 3600)
    Need ((Fmt 3725) -eq '1:02:05') (Fmt 3725)
    Need ((Fmt -5) -eq '00:00') (Fmt -5)
}
T 'Video player button captions are distinct and descriptive' {
    $v = @{}
    foreach ($n in 'PlayText', 'PauseText', 'StopText') { $v[$n] = [NativeMfPlayer].GetField($n, $NP_S).GetRawConstantValue() }
    Need ($v.PlayText -match 'PLAY') 'PlayText'; Need ($v.PauseText -match 'PAUSE') 'PauseText'; Need ($v.StopText -match 'STOP') 'StopText'
    Need ($v.PlayText -ne $v.PauseText) 'play/pause captions identical'
    foreach ($s in $v.Values) { foreach ($ch in $s.ToCharArray()) { } }
}
T 'Video player controls tolerate a missing player (no NullReferenceException)' {
    foreach ($n in 'TogglePlayback', 'SeekFromSlider', 'RefreshPosition') { [void](Invoke-Private $n) }
    [void](Invoke-Private 'Skip' @([long]10))
    [void](Invoke-Private 'Skip' @([long]-10))
}
T 'Video player: PROPVARIANT time helpers return 0 without a player' {
    Need ((Invoke-Private 'ReadTime' @($true)) -eq 0) 'duration'
    Need ((Invoke-Private 'ReadTime' @($false)) -eq 0) 'position'
    [void](Invoke-Private 'SetPosition' @([long]10000000))
}

# ---- Integration: real MFPlay -----------------------------------------------
if (-not $Integration) {
    Report 'SKIP' 'Real MFPlay playback (audio engine)' 'run this suite with -Integration on Windows'
    Report 'SKIP' 'Video window smoke test (GUI)' 'run this suite with -Integration on Windows'
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('mfplay_it_' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tmp)

# Offline media fixtures are embedded as Base64 so this remains a single file.
$fixtureRoot = Join-Path $tmp 'fixtures'
[void][System.IO.Directory]::CreateDirectory($fixtureRoot)

function Get-MediaFixture {
    param([string]$Name, [string]$Base64)
    $path = Join-Path $fixtureRoot $Name
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    try {
        $bytes = [Convert]::FromBase64String($Base64)
        [System.IO.File]::WriteAllBytes($path, $bytes)
        if ((Get-Item -LiteralPath $path).Length -lt 256) { throw 'embedded fixture is unexpectedly small' }
        return $path
    }
    catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw "Could not create embedded media fixture '$Name': $($_.Exception.Message)"
    }
}

$aiffFixtureBase64 = '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'

$audioFixtureBase64 = [ordered]@{
    '.mp3' = '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O7v2r0e5v+4mrXq/Vcv7VW539q7P03oq///5tkCIa8EKzBwEjEUNzHobDOX/8zjEtRLgaiAA5/qAN04EngypFgQNZaDZjCeQXkz5Uc0a2QxnSQxDD0wGAwuusI1t2IxPmbmqtXPIU3+KWFbkXN2r6pNWrXp+xVqckr2bq7V2Knf21cAEf3/7MtyQmgUBGEQYYgCZjkPGYh7/8zjEyBUQdiIM7/iAmuUce08Zkp6i+aeIE0hwdeYBqBqmBQheRgHAIMYB4AbmAEgBRf1cz61hhRW2r29Mu+P+q3fuRe1VnSt7Pnt/l7U+5item9C9dpa/1v//5eeZJEDDjEmgA7EeYqgWY4D/8zjE0hcIdhQA7/qAshgBAgmYLvRwmGtCsZgNgLobCLh6krGqhIDoyLFIeCKhTUH7ldwltuYXsKLOftKZS9C3Edq/eTurtR+udKXI0KsznTc29qLUaF21gAAGaJOfv/+pE3AhtrABAJhIKGL/8zjE1Bh42hlI58SI8amYjsbxtpqRc9nXWPyYlwYRnhMGmc6YwQJhwHIPs4f+MU9vB/X7d38T/rcz/f6v/sL3p0K9/3N6rPXJqqAACAUj9c/7kEryS9AwQFo/DMehAz4PTlr2NoyyQ98xNjH/8zjE0RdYdhQA1/hkTAIDAwCWMEIg8wDwsTAVAeLUrmdmVXTT+u3Zv/Z09f/6/q0fej9Xu/bsXb66auAvcktuwz/WGH6wx3TxteAMABhgaGCssLM5OtYdWd+2n06R3gBkcMcHvwH+I9I7M/D/8zjE0hQIdioU57iAD/EfEM/+B/u/Az/8PeIMiCOr6D3yGRBHz+P934O/3p/d+nfm0HrwPiEGT8A86QzAzv7qCBjIRGASCFwQNBL/MghcySazBgnMFCH/LGkO0sECAQLgf/A9o4DDrgBpABD/8zjE4BPQbiX0xzxgRAGQgRCcDDBggCgMCwt/E3B6whCQ3w/IL6COBXRAMZkZ4pEGI34x45QpQdBFRcZiTpSUXjH8jyeHAShOkHKKzU4pJf+ViKFI1J8xPk4ZIqpLoq/88XzE+XEjQvmpugb/8zjE7xjQXnT/XBgDyter//5omam6BsaA6DgEJEVuTCZZn8LVTEFNRVVVTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/8zjE6iiajmADnKAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/8zjEoAAAA0gBwAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVU='
    '.wav' = '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'
    '.ogg' = 'T2dnUwACAAAAAAAAAAAMjx69AAAAAMwe+/wBHgF2b3JiaXMAAAAAASJWAAAAAAAA7HYAAAAAAACpAU9nZ1MAAAAAAAAAAAAADI8evQEAAACBBnj5Dl/////////////////FA3ZvcmJpcwwAAABMYXZmNjEuNy4xMDMCAAAAHwAAAGVuY29kZXI9TGF2YzYxLjE5LjEwMSBsaWJ2b3JiaXMcAAAAdGl0bGU9Vm9yYmlzIGRlY29kZXIgZml4dHVyZQEFdm9yYmlzIkJDVgEAQAAAGEIQKgWtY446yBUhjBmioELKKccdQtAhoyRDiDrGNccYY0e5ZIpCyYHQkFUAAEAAAKQcV1BySS3nnHOjGFfMcegg55xz5SBnzHEJJeecc44555JyjjHnnHOjGFcOcikt55xzgRRHinGnGOecc6QcR4pxqBjnnHNtMbeScs4555xz5iCHUnKuNeecc6QYZw5yCyXnnHPGIGfMcesg55xzjDW31HLOOeecc84555xzzjnnnHOMMeecc84555xzbjHnFnOuOeecc8455xxzzjnnnHMgNGQVAJAAAKChKIriKA4QGrIKAMgAABBAcRRHkRRLsRzL0SQNCA1ZBQAAAQAIAACgSIakSIqlWI5maZ4meqIomqIqq7JpyrIsy7Lrui4QGrIKAEgAAFBRFMVwFAcIDVkFAGQAAAhgKIqjOI7kWJKlWZ4HhIasAgCAAAAEAABQDEexFE3xJM/yPM/zPM/zPM/zPM/zPM/zPM/zPA0IDVkFACAAAACCKGQYA0JDVgEAQAAACCEaGUOdUhJcChZCHBFDHULOQ6mlg+AphSVj0lOsQQghfO89995774HQkFUAABAAAGEUOIiBxyQIIYRiFCdEcaYgCCGE5SRYynnoJAjdgxBCuJx7y7n33nsgNGQVAAAIAMAghBBCCCGEEEIIKaSUUkgppphiiinHHHPMMccggwwy6KCTTjrJpJJOOsoko45Saym1FFNMseUWY6211pxzr0EpY4wxxhhjjDHGGGOMMcYYIwgNWQUAgAAAEAYZZJBBCCGEFFJIKaaYcswxxxwDQkNWAQCAAAACAAAAHEVSJEdyJEeSJMmSLEmTPMuzPMuzPE3URE0VVdVVbdf2bV/2bd/VZd/2ZdvVZV2WZd21bV3WXV3XdV3XdV3XdV3XdV3XdV3XgdCQVQCABACAjuQ4juQ4juRIjqRIChAasgoAkAEAEACAoziK40iO5FiOJVmSJmmWZ3mWp3maqIkeEBqyCgAABAAQAAAAAACAoiiKoziOJFmWpmmep3qiKJqqqoqmqaqqapqmaZqmaZqmaZqmaZqmaZqmaZqmaZqmaZqmaZqmaZqmaQKhIasAAAkAAB3HcRxHcRzHcSRHkiQgNGQVACADACAAAENRHEVyLMeSNEuzPMvTRM/0XFE2dVNXbSA0ZBUAAAgAIAAAAAAAAMdzPMdzPMmTPMtzPMeTPEnTNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE0DQkNWAgBkAAAQk5BKTrFXRinGJLReKqQUk9R7qJhiTDrtqUIGKQe5h0ohpaDT3jKlkFIMe6eYQsgY6qGDkDGFsNfac8+99x4IDVkRAEQBAADGIMYQY8gxJiWDEjHHJGRSIueclE5KJqWkVlrMpISYSouRc05KJyWTUloLqWWSSmslpgIAAAIcAAACLIRCQ1YEAFEAAIgxSCmkFFJKMaeYQ0opx5RjSCnlnHJOOceYdBAq5xh0DkqklHKOOaeccxIyB5VzDkImnQAAgAAHAIAAC6HQkBUBQJwAAICQc4oxCBFjEEIJKYVQUqqck9JBSamDklJJqcWSUoyVc1I6CSl1ElIqKcVYUootpFRjaS3X0lKNLcacW4y9hpRiLanVWlqrucVYc4s198g5Sp2U1jopraXWak2t1dpJaS2k1mJpLcbWYs0pxpwzKa2FlmIrqcXYYss1tZhzaS3XFGPPKcaea6y5x5yDMK3VnFrLOcWYe8yx55hzD5JzlDoprXVSWkut1ZpaqzWT0lpprcaQWostxpxbizFnUlosqcVYWooxxZhziy3X0FquKcacU4s5x1qDkrH2XlqrOcWYe4qt55hzMDbHnjtKuZbWei6t9V5zLkLW3ItoLefUag8qxp5zzsHY3IMQreWcauw9xdh77jkY23PwrdbgW81FyJyD0Ln4pnswRtXag8y1CJlzEDroInTwyXiUai6t5Vxa6z3WGnzNOQjRWu4pxt5Ti73XnpuwvQchWss9xdiDijH4mnMwOudiVK3Bx5yDkLUWoXsvSucglKq1B5lrUDLXInTwxeigiy8AAGDAAQAgwIQyUGjIigAgTgCAQcg5pRiESikIoYSUQigpVYxJyJiDkjEnpZRSWggltYoxCJljUjLHpIQSWioltBJKaamU0loopbWWWowptRZDKamFUlorpbSWWqoxtVZjxJiUzDkpmWNSSimtlVJaqxyTkjEoqYOQSikpxVJSi5VzUjLoqHQQSiqpxFRSaa2k0lIppcWSUmwpxVRbi7WGUlosqcRWUmoxtVRbizHXiDEpGXNSMueklFJSK6W0ljknpYOOSuagpJJSa6WkFDPmpHQOSsogo1JSii2lElMopbWSUmylpNZajLWm1FotJbVWUmqxlBJbizHXFktNnZTWSioxhlJaazHmmlqLMZQSWykpxpJKbK3FmltsOYZSWiypxFZKarHVlmNrsebUUo0ptZpbbLnGlFOPtfacWqs1tVRja7HmWFtvtdacOymthVJaKyXFmFqLscVYcygltpJSbKWkGFtsubYWYw+htFhKarGkEmNrMeYYW46ptVpbbLmm1GKttfYcW249pRZri7Hm0lKNNdfeY005FQAAMOAAABBgQhkoNGQlABAFAAAYwxhjEBqlnHNOSoOUc85JyZyDEEJKmXMQQkgpc05CSi1lzkFIqbVQSkqtxRZKSam1FgsAAChwAAAIsEFTYnGAQkNWAgBRAACIMUoxBqExRinnIDTGKMUYhEopxpyTUCnFmHNQMsecg1BK5pxzEEoJIZRSSkohhFJKSakAAIACBwCAABs0JRYHKDRkRQAQBQAAGGOcM84hCp2lzlIkqaPWUWsopRpLjJ3GVnvrudMae225N5RKjanWjmvLudXeaU09txwLAAA7cAAAO7AQCg1ZCQDkAQAQxijFmHPOGYUYc8455wxSjDnnnHOKMeecgxBCxZhzzkEIIXPOOQihhJI55xyEEEronINQSimldM5BCKGUUjrnIIRSSimdcxBKKaWUAgCAChwAAAJsFNmcYCSo0JCVAEAeAABgDELOSWmtYcw5CC3V2DDGHJSUYoucg5BSi7lGzEFIKcagOygptRhs8J2ElFqLOQeTUos1596DSKm1moPOPdVWc8+995xirDXn3nMvAAB3wQEA7MBGkc0JRoIKDVkJAOQBABAIKcWYc84ZpRhzzDnnjFKMMeacc4oxxpxzzkHFGGPOOQchY8w55yCEkDHmnHMQQuiccw5CCCF0zjkHIYQQOueggxBCCJ1zEEIIIYQCAIAKHAAAAmwU2ZxgJKjQkJUAQDgAAAAhhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQuicc84555xzzjnnnHPOOeecc845JwDIt8IBwP/BxhlWks4KR4MLDVkJAIQDAAAKQSilYhBKKSWSTjopnZNQSimRg1JK6aSUUkoJpZRSSgillFJKCB2UUkIppZRSSimllFJKKaWUUjoppZRSSimllMo5KaWTUkoppUTOSSkhlFJKKaWEUkoppZRSSimllFJKKaWUUkoppYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhAIAuBscACASbJxhJemscDS40JCVAEBIAACgFHOOSggplJBSqJiijkIpKaRSSgoRY85J6hyFUFIoqYPKOQilpJRCKiF1zkEHJYWQUgkhlY466CiUUFIqJZTSOSilhBRKSimVkEJIqXSUUigllZRCKiGVUkpIJZUQSgqdpFRKCqmkVFIInXSQQiclpJJKCqmTlFIqJaWUSkoldFJCKimlEEJKqZQQSkgppU5SSamkFEIoIYWUUkolpZJKSiGVVEIJpaSUUiihpFRSSimlklIpAADgwAEAIMAIOsmosggbTbjwABQashIAIAMAQJR01mmnSSIIMUWZJw0pxiC1pCzDEFOSifEUY4w5KEZDDjHklBgXSgihg2I8JpVDylBRubfUOQXFFmN877EXAQAACAIABIQEABggKJgBAAYHCCMHAh0BBA5tAICBCJkJDAqhwUEmADxAREgFAIkJitKFLgghgnQRZPHAhRM3nrjhhA5tEAAAAAAAEADwAQCQUAAREdHMVVhcYGRobHB0eHyAhAQAAAAAAAgAfAAAJCJAREQ0cxUWFxgZGhscHR4fICEBAAAAAAAAAABAQEAAAAAAACAAAABAQE9nZ1MABBErAAAAAAAADI8evQIAAAB5MQz0FxwYFxgYGBgYGBcYGBgYGBgYFxcYGBckRKu1EviGo18DAAoYgJCDk5a0NAAAm23btnsOAVrKKnfQACIj7BLANiUAAAAAgCsvNIJcAN7KGndaBJD8IuwSwM8FAAAAAKC/2gUA/sqad0oAYEA22CWAblMAAAAAAMCqNzoA/sqadzIAMKAD7BLA16kBAAAAALDLqxQA/sqa9zIAMCAj7BLAPRwAAAAAAHagqAUAHsta9koAYEBH2CWA1zQAAAAAALKtrgUA3soa90oAEL8ddgng5xQAAAAAAPSaewoA/sqad0oAYEA22CWAVlMAAAAAAMCkHzoAvsoa9kYEkPwNdgngjwcAAAAAQPUdBADeyhr3SgBgIAF2CSCbEgAAAAAAPhzQBQDeyhr3MgAwIBvsEsDPSQAAAAAAsnkrAQD+ypp3SgBgQHbYJYDXVAAAAAAA5IeCBgD+ypp3MgAwICPsEsBtOgAAAAAAprOvAQD+ypr3SgBgQDbYJYB7GAAAAAAA9vZbBQD+ypp3XAMwoCPsEsA2dQAAAAAA0L+sCwC+yhr2WgSQ/ALsEsC/IwAAAAAA+mchAAD+ypp3SgBgoAF2CSCaAgAAAAAAyrQaAN7KGncyADAgI+wSwNcZAAAAAIDK0RMA/sqa9zIAMCAj7BLAHD4AAAAAANZhpgsA/sqa9zIAMCAj7BLA6wwAAAAAQI691QIAvsoadkQDiMtglwBeJwAAAAAAUnNYAwDeiUqfNEI7zSYIkOgA7KkDQFAAAITJ0FnsBhVdBAngQTWeTgE='
    '.aiff' = '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'
    '.aif' = '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'
    '.flac' = 'ZkxhQwAAACIEgASAAABvAAG0A+gA8AAAMgD3qH3c55781OTBsmUZAytEBAAALAwAAABMYXZmNjEuNy4xMDMBAAAAFAAAAGVuY29kZXI9TGF2ZjYxLjcuMTAzgQAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//g1CAADTgAAAsAFawftCjIMKg3FDvbmK1S6igzsKb+zMIugSn8VgAEpCJLAiGRAphzIRDJkpJlJzMiGmYaFAzkwoZkoZPkmZhyEQMzMlChEJZKFJoSkoSmEQmZhnhEOGkkQzJycOZJQKgcpCw0DhIgUwIhlJmgU5w8w5MzApDMpChEycoUzhTkk8zKTQImZnChQLCcKHIWHCwygWZlMkoFJSHgUzk5KTPCIQiTDQlIRJYEQyIFMOZCIZMlJMpOZkQ0zDQoGcmFDMlDJ8kzMOQiBmZkoUIhLJQpNCUlCUwiEzMM8Ihw0kiGZOThzJKBUDlIWGgcJECmBEMpM0CnOHmHJmYFIZlIUImTlCmcKcknmZSaBEzM4UKBYThQ5Cw4WGUCzMpklApKQ8CmcnJSZ4RCESYaEpCJLAiGRAphzIRDJkpJlJzMiGmYaFAzkwoZkoZPkmZhyEQMzMlChEJZKFJoSkoSmEQmZhnhEOGkkQzJycOZJQKgcpCw0DhIgUwIhlJmgU5w8w5MzApDMpChEycoUzhTkk8zKTQImZnChQLCcKHIWHCwygUYw//g1CAEETvGH8JLwE/AN8IHxa/LF9IPmJjnbu9QQFj/lQT0fdX79gAZJQ5yaB4aSZCyTwpCzDQlhk4FMoeEpkImTJSTOScyhLmaUJNJlJOGcnknmHkQzk4ZhSHlDmksoTMKTMwzwpMnIRJKQ80J5JQ0JlIWEpyRDMKSWGaBnOHmTyZhYSZkMLkOYeSmTknkmUkwKZOSmUNJMKTIcJhZlDmZTJKHOTQPDSTIWSeFIWYaEsMnAplDwlMhEyZKSZyTmUJczShJpMpJwzk8k8w8iGcnDMKQ8oc0llCZhSZmGeFJk5CJJSHmhPJKGhMpCwlOSIZhSSwzQM5w8yeTMLCTMhhchzDyUyck8kykmBTJyUyhpJhSZDhMLMoczKZJQ5yaB4aSZCyTwpCzDQlhk4FMoeEpkImTJSTOScyhLmaUJNJlJOGcnknmHkQzk4ZhSHlDmksoTMKTMwzwpMnIRJKQ80J5JQ0JlIWEpyRDMKSWGaBnOHmTyZhYSZkMLkOYeSmTknkmAbY3/+DUIAg1ODFQKZAglBagDAABA/YD60uYrE7psEWwol55QeiDO/qOABmZwoYFhJhQ5Cw4WZQLKZTJKBSGQ8CJlnkpM8ChCkw0CUhElQIhSIETDmQiGTCUJMs9MiGmYaFAzkwoZkoWfMzMMkIgZmZKFIhLlCk0JSUJmEQmGYZ4RDTSSIGYTJOHMkiFQ5SEYaBwhEChgRAykzQKcsLmEySGYFIZlIUImTlCmcKEySZmZToETMzhQwLCTChyFhwsygWUymSUCkMh4ETLPJSZ4FCFJhoEpCJKgRCkQImHMhEMmEoSZZ6ZENMw0KBnJhQzJQs+ZmYZIRAzMyUKRCXKFJoSkoTMIhMMwzwiGmkkQMwmScOZJEKhykIw0DhCIFDAiBlJmgU5YXMJkkMwKQzKQoRMnKFM4UJkkzMynQImZnChgWEmFDkLDhZlAsplMkoFIZDwImWeSkzwKEKTDQJSESVAiFIgRMOZCIZMJQkyz0yIaZhoUDOTChmShZ8zMwyQiBmZkoUiEuUKTQlJQmYRCYZhnhENNJIgZhMk4cySIVDlIRhoHCEQKGBEDKTNApywuYTJIQMub//g1CAMKTgP6BpUI/QsiDPEOXQ9cD+bmK0m62gs4Po9PsUl/xf8egAZSFCJkyUKSTChMknmZScCJnkwoYFhmFDSFlhYZQLChlMkoFhSdCJmmZKTPAoQiEw0DSESWBEMoFMJhhCIZMJSTLPmUJTMNCgZzhQ+ULPkmZhyRAzJOUKRCUyhSGhMJQlMIhKFMM8IhKHJCgZkMzhzJIhUCykIkNA4SIFMIhllKgU5YeYTJJmFhmUhQiZMlCkkwoTJJ5mUnAiZ5MKGBYZhQ0hZYWGUCwoZTJKBYUnQiZpmSkzwKEIhMNA0hElgRDKBTCYYQiGTCUkyz5lCUzDQoGc4UPlCz5JmYckQMyTlCkQlMoUhoTCUJTCIShTDPCIShyQoGZDM4cySIVAspCJDQOEiBTCIZZSoFOWHmEySZhYZlIUImTJQpJMKEySeZlJwImeTChgWGYUNIWWFhlAsKGUySgWFJ0ImaZkpM8ChCITDQNIRJYEQygUwmGEIhkwlJMs+ZQlMw0KBnOFD5Qs+SZmHJEDMk5QpEJTKFIaEwlCUwiEoUwzwiEockKBmQzOHMkiFQLKQgcJn/+DUIBB9O8ErwAfAz8N7x+/OE9Wz3pOYnwNLL4Bwiv9XRDn+cPxWABIhmETLDNAzhw8yczKFmZSFCkkMmGSTKf+ZlJMCmSZKGUNJoU2FhwsMoHMMpklDlnQLmkmQsJPCkIzDQlhScCmUDMJTIRMlJSTOTMwoTMw0KHpynzDJJJJMzDyIZ5wphSHIUMhKEpKEphEmUwzwpMJkhEJMh5oS5JQ0CZSFhKHJEMwiZYZoGcOHmTmZQszKQoUkhkwySZT/zMpJgUyTJQyhpNCmwsOFhlA5hlMkocs6Bc0kyFhJ4UhGYaEsKTgUygZhKZCJkpKSZyZmFCZmGhQ9OU+YZJJJJmYeRDPOFMKQ5ChkJQlJQlMIkymGeFJhMkIhJkPNCXJKGgTKQsJQ5IhmETLDNAzhw8yczKFmZSFCkkMmGSTKf+ZlJMCmSZKGUNJoU2FhwsMoHMMpklDlnQLmkmQsJPCkIzDQlhScCmUDMJTIRMlJSTOTMwoTMw0KHpynzDJJJJMzDyIZ5wphSHIUMhKEpKEphEmUwgM8Y//g1CAUYTAlnBwoEdwHC/v/8Rfmm5iuKtn4iF/unv/EwfusAAOHJCgZhDJDh8yIRQspKQlAyEKBQwIhllKhSywzDCZJDMCkylJQiUllCmEwwkkk88idCJTyYUKBkJMKHJZZGUoFmGGGElApKToRMqdJSSZgUCFCYcNhE1CIUiBTCYYQoYTCUylnpkQ5hhwoGHCYUMspfyTJMDJCgYZJyhQiblCk4TCYEwwiEylKXCIcOSFAzCGSHD5kQihZSUhKBkIUChgRDLKVCllhmGEySGYFJlKShEpLKFMJhhJJJ55E6ESnkwoUDISYUOSyyMpQLMMMMJKBSUnQiZU6SkkzAoEKEw4bCJqEQpECmEwwhQwmEplLPTIhzDDhQMOEwoZZS/kmSYGSFAwyTlChE3KFJwmEwJhhEJlKUuEQ4ckKBmEMkOHzIhFCykpCUDIQoFDAiGWUqFLLDMMJkkMwKTKUlCJSWUKYTDCSSTzyJ0IlPJhQoGQkwocllkZSgWYYYYSUCkpOhEyp0lJJmBQIUJhw2ETUIhSIFMJhhChhMJTKWemRDmGHCgYcJhQyyl/JMkwMkKBCWmf/4NQgGEU4HtAoAC/8Now7fD6oP/Q/W5ikWyQvz7CY3tYDqoAU+6IAFDKTyhSaEyUJmEQmZhnhSYTJCIZkPOE8koVDlIWEocJEMwiGWZUDOcPMJkkzCwzKQoUycoUkmFJkk8zKTQKZmTCmHJMKHIWcLMoFmZTJKHLOgUzSTJZJ4UIUmGhLCksCmUCmEzCETJkpJlnzKEpmGhQzkwofKHPkmZhyEQzM5Qyk8oUmhMlCZhEJmYZ4UmEyQiGZDzhPJKFQ5SFhKHCRDMIhlmVAznDzCZJMwsMykKFMnKFJJhSZJPMyk0CmZkwphyTChyFnCzKBZmUyShyzoFM0kyWSeFCFJhoSwpLAplAphMwhEyZKSZZ8yhKZhoUM5MKHyhz5JmYchEMzOUMpPKFJoTJQmYRCZmGeFJhMkIhmQ84TyShUOUhYShwkQzCIZZlQM5w8wmSTMLDMpChTJyhSSYUmSTzMpNApmZMKYckwochZwsygWZlMkocs6BTNJMlknhQhSYaEsKSwKZQKYTMIRMmSkmWfMoSmc+//4NQgHFk7wCfBy8VHyofRX9mX4vftL5ijNy6/tUCX/wOEFv63/IoABnJhQkyGGSTknlDyIZkmQoYUIclCk0lJQlMIhMzDPCkw0kiHSHnCZklDgcpCwlDkiFMIhJSGHAznDzN5mFhmZDCmTlC5pT5PJMKSYFM80KUKk4UOQ4cLDKBZmUyShykPApIaSZLM8KSJMNCWFJwKGUC4aUkTJkpJmQkmZQlMzShnJhQkyGGSTknlDyIZkmQoYUIclCk0lJQlMIhMzDPCkw0kiHSHnCZklDgcpCwlDkiFMIhJSGHAznDzN5mFhmZDCmTlC5pT5PJMKSYFM80KUKk4UOQ4cLDKBZmUyShykPApIaSZLM8KSJMNCWFJwKGUC4aUkTJkpJmQkmZQlMzShnJhQkyGGSTknlDyIZkmQoYUIclCk0lJQlMIhMzDPCkw0kiHSHnCZklDgcpCwlDkiFMIhJSGHAznDzN5mFhmZDCmTlC5pT5PJMKSYFM80KUKk4UOQ4cLDKBZmUyShykPApIaSZLM8KSJMNCWFJNQl//g1CAg7TgXkAz4Agf2/+w/4hPYz9CvmK7u2KhgMMq92YKsgn77EgABTDlIRDJkoSZSczIhpmGhEDOcKGZKGT5J5Q5IgZmZKFCISklCk0NJQlMIhMMwzwiGhpJEDMnJw5klAsDhSEYaBYSIFMCIZSYaBTnC5hyZmBSGZSFAiZMlCmcKcknkmFJwImZnChQLDwochSHCwygWUymSUCkKQ8CJnJyUmeEQkSUNAlIRCWBEMiBTDlIRDJkoSZSczIhpmGhEDOcKGZKGT5J5Q5IgZmZKFCISklCk0NJQlMIhMMwzwiGhpJEDMnJw5klAsDhSEYaBYSIFMCIZSYaBTnC5hyZmBSGZSFAiZMlCmcKcknkmFJwImZnChQLDwochSHCwygWUymSUCkKQ8CJnJyUmeEQkSUNAlIRCWBEMiBTDlIRDJkoSZSczIhpmGhEDOcKGZKGT5J5Q5IgZmZKFCISklCk0NJQlMIhMMwzwiGhpJEDMnJw5klAsDhSEYaBYSIFMCIZSYaBTnC5hyZmBSGZSFAiZMlCmcKcknkmFJwImZnChQLDwochSHCwygWUymSUCgeLP/+DUICTxOCvMMyw5BD0oP3w/7D50Ox+YoBdEr31Q5Z7Gg1OBdfo6AAXNJyWEngUIUmGhLCkqBTKB4TMIRMmSkmWemUJTMNChJyYU+U58kyTCZCISZJymUlyhSGhMlCZIUJnmeFJSUkKEmQ5OEuSRCocpCwlDhCIZhEksyoGc4eYTJIZhYZlIULk5QySYZMknnlmgXPJhmHCTChpCzhZ0LMkzJKHDh0Lmk5LCTwKEKTDQlhSVAplA8JmEImTJSTLPTKEpmGhQk5MKfKc+SZJhMhEJMk5TKS5QpDQmShMkKEzzPCkpKSFCTIcnCXJIhUOUhYShwhEMwiSWZUDOcPMJkkMwsMykKFycoZJMMmSTzyzQLnkwzDhJhQ0hZws6FmSZklDhw6FzSclhJ4FCFJhoSwpKgUygeEzCETJkpJlnplCUzDQoScmFPlOfJMkwmQiEmScplJcoUhoTJQmSFCZ5nhSUlJChJkOThLkkQqHKQsJQ4QiGYRJLMqBnOHmEySGYWGZSFC5OUMkmGTJJ55ZoFzySMh//4NQgKNU7wyfHd81z1PPdt+eH8g/8/5io2wWoBkC0HmuDVgDm+34AHhQ5CkOFhlAsplMkoWUh4FJOSZLM8IhIkw0JSFCcChlAphpSRMmSkmZJJmUJTMNChnOFDMmGSeSeUPIhmZkKGFCZJQpNDSUJTCITDMM8KEw0kiHk84TMkoFgcpCw0LJEKYRDKQw4Gc4eZ+ZhYZlIUKZMlCmcp5J5JhSTApmZoUoWeFDkKQ4WGUCymUyShZSHgUk5JkszwiEiTDQlIUJwKGUCmGlJEyZKSZkkmZQlMw0KGc4UMyYZJ5J5Q8iGZmQoYUJklCk0NJQlMIhMMwzwoTDSSIeTzhMySgWBykLDQskQphEMpDDgZzh5n5mFhmUhQpkyUKZynknkmFJMCmZmhShZ4UOQpDhYZQLKZTJKFlIeBSTkmSzPCISJMNCUhQnAoZQKYaUkTJkpJmSSZlCUzDQoZzhQzJhknknlDyIZmZChhQmSUKTQ0lCUwiEwzDPChMNJIh5POEzJKBYHKQsNCyRCmEQykMOBnOHmfmYWGZSFC7nH/+GUIC38YTgIC/0D8g/nh9271PPNc8d3mMPqCgtW2pOoVnTHC676DAEWOnJCEYYgQwwghjMyax4VRaHoWj0sWJDQNAxAhhAjBMbE+/dTucpT0ePZGgmGYIwIgYghCIkYuPBXKUp1d/7MyCYMAaxw='
    '.m4a' = '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'
    '.aac' = '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mhdvvdFgaMD1H/JtDW0IgDc9v4XrpeAYhPcEa2hjYE4GRAwO/dELTIrpZmUiznnIKkAgymBliyJHn2jj0BkMhgKAE8Bz4C+QQHIO0PqkUHfAsAVY5/aK8rHcHVIqBzgOArAZFcwkJgZkr38h3+ArgOPyPzh6FmKhdKAAgHuBppRE/5TzBsrRUd/kEitC/gH0B68DccD/8WBAGr/8ANo1INY2KtzGon7aun/+jX//ks8ZKnU+vf01retOeEyVuXY7rufK4IgiMkikjZSaVGkzdXN1c3SAA91yHHgFQA3VfMjRH791+6mukqa6XsJna83YmcyICQkICQkPTAsCJieUxNSKsMhQUFhcDzwHAJCQoNBQdfAc+ArxF7FdQZDmAJ4CwBXAb+kX9Qd4dsDjI7+Avwg49ASL+AQHdI6pEeI7/AXwGv3Q/Mn8p3yicGilBcBFM5gaZEkT+oOAZkcQqRz5BIvIeIn7A+yB3Tz/8WBAGV/8ANo1INYoILlYIlE/bWaz/+96//j85rJ6mu+N+fv9vXF3at8ZFaznUDbbnttyIIgiJKJaJKJnRLa1jRZzwAw1qGXGX4oOdoa6LnWudFKJKJKJKC09s6btnsIrGhtIsRsSJ/Dj9J1MKxdnKkXnYvIrAcA5hIWHEOcDjgJDIdofbAsOuBYAuBXoFfMOIcQiRPAXwDgFh2hIcwxA9fIc/CDnkc/iHsD5hsAWMahUBgUPYF0gEegOQcwiQkc5AEitB8g7JGp4//FgQBef/ADkNQRMSxsQ6KUyPeac//3fX//m7PCa9TXnj5781F348rrfFc6A/daFhcs8s8vl3+OWc7gEAnyDRJGyAU3FHW0eXpbnlnOsLC3DAlXAKkWgd1uSCZ7pFRKAQXMDLFQi9ingXMCRRM9g78XyYWIvNwHeg0w3hz8w+4OoOiRYb4DnwF5CA6AgNh1wX+Ac/CDnsb/VJj7A+AakWFwaKUQBRc8mFU4Cf8h65yUzSd+AQb4/kPBi5fD/8WBAGV/8AUY1EHZKKltOIV19cT+9/yk97lpEkkSSSSOKSSX9wAAAAAAAA0NDQ0WxbFsZg407I9Y+4CJHJ3x/vj1Zv4Pq+15Xi7HPz8/Pt28e3bt27cPDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw+X+M5oSNCo4//FgQBZf/AEINQvj05Bc85Wf/2X+fOruSIRCIRECAgHv7+/v7+/v7+4fD+YfA+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+PjgA=='
    '.wma' = 'MCaydY5mzxGm2QCqAGLObOwBAAAAAAAABQAAAAECodyrjEepzxGO5ADADCBTZWgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB4bAAAAAAAAAIA+1d6xnQECAAAAAAAAAMAXUwIAAAAAABJ6AAAAAAAcDAAAAAAAAAIAAACADAAAgAwAAAB9AAC1A79fLqnPEY7jAMAMIFNlLgAAAAAAAAAR0tOruqnPEY7mAMAMIFNlBgAAAAAAQKTQ0gfj0hGX8ACgyV6oUGIAAAAAAAAAAQAoAFcATQAvAEUAbgBjAG8AZABpAG4AZwBTAGUAdAB0AGkAbgBnAHMAAAAAABoATABhAHYAZgA2ADEALgA3AC4AMQAwADMAAACRB9y3t6nPEY7mAMAMIFNlcgAAAAAAAABAnmn4TVvPEaj9AIBfXEQrUM3Dv49hzxGLsgCqALTiIAAAAAAAAAAAHAAAAAgAAAABAAAAAABhAQEAgD4AAKAPAACAABAACgAAAAAAAQAAAAAAAYAAgAABAABAUtGGHTHQEaOkAKDJA0j2ZAAAAAAAAABBUtGGHTHQEaOkAKDJA0j2AQAAAAIAFwBXAGkAbgBkAG8AdwBzACAATQBlAGQAaQBhACAAQQB1AGQAaQBvACAAVgA4AAAAAAACAGEBNiaydY5mzxGm2QCqAGLObDIZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAQGCAAAJXY4AAAAAgAKVAQEAAAAACIAAAAAcDAAAgADAD/QAAAZTlH5ZT+eUfl+eA/ywFgPzeAq4PN571weEHS+fK4iOkZ/Puny/yZ4CbwAdPm8BOQA+Ap8AfOM5VYrA50/2x7pbPbzfm8o/K3/vity3xrS0/W3z6l/Q+ppRQmlFCUoQUhBSEFIQUgEgEgEgEgEgTExMTExMTExMTEw8TgECAAAAAAiAAAAAPAwAAIAAwg/0AAAHtMFIWn+CZ8BRgAeA/IAcEtY6HxTEvE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk4BAwAAAAAIgAAAAFwMAACAAMMP9AAAA74qu2H8+6fXwHsACtebNFWJeE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OAQQAAAAACIAAAAB8DAAAgADBD/QAAAO8gJStW6tM+AwIAfAfEAP4u82/oQkgF4BOTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTgEFAAAAAAiAAAAAnAwAAIAAvw/0AAAHDEhBf0VjYJfAfgAPgM8AHzgT9/tFBSBMPE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk4BBgAAAAAIgAAAALwMAACAAMAP9AAABwxNR2TWNR4D5gBcRsriOH7WFWJh4E5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OAQcAAAAACIAAAADcDAAAgAC/D/QAAAcMAlCH7+sbPk8B5YA+A5kALYasBfumgJIBeE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTgEIAAAAAAiAAAAA/AwAAIAAwg/0AAADukIStrX894CuAB8B6wAZ8nmqaQgmHk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk4BCQAAAAAIgAAAABwNAACAAMMP9AAAA7pqO38BDQBUeA9wAHEEsakw8E5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OAQoAAAAACIAAAAA8DQAAgADCD/QAAAO6ShC2t/z3gK9ADwHpAA4h/NUUlAMPAE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTgELAAAAAAiAAAAAXA0AAIAAvw/0AAAHBIBSh8/rHwbPAegAHgOPADzjP5fqmkIJh4BOTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk4BDAAAAAAIgAAAAHwNAACAAMAP9AAABwTFV2HSlR4D5gA/kyuI8fpY1JiXgE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OAQ0AAAAACIAAAACcDQAAgAC/D/QAAAcEkBJfUVj+EfAfaAHgNHAFxLef3+kUlAMS8E5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTgEOAAAAAAiAAAAAvA0AAIAAwQ/0AAAHtIBShat9aZ8BfgAeA+gAawPrHfPkpAJeTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk4BDwAAAAAIgAAAANwNAACAAMMP9AAAA74qu2P8/nwLwHsgCt+bFFWJeE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OARAAAAAACIAAAAD8DQAAgADCD/QAAAO+AkrT7BM+ApEAfAfeAOCSsdL4JiXgTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTgERAAAAAAiAAAAAHA4AAIAAvw/0AAADgJCEv1rzVaZ8B1AA+A90AcF3vN2+ihJAJeBOTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk4BEgAAAAAIgAAAADwOAACAAMAP9AAABwxNR2RWNx+A98AfATyANcR1P7FFWJeATk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OARMAAAAACIAAAABcDgAAgADAD/QAAAcMSUB+msbAXgPOAHwFqgBbDUtftNATEvBOTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTgEUAAAAAAiAAAAAfA4AAIAAwA/0AAAHuASEUreUYJjwGlgD4D7gAdPmrG436EEgPE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk4BFQAAAAAIgAAAAJwOAACAAMMP9AAAA7pqFbR/PeAlMAfAecAH5eaNIRMPAE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIIAABFdLgqgAgAAYACEARYAAAAACIAAAAC8DgAAgADDD/QAAAO6agW0/z3gJYADwHmABgPzQpKJh4BOTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTgEXAAAAAAiAAAAA3A4AAIAAwA/0AAADhAJRQt5TWmPAagAHgPnAB0+esbifpQCQ8E5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk4BGAAAAAAIgAAAAPwOAACAAMAP9AAABwTFUPk1j4C8B6AAeAssAPOMrX6NIRMPAE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OARkAAAAACIAAAAAcDwAAgADAD/QAAAcExVL4Vj2/wHvAB4CgwBrTn0/oU1JiXk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
}
$videoFixtureBase64 = [ordered]@{
    '.mp4' = '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'
    '.mkv' = 'GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAQVRFNm3TAv4SvP51DTbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIBhU27jFOrhBxTu2tTrIIQOewBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hL9bXi4q17GDD0JATYCMTGF2ZjYxLjcuMTAzV0GMTGF2ZjYxLjcuMTAzc6SQ2wHntzWnyf9VlvlRVvxO8USJiECJAAAAAAAAFlSua0CQv4Q+jnuorgEAAAAAAACB14EBc8WI37TBGhR0AOqcgQAitZyDdW5kiIEAho9WX01QRUc0L0lTTy9BVkODgQEj44OEC+vCAOCQsIFguoE2moECVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOipgFCwAr/4QAXZ0LACtoYn5sBEAAAAwAQAAADAKjxImoBAARozg/IElTDZ0CCv4TmLuEjc3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2MS43LjEwM3Nz12PAi2PFiN+0wRoUdADqZ8iiRaOHRU5DT0RFUkSHlUxhdmM2MS4xOS4xMDEgbGlieDI2NGfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDAuODAwMDAwMDAwAB9DtnVOJr+E7VmPaueBAKNJ6IEAAIAAAAJTBgX//0/cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY0IHIzMTA4IDMxZTE5ZjkgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDIzIC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTUgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAB4lliIQ6DGAAgilEQhKWgA0HLKLT0AAp//gAU2RExv0Mjv4aGdJ8zIiuADhEwCChAAEQgFiUHBBGIAshiqUns9BwACgAAgCsQBYABEDAoiVcVzwYwAIwAAgAwFNJHkyYnizESxAB4P8S2Mto139dAA8F+LbGWwa7+ugw/z2Zmxv1OruGH8IAAqCAFgDwQAAgRAACASAAIHoLgPAeQSSx6f58d/bPAdAANCCzNBw+W/wPsUolIkkGMwHAAEC4AAQEgBwAB9MEAALgACAREAAECIAAQkYOEFYwcIKxBwACoAAgCMYOAAVAAEARiMwHAAEC4AAQEwBwAAj/JggABUAAR04gAAgRDYOEFYg4QViDgAFQABAEYg4ABUAAQBGAxgAIMhQFQWUWMdcLpFgEhn4AHk7RZ8gLhhv7cpkZIbdTKz/QD3FpjbaMd/XX/wgAEIA0IBAACAkABwABBRAAtgAe+Hcxbihht/7+AB4Eyg1NPGWy4Om1/74X/AjHAi1NWIAyKbGUutICYCaZAACBgmWHAAQMEy00w4ACBgmWHAAQMEywB0EondVtcQN33BgKmIy3d3DbnB4f4QEAAQA1DAgAD4AAhCBYKiAgjGAC7KoGc0NR7xAACgAAgDsYAE4NB7v7DChOZOwYWcABJpNNMAAQEwAJV2BIh/noyNicBy154iIAARAAzHwcAAiABmIOAARAAzAEgAEwwQkAAIDgAB4OukAEHqbWckAAGgd9yCyDbbwDxamS745IAAEDcAAQBgRcFOMdPBcwZaVPM/ULYACaaQELN1YuDXv/gAODBTRZFtQ2bUIC6BUq0AMgDgnzWDSgoxbXaP//+AYKjHC1VMPCFl1BBwABghjHsNSkAgRluo/IAAEAoAAQBgA64QAAIGwAAgDgu4EAAUBQacCAANAcOMweAGZ4OAAgACAIZm0LP4Gc5zmMY4GFa1oETEgAAgBQi4AEoIoj2INMS8V9RUgAAgBQi4QAAIBYAAgDgB9wPyAACAFCLgcAAQCwABAHAD7gcAAgBQi4HAAEAsAAQBwA+5+IAJYgABwCSACy3MOAWW5kAACAOByrmHAAEAcDlXMLOAAh5wAVjQRMEHh/XuD20bP4ADtiOk3cofN4NEgCwJAWAHQAMvBxlw6KgAFJwCgq88EgLAsBYKgAGpwA4HXng6AAUl4BQVcOggADYAAgMBQOgYAAQQwUAAQAGgDoYrp+TeACx6Cc1pmJ4EcAyaHZYAlgAP0MIT5RXvwBwDZArGB1bsVPQMqJAW34LYACUwHaJEOkK6CqM0w/imKYEJkZBFbqYKZanjJbBTFMSAbA4iWwSBsFKrYEAAIAoGDHQgABABAAECAKB9hpZRpYYQAGWwCG+qh4ACAgmtGWWUVL56ZYsqbjqMdAANkAQT4OgvgAI2QAAgFZQmBBQ0eRAZ+Gv+77mIOAQURGh3BwAg4yNAOAECjo0BAAqBHBAACAKAmAFhgfAXIqlkoANAx5ayg6Ay0MS8OgwAArYAAIAmRVLBzmBkrgQ1G7Q8EI2KAtgAuaAA+AUIIsAAogBrff4gAsCALADgDZhi+DooAA3AQJtPBAFgQBYKAAF7gDA208KAANwECbTwIEAAQPwABAJuEAEfgwrcsESTADyCAAMtAcVu0SgAEKAcZ1ZwqljQACsAAEATUCAGWhiW2jECC5YqOpgvgAMyAC4FFSn2YNSifRd8AJYZRXtKNNS8W4WVoYYpXDsmOIPbtB+KMUdocYgiT2CjFGJAAISgcMnsEgAFJQHBU9gYAAgCAHlBAAGSgACBKAAIBxW5ZQDpY8AAgAUZSgeAQcrKFssOAIcuWOgZaHc8Oh1XhOFDoLYAgEG4AbjYvyTrlA1pCEWC/+ABTZETG/QyO5AAAgFAACAMAHXPgocAAQCgABAGABFweAIYTCgSAAbADAFGBU4zSo8AA2AGATCgHAAOgAgC4UBCAAIBAw0IAAkAKBegBifouwA7/elCgBFAQsArTABPkapsA9rgABACLsuTkAnhAOIz9oeBDkTQFnG1AIfof/0Oh/EAQABAQiAACBGABb4LA8aEoeCwOImD+AqGAG0AOuPgsBwDQAtwME+MzDUZzkgPH8rsrJsCdos+QFww39g/AAdsZ1mzsqIwAP4eIAAQAAViDgAEAAFY8IgEAAcAAoIAAmoAAgMxg2mqA9UDCb+TAQWQxAUBVjgA0wAIZKk+HQ3LpcDl4oMswAAgABaAAxYfYWJA9BphZVZlVVVVVVQwACwMAqGAAcBLoAYQuSgBEyEAULRggqIAAF4QABMlIAi5A4ABdgAEoyEWgWfRR0fsf/2Ox/BwIAAhQxAABAeAAEAzVEWRMs8jwWHhYsAFQgAYACWHgLA4AgBmAvgA6MkYCHdYA0OZX5pk/+ALDdETAn7Omh94ACmiMmJxSlb4kPyAACIGC7mHAAIgYLuYQQABAFEvhAAEgAOMH3bLBu7QWRRwt3sgsAAQC7m+gYJgk6sXHqPDAGH7IAAJjAACABcCxIFh3e7d73d3cQAnYYAAgagAFdIBhqMw6BwcahWHRBACoFAfkHuABygegBA4D6whABySCjQTSBAMgAAAABLEGaIEonXV8VvWtS9T3wxFAAEASJAAEALgPGYCSwORmAksKAAIAkGgBBKA5GYDSxhUyBCDgYABChYgABYFSZB4HvQmVbDtg3yyty/DEsABigAEZBYPw2wcsKAAwYIdBswOWi2xzAYBIgYAAwB17aO3MrcsLX4vDEsxQ39BilLChg0D6LPGwH5gYABuASK+UVLHVrWgwe4YYgggOACDjQomYOACDjQomcYrtz1hjABlpoGrdWCG+wMILkOEAAZBgkhA4BQe4gghzuVQOAAIAocCLkALNbZTzE6LwxFAAxQACEDqAvDEgKWFAAIQaQVBiQFLGykLAYGFg4ABcDL9YS71dhUsLsuvDEsGKO6DLEr4UGDAHUJhaCDHMwgABgDoFeP9Bty9JDMT8PWK+srqNBWIEBkAAAAAFQQZpAWl1TydYJepS+rfDEUAAQBooAAgDQHIZgGlgchmAaWAxEAyYKQGmDnQyICPGzODEEEznEAAMAdIKDfLJQBNGDfLC92LwxLAAKxQACsWyGLTgdIwHLAxAOhPpFLwOZm4KA1GCIAJwLtNASLQ55h0nLI5w7jwxLDFNEBljuA6JkFIAAgDpgsZYONBHwHeBIADgCBga7SsCpYPaVBkvXQjQfdhiCCA4ACDjQ4mYOAAg40OJnb40KAPUABk0aA1a9gx/kAkEE5jhAAGwMFlIHAKBbmIBmkfPANAAEAcFiAM7sALNZsU9ciovDEUAApFAAKQHmIaWB7IClgbAKhSdIQlApjzwhALBQgQLh34gRFiuG6wjJroCigrjwxLBig0oMsLJywPGyC6AAIAyYjBWx0+GTgZ4BgADlA4QMa4dI5YOpujqCJBWJc9f8em76v9Yso0GdgQJYAAAAAZVBmmBqXE31VVX1S/VJ8Vq93d/V/nrGUzg/9SX1S/VJ8l3uuNuvq2KAAIB0FYAAgGJgDhFcESwg8DNAGgHgi0LAALyjLCVzD0hhZYIACg+gcAA9AHwHU+gd4IJoDpHLDpHL8MRQACsSAAV4I5GAdTD0hjywNGoeB5Y3FYpYICCpMCACCNLw7K6gfY99oppBCwfUzO/V4YihhY0FZS0vFSGRAFTCwABANhxdEGwFHBINhBQm8wQgAGgCBABKOrDzKWMVUdCAlWnNsMRu3bAcAAiBwsFEzBwACIHCwUTMVhZTG+KwQHlQAZMjQN26kDC7rBhBOI0IAA6AgJMQNACwevMBi9O/tFNANAAEA0HkBXq8AKGWZhb1zFTwQbu4oABSIAAKcB7ENLDBENLFD0LBvnQ9n4IBBFGhACHYVjUvLLIwTW1yQlLIWW7PG11vUUBhUaFE/IQVQ1GARMLAAEAyFa/GRwYGFhpxgitgiAAlAcIABIMukNSx7E62rfRqU0iBazee3+zWb3z9n+0N7XyXt1890u2Gf+AcU7trl7+E/glajbuPs4EAt4r3gQHxggIN8IEJ'
    '.avi' = 'UklGRnAeAABBVkkgTElTVDgSAABoZHJsYXZpaDgAAABADQMAqGEAAAAAAAAQCQAABAAAAAAAAAABAAAAAAAQAGAAAAA2AAAAAAAAAAAAAAAAAAAAAAAAAExJU1TgEAAAc3RybHN0cmg4AAAAdmlkc0ZNUDQAAAAAAAAAAAAAAAABAAAABQAAAAAAAAAEAAAA+QUAAP////8AAAAAAAAAAGAANgBzdHJmKAAAACgAAABgAAAANgAAAAEAGABGTVA0wDwAAAAAAAAAAAAAAAAAAAAAAABKVU5LGBAAAAQAAAAAAAAAMDBkYwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB2cHJwRAAAAAAAAAAAAAAABQAAAGAAAAA2AAAACQAQAGAAAAA2AAAAAQAAADYAAABgAAAANgAAAGAAAAAAAAAAAAAAAAAAAAAAAAAASlVOSwQBAABvZG1sZG1saPgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAExJU1QaAAAASU5GT0lTRlQNAAAATGF2ZjYxLjcuMTAzAABKVU5L+AMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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'
    '.mov' = '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'
    '.wmv' = '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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACQCAAzseXPEYn0AKDJA0nLVgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgJaYAAAAAAAAAAAABQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=='
    '.m4v' = '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'
}

function New-SineWav {
    param([string]$Path, [double]$Seconds, [switch]$Float, [int]$Junk = 0)
    $rate = 8000; $n = [int]($rate * $Seconds)
    $bits = if ($Float) { 32 } else { 16 }; $bp = $bits / 8
    $data = New-Object 'System.Collections.Generic.List[byte]'
    for ($i = 0; $i -lt $n; $i++) {
        $v = 0.3 * [Math]::Sin(2 * [Math]::PI * 440 * $i / $rate)
        if ($Float) { $data.AddRange([System.BitConverter]::GetBytes([single]$v)) }
        else { $data.AddRange([System.BitConverter]::GetBytes([int16]($v * 32767))) }
    }
    $f = New-Object 'System.Collections.Generic.List[byte]'
    for ($i = 0; $i -lt $Junk; $i++) { $f.Add([byte](0x20 + ($i % 40))) }
    $f.AddRange([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
    $f.AddRange([System.BitConverter]::GetBytes([uint32](4 + 8 + 16 + 8 + $data.Count)))
    $f.AddRange([System.Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $f.AddRange([System.BitConverter]::GetBytes([uint32]16))
    $f.AddRange([System.BitConverter]::GetBytes([uint16]$(if ($Float) { 3 } else { 1 })))
    $f.AddRange([System.BitConverter]::GetBytes([uint16]1))
    $f.AddRange([System.BitConverter]::GetBytes([uint32]$rate))
    $f.AddRange([System.BitConverter]::GetBytes([uint32]($rate * $bp)))
    $f.AddRange([System.BitConverter]::GetBytes([uint16]$bp))
    $f.AddRange([System.BitConverter]::GetBytes([uint16]$bits))
    $f.AddRange([System.Text.Encoding]::ASCII.GetBytes('data'))
    $f.AddRange([System.BitConverter]::GetBytes([uint32]$data.Count))
    $f.AddRange($data.ToArray())
    [System.IO.File]::WriteAllBytes($Path, $f.ToArray())
}
function Pump { param([int]$Ms) $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $Ms) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 } }
function Wait-State { param([int]$State, [int]$TimeoutMs = 6000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) { [System.Windows.Forms.Application]::DoEvents(); if ([NativeMfAudioEngine]::GetState() -eq $State) { return $true }; Start-Sleep -Milliseconds 20 }
    return $false
}

try {
    $wav = Join-Path $tmp 'tone.wav'
    New-SineWav -Path $wav -Seconds 3

    [NativeMfAudioEngine]::Open($wav)
    $started = Wait-State 2
    if (-not $started) {
        Report 'FAIL' 'MFPlay: a PCM WAV reaches PLAYING' 'state never became PLAYING within 6 s (no audio device, or messages not pumped?)'
        foreach ($n in 'duration is reported', 'position advances', 'pause/resume', 'seek while paused', 'seek past the end', 'volume', 'play to the end', 'stop/close', 'float WAV (converted)', 'WAV with junk (stripped)') {
            Report 'SKIP' "MFPlay: $n" 'engine never started'
        }
    }
    else {
        Report 'PASS' 'MFPlay: a PCM WAV reaches PLAYING'
        T 'MFPlay: duration is reported (about 3 s)' {
            $d = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 3000 -and $d -le 0) { Pump 50; $d = [NativeMfAudioEngine]::GetDurationMilliseconds() }
            Need ($d -ge 2500 -and $d -le 3500) "duration was $d ms"
        }
        T 'MFPlay: position advances while playing' {
            $p1 = [NativeMfAudioEngine]::GetPositionMilliseconds(); Pump 500; $p2 = [NativeMfAudioEngine]::GetPositionMilliseconds()
            Need ($p2 -gt $p1) "position did not advance ($p1 -> $p2)"
        }
        T 'MFPlay: pause freezes the position, play resumes' {
            [NativeMfAudioEngine]::Pause(); Pump 150
            Need ([NativeMfAudioEngine]::GetState() -eq 3) 'state is not PAUSED'
            $p1 = [NativeMfAudioEngine]::GetPositionMilliseconds(); Pump 300; $p2 = [NativeMfAudioEngine]::GetPositionMilliseconds()
            Need (($p2 - $p1) -lt 120) "position moved while paused ($p1 -> $p2)"
            [NativeMfAudioEngine]::Play(); Pump 100
            Need ([NativeMfAudioEngine]::GetState() -eq 2) 'state is not PLAYING after resume'
        }
        T 'MFPlay: seek works while paused' {
            [NativeMfAudioEngine]::Pause(); Pump 100
            [NativeMfAudioEngine]::SetPositionMilliseconds(1500); Pump 250
            $p = [NativeMfAudioEngine]::GetPositionMilliseconds()
            Need ($p -ge 1300 -and $p -le 1900) "position after seek was $p ms"
            [NativeMfAudioEngine]::Play()
        }
        T 'MFPlay: seeking past the end is clamped and does not throw' {
            [NativeMfAudioEngine]::SetPositionMilliseconds(999999999); Pump 100
        }
        T 'MFPlay: volume changes are accepted' {
            Need ([NativeMfAudioEngine]::SetVolume(50)) 'SetVolume(50) failed'
            Need ([NativeMfAudioEngine]::SetVolume(100)) 'SetVolume(100) failed'
        }
        T 'MFPlay: a track plays to the end and then reports STOPPED' {
            [NativeMfAudioEngine]::Open($wav)
            Need (Wait-State 2) 'did not start'
            Need (Wait-State 1 8000) 'never reached STOPPED at the end of the track'
        }
        T 'MFPlay: Stop then Close return the engine to EMPTY' {
            [NativeMfAudioEngine]::Open($wav)
            Need (Wait-State 2) 'did not start'
            [NativeMfAudioEngine]::Stop(); Pump 100
            Need ([NativeMfAudioEngine]::GetState() -eq 1) 'not STOPPED after Stop'
            [NativeMfAudioEngine]::Close()
            Need ([NativeMfAudioEngine]::GetState() -eq 0) 'not EMPTY after Close'
        }
        # ---- Stress and reliability: native engine lifecycle -----------------
        T 'Stress: repeated MFPlay open/play/stop/close cycles' {
            try {
                for ($i = 1; $i -le 8; $i++) {
                    [NativeMfAudioEngine]::Open($wav)
                    Need (Wait-State 2 8000) "cycle $i did not reach PLAYING"
                    [NativeMfAudioEngine]::Stop(); Pump 40
                    [NativeMfAudioEngine]::Close(); Pump 40
                    Need ([NativeMfAudioEngine]::GetState() -eq 0) "cycle $i did not return to EMPTY"
                }
            }
            finally { [NativeMfAudioEngine]::Close() }
        }
        T 'Stress: rapid playback controls and close tolerate callback activity' {
            try {
                for ($i = 1; $i -le 6; $i++) {
                    [NativeMfAudioEngine]::Open($wav)
                    Need (Wait-State 2 8000) "cycle $i did not reach PLAYING"
                    # MFPlay callbacks are asynchronous; pump messages between
                    # rapid state changes and verify cleanup after each sequence.
                    [NativeMfAudioEngine]::Pause(); Pump 40
                    [NativeMfAudioEngine]::Play(); Pump 40
                    [NativeMfAudioEngine]::SetPositionMilliseconds(250); Pump 40
                    [void][NativeMfAudioEngine]::SetVolume(65)
                    [NativeMfAudioEngine]::Pause(); Pump 40
                    [NativeMfAudioEngine]::Stop(); Pump 40
                    [NativeMfAudioEngine]::Close(); Pump 100
                    Need ([NativeMfAudioEngine]::GetState() -eq 0) "cycle $i left the engine outside EMPTY"
                }
            }
            finally { [NativeMfAudioEngine]::Close() }
        }
        T 'Stress: repeated playback does not cause unbounded process resource growth' {
            $proc = [Diagnostics.Process]::GetCurrentProcess()
            try {
                # Warm up MFPlay before taking the baseline so one-time startup
                # allocations do not look like per-playback leaks.
                for ($i = 1; $i -le 2; $i++) {
                    [NativeMfAudioEngine]::Open($wav)
                    Need (Wait-State 2 8000) "warm-up $i did not reach PLAYING"
                    [NativeMfAudioEngine]::Close(); Pump 100
                }
                [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
                Pump 200
                $proc.Refresh()
                $baseHandles = $proc.HandleCount
                $basePrivate = $proc.PrivateMemorySize64
                for ($i = 1; $i -le 10; $i++) {
                    [NativeMfAudioEngine]::Open($wav)
                    Need (Wait-State 2 8000) "cycle $i did not reach PLAYING"
                    [NativeMfAudioEngine]::Close(); Pump 80
                }
                [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
                Pump 200
                $proc.Refresh()
                $handleGrowth = $proc.HandleCount - $baseHandles
                $privateGrowth = $proc.PrivateMemorySize64 - $basePrivate
                Need ($handleGrowth -le 32) "process handle count grew by $handleGrowth (baseline $baseHandles)"
                Need ($privateGrowth -le 67108864) "private memory grew by $([Math]::Round($privateGrowth / 1MB, 1)) MB"
            }
            finally { [NativeMfAudioEngine]::Close(); $proc.Dispose() }
        }
        T 'MFPlay: a WAV with leading junk is playable after stripping' {
            $jw = Join-Path $tmp 'junk.wav'; $out = Join-Path $tmp 'junk.clean.wav'
            New-SineWav -Path $jw -Seconds 2 -Junk 64
            Need ([WavFloatConverter]::TryPrepare($jw, $out, $true)) 'junk was not detected'
            [NativeMfAudioEngine]::Open($out)
            Need (Wait-State 2) 'stripped copy did not start playing'
            [NativeMfAudioEngine]::Close()
        }
    }
    [NativeMfAudioEngine]::Close()

    # ---- Real codec fixtures: automatically provision one file per audio extension ----
    foreach ($ext in $audioFixtureBase64.Keys) {
        $fixtureName = 'audio_' + $ext.TrimStart('.') + $ext
        $fixture = Get-MediaFixture -Name $fixtureName -Base64 $audioFixtureBase64[$ext]
        if (-not $fixture) {
            Report 'FAIL' "Audio playback: $ext" 'could not create the embedded test fixture'
            continue
        }
		$testExt = $ext
		$testFixture = $fixture
		
		T "Audio playback: $testExt decodes and plays" {
			try {
				switch ($testExt.ToLowerInvariant()) {
					'.ogg' {
						[DirectPcmAudioEngine]::Open($testFixture)
						break
					}
					'.aiff' {
						[DirectPcmAudioEngine]::OpenAiff($testFixture)
						break
					}
					'.aif' {
						[DirectPcmAudioEngine]::OpenAiff($testFixture)
						break
					}
					default {
						[NativeMfAudioEngine]::Open($testFixture)
						break
					}
				}
				
				if ($testExt -in @('.ogg', '.aiff', '.aif')) {
					$duration = [DirectPcmAudioEngine]::GetDurationMilliseconds()
					Need ($duration -gt 0) "decoder returned no playable audio ($duration ms)"
					$p1 = [DirectPcmAudioEngine]::GetPositionMilliseconds()
					Pump 40
					$p2 = [DirectPcmAudioEngine]::GetPositionMilliseconds()
					Need ($p2 -gt $p1) "waveOut playback position did not advance ($p1 -> $p2)"
				}				
				else {
					Need (Wait-State 2 8000) 'file did not reach PLAYING'
					$p1 = [NativeMfAudioEngine]::GetPositionMilliseconds()
					Pump 500
					$p2 = [NativeMfAudioEngine]::GetPositionMilliseconds()
					Need ($p2 -gt $p1) "MFPlay position did not advance ($p1 -> $p2)"
				}                
            }
            finally { 
				[DirectPcmAudioEngine]::Close()
				[NativeMfAudioEngine]::Close()
			}
        }
    }

    # ---- Exercise the actual queue functions with the real MFPlay engine -------
        $targetTokens = $null
        $targetParseErrors = $null
        $targetAst = [System.Management.Automation.Language.Parser]::ParseFile($TargetPath, [ref]$targetTokens, [ref]$targetParseErrors)
        Need ($targetParseErrors.Count -eq 0) 'play.ps1 failed to parse during queue integration setup'
        $targetFunctions = @($targetAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
        foreach ($fn in $targetFunctions) {
            . ([scriptblock]::Create($fn.Extent.Text))
        }
        # Suppress tray notifications in this headless playback check.
        function Show-Notification { param($title, $text) }
        function Update-KeyBuffer { }
        $global:TempAudioDir = Join-Path $tmp 'queue-temp'
        $global:TempAudioFile = $null
        $global:Volume = 70
        $global:Paused = $false
        $global:Alias = $null
        $global:SeekEnabled = $false
        $global:ArrowSteps = 0
        $global:AudioHasPlayed = $false
        $queueFixtureA = Join-Path $tmp 'queue_fixture_a.wav'
        $queueFixtureB = Join-Path $tmp 'queue_fixture_b.wav'
        New-SineWav -Path $queueFixtureA -Seconds 2
        New-SineWav -Path $queueFixtureB -Seconds 2
        $global:Queue = @($queueFixtureA, $queueFixtureB)
        $global:Index = 0
        $global:LastPlayedIndex = 0
        T 'MFPlay queue: Next-Track and Prev-Track switch real files' {
            try {
                Play-Current
                Need (Wait-State 2 8000) 'first track did not start'
                Next-Track
                Need ($global:Index -eq 1) "Next-Track index was $global:Index"
                Need (Wait-State 2 8000) 'second track did not start'
                Prev-Track
                Need ($global:Index -eq 0) "Prev-Track index was $global:Index"
                Need (Wait-State 2 8000) 'previous track did not restart'
            }
            finally { Stop-Current }
        }

        # Execute the exact end-of-track branch extracted from play.ps1's main loop.
        $transitionAst = $targetAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text -match '\$mediaState\s+-eq\s+1' -and
            $node.Extent.Text -match '\$global:RepeatOne'
        }, $true) | Select-Object -First 1
        if ($transitionAst) {
            $transitionBlock = [scriptblock]::Create($transitionAst.Extent.Text)
            $shortA = Join-Path $tmp 'queue_auto_a.wav'
            $shortB = Join-Path $tmp 'queue_auto_b.wav'
            New-SineWav -Path $shortA -Seconds 2
            New-SineWav -Path $shortB -Seconds 2
            $global:Queue = @($shortA, $shortB)
            $global:Index = 0
            $global:LoopMode = $false
            $global:RepeatOne = $false
            T 'MFPlay queue: natural end automatically starts the next track' {
                try {
                    Play-Current
                    Need (Wait-State 2 8000) 'first track did not start'
                    $global:AudioHasPlayed = $true
                    Need (Wait-State 1 8000) 'first track did not finish'
                    $mediaState = [NativeMfAudioEngine]::GetState()
                    & $transitionBlock
                    Need ($global:Index -eq 1) "automatic advance left index at $global:Index"
                    Need (Wait-State 2 8000) 'next track did not start after natural end'
                }
                finally { Stop-Current }
            }
            $global:Index = 0
            $global:LoopMode = $false
            $global:RepeatOne = $true
            T 'MFPlay queue: repeat-one restarts the current track after natural end' {
                try {
                    Play-Current
                    Need (Wait-State 2 8000) 'track did not start'
                    $global:AudioHasPlayed = $true
                    Need (Wait-State 1 8000) 'track did not finish'
                    $mediaState = [NativeMfAudioEngine]::GetState()
                    & $transitionBlock
                    Need ($global:Index -eq 0) "repeat-one changed index to $global:Index"
                    Need (Wait-State 2 8000) 'repeat-one did not restart playback'
                }
                finally { Stop-Current }
            }
            $global:Index = 1
            $global:LoopMode = $true
            $global:RepeatOne = $false
            T 'MFPlay queue: loop mode restarts the queue from its first track' {
                try {
                    Play-Current
                    Need (Wait-State 2 8000) 'last track did not start'
                    $global:AudioHasPlayed = $true
                    Need (Wait-State 1 8000) 'last track did not finish'
                    $mediaState = [NativeMfAudioEngine]::GetState()
                    & $transitionBlock
                    Need ($global:Index -eq 0) "loop mode left index at $global:Index"
                    Need (Wait-State 2 8000) 'loop mode did not restart the first track'
                }
                finally { Stop-Current }
            }
        }
        else {
            Report 'SKIP' 'MFPlay queue: natural-end, repeat-one and loop transitions' 'could not locate the end-of-track branch in play.ps1'
        }

    # ---- Full application smoke test: start the real main menu and exit ---------
    T 'Application: complete play.ps1 startup and clean menu exit' {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $escapedTarget = $TargetPath.Replace('"', '\"')
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $escapedTarget + '"'
        $psi.UseShellExecute = $false
        # Keep stdout attached to the console so Clear-Host is exercised in a
        # normal console environment; only stdin is piped to select Exit.
        $psi.CreateNoWindow = $false
        $psi.RedirectStandardInput = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        Need $proc.Start() 'could not launch play.ps1'
        try {
            $proc.StandardInput.WriteLine('0')
            $proc.StandardInput.Close()
            if (-not $proc.WaitForExit(15000)) {
                try { $proc.Kill() } catch { }
                throw 'application did not exit after selecting 0 (process was terminated)'
            }
            Need ($proc.ExitCode -eq 0) "application exited with code $($proc.ExitCode)"
        }
        finally { $proc.Dispose() }
    }

    # ---- GUI smoke test of the real video window --------------------------------
    if (-not [Environment]::UserInteractive) {
        Report 'SKIP' 'Video window smoke test (GUI)' 'no interactive desktop session'
        foreach ($ext in '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.m4v') {
            Report 'SKIP' "MFPlay codec: video $ext" 'no interactive desktop session'
        }
    }
    elseif ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Report 'SKIP' 'Video window smoke test (GUI)' 'child process is not STA'
        foreach ($ext in '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.m4v') {
            Report 'SKIP' "MFPlay codec: video $ext" 'child process is not STA'
        }
    }
    else {
        $guiWav = Join-Path $tmp 'gui_test_clip.wav'
        New-SineWav -Path $guiWav -Seconds 12
        $script:gui = @{}
        $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 2500
        $guard = New-Object System.Windows.Forms.Timer; $guard.Interval = 25000
        $guard.Add_Tick({
            $script:gui.Guard = $true
            try { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') } catch { }
            foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { try { $f.Close() } catch { } }
        })
        $timer.Add_Tick({
            $timer.Stop()
            try {
                $form = $null
                foreach ($f in [System.Windows.Forms.Application]::OpenForms) { if (-not $form) { $form = $f } }
                $script:gui.HasForm = ($null -ne $form)
                if ($form) {
                    $script:gui.Title = $form.Text
                    $all = New-Object System.Collections.ArrayList
                    $stack = New-Object System.Collections.Stack
                    $stack.Push($form)
                    while ($stack.Count -gt 0) { $c = $stack.Pop(); foreach ($ch in $c.Controls) { [void]$all.Add($ch); $stack.Push($ch) } }
                    $buttons = @($all | Where-Object { $_ -is [System.Windows.Forms.Button] })
                    $labels  = @($all | Where-Object { $_ -is [System.Windows.Forms.Label] })
                    $bars    = @($all | Where-Object { $_ -is [System.Windows.Forms.TrackBar] })
                    $script:gui.ButtonTexts = ($buttons | ForEach-Object { $_.Text }) -join ' | '
                    $script:gui.BarCount = $bars.Count
                    $status = $labels | Where-Object { @('Playing', 'Paused', 'Stopped', 'Finished', 'Playback error', 'Opening media...') -contains $_.Text } | Select-Object -First 1
                    $script:gui.StatusInitial = if ($status) { $status.Text } else { '<none>' }
                    $script:gui.TimeLabels = (($labels | Where-Object { $_.Text -match '^\d\d:\d\d$' }) | ForEach-Object { $_.Text }) -join ','
                    $seekBar = $bars | Where-Object { $_.Maximum -eq 1000 } | Select-Object -First 1
                    $script:gui.SeekValue = if ($seekBar) { $seekBar.Value } else { -1 }

                    $pause = $buttons | Where-Object { $_.Text -match 'PAUSE' } | Select-Object -First 1
                    if ($pause) {
                        $pause.PerformClick()
                        $script:gui.AfterPause = $pause.Text + ' / ' + $status.Text
                        $pause.PerformClick()
                        $script:gui.AfterResume = $pause.Text + ' / ' + $status.Text
                    }
                    $mute = $buttons | Where-Object { $_.Text -eq 'MUTE' } | Select-Object -First 1
                    if ($mute) { $mute.PerformClick(); $script:gui.MuteOn = $mute.Text; $mute.PerformClick(); $script:gui.MuteOff = $mute.Text }
                    $volBar = $bars | Where-Object { $_.Maximum -eq 100 } | Select-Object -First 1
                    if ($volBar) { $volBar.Value = 40; $script:gui.VolStatus = $status.Text }
                    $full = $buttons | Where-Object { $_.Text -eq 'FULLSCREEN' } | Select-Object -First 1
                    if ($full) {
                        $full.PerformClick(); $script:gui.FullOn = $form.FormBorderStyle.ToString()
                        $full.PerformClick(); $script:gui.FullOff = $form.FormBorderStyle.ToString()
                    }

                    # Exercise the actual Form.KeyDown shortcuts, not just button handlers.
                    $form.Activate()
                    $videoPanel = @($form.Controls | Where-Object {
                        $_ -is [System.Windows.Forms.Panel] -and
                        $_.BackColor.ToArgb() -eq [System.Drawing.Color]::Black.ToArgb()
                    } | Select-Object -First 1)
                    if ($videoPanel.Count -gt 0) { $videoPanel = $videoPanel[0] } else { $videoPanel = $null }
                    if ($videoPanel) {
                        $videoPanel.Focus()
                        [System.Windows.Forms.SendKeys]::SendWait(' ')
                        [System.Windows.Forms.Application]::DoEvents()
                        $script:gui.KeyboardPause = $status.Text
                        [System.Windows.Forms.SendKeys]::SendWait(' ')
                        [System.Windows.Forms.Application]::DoEvents()
                        $script:gui.KeyboardResume = $status.Text

                        [System.Windows.Forms.SendKeys]::SendWait('m')
                        [System.Windows.Forms.Application]::DoEvents()
                        $script:gui.KeyboardMute = ($buttons | Where-Object { $_.Text -eq 'UNMUTE' }).Count -gt 0
                        [System.Windows.Forms.SendKeys]::SendWait('m')

                        [System.Windows.Forms.SendKeys]::SendWait('f')
                        [System.Windows.Forms.Application]::DoEvents()
                        $script:gui.KeyboardFullscreen = $form.FormBorderStyle.ToString()
                        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
                        [System.Windows.Forms.Application]::DoEvents()
                        $script:gui.KeyboardRestored = $form.FormBorderStyle.ToString()
                    }
                    # Run the seek-to-end control last; it can naturally finish
                    # this short clip and would make subsequent key checks flaky.
                    $skip = $buttons | Where-Object { $_.Text -eq '10s >>' } | Select-Object -First 1
                    if ($skip) { $skip.PerformClick(); $script:gui.SkipStatus = $status.Text }
                    $form.Close()
                }
            }
            catch { $script:gui.Error = $_.Exception.Message; foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { $f.Close() } }
        })
        $timer.Start(); $guard.Start()
        try { [NativeMfPlayer]::Start($guiWav) } catch { $script:gui.StartError = $_.Exception.Message }
        $timer.Stop(); $guard.Stop()

        T 'GUI: window opens and shows the file name in its title' {
            Need (-not $script:gui.StartError) "Start threw: $($script:gui.StartError)"
            Need (-not $script:gui.Guard) 'window never responded (modal error dialog?)'
            Need $script:gui.HasForm 'no form was open'
            Need ($script:gui.Title -like '*gui_test_clip.wav*') "title was '$($script:gui.Title)'"
        }
        T 'GUI: handler ran without errors' { Need (-not $script:gui.Error) $script:gui.Error }
        T 'GUI: transport controls, two sliders and a time display are present' {
            foreach ($t in '<< 10s', '10s >>', 'MUTE', 'FULLSCREEN', 'STOP') { Need ($script:gui.ButtonTexts -match [regex]::Escape($t)) "button '$t' missing in: $($script:gui.ButtonTexts)" }
            Need ($script:gui.BarCount -eq 2) "expected 2 sliders, found $($script:gui.BarCount)"
        }
        T 'GUI: playback starts (status Playing, pause button offered)' {
            Need ($script:gui.StatusInitial -eq 'Playing') "status was '$($script:gui.StatusInitial)'"
            Need ($script:gui.ButtonTexts -match 'PAUSE') 'no PAUSE button while playing'
        }
        T 'GUI: duration label and seek slider are updated by the timer' {
            Need ($script:gui.TimeLabels -match '00:1[12]') "time labels were '$($script:gui.TimeLabels)' (expected total about 00:12)"
            Need ($script:gui.SeekValue -gt 0) "seek slider still at $($script:gui.SeekValue)"
        }
        T 'GUI: pause button pauses and resumes' {
            Need ($script:gui.AfterPause -match 'PLAY.*Paused') "after pause: '$($script:gui.AfterPause)'"
            Need ($script:gui.AfterResume -match 'PAUSE.*Playing') "after resume: '$($script:gui.AfterResume)'"
        }
        T 'GUI: mute button toggles its caption' {
            Need ($script:gui.MuteOn -eq 'UNMUTE') "muted caption '$($script:gui.MuteOn)'"
            Need ($script:gui.MuteOff -eq 'MUTE') "unmuted caption '$($script:gui.MuteOff)'"
        }
        T 'GUI: volume slider and +10 s skip do not raise errors' {
            Need ($script:gui.VolStatus -eq 'Playing') "status after volume change: '$($script:gui.VolStatus)'"
            Need ($script:gui.SkipStatus -match 'forward') "status after skip: '$($script:gui.SkipStatus)'"
        }
        T 'GUI: fullscreen button toggles the window border and restores it' {
            Need ($script:gui.FullOn -eq 'None') "fullscreen border was '$($script:gui.FullOn)'"
            Need ($script:gui.FullOff -ne 'None') "border after leaving fullscreen: '$($script:gui.FullOff)'"
        }
        T 'GUI: Space, M, F and Escape keyboard shortcuts work' {
            Need ($script:gui.KeyboardPause -eq 'Paused') "Space did not pause: '$($script:gui.KeyboardPause)'"
            Need ($script:gui.KeyboardResume -eq 'Playing') "Space did not resume: '$($script:gui.KeyboardResume)'"
            Need $script:gui.KeyboardMute 'M did not toggle mute'
            Need ($script:gui.KeyboardFullscreen -eq 'None') "F did not enter fullscreen: '$($script:gui.KeyboardFullscreen)'"
            Need ($script:gui.KeyboardRestored -ne 'None') "Escape did not restore window: '$($script:gui.KeyboardRestored)'"
        }

        # Open each automatically provisioned video format in the real MFPlay video window.
        foreach ($ext in @($videoFixtureBase64.Keys | Where-Object { $_ -ne '.mp4' })) {
            $fixtureName = 'video_' + $ext.TrimStart('.') + $ext
            $videoFixture = Get-MediaFixture -Name $fixtureName -Base64 $videoFixtureBase64[$ext]
            if (-not $videoFixture) {
                Report 'FAIL' "MFPlay codec: video $ext" 'could not create the embedded test fixture'
                continue
            }

            $script:videoProbe = @{ Statuses = @(); Times = @() }
            $script:CurrentVideoFixture = $videoFixture
            $probeTimer = New-Object System.Windows.Forms.Timer; $probeTimer.Interval = 100
            $probeGuard = New-Object System.Windows.Forms.Timer; $probeGuard.Interval = 20000
            $probeGuard.Add_Tick({
                $script:videoProbe.Guard = $true
                try { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') } catch { }
                foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { try { $f.Close() } catch { } }
            })
            $probeTimer.Add_Tick({
                try {
                    $form = $null
                    foreach ($f in [System.Windows.Forms.Application]::OpenForms) {
                        if (-not $form -and $f.Text -eq [System.IO.Path]::GetFileName($script:CurrentVideoFixture)) { $form = $f }
                    }
                    if ($form) {
                        $script:videoProbe.Title = $form.Text
                        $labels = @()
                        $stack = New-Object System.Collections.Stack
                        $stack.Push($form)
                        while ($stack.Count -gt 0) {
                            $c = $stack.Pop()
                            foreach ($ch in $c.Controls) {
                                if ($ch -is [System.Windows.Forms.Label]) { $labels += $ch }
                                $stack.Push($ch)
                            }
                        }
                        $statusLabel = $labels | Where-Object { $_.Text -in @('Playing', 'Playback error', 'Paused', 'Finished') } | Select-Object -First 1
                        $status = if ($statusLabel) { $statusLabel.Text } else { '<missing>' }
                        $script:videoProbe.Status = $status
                        if ($status -ne '<missing>') { $script:videoProbe.Statuses += $status }
                        $timeLabels = @($labels | Where-Object { $_.Text -match '^\d\d:\d\d$' })
                        $script:videoProbe.Times = @($timeLabels | ForEach-Object { $_.Text })
                        # Embedded clips are intentionally very short, so their mm:ss
                        # display can remain 00:00 even when playback starts correctly.
                        if ($status -eq 'Finished' -or $status -eq 'Playback error') {
                            $probeTimer.Stop()
                            $form.Close()
                        }
                    }
                }
                catch {
                    $script:videoProbe.Error = $_.Exception.Message
                    $probeTimer.Stop()
                    foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { try { $f.Close() } catch { } }
                }
            })
            $probeTimer.Start(); $probeGuard.Start()
            try { [NativeMfPlayer]::Start($videoFixture) }
            catch { $script:videoProbe.StartError = $_.Exception.Message }
            $probeTimer.Stop(); $probeGuard.Stop()
            $probeTimer.Dispose(); $probeGuard.Dispose()

            T "GUI codec: video $ext opens and starts playback in the real player" {
                Need (-not $script:videoProbe.StartError) "Start threw: $($script:videoProbe.StartError)"
                Need (-not $script:videoProbe.Error) $script:videoProbe.Error
                Need (-not $script:videoProbe.Guard) 'video window did not respond before timeout'
                Need ($script:videoProbe.Title -eq [System.IO.Path]::GetFileName($videoFixture)) "window title '$($script:videoProbe.Title)'"
                Need ($script:videoProbe.Statuses -contains 'Playing') "Playing state was never observed (states: $($script:videoProbe.Statuses -join ', '))"
                Need (-not ($script:videoProbe.Statuses -contains 'Playback error')) 'player reported a playback error'
                Need ($script:videoProbe.Times.Count -ge 2) 'time labels were not populated'
            }
        }
    }
}
finally {
    try { [NativeMfAudioEngine]::Close() } catch { }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
'@

if (-not $onWindows) {
    Skip-Case 'Embedded C# compiles; COM interface layout; video player internals' 'Windows only (needs mfplay.dll / WinForms)'
    Skip-Case 'Real MFPlay playback, queue transitions, application startup and video tests' 'Windows only'
}
else {
    $csFile = Join-Path $script:Tmp 'embedded.cs'
    $childFile = Join-Path $script:Tmp 'child_checks.ps1'
    [System.IO.File]::WriteAllText($csFile, $csSource)
    [System.IO.File]::WriteAllText($childFile, $childScript)
    $psExe = (Get-Process -Id $PID).Path
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childFile, '-CsPath', $csFile, '-TargetPath', $ScriptPath)
    if ($Integration) { $childArgs += '-Integration' }
    $childOut = @(& $psExe @childArgs 2>&1 | ForEach-Object { "$_" })
    $childExit = $LASTEXITCODE
    $got = 0
    foreach ($line in $childOut) {
        if ($line -match '^RESULT\|(PASS|FAIL|SKIP)\|([^|]*)\|(.*)$') {
            $got++
            Register-Result $Matches[1] $Matches[2] $Matches[3]
        }
    }
    if ($got -eq 0 -or $childExit -ne 0) {
        $tail = ($childOut | Where-Object { $_ -notmatch '^RESULT\|' } | Select-Object -Last 8) -join ' / '
        if ($got -eq 0) { Register-Result 'FAIL' 'Child process (C# + video checks) produced no results' $tail }
        elseif ($childExit -ne 0) { Register-Result 'FAIL' "Child process exited with code $childExit" $tail }
    }
}

}
finally {
    try { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Say ''
Say '----------------------------------------'
Say ("Passed:  {0}" -f $script:Passed) 'Green'
Say ("Failed:  {0}" -f $script:Failed) $(if ($script:Failed -gt 0) { 'Red' } else { 'Green' })
if ($script:Skipped -gt 0) { Say ("Skipped: {0}" -f $script:Skipped) 'Yellow' }
Say '----------------------------------------'

if ($script:Failed -gt 0) { exit 1 }
exit 0
