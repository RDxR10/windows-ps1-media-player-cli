param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$MediaArgs
)
$Name = ($MediaArgs -join ' ').Trim()

$ErrorActionPreference = 'Stop'
$MusicDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MusicDir)) { $MusicDir = (Get-Location).Path }

$AudioExt = @('.mp3', '.wav', '.flac', '.m4a', '.aac', '.wma', '.ogg', '.aiff', '.aif', '.aifc')
$VideoExt = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.m4v')
$AllExt   = $AudioExt + $VideoExt

$global:CodecHintShown = $false
$global:VideoTempDir   = Join-Path ([System.IO.Path]::GetTempPath()) ("play-ps1-video-" + $PID)
$global:AudioDirectFile = $null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mfSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Drawing;
using System.IO;
using System.Text;

[ComImport]
[Guid("A714590A-58AF-430A-85BF-44F5EC838D85")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFPMediaPlayer
{
    [PreserveSig] int Play();
    [PreserveSig] int Pause();
    [PreserveSig] int Stop();
    [PreserveSig] int FrameStep();

    [PreserveSig] int SetPosition(ref Guid type, IntPtr position);
    [PreserveSig] int GetPosition(ref Guid type, IntPtr position);
    [PreserveSig] int GetDuration(ref Guid type, IntPtr duration);

    [PreserveSig] int SetRate(float rate);
    [PreserveSig] int GetRate(out float rate);
    [PreserveSig] int GetSupportedRates(
        [MarshalAs(UnmanagedType.Bool)] bool forward,
        out float slowest, out float fastest);

    [PreserveSig] int GetState(out int state);

    [PreserveSig] int CreateMediaItemFromURL(
        [MarshalAs(UnmanagedType.LPWStr)] string url,
        [MarshalAs(UnmanagedType.Bool)] bool sync,
        UIntPtr userData, out IntPtr item);

    [PreserveSig] int CreateMediaItemFromObject(
        IntPtr obj,
        [MarshalAs(UnmanagedType.Bool)] bool sync,
        UIntPtr userData, out IntPtr item);

    [PreserveSig] int SetMediaItem(IntPtr item);
    [PreserveSig] int ClearMediaItem();
    [PreserveSig] int GetMediaItem(out IntPtr item);

    [PreserveSig] int GetVolume(out float volume);
    [PreserveSig] int SetVolume(float volume);
    [PreserveSig] int GetBalance(out float balance);
    [PreserveSig] int SetBalance(float balance);
    [PreserveSig] int GetMute(out int mute);
    [PreserveSig] int SetMute(int mute);

    [PreserveSig] int GetNativeVideoSize(IntPtr video, IntPtr aspect);
    [PreserveSig] int GetIdealVideoSize(IntPtr min, IntPtr max);
    [PreserveSig] int SetVideoSourceRect(IntPtr rect);
    [PreserveSig] int GetVideoSourceRect(IntPtr rect);
    [PreserveSig] int SetAspectRatioMode(int mode);
    [PreserveSig] int GetAspectRatioMode(out int mode);
    [PreserveSig] int GetVideoWindow(out IntPtr hwnd);
    [PreserveSig] int UpdateVideo();
    [PreserveSig] int SetBorderColor(int color);
    [PreserveSig] int GetBorderColor(out int color);
    [PreserveSig] int InsertEffect(IntPtr effect, int optional);
    [PreserveSig] int RemoveEffect(IntPtr effect);
    [PreserveSig] int RemoveAllEffects();
    [PreserveSig] int Shutdown();
}


public static class NativeMfAudioEngine
{
    [DllImport("mfplay.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int MFPCreateMediaPlayer(
        string url,
        [MarshalAs(UnmanagedType.Bool)] bool startPlayback,
        int options,
        IntPtr callback,
        IntPtr hwnd,
        out IMFPMediaPlayer player);

    private static IMFPMediaPlayer player;
    private static Guid timeFormat = Guid.Empty;
    private static int volumePercent = 100;

    private static void Check(int hr, string operation)
    {
        if (hr < 0) throw new COMException(operation + " failed: 0x" + hr.ToString("X8"), hr);
    }

    public static void Open(string path)
    {
        Close();
        IMFPMediaPlayer created = null;
        Check(MFPCreateMediaPlayer(path, true, 0, IntPtr.Zero, IntPtr.Zero, out created), "MFPCreateMediaPlayer");
        player = created;
        try { player.SetVolume(volumePercent / 100.0f); } catch { }
    }

    public static void Play()  { if (player != null) Check(player.Play(), "Play"); }
    public static void Pause() { if (player != null) Check(player.Pause(), "Pause"); }
    public static void Stop()  { if (player != null) Check(player.Stop(), "Stop"); }

    public static void Close()
    {
        if (player != null)
        {
            try { player.Stop(); } catch { }
            try { player.Shutdown(); } catch { }
            try { if (Marshal.IsComObject(player)) Marshal.ReleaseComObject(player); } catch { }
            player = null;
        }
    }

    private static long ReadTicks(bool duration)
    {
        if (player == null) return 0;
        IntPtr pv = Marshal.AllocCoTaskMem(24);
        try
        {
            for (int i = 0; i < 24; i++) Marshal.WriteByte(pv, i, 0);
            int hr = duration ? player.GetDuration(ref timeFormat, pv) : player.GetPosition(ref timeFormat, pv);
            if (hr < 0) return 0;
            short vt = Marshal.ReadInt16(pv, 0);
            if (vt != 20 && vt != 21) return 0; // VT_I8 / VT_UI8
            return Marshal.ReadInt64(pv, 8);
        }
        finally { Marshal.FreeCoTaskMem(pv); }
    }

    public static long GetDurationMilliseconds() { return ReadTicks(true) / TimeSpan.TicksPerMillisecond; }
    public static long GetPositionMilliseconds() { return ReadTicks(false) / TimeSpan.TicksPerMillisecond; }

    public static void SetPositionMilliseconds(long milliseconds)
    {
        if (player == null) return;
        long duration = GetDurationMilliseconds();
        if (duration > 0) milliseconds = Math.Max(0, Math.Min(milliseconds, duration));
        else milliseconds = Math.Max(0, milliseconds);
        IntPtr pv = Marshal.AllocCoTaskMem(24);
        try
        {
            for (int i = 0; i < 24; i++) Marshal.WriteByte(pv, i, 0);
            Marshal.WriteInt16(pv, 0, 20); // VT_I8
            Marshal.WriteInt64(pv, 8, checked(milliseconds * TimeSpan.TicksPerMillisecond));
            Check(player.SetPosition(ref timeFormat, pv), "SetPosition");
        }
        finally { Marshal.FreeCoTaskMem(pv); }
    }

    // Remembers the volume so every newly opened track gets it. Returns false if the
    // player rejected the value (for example while a media item is still loading).
    public static bool SetVolume(int percent)
    {
        volumePercent = Math.Max(0, Math.Min(100, percent));
        if (player == null) return true;
        try { return player.SetVolume(volumePercent / 100.0f) >= 0; }
        catch { return false; }
    }

    // MFPlay states: EMPTY=0, STOPPED=1, PLAYING=2, PAUSED=3, SHUTDOWN=4.
    public static int GetState()
    {
        if (player == null) return 0;
        int state;
        Check(player.GetState(out state), "GetState");
        return state;
    }
}

public class NativeMfPlayer
{
    [DllImport("mfplay.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int MFPCreateMediaPlayer(
        string url,
        [MarshalAs(UnmanagedType.Bool)] bool startPlayback,
        int options,
        IntPtr callback,
        IntPtr hwnd,
        out IMFPMediaPlayer player
    );

    private IMFPMediaPlayer player;
    private Form window;
    private Panel video;
    private TrackBar seek;
    private TrackBar volume;
    private Button playBtn;
    private Label currentTime;
    private Label totalTime;
    private Label status;
    private Timer timer;

    private long durationTicks;
    private bool seeking;
    private bool muted;
    private bool fullscreen;
    private bool isPlaying = true;
    private bool hasPlayed;
    private DateTime openedAt = DateTime.UtcNow;
    private bool loadWarned;

    private FormBorderStyle previousBorder;
    private FormWindowState previousState;
    private Rectangle previousBounds;

    private static Guid TimeFormat = Guid.Empty;

    private const string PlayText = "\u25B6  PLAY";
    private const string PauseText = "\u2161  PAUSE";
    private const string StopText = "\u25A0  STOP";

    private void Check(int hr, string operation)
    {
        if (hr < 0)
            throw new COMException(operation + " failed: 0x" + hr.ToString("X8"), hr);
    }

    private Button MakeButton(string text, int width)
    {
        Button b = new Button();
        b.Text = text;
        b.Width = width;
        b.Height = 42;
        b.Margin = new Padding(4);
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderColor = Color.FromArgb(90, 90, 90);
        b.FlatAppearance.BorderSize = 1;
        b.BackColor = Color.FromArgb(55, 55, 55);
        b.ForeColor = Color.White;
        b.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        b.Cursor = Cursors.Hand;
        b.TabStop = false;   // keep keyboard shortcuts working on the form
        return b;
    }

    private long ReadTime(bool readDuration)
    {
        if (player == null)
            return 0;

        IntPtr pv = Marshal.AllocCoTaskMem(24);

        try
        {
            for (int i = 0; i < 24; i++)
                Marshal.WriteByte(pv, i, 0);

            int hr = readDuration
                ? player.GetDuration(ref TimeFormat, pv)
                : player.GetPosition(ref TimeFormat, pv);

            if (hr < 0)
                return 0;

            // Position is VT_I8 (20), duration is VT_UI8 (21); value is at offset 8.
            short vt = Marshal.ReadInt16(pv, 0);

            if (vt != 20 && vt != 21)
                return 0;

            return Marshal.ReadInt64(pv, 8);
        }
        finally
        {
            Marshal.FreeCoTaskMem(pv);
        }
    }

    private void SetPosition(long ticks)
    {
        if (player == null || durationTicks <= 0)
            return;

        ticks = Math.Max(0, Math.Min(ticks, durationTicks));

        IntPtr pv = Marshal.AllocCoTaskMem(24);

        try
        {
            for (int i = 0; i < 24; i++)
                Marshal.WriteByte(pv, i, 0);

            Marshal.WriteInt16(pv, 0, 20);
            Marshal.WriteInt64(pv, 8, ticks);

            Check(player.SetPosition(ref TimeFormat, pv), "SetPosition");
        }
        finally
        {
            Marshal.FreeCoTaskMem(pv);
        }
    }

    private string FormatTime(long ticks)
    {
        if (ticks < 0)
            ticks = 0;

        TimeSpan t = TimeSpan.FromTicks(ticks);

        if (t.TotalHours >= 1)
            return t.ToString(@"h\:mm\:ss");

        return t.ToString(@"mm\:ss");
    }

    private void Skip(long seconds)
    {
        if (player == null)
            return;

        if (durationTicks <= 0)
            durationTicks = ReadTime(true);

        if (durationTicks <= 0)
        {
            status.Text = "Seeking unavailable: duration not ready";
            return;
        }

        long current = ReadTime(false);
        long target = current + seconds * TimeSpan.TicksPerSecond;
        SetPosition(target);
        currentTime.Text = FormatTime(Math.Max(0, Math.Min(target, durationTicks)));
        status.Text = seconds < 0 ? "Skipped back 10 seconds" : "Skipped forward 10 seconds";
    }

    private void RunControl(Action action)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            if (status != null)
                status.Text = ex.Message;
        }
    }

    private void TogglePlayback()
    {
        if (player == null)
            return;

        if (isPlaying)
        {
            Check(player.Pause(), "Pause");
            isPlaying = false;
            playBtn.Text = PlayText;
            status.Text = "Paused";
        }
        else
        {
            Check(player.Play(), "Play");
            isPlaying = true;
            hasPlayed = false;
            playBtn.Text = PauseText;
            status.Text = "Playing";
        }
    }

    private void SeekFromSlider()
    {
        if (player == null)
            return;

        if (durationTicks <= 0)
            durationTicks = ReadTime(true);

        if (durationTicks <= 0)
        {
            status.Text = "Seeking unavailable: duration not ready";
            return;
        }

        long target = (long)(durationTicks * (seek.Value / 1000.0));
        SetPosition(target);
        currentTime.Text = FormatTime(target);
    }

    private void ToggleFullscreen()
    {
        if (!fullscreen)
        {
            previousBorder = window.FormBorderStyle;
            previousState = window.WindowState;
            previousBounds = window.Bounds;

            window.FormBorderStyle = FormBorderStyle.None;
            window.WindowState = FormWindowState.Normal;
            window.Bounds = Screen.FromControl(window).Bounds;

            fullscreen = true;
        }
        else
        {
            window.FormBorderStyle = previousBorder;
            window.WindowState = previousState;

            if (previousState == FormWindowState.Normal)
                window.Bounds = previousBounds;

            fullscreen = false;
        }

        video.Focus();
    }

    private void RefreshPosition()
    {
        if (player == null)
            return;

        try
        {
            long position = ReadTime(false);

            if (durationTicks <= 0)
            {
                durationTicks = ReadTime(true);

                if (durationTicks > 0)
                    totalTime.Text = FormatTime(durationTicks);
            }

            if (!seeking && durationTicks > 0)
            {
                int value = (int)Math.Min(1000, Math.Max(0, position * 1000.0 / durationTicks));
                seek.Value = value;
            }

            currentTime.Text = FormatTime(position);

            if (!hasPlayed && !loadWarned && durationTicks <= 0 && (DateTime.UtcNow - openedAt).TotalSeconds > 8)
            {
                loadWarned = true;
                status.Text = "Unable to play this file - a compatible codec may be required.";
            }

            // Detect end of playback (state STOPPED after having been PLAYING).
            int st;
            if (player.GetState(out st) >= 0)
            {
                if (st == 2) hasPlayed = true;
                else if (st == 1 && hasPlayed && isPlaying)
                {
                    isPlaying = false;
                    hasPlayed = false;
                    playBtn.Text = PlayText;
                    status.Text = "Finished";
                }
            }

            player.UpdateVideo();
        }
        catch
        {
            // A transient media state should not terminate the UI.
        }
    }

    public void Run(string path)
    {
        Application.EnableVisualStyles();

        window = new Form();
        window.Text = Path.GetFileName(path);
        window.Width = 1100;
        window.Height = 740;
        window.MinimumSize = new Size(650, 450);
        window.StartPosition = FormStartPosition.CenterScreen;
        window.BackColor = Color.Black;
        window.KeyPreview = true;

        // Video surface.
        video = new Panel();
        video.Dock = DockStyle.Fill;
        video.BackColor = Color.Black;
        video.TabStop = true;

        // MFPlay needs UpdateVideo on paint/resize to redraw the frame.
        video.Resize += delegate { try { if (player != null) player.UpdateVideo(); } catch { } };
        video.Paint += delegate { try { if (player != null) player.UpdateVideo(); } catch { } };

        // Bottom controls.
        Panel bottom = new Panel();
        bottom.Dock = DockStyle.Bottom;
        bottom.Height = 120;
        bottom.BackColor = Color.FromArgb(28, 28, 28);

        // Seek row.
        TableLayoutPanel seekRow = new TableLayoutPanel();
        seekRow.Dock = DockStyle.Top;
        seekRow.Height = 43;
        seekRow.ColumnCount = 3;
        seekRow.RowCount = 1;
        seekRow.Padding = new Padding(8, 0, 8, 0);

        seekRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 65));
        seekRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        seekRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 65));

        currentTime = new Label();
        currentTime.Text = "00:00";
        currentTime.ForeColor = Color.White;
        currentTime.TextAlign = ContentAlignment.MiddleCenter;
        currentTime.Dock = DockStyle.Fill;

        totalTime = new Label();
        totalTime.Text = "00:00";
        totalTime.ForeColor = Color.White;
        totalTime.TextAlign = ContentAlignment.MiddleCenter;
        totalTime.Dock = DockStyle.Fill;

        seek = new TrackBar();
        seek.Minimum = 0;
        seek.Maximum = 1000;
        seek.Value = 0;
        seek.TickStyle = TickStyle.None;
        seek.Dock = DockStyle.Fill;
        seek.Height = 38;
        seek.TabStop = false;
        seek.BackColor = Color.FromArgb(28, 28, 28);

        seekRow.Controls.Add(currentTime, 0, 0);
        seekRow.Controls.Add(seek, 1, 0);
        seekRow.Controls.Add(totalTime, 2, 0);

        // Main control row.
        FlowLayoutPanel controls = new FlowLayoutPanel();
        controls.Dock = DockStyle.Fill;
        controls.Padding = new Padding(10, 4, 10, 4);
        controls.WrapContents = false;
        controls.BackColor = Color.FromArgb(28, 28, 28);

        Button back = MakeButton("<< 10s", 85);
        playBtn = MakeButton(PauseText, 115);
        Button stop = MakeButton(StopText, 95);
        Button forward = MakeButton("10s >>", 85);
        Button mute = MakeButton("MUTE", 85);
        Button full = MakeButton("FULLSCREEN", 125);

        playBtn.BackColor = Color.FromArgb(55, 85, 145);
        stop.BackColor = Color.FromArgb(145, 45, 45);

        Label volumeText = new Label();
        volumeText.Text = "VOLUME";
        volumeText.ForeColor = Color.White;
        volumeText.AutoSize = true;
        volumeText.Padding = new Padding(8, 14, 0, 0);

        volume = new TrackBar();
        volume.Minimum = 0;
        volume.Maximum = 100;
        volume.Value = 100;
        volume.TickFrequency = 20;
        volume.TickStyle = TickStyle.None;
        volume.Width = 110;
        volume.Height = 42;
        volume.TabStop = false;
        volume.BackColor = Color.FromArgb(28, 28, 28);

        status = new Label();
        status.Text = "Ready";
        status.ForeColor = Color.LightGray;
        status.AutoSize = true;
        status.Padding = new Padding(8, 14, 0, 0);

        controls.Controls.Add(back);
        controls.Controls.Add(playBtn);
        controls.Controls.Add(stop);
        controls.Controls.Add(forward);
        controls.Controls.Add(volumeText);
        controls.Controls.Add(volume);
        controls.Controls.Add(mute);
        controls.Controls.Add(full);
        controls.Controls.Add(status);

        bottom.Controls.Add(controls);
        bottom.Controls.Add(seekRow);

        window.Controls.Add(video);
        window.Controls.Add(bottom);
        bottom.BringToFront();

        // Playback actions.
        playBtn.Click += delegate
        {
            RunControl(delegate { TogglePlayback(); });
            video.Focus();
        };

        stop.Click += delegate
        {
            RunControl(delegate
            {
                if (player != null)
                {
                    Check(player.Stop(), "Stop");
                    isPlaying = false;
                    hasPlayed = false;
                    playBtn.Text = PlayText;
                    status.Text = "Stopped";
                    currentTime.Text = "00:00";
                    seek.Value = 0;
                }
            });
            video.Focus();
        };

        back.Click += delegate { RunControl(delegate { Skip(-10); }); video.Focus(); };
        forward.Click += delegate { RunControl(delegate { Skip(10); }); video.Focus(); };

        mute.Click += delegate
        {
            RunControl(delegate
            {
                if (player == null)
                    return;

                muted = !muted;
                Check(player.SetMute(muted ? 1 : 0), "SetMute");
                mute.Text = muted ? "UNMUTE" : "MUTE";
            });
            video.Focus();
        };

        full.Click += delegate { RunControl(delegate { ToggleFullscreen(); }); };

        volume.ValueChanged += delegate
        {
            RunControl(delegate
            {
                if (player != null)
                {
                    Check(player.SetVolume(volume.Value / 100.0f), "SetVolume");

                    if (muted && volume.Value > 0)
                    {
                        muted = false;
                        player.SetMute(0);
                        mute.Text = "MUTE";
                    }
                }
            });
        };
        volume.MouseUp += delegate { video.Focus(); };

        // Seek handling: preview while dragging, perform one seek on release.
        seek.MouseDown += delegate { seeking = true; };

        seek.Scroll += delegate
        {
            if (durationTicks <= 0)
                durationTicks = ReadTime(true);

            if (durationTicks > 0)
            {
                long preview = (long)(durationTicks * (seek.Value / 1000.0));
                currentTime.Text = FormatTime(preview);
            }
        };

        seek.MouseUp += delegate
        {
            RunControl(delegate { SeekFromSlider(); });
            seeking = false;
            video.Focus();
        };

        // Keyboard shortcuts.
        window.KeyDown += delegate(object sender, KeyEventArgs e)
        {
            bool handled = true;

            if (e.KeyCode == Keys.Space) RunControl(delegate { TogglePlayback(); });
            else if (e.KeyCode == Keys.Left) RunControl(delegate { Skip(-10); });
            else if (e.KeyCode == Keys.Right) RunControl(delegate { Skip(10); });
            else if (e.KeyCode == Keys.F) RunControl(delegate { ToggleFullscreen(); });
            else if (e.KeyCode == Keys.M) mute.PerformClick();
            else if (e.KeyCode == Keys.Escape && fullscreen) RunControl(delegate { ToggleFullscreen(); });
            else if (e.KeyCode == Keys.Up) volume.Value = Math.Min(100, volume.Value + 5);
            else if (e.KeyCode == Keys.Down) volume.Value = Math.Max(0, volume.Value - 5);
            else handled = false;

            if (handled)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
            }
        };

        // Playback initialization.
        window.Shown += delegate
        {
            try
            {
                status.Text = "Opening media...";

                int hr = MFPCreateMediaPlayer(path, true, 0, IntPtr.Zero, video.Handle, out player);
                Check(hr, "MFPCreateMediaPlayer");

                try { player.SetVolume(1.0f); } catch { }

                isPlaying = true;
                playBtn.Text = PauseText;
                status.Text = "Playing";

                durationTicks = ReadTime(true);

                if (durationTicks > 0)
                    totalTime.Text = FormatTime(durationTicks);

                timer = new Timer();
                timer.Interval = 500;
                timer.Tick += delegate { RefreshPosition(); };

                timer.Start();
                video.Focus();
            }
            catch (Exception ex)
            {
                status.Text = "Playback error";

                MessageBox.Show(
                    ex.Message,
                    "Media Foundation Error",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }
        };

        window.FormClosing += delegate
        {
            if (timer != null)
            {
                timer.Stop();
                timer.Dispose();
                timer = null;
            }

            if (player != null)
            {
                try { player.Stop(); } catch { }
                try { player.Shutdown(); } catch { }
                try { Marshal.ReleaseComObject(player); } catch { }
                player = null;
            }
        };

        Application.Run(window);
    }

    public static void Start(string path)
    {
        new NativeMfPlayer().Run(path);
    }
}



public static class WavFloatConverter {
    private static readonly byte[] IeeeFloatSubFormat = new byte[] {
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    };

    private static bool CopyFrom(string inputPath, long start, string outputPath) {
        bool created = false;
        try {
            using (FileStream input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (FileStream output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                created = true;
                input.Position = start;
                byte[] buf = new byte[65536];
                int n;
                while ((n = input.Read(buf, 0, buf.Length)) > 0) output.Write(buf, 0, n);
            }
            return true;
        } catch {
            if (created) { try { File.Delete(outputPath); } catch { } }
            return false;
        }
    }

    private static bool IsValidWavAt(FileStream fs, long offset) {
        long len = fs.Length;
        if (offset < 0 || offset + 12 > len) return false;
        byte[] h = new byte[12];
        fs.Position = offset;
        if (fs.Read(h, 0, 12) != 12) return false;
        if (Encoding.ASCII.GetString(h, 0, 4) != "RIFF" || Encoding.ASCII.GetString(h, 8, 4) != "WAVE") return false;
        long end = offset + 8L + BitConverter.ToUInt32(h, 4);
        if (end > len || end <= offset + 12) return false;
        long pos = offset + 12;
        bool hasFmt = false, hasData = false;
        byte[] ch = new byte[8];
        while (pos + 8 <= end) {
            fs.Position = pos;
            if (fs.Read(ch, 0, 8) != 8) return false;
            string id = Encoding.ASCII.GetString(ch, 0, 4);
            long size = BitConverter.ToUInt32(ch, 4);
            long next = pos + 8 + size + (size & 1L);
            if (pos + 8 + size > end || next > end) return false;
            if (id == "fmt ") { if (size < 16) return false; hasFmt = true; }
            else if (id == "data") { if (size <= 0) return false; hasData = true; }
            pos = next;
        }
        return pos == end && hasFmt && hasData;
    }

    // Offset of a valid RIFF/WAVE container, or 0 when the file starts with RIFF already.
    private static long FindWavStart(string path) {
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
            long length = fs.Length;
            byte[] head = new byte[12];
            fs.Position = 0;
            int got = fs.Read(head, 0, 12);
            if (got == 12 && head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46) return 0;
            const int Chunk = 65536;
            byte[] buf = new byte[Chunk];
            long pos = 0;
            while (pos < length) {
                fs.Position = pos;
                int read = 0;
                while (read < Chunk) { int c = fs.Read(buf, read, Chunk - read); if (c <= 0) break; read += c; }
                if (read < 12) break;
                for (int i = 0; i + 12 <= read; i++) {
                    if (buf[i] == 0x52 && buf[i + 1] == 0x49 && buf[i + 2] == 0x46 && buf[i + 3] == 0x46 &&
                        buf[i + 8] == 0x57 && buf[i + 9] == 0x41 && buf[i + 10] == 0x56 && buf[i + 11] == 0x45) {
                        if (IsValidWavAt(fs, pos + i)) return pos + i;
                    }
                }
                if (pos + read >= length) break;
                pos += read - 11;
            }
        }
        return 0;
    }

    private static readonly int[][] Mp3Rates = new int[][] {
        new int[] { 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448 },
        new int[] { 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384 },
        new int[] { 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 },
        new int[] { 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256 },
        new int[] { 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 }
    };

    // Frame length (>0) of the MPEG audio header at p, or 0 if it is not a valid header.
    private static int MpegFrame(byte[] b, int p, out int ver, out int layer, out int rate) {
        ver = 0; layer = 0; rate = 0;
        if (p < 0 || p + 4 > b.Length) return 0;
        if (b[p] != 0xFF || (b[p + 1] & 0xE0) != 0xE0) return 0;
        int verBits = (b[p + 1] >> 3) & 3;
        int layerBits = (b[p + 1] >> 1) & 3;
        int br = (b[p + 2] >> 4) & 15;
        int sr = (b[p + 2] >> 2) & 3;
        int pad = (b[p + 2] >> 1) & 1;
        if (verBits == 1 || layerBits == 0 || br == 0 || br == 15 || sr == 3) return 0;
        bool mpeg1 = verBits == 3;
        int table;
        if (layerBits == 3) table = mpeg1 ? 0 : 3;
        else if (layerBits == 2) table = mpeg1 ? 1 : 4;
        else table = mpeg1 ? 2 : 4;
        int bitrate = Mp3Rates[table][br - 1] * 1000;
        int[] rates = verBits == 3 ? new int[] { 44100, 48000, 32000 }
                    : verBits == 2 ? new int[] { 22050, 24000, 16000 }
                    : new int[] { 11025, 12000, 8000 };
        int sampleRate = rates[sr];
        int len;
        if (layerBits == 3) len = (12 * bitrate / sampleRate + pad) * 4;
        else { int coef = (layerBits == 1 && !mpeg1) ? 72 : 144; len = coef * bitrate / sampleRate + pad; }
        if (len < 4) return 0;
        ver = verBits; layer = layerBits; rate = sampleRate;
        return len;
    }

    private static long Id3End(FileStream fs) {
        long len = fs.Length, off = 0;
        byte[] h = new byte[10];
        while (off + 10 <= len) {
            fs.Position = off;
            if (fs.Read(h, 0, 10) != 10) break;
            if (h[0] != 0x49 || h[1] != 0x44 || h[2] != 0x33) break;
            if (h[3] < 2 || h[3] > 4) break;
            if (((h[6] | h[7] | h[8] | h[9]) & 0x80) != 0) break;
            long size = ((long)h[6] << 21) | ((long)h[7] << 14) | ((long)h[8] << 7) | (long)h[9];
            long end = off + 10 + size + ((h[3] == 4 && (h[5] & 0x10) != 0) ? 10 : 0);
            if (end > len || end <= off) break;
            off = end;
        }
        return off;
    }

    
    
    private static long FindMp3JunkStart(string path) {
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
            long length = fs.Length;
            long id3 = Id3End(fs);
            if (id3 >= length) return 0;
            const int Chunk = 262144;
            const int Overlap = 8192;
            byte[] buf = new byte[Chunk];
            long pos = id3;
            while (pos < length) {
                fs.Position = pos;
                int read = 0;
                while (read < Chunk) { int c = fs.Read(buf, read, Chunk - read); if (c <= 0) break; read += c; }
                if (read < 4) break;
                bool last = pos + read >= length;
                int lastCand = last ? read - 4 : read - Overlap - 1;
                for (int i = 0; i <= lastCand; i++) {
                    if (buf[i] != 0xFF) continue;
                    int v1, l1, r1, v2, l2, r2, v3, l3, r3;
                    int n1 = MpegFrame(buf, i, out v1, out l1, out r1);
                    if (n1 == 0) continue;
                    int n2 = MpegFrame(buf, i + n1, out v2, out l2, out r2);
                    if (n2 == 0 || v2 != v1 || l2 != l1 || r2 != r1) continue;
                    int n3 = MpegFrame(buf, i + n1 + n2, out v3, out l3, out r3);
                    if (n3 == 0 || v3 != v1 || l3 != l1 || r3 != r1) continue;
                    long found = pos + i;
                    return found == id3 ? 0 : found;
                }
                if (last) break;
                int adv = read - Overlap;
                if (adv <= 0) break;
                pos += adv;
            }
        }
        return 0;
    }

    // Writes a fixed temporary copy and returns true when the file needs one:
    // IEEE-float WAV -> PCM16, or leading junk bytes before WAV/MP3 data.
    // Returns false when the original can be played as-is. Originals are never modified.
    public static bool TryPrepare(string inputPath, string outputPath, bool isWav) {
        try {
            if (isWav) {
                //if (TryConvertFile(inputPath, outputPath)) return true;
                long start = FindWavStart(inputPath);
                if (start > 0) return CopyFrom(inputPath, start, outputPath);
                return false;
            }
            long mp3 = FindMp3JunkStart(inputPath);
            if (mp3 > 0) return CopyFrom(inputPath, mp3, outputPath);
            return false;
        } catch {
            return false;
        }
    }

    // Entry point: converts when the file (or a RIFF/WAVE container hidden behind
    // leading junk bytes) is IEEE-float. Ordinary PCM files return false quickly,
    // because a valid RIFF/WAVE header at offset 0 is never scanned past.
    

    // Decodes IEEE-float WAV data directly to signed 16-bit PCM in memory.
    // Returns false for non-float WAVs or layouts not handled by waveOut.
    public static bool TryDecodeToPcm(string inputPath, out byte[] pcm, out int channels, out int sampleRate) {
        pcm = null; channels = 0; sampleRate = 0;
        try {
            long startOffset = FindWavStart(inputPath);
            using (FileStream input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (BinaryReader reader = new BinaryReader(input)) {
                if (startOffset < 0 || startOffset + 12 > input.Length) return false;
                input.Position = startOffset;
                byte[] riff = reader.ReadBytes(12);
                if (riff.Length != 12 || Encoding.ASCII.GetString(riff, 0, 4) != "RIFF" ||
                    Encoding.ASCII.GetString(riff, 8, 4) != "WAVE") return false;

                long containerEnd = startOffset + 8L + BitConverter.ToUInt32(riff, 4);
                if (containerEnd > input.Length || containerEnd < startOffset + 12) return false;

                byte[] format = null;
                long dataOffset = -1, dataSize = -1;
                long position = startOffset + 12;
                while (position + 8 <= containerEnd) {
                    input.Position = position;
                    byte[] chunkHeader = reader.ReadBytes(8);
                    if (chunkHeader.Length != 8) return false;
                    string chunkId = Encoding.ASCII.GetString(chunkHeader, 0, 4);
                    long chunkSize = BitConverter.ToUInt32(chunkHeader, 4);
                    long chunkData = position + 8;
                    long chunkEnd = chunkData + chunkSize;
                    long nextChunk = chunkEnd + (chunkSize & 1L);
                    if (chunkEnd > containerEnd || nextChunk > containerEnd) return false;

                    if (chunkId == "fmt " && format == null) {
                        if (chunkSize < 16) return false;
                        input.Position = chunkData;
                        format = reader.ReadBytes((int)Math.Min(chunkSize, 40L));
                        if (format.Length < 16) return false;
                    } else if (chunkId == "data" && dataOffset < 0) {
                        dataOffset = chunkData;
                        dataSize = chunkSize;
                    }
                    position = nextChunk;
                }

                if (position != containerEnd || format == null || dataOffset < 0 || dataSize <= 0) return false;

                ushort formatTag = BitConverter.ToUInt16(format, 0);
                int ch = BitConverter.ToUInt16(format, 2);
                uint hz = BitConverter.ToUInt32(format, 4);
                uint byteRate = BitConverter.ToUInt32(format, 8);
                ushort blockAlign = BitConverter.ToUInt16(format, 12);
                ushort bits = BitConverter.ToUInt16(format, 14);
                bool isFloat = formatTag == 3;

                if (formatTag == 0xFFFE) {
                    if (format.Length < 40 || BitConverter.ToUInt16(format, 16) < 22 ||
                        BitConverter.ToUInt16(format, 18) != bits) return false;
                    isFloat = true;
                    for (int i = 0; i < 16; i++) {
                        if (format[24 + i] != IeeeFloatSubFormat[i]) { isFloat = false; break; }
                    }
                }
                if (!isFloat || ch < 1 || ch > 2 || hz < 1 || hz > 768000 ||
                    (bits != 32 && bits != 64)) return false;

                int bytesPerSample = bits / 8;
                int expectedBlockAlign = ch * bytesPerSample;
                if (blockAlign != expectedBlockAlign || dataSize % blockAlign != 0 ||
                    byteRate != (long)hz * blockAlign) return false;

                long outputLength = (dataSize / bytesPerSample) * 2L;
                if (outputLength <= 0 || outputLength > Int32.MaxValue) return false;
                byte[] converted = new byte[(int)outputLength];
                byte[] buffer = new byte[65536 - (65536 % bytesPerSample)];
                input.Position = dataOffset;
                long remaining = dataSize;
                int outputOffset = 0;

                while (remaining > 0) {
                    int wanted = (int)Math.Min(buffer.Length, remaining);
                    wanted -= wanted % bytesPerSample;
                    if (wanted <= 0) return false;
                    int read = 0;
                    while (read < wanted) {
                        int count = input.Read(buffer, read, wanted - read);
                        if (count <= 0) return false;
                        read += count;
                    }

                    for (int i = 0; i < read; i += bytesPerSample) {
                        double sample = bits == 32
                            ? (double)BitConverter.ToSingle(buffer, i)
                            : BitConverter.ToDouble(buffer, i);
                        short pcmSample;
                        if (Double.IsNaN(sample) || Double.IsInfinity(sample)) pcmSample = 0;
                        else if (sample >= 1.0) pcmSample = Int16.MaxValue;
                        else if (sample <= -1.0) pcmSample = Int16.MinValue;
                        else pcmSample = (short)Math.Round(sample < 0 ? sample * 32768.0 : sample * 32767.0);
                        ushort sampleBits = unchecked((ushort)pcmSample);
                        converted[outputOffset++] = (byte)(sampleBits & 0xFF);
                        converted[outputOffset++] = (byte)(sampleBits >> 8);
                    }
                    remaining -= read;
                }

                pcm = converted;
                channels = ch;
                sampleRate = (int)hz;
                return true;
            }
        } catch {
            pcm = null; channels = 0; sampleRate = 0;
            return false;
        }
    }
	
}
// ---- Managed audio decoders --------------------------
public static class AudioDecoders
{
    // AIFF decoding returns 16-bit PCM in memory.
    public static string DecodeAiff(string inPath, out byte[] pcm, out int channels, out int sampleRate)
    {
        try { return AiffDecoder.Decode(inPath, out pcm, out channels, out sampleRate); }
        catch (Exception ex) { pcm = null; channels = 0; sampleRate = 0; return ex.Message; }
    }

}

// Direct PCM playback for OGG Vorbis, supported AIFF/AIFF-C files, and IEEE-float WAVs.
// Audio is decoded or converted in memory and submitted to Windows waveOut.
public static class DirectPcmAudioEngine
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    private struct WaveFormat { public ushort wFormatTag, nChannels; public uint nSamplesPerSec, nAvgBytesPerSec; public ushort nBlockAlign, wBitsPerSample, cbSize; }
    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHeader { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded; public UIntPtr dwUser; public uint dwFlags, dwLoops; public IntPtr lpNext; public UIntPtr reserved; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MmTime { public uint wType; public uint u; public uint u2; }
    [DllImport("winmm.dll")] private static extern uint waveOutOpen(out IntPtr h, uint device, ref WaveFormat fmt, IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveOutPrepareHeader(IntPtr h, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveOutUnprepareHeader(IntPtr h, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveOutWrite(IntPtr h, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveOutPause(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveOutRestart(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveOutReset(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveOutClose(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveOutGetPosition(IntPtr h, ref MmTime time, uint size);
    [DllImport("winmm.dll")] private static extern uint waveOutSetVolume(IntPtr h, uint volume);
    private static IntPtr device = IntPtr.Zero, headerPtr = IntPtr.Zero;
    private static GCHandle pcmPin;
    private static byte[] pcm;
    private static int channels, rate, blockAlign, startByte;
    private static bool opened, paused;
    private static readonly int HeaderSize = Marshal.SizeOf(typeof(WaveHeader));
    private static void Check(uint result, string operation) { if (result != 0) throw new InvalidOperationException(operation + " failed (MMRESULT " + result + ")"); }
    private static void Submit(int byteOffset)
    {
        startByte = Math.Max(0, Math.Min(byteOffset, pcm.Length)); startByte -= startByte % blockAlign;
        WaveHeader wh = new WaveHeader(); wh.lpData = IntPtr.Add(pcmPin.AddrOfPinnedObject(), startByte); wh.dwBufferLength = (uint)(pcm.Length - startByte);
        Marshal.StructureToPtr(wh, headerPtr, false);
        Check(waveOutPrepareHeader(device, headerPtr, (uint)HeaderSize), "waveOutPrepareHeader");
        Check(waveOutWrite(device, headerPtr, (uint)HeaderSize), "waveOutWrite"); paused = false;
    }
    private static void OpenPcm(byte[] data, int ch, int hz)
    {
        Close();
        if (data == null || data.Length == 0) throw new InvalidOperationException("Decoder returned no PCM samples");
        if (ch < 1 || ch > 2 || hz < 1) throw new InvalidOperationException("Unsupported PCM channel count or sample rate");
        pcm = data; channels = ch; rate = hz; blockAlign = channels * 2; startByte = 0;
        pcmPin = GCHandle.Alloc(pcm, GCHandleType.Pinned);
        WaveFormat fmt = new WaveFormat(); fmt.wFormatTag = 1; fmt.nChannels = (ushort)channels; fmt.nSamplesPerSec = (uint)rate; fmt.wBitsPerSample = 16; fmt.nBlockAlign = (ushort)blockAlign; fmt.nAvgBytesPerSec = (uint)(rate * blockAlign); fmt.cbSize = 0;
        try { Check(waveOutOpen(out device, 0xFFFFFFFF, ref fmt, IntPtr.Zero, IntPtr.Zero, 0), "waveOutOpen"); opened = true; headerPtr = Marshal.AllocHGlobal(HeaderSize); Submit(0); }
        catch { Close(); throw; }
    }
    public static void Open(string path)
    {
        byte[] data; int ch, hz;
        string error = VorbisDecoder.Decode(path, out data, out ch, out hz);
        if (error != null) throw new InvalidOperationException("Vorbis decoder: " + error);
        OpenPcm(data, ch, hz);
    }
    public static void OpenAiff(string path)
    {
        byte[] data; int ch, hz;
        string error = AudioDecoders.DecodeAiff(path, out data, out ch, out hz);
        if (error != null) throw new InvalidOperationException("AIFF decoder: " + error);
        OpenPcm(data, ch, hz);
    }
    public static bool OpenWavFloat(string path)
    {
        byte[] data; int ch, hz;
        if (!WavFloatConverter.TryDecodeToPcm(path, out data, out ch, out hz)) return false;
        OpenPcm(data, ch, hz);
        return true;
    }
    public static void Play() { if (opened && paused) { Check(waveOutRestart(device), "waveOutRestart"); paused = false; } }
    public static void Pause() { if (opened && !paused) { Check(waveOutPause(device), "waveOutPause"); paused = true; } }
    public static void Stop() { if (opened) { waveOutReset(device); paused = true; } }
    public static void Close()
    {
        if (opened) { try { waveOutReset(device); } catch { } try { waveOutUnprepareHeader(device, headerPtr, (uint)HeaderSize); } catch { } try { waveOutClose(device); } catch { } }
        opened = false; paused = false; device = IntPtr.Zero;
        if (headerPtr != IntPtr.Zero) { Marshal.FreeHGlobal(headerPtr); headerPtr = IntPtr.Zero; }
        if (pcmPin.IsAllocated) pcmPin.Free(); pcm = null;
    }
    public static long GetDurationMilliseconds() { return pcm == null || rate == 0 ? 0 : (long)pcm.Length * 1000L / (rate * blockAlign); }
    public static long GetPositionMilliseconds()
    {
        if (!opened) return 0; MmTime t = new MmTime(); t.wType = 4; Check(waveOutGetPosition(device, ref t, (uint)Marshal.SizeOf(typeof(MmTime))), "waveOutGetPosition");
        long bytes = Math.Min((long)pcm.Length, (long)startByte + t.u); return bytes * 1000L / (rate * blockAlign);
    }
    public static void SetPositionMilliseconds(long ms)
    {
        if (!opened) return; bool wasPaused = paused; long frame = Math.Max(0, Math.Min((long)pcm.Length / blockAlign, ms * rate / 1000L));
        Check(waveOutReset(device), "waveOutReset"); try { waveOutUnprepareHeader(device, headerPtr, (uint)HeaderSize); } catch { }
        if (frame >= (long)pcm.Length / blockAlign) { startByte = pcm.Length; paused = false; return; }
        Submit((int)(frame * blockAlign)); if (wasPaused) Pause();
    }
    public static bool SetVolume(int percent)
    {
        if (!opened) return true; uint v = (uint)(Math.Max(0, Math.Min(100, percent)) * 0xFFFF / 100); uint packed = v | (v << 16); return waveOutSetVolume(device, packed) == 0;
    }
    // Match the MFPlay state values consumed by the existing queue controller.
    public static int GetState() { if (!opened) return 0; if (GetPositionMilliseconds() >= GetDurationMilliseconds()) return 1; if (paused) return 3; return 2; }
}

internal static class AiffDecoder
{
    [StructLayout(LayoutKind.Explicit)] private struct FloatBits { [FieldOffset(0)] public int I; [FieldOffset(0)] public float F; }
    [StructLayout(LayoutKind.Explicit)] private struct DoubleBits { [FieldOffset(0)] public long I; [FieldOffset(0)] public double D; }
    // The AIFF-C spec requires an FVER chunk (version 0xA2805140). An unsupported version is always rejected;
    // set this to true to also reject AIFF-C files that omit FVER (some real-world writers do).
    private const bool RequireFver = false;
    private static float ReadFloat32(byte[] b, int o, bool little)
    {
        uint bits = 0;
        if (little) { for (int j = 3; j >= 0; j--) bits = (bits << 8) | b[o + j]; }
        else { for (int j = 0; j < 4; j++) bits = (bits << 8) | b[o + j]; }
        FloatBits value = new FloatBits(); value.I = unchecked((int)bits); return value.F;
    }
    private static double ReadFloat64(byte[] b, int o, bool little)
    {
        ulong bits = 0;
        if (little) { for (int j = 7; j >= 0; j--) bits = (bits << 8) | b[o + j]; }
        else { for (int j = 0; j < 8; j++) bits = (bits << 8) | b[o + j]; }
        DoubleBits value = new DoubleBits(); value.I = unchecked((long)bits); return value.D;
    }
    private static uint BE32(byte[] b, int o) { return ((uint)b[o] << 24) | ((uint)b[o + 1] << 16) | ((uint)b[o + 2] << 8) | b[o + 3]; }
    private static int BE16(byte[] b, int o) { return (b[o] << 8) | b[o + 1]; }
    private static int LE16(byte[] b, int o) { return b[o] | (b[o + 1] << 8); }
    private static short Clamp16(int v) { return (short)(v < -32768 ? -32768 : (v > 32767 ? 32767 : v)); }
    private static void Put16(byte[] dst, int index, short value)
    {
        dst[index] = (byte)(value & 255); dst[index + 1] = (byte)((value >> 8) & 255);
    }
    private static short DecodeMuLaw(byte value)
    {
        int u = (~value) & 255; int t = ((u & 15) << 3) + 132; t <<= (u >> 4) & 7;
        return (short)(((u & 128) != 0) ? (132 - t) : (t - 132));
    }
    private static short DecodeALaw(byte value)
    {
        int a = value ^ 0x55; int t = (a & 15) << 4; int seg = (a & 0x70) >> 4;
        if (seg == 0) t += 8; else if (seg == 1) t += 0x108; else { t += 0x108; t <<= seg - 1; }
        return (short)(((a & 0x80) != 0) ? t : -t);
    }
    private static readonly int[] ImaStepTable = { 7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767 };
    private static readonly int[] ImaIndexTable = { -1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8 };
    private static int ImaNibble(int nibble, ref int predictor, ref int index)
    {
        int step = ImaStepTable[index]; int diff = step >> 3;
        if ((nibble & 1) != 0) diff += step >> 2;
        if ((nibble & 2) != 0) diff += step >> 1;
        if ((nibble & 4) != 0) diff += step;
        predictor += ((nibble & 8) != 0) ? -diff : diff;
        if (predictor < -32768) predictor = -32768; else if (predictor > 32767) predictor = 32767;
        index += ImaIndexTable[nibble & 15]; if (index < 0) index = 0; else if (index > 88) index = 88;
        return predictor;
    }
    // QuickTime IMA4: every packet is 34 bytes per channel and holds 64 frames. The first two bytes are a
    // big-endian header (9-bit predictor in the top bits, 7-bit step index), followed by 32 bytes of nibbles.
    // QuickTime packs the FIRST sample of each byte in the LOW nibble and the second in the HIGH nibble.
    // Channels are interleaved packet by packet. Truncated data decodes as far as it goes.
    private static string DecodeIma4(byte[] f, int dataOff, int dataLen, int channels, long frames, out byte[] pcm)
    {
        pcm = null;
        const int packetBytes = 34, packetFrames = 64;
        long packetsAvailable = dataLen / ((long)packetBytes * channels);
        if (packetsAvailable < 1) return "truncated AIFF-C ima4 packet data";
        // Apple-written ima4 files store the number of 34-byte PACKETS in COMM; other writers store the number of
        // sample frames. A packet count can never exceed the packets actually present, a sample count always does.
        if (frames <= packetsAvailable) frames *= packetFrames;
        long packetsWanted = (frames + packetFrames - 1) / packetFrames;
        long packetsPerChannel = Math.Min(packetsWanted, packetsAvailable);
        long decodableFrames = Math.Min(frames, packetsPerChannel * packetFrames);
        long outputLength = decodableFrames * channels * 2;
        if (outputLength <= 0 || outputLength > Int32.MaxValue) return "AIFF-C PCM data is empty or too large for in-memory playback";
        pcm = new byte[(int)outputLength];
        int outFrame = 0;
        for (long packet = 0; packet < packetsPerChannel; packet++)
        {
            int thisFrames = (int)Math.Min(packetFrames, decodableFrames - outFrame);
            for (int ch = 0; ch < channels; ch++)
            {
                int packetOffset = dataOff + (int)((packet * channels + ch) * packetBytes);
                int header = BE16(f, packetOffset); int predictor = (short)(header & 0xFF80); int index = header & 0x7F;
                if (index > 88) index = 88;
                for (int j = 0; j < thisFrames; j++)
                {
                    int packed = f[packetOffset + 2 + (j >> 1)];
                    int nibble = ((j & 1) == 0) ? (packed & 15) : (packed >> 4);
                    short sample = (short)ImaNibble(nibble, ref predictor, ref index);
                    Put16(pcm, ((outFrame + j) * channels + ch) * 2, sample);
                }
            }
            outFrame += thisFrames;
        }
        return null;
    }

    public static string Decode(string inPath, out byte[] pcm, out int channels, out int sampleRate)
    {
        pcm = null; channels = 0; sampleRate = 0;
        byte[] f = File.ReadAllBytes(inPath);
        if (f.Length < 12 || Encoding.ASCII.GetString(f, 0, 4) != "FORM") return "not an AIFF/AIFF-C file";
        string form = Encoding.ASCII.GetString(f, 8, 4);
        bool aifc = form == "AIFC";
        if (!aifc && form != "AIFF") return "not an AIFF/AIFF-C file";
        uint formLength = BE32(f, 4);
        if (formLength < 4 || (long)formLength + 8 > f.Length) return "invalid or truncated AIFF FORM length";
        int formEnd = (int)(formLength + 8);
        int bits = 0, dataOff = -1, dataLen = 0;
        long frames = -1; double rate = 0; bool littleEndian = false;
        string compression = "NONE"; bool commFound = false; bool fverFound = false;
        int pos = 12;
        while (pos + 8 <= formEnd)
        {
            string id = Encoding.ASCII.GetString(f, pos, 4);
            uint chunkLength = BE32(f, pos + 4);
            if (chunkLength > Int32.MaxValue) return "AIFF chunk is too large";
            int len = (int)chunkLength; int body = pos + 8;
            if (body > formEnd || len > formEnd - body) return "truncated AIFF chunk";
            if (id == "COMM")
            {
                if (len < (aifc ? 23 : 18)) return "invalid AIFF COMM chunk";
                channels = BE16(f, body); frames = BE32(f, body + 2); bits = BE16(f, body + 6);
                int exp = BE16(f, body + 8); ulong mant = ((ulong)BE32(f, body + 10) << 32) | BE32(f, body + 14);
                if ((exp & 0x7FFF) == 0 || mant == 0) return "invalid AIFF sample rate";
                bool negative = (exp & 0x8000) != 0; int unbiased = (exp & 0x7FFF) - 16383;
                rate = mant * Math.Pow(2.0, unbiased - 63); if (negative) rate = -rate;
                if (aifc)
                {
                    compression = Encoding.ASCII.GetString(f, body + 18, 4);
                    // compressionName is a Pascal string (length byte + text) that must fit inside the chunk.
                    int nameLen = f[body + 22];
                    if (23 + nameLen > len) return "invalid AIFF-C COMM compression name";
                }
                commFound = true;
            }
            else if (id == "FVER")
            {
                if (!aifc) { /* FVER is only defined for AIFF-C; ignore it elsewhere */ }
                else
                {
                    if (len != 4) return "invalid AIFF-C FVER chunk";
                    if (BE32(f, body) != 0xA2805140u) return "unsupported AIFF-C format version";
                    fverFound = true;
                }
            }
            else if (id == "SSND")
            {
                if (len < 8) return "invalid AIFF SSND chunk";
                uint offset = BE32(f, body);
                if (offset > (uint)(len - 8)) return "invalid AIFF sound-data offset";
                dataOff = body + 8 + (int)offset; dataLen = len - 8 - (int)offset;
            }
            long next = (long)body + len + (len & 1);
            if (next > formEnd) return "truncated AIFF chunk padding";
            pos = (int)next;
        }
        if (!commFound || dataOff < 0) return "AIFF is missing COMM or SSND data";
        if (aifc && RequireFver && !fverFound) return "AIFF-C file is missing the required FVER chunk";
        if (channels < 1 || channels > 2 || frames < 1 || rate < 1 || rate > 384000) return "unsupported AIFF layout (requires mono/stereo and a valid sample rate)";
        sampleRate = (int)Math.Round(rate);
        if (sampleRate < 1) return "invalid AIFF sample rate";
        if (compression == "ima4") return DecodeIma4(f, dataOff, dataLen, channels, frames, out pcm);

        // Compression identifiers. Float: fl32/FL32/fl64/FL64 are ALL big-endian (the case only differs by writer).
        bool isFloat = compression == "fl32" || compression == "FL32" || compression == "fl64" || compression == "FL64";
        bool isMuLaw = compression == "ulaw" || compression == "ULAW";
        bool isALaw = compression == "alaw" || compression == "ALAW";
        bool isUnsigned8 = compression == "raw ";            // offset-binary unsigned 8-bit PCM
        bool isIn24 = compression == "in24" || compression == "42ni";   // 24-bit integer PCM (big / little endian)
        bool isIn32 = compression == "in32" || compression == "23ni";   // 32-bit integer PCM (big / little endian)
        bool isIntPcm = compression == "NONE" || compression == "twos" || compression == "sowt" || isUnsigned8 || isIn24 || isIn32;
        // Little-endian integer PCM: sowt, plus the byte-swapped identifiers 42ni (in24) and 23ni (in32).
        if (compression == "sowt" || compression == "42ni" || compression == "23ni") littleEndian = true;
        if (!isIntPcm && !isFloat && !isMuLaw && !isALaw)
            return "AIFF-C compression type '" + compression + "' is not supported";
        if (isMuLaw || isALaw || isUnsigned8) bits = 8;
        if (isIn24) bits = 24;
        if (isIn32) bits = 32;
        if (isFloat) bits = compression.EndsWith("64") ? 64 : 32;
        if (!isFloat && (bits < 1 || bits > 32))
            return "unsupported AIFF sample format (integer PCM: 1-32 bits; float: 32/64-bit)";
        // AIFF stores each sample left-justified in a whole number of bytes, so e.g. 12-bit samples use
        // 2 bytes and 20-bit samples use 3 bytes, with the unused low bits zero.
        int bytesPerSample = (bits + 7) / 8;
        int containerBits = bytesPerSample * 8;
        long availableFrames = dataLen / (long)(bytesPerSample * channels);
        long frameCount = Math.Min(frames, availableFrames);
        long outputBytes = frameCount * channels * 2;
        if (outputBytes <= 0 || outputBytes > Int32.MaxValue) return "AIFF PCM data is empty or too large for in-memory playback";
        pcm = new byte[(int)outputBytes];
        int samples = (int)(frameCount * channels);
        for (int i = 0; i < samples; i++)
        {
            int o = dataOff + i * bytesPerSample; short value;
            if (isMuLaw) value = DecodeMuLaw(f[o]);
            else if (isALaw) value = DecodeALaw(f[o]);
            else if (isFloat)
            {
                double v;
                if (bits == 32) v = ReadFloat32(f, o, false);
                else v = ReadFloat64(f, o, false);
                if (Double.IsNaN(v)) v = 0; else if (v > 1.0) v = 1.0; else if (v < -1.0) v = -1.0;
                value = Clamp16((int)Math.Round(v < 0 ? v * 32768.0 : v * 32767.0));
            }
            else if (isUnsigned8)
            {
                value = Clamp16((f[o] - 128) << 8);
            }
            else
            {
                long raw = 0;
                if (littleEndian) { for (int j = bytesPerSample - 1; j >= 0; j--) raw = (raw << 8) | f[o + j]; }
                else { for (int j = 0; j < bytesPerSample; j++) raw = (raw << 8) | f[o + j]; }
                int shift = 64 - containerBits; long sv = (raw << shift) >> shift;       // sign-extend the whole container
                if (bits < containerBits) sv &= ~((1L << (containerBits - bits)) - 1);   // ignore the padding bits
                if (containerBits > 16) { int down = containerBits - 16; sv = (sv + (1L << (down - 1))) >> down; }   // round to 16-bit
                else sv <<= (16 - containerBits);
                value = Clamp16((int)sv);
            }
            Put16(pcm, i * 2, value);
        }
        return null;
    }
}
internal class VorbisException : Exception
{
    public VorbisException(string m) : base(m) { }
}

internal class VBitReader
{
    private byte[] data; private int pos; private int bit;
    public bool Eop;
    public VBitReader(byte[] d) { data = d; }
    public uint Read(int n)
    {
        uint r = 0; int got = 0;
        while (got < n)
        {
            if (pos >= data.Length) { Eop = true; return r; }
            int take = Math.Min(8 - bit, n - got);
            uint v = ((uint)data[pos] >> bit) & ((1u << take) - 1);
            r |= v << got;
            got += take; bit += take;
            if (bit == 8) { bit = 0; pos++; }
        }
        return r;
    }
}

internal class OggPacketReader
{
    private Stream s; private bool serialSet; private uint serial; private bool finished;
    public long EosGranule = -1;
    private Queue<byte[]> queue = new Queue<byte[]>();
    private MemoryStream partial = new MemoryStream();
    public OggPacketReader(Stream st) { s = st; }

    public byte[] NextPacket()
    {
        while (queue.Count == 0) { if (!ReadPage()) return null; }
        return queue.Dequeue();
    }

    private bool ReadExact(byte[] b, int n)
    {
        int got = 0;
        while (got < n) { int r = s.Read(b, got, n - got); if (r <= 0) return false; got += r; }
        return true;
    }

    private bool ReadPage()
    {
        if (finished) return false;
        // find capture pattern "OggS"
        int state = 0;
        while (state < 4)
        {
            int c = s.ReadByte();
            if (c < 0) return false;
            if (c == "OggS"[state]) state++;
            else state = (c == 'O') ? 1 : 0;
        }
        byte[] h = new byte[23];
        if (!ReadExact(h, 23)) return false;
        int type = h[1];
        uint ser = (uint)(h[10] | h[11] << 8 | h[12] << 16 | h[13] << 24);
        int nseg = h[22];
        byte[] lace = new byte[nseg];
        if (!ReadExact(lace, nseg)) return false;
        int total = 0;
        for (int i = 0; i < nseg; i++) total += lace[i];
        byte[] body = new byte[total];
        if (!ReadExact(body, total)) return false;

        if (!serialSet) { serial = ser; serialSet = true; }
        else if (ser != serial) return true;   // ignore other logical streams

        if ((type & 1) == 0 && partial.Length > 0) partial.SetLength(0);
        int off = 0;
        for (int i = 0; i < nseg; i++)
        {
            partial.Write(body, off, lace[i]);
            off += lace[i];
            if (lace[i] < 255) { queue.Enqueue(partial.ToArray()); partial.SetLength(0); }
        }
        if ((type & 4) != 0)
        {
            finished = true;
            long g = BitConverter.ToInt64(h, 2);
            if (g >= 0) EosGranule = g;
        }
        return true;
    }
}

internal class VCodebook
{
    public int Dim, Entries;
    public float[] Vectors;            // Entries * Dim, null when no lookup table
    private List<int> left = new List<int>(), right = new List<int>();

    private static int Ilog(int x) { int r = 0; while (x > 0) { r++; x >>= 1; } return r; }

    private static float Unpack(uint v)
    {
        double mant = v & 0x1FFFFF;
        int exp = (int)((v & 0x7FE00000) >> 21);
        if ((v & 0x80000000) != 0) mant = -mant;
        return (float)(mant * Math.Pow(2.0, exp - 788));
    }

    public static VCodebook Read(VBitReader br)
    {
        if (br.Read(24) != 0x564342) throw new VorbisException("bad codebook sync");
        VCodebook cb = new VCodebook();
        cb.Dim = (int)br.Read(16);
        cb.Entries = (int)br.Read(24);
        int n = cb.Entries;
        int[] len = new int[n];
        bool ordered = br.Read(1) != 0;
        if (!ordered)
        {
            bool sparse = br.Read(1) != 0;
            for (int i = 0; i < n; i++)
            {
                if (sparse) len[i] = br.Read(1) != 0 ? (int)br.Read(5) + 1 : 0;
                else len[i] = (int)br.Read(5) + 1;
            }
        }
        else
        {
            int cur = 0, curLen = (int)br.Read(5) + 1;
            while (cur < n)
            {
                int num = (int)br.Read(Ilog(n - cur));
                if (cur + num > n) throw new VorbisException("bad codebook lengths");
                for (int i = 0; i < num; i++) len[cur + i] = curLen;
                cur += num; curLen++;
                if (num == 0 && curLen > 33) throw new VorbisException("bad codebook lengths");
            }
        }
        cb.BuildTree(len);

        int lookup = (int)br.Read(4);
        if (lookup == 1 || lookup == 2)
        {
            float minv = Unpack(br.Read(32)), delta = Unpack(br.Read(32));
            int valueBits = (int)br.Read(4) + 1;
            bool seq = br.Read(1) != 0;
            int lookupValues;
            if (lookup == 1)
            {
                lookupValues = (int)Math.Floor(Math.Pow(n, 1.0 / cb.Dim));
                while (Pow(lookupValues + 1, cb.Dim) <= n) lookupValues++;
                while (lookupValues > 0 && Pow(lookupValues, cb.Dim) > n) lookupValues--;
            }
            else lookupValues = n * cb.Dim;
            float[] mult = new float[lookupValues];
            for (int i = 0; i < lookupValues; i++) mult[i] = br.Read(valueBits);
            cb.Vectors = new float[n * cb.Dim];
            for (int e = 0; e < n; e++)
            {
                float last = 0; int idiv = 1;
                for (int j = 0; j < cb.Dim; j++)
                {
                    int moff = lookup == 1 ? (e / idiv) % lookupValues : e * cb.Dim + j;
                    float v = mult[moff] * delta + minv + last;
                    if (seq) last = v;
                    cb.Vectors[e * cb.Dim + j] = v;
                    if (lookup == 1) idiv *= lookupValues;
                }
            }
        }
        else if (lookup != 0) throw new VorbisException("bad codebook lookup type");
        if (br.Eop) throw new VorbisException("truncated setup header");
        return cb;
    }

    private static long Pow(int b, int e)
    {
        long r = 1;
        for (int i = 0; i < e; i++) { r *= b; if (r > 100000000L) return r; }
        return r;
    }

    private void BuildTree(int[] len)
    {
        left.Add(0); right.Add(0);
        uint[] avail = new uint[33];
        int k = 0;
        while (k < len.Length && len[k] == 0) k++;
        if (k == len.Length) return;
        Insert(0, len[k], k);
        for (int i = 1; i <= len[k]; i++) avail[i] = 1u << (32 - i);
        for (int i = k + 1; i < len.Length; i++)
        {
            int z = len[i];
            if (z == 0) continue;
            while (z > 0 && avail[z] == 0) z--;
            if (z == 0) throw new VorbisException("over-specified codebook");
            uint res = avail[z]; avail[z] = 0;
            Insert(res, len[i], i);
            if (z != len[i]) for (int y = len[i]; y > z; y--) avail[y] = res + (1u << (32 - y));
        }
    }

    private void Insert(uint code, int length, int entry)
    {
        int node = 0;
        for (int j = 0; j < length; j++)
        {
            int bit = (int)((code >> (31 - j)) & 1);
            List<int> arr = bit == 0 ? left : right;
            if (j == length - 1) { arr[node] = ~entry; return; }
            int next = arr[node];
            if (next == 0) { next = left.Count; left.Add(0); right.Add(0); arr[node] = next; }
            else if (next < 0) throw new VorbisException("bad huffman tree");
            node = next;
        }
    }

    private int[] leftA, rightA;
    public int DecodeScalar(VBitReader br)
    {
        if (leftA == null) { leftA = left.ToArray(); rightA = right.ToArray(); }
        int node = 0;
        while (true)
        {
            int b = (int)br.Read(1);
            if (br.Eop) return -1;
            int next = b == 0 ? leftA[node] : rightA[node];
            if (next == 0) return -1;
            if (next < 0) return ~next;
            node = next;
        }
    }
}

internal class VFloor1
{
    public int[] PartitionClass; public int[] ClassDim, ClassSub, MasterBook;
    public int[][] SubBooks;
    public int Multiplier, RangeBits;
    public int[] X; public int[] Order; public int[] LowN, HighN;
    public int Count;

    private static int Ilog(int x) { int r = 0; while (x > 0) { r++; x >>= 1; } return r; }

    public static VFloor1 Read(VBitReader br)
    {
        VFloor1 f = new VFloor1();
        int parts = (int)br.Read(5);
        f.PartitionClass = new int[parts];
        int maxClass = -1;
        for (int i = 0; i < parts; i++) { f.PartitionClass[i] = (int)br.Read(4); if (f.PartitionClass[i] > maxClass) maxClass = f.PartitionClass[i]; }
        f.ClassDim = new int[maxClass + 1]; f.ClassSub = new int[maxClass + 1]; f.MasterBook = new int[maxClass + 1];
        f.SubBooks = new int[maxClass + 1][];
        for (int i = 0; i <= maxClass; i++)
        {
            f.ClassDim[i] = (int)br.Read(3) + 1;
            f.ClassSub[i] = (int)br.Read(2);
            if (f.ClassSub[i] != 0) f.MasterBook[i] = (int)br.Read(8);
            f.SubBooks[i] = new int[1 << f.ClassSub[i]];
            for (int j = 0; j < f.SubBooks[i].Length; j++) f.SubBooks[i][j] = (int)br.Read(8) - 1;
        }
        f.Multiplier = (int)br.Read(2) + 1;
        f.RangeBits = (int)br.Read(4);
        List<int> xs = new List<int>(); xs.Add(0); xs.Add(1 << f.RangeBits);
        for (int i = 0; i < parts; i++)
            for (int j = 0; j < f.ClassDim[f.PartitionClass[i]]; j++) xs.Add((int)br.Read(f.RangeBits));
        f.X = xs.ToArray(); f.Count = f.X.Length;
        if (f.Count > 65) throw new VorbisException("bad floor");
        // sort order
        f.Order = new int[f.Count];
        for (int i = 0; i < f.Count; i++) f.Order[i] = i;
        int[] xx = f.X;
        Array.Sort(f.Order, delegate(int a, int b) { int c = xx[a].CompareTo(xx[b]); return c != 0 ? c : a.CompareTo(b); });
        // neighbours
        f.LowN = new int[f.Count]; f.HighN = new int[f.Count];
        for (int i = 2; i < f.Count; i++)
        {
            int lo = 0, hi = 1; int loV = -1, hiV = int.MaxValue;
            for (int j = 0; j < i; j++)
            {
                if (f.X[j] < f.X[i] && f.X[j] > loV) { loV = f.X[j]; lo = j; }
                if (f.X[j] > f.X[i] && f.X[j] < hiV) { hiV = f.X[j]; hi = j; }
            }
            f.LowN[i] = lo; f.HighN[i] = hi;
        }
        if (br.Eop) throw new VorbisException("truncated setup header");
        return f;
    }

    private static float[] invDb;
    private static float InvDb(int i)
    {
        if (invDb == null)
        {
            float[] t = new float[256];
            for (int k = 0; k < 256; k++) t[k] = (float)Math.Pow(10.0, (k - 255) * 7.0 / 256.0);
            invDb = t;
        }
        if (i < 0) i = 0; if (i > 255) i = 255;
        return invDb[i];
    }

    private static int RenderPoint(int x0, int y0, int x1, int y1, int x)
    {
        int dy = y1 - y0, adx = x1 - x0, ady = Math.Abs(dy);
        int err = ady * (x - x0);
        int off = err / adx;
        return dy < 0 ? y0 - off : y0 + off;
    }

    private static void RenderLine(int x0, int y0, int x1, int y1, float[] outp, int n)
    {
        int dy = y1 - y0, adx = x1 - x0, ady = Math.Abs(dy);
        int bas = dy / adx;
        int sy = dy < 0 ? bas - 1 : bas + 1;
        ady = ady - Math.Abs(bas) * adx;
        int x = x0, y = y0, err = 0;
        if (x < n) outp[x] = InvDb(y);
        for (x = x0 + 1; x < x1 && x < n; x++)
        {
            err += ady;
            if (err >= adx) { err -= adx; y += sy; } else y += bas;
            outp[x] = InvDb(y);
        }
    }

    // Returns false if the channel carries no floor ("unused"), otherwise fills curve[0..n)
    public bool Decode(VBitReader br, VCodebook[] books, float[] curve, int n)
    {
        if (br.Read(1) == 0) return false;
        int[] range = { 256, 128, 86, 64 };
        int rng = range[Multiplier - 1];
        int rb = Ilog(rng - 1);
        int[] y = new int[Count];
        y[0] = (int)br.Read(rb); y[1] = (int)br.Read(rb);
        int offset = 2;
        for (int i = 0; i < PartitionClass.Length; i++)
        {
            int cls = PartitionClass[i], cdim = ClassDim[cls], cbits = ClassSub[cls];
            int csub = (1 << cbits) - 1, cval = 0;
            if (cbits > 0)
            {
                cval = books[MasterBook[cls]].DecodeScalar(br);
                if (cval < 0) return false;
            }
            for (int j = 0; j < cdim; j++)
            {
                int book = SubBooks[cls][cval & csub];
                cval >>= cbits;
                if (book >= 0)
                {
                    int v = books[book].DecodeScalar(br);
                    if (v < 0) return false;
                    y[offset + j] = v;
                }
                else y[offset + j] = 0;
            }
            offset += cdim;
        }
        if (br.Eop) return false;

        int[] fy = new int[Count]; bool[] flag = new bool[Count];
        fy[0] = y[0]; fy[1] = y[1]; flag[0] = flag[1] = true;
        for (int i = 2; i < Count; i++)
        {
            int lo = LowN[i], hi = HighN[i];
            int pred = RenderPoint(X[lo], fy[lo], X[hi], fy[hi], X[i]);
            int val = y[i];
            int highroom = rng - pred, lowroom = pred;
            int room = (highroom < lowroom ? highroom : lowroom) * 2;
            if (val != 0)
            {
                flag[lo] = flag[hi] = flag[i] = true;
                if (val >= room)
                    fy[i] = highroom > lowroom ? val - lowroom + pred : pred - val + highroom - 1;
                else
                    fy[i] = (val & 1) != 0 ? pred - ((val + 1) >> 1) : pred + (val >> 1);
            }
            else { flag[i] = false; fy[i] = pred; }
        }

        int hx = 0, lx = 0, hy = 0;
        int ly = fy[Order[0]] * Multiplier;
        for (int i = 1; i < Count; i++)
        {
            int idx = Order[i];
            if (flag[idx])
            {
                hy = fy[idx] * Multiplier; hx = X[idx];
                if (hx > lx) RenderLine(lx, ly, hx, hy, curve, n);
                lx = hx; ly = hy;
            }
        }
        if (hx < n)
        {
            float v = InvDb(hy);
            for (int i = hx; i < n; i++) curve[i] = v;
        }
        return true;
    }
}

internal class VResidue
{
    public int Type, Begin, End, PartSize, Classes, ClassBook;
    public int[][] Books;

    public static VResidue Read(VBitReader br, int type)
    {
        VResidue r = new VResidue();
        r.Type = type;
        r.Begin = (int)br.Read(24); r.End = (int)br.Read(24);
        r.PartSize = (int)br.Read(24) + 1;
        r.Classes = (int)br.Read(6) + 1;
        r.ClassBook = (int)br.Read(8);
        int[] cascade = new int[r.Classes];
        for (int i = 0; i < r.Classes; i++)
        {
            int low = (int)br.Read(3), high = 0;
            if (br.Read(1) != 0) high = (int)br.Read(5);
            cascade[i] = high * 8 + low;
        }
        r.Books = new int[r.Classes][];
        for (int i = 0; i < r.Classes; i++)
        {
            r.Books[i] = new int[8];
            for (int j = 0; j < 8; j++)
                r.Books[i][j] = (cascade[i] & (1 << j)) != 0 ? (int)br.Read(8) : -1;
        }
        if (br.Eop) throw new VorbisException("truncated setup header");
        return r;
    }

    // vectors: one array per channel handled together (type 2 passes a single interleaved vector)
    public void Decode(VBitReader br, VCodebook[] books, float[][] vecs, bool[] skip, int size)
    {
        int ch = vecs.Length;
        int begin = Math.Min(Begin, size), end = Math.Min(End, size);
        VCodebook cb = books[ClassBook];
        int cw = cb.Dim;
        int toRead = end - begin;
        if (toRead <= 0) return;
        int partsToRead = toRead / PartSize;
        int[][] cls = new int[ch][];
        for (int j = 0; j < ch; j++) cls[j] = new int[partsToRead + cw + 1];
        bool any = false;
        for (int j = 0; j < ch; j++) if (!skip[j]) any = true;
        if (!any) return;

        for (int pass = 0; pass < 8; pass++)
        {
            int pc = 0;
            while (pc < partsToRead)
            {
                if (pass == 0)
                {
                    for (int j = 0; j < ch; j++)
                    {
                        if (skip[j]) continue;
                        int temp = cb.DecodeScalar(br);
                        if (temp < 0) return;
                        for (int i = cw - 1; i >= 0; i--)
                        {
                            cls[j][i + pc] = temp % Classes;
                            temp /= Classes;
                        }
                    }
                }
                for (int i = 0; i < cw && pc < partsToRead; i++)
                {
                    for (int j = 0; j < ch; j++)
                    {
                        if (skip[j]) continue;
                        int book = Books[cls[j][pc]][pass];
                        if (book < 0) continue;
                        VCodebook vb = books[book];
                        if (vb.Vectors == null) return;
                        int offset = begin + pc * PartSize;
                        float[] v = vecs[j];
                        int dim = vb.Dim;
                        if (Type == 0)
                        {
                            int step = PartSize / dim;
                            for (int k = 0; k < step; k++)
                            {
                                int e = vb.DecodeScalar(br);
                                if (e < 0) return;
                                for (int d = 0; d < dim; d++) v[offset + k + d * step] += vb.Vectors[e * dim + d];
                            }
                        }
                        else
                        {
                            for (int k = 0; k < PartSize; k += dim)
                            {
                                int e = vb.DecodeScalar(br);
                                if (e < 0) return;
                                for (int d = 0; d < dim; d++) v[offset + k + d] += vb.Vectors[e * dim + d];
                            }
                        }
                    }
                    pc++;
                }
            }
        }
    }
}

internal class VMapping
{
    public int Submaps; public int[] Mux; public int[] Mag, Ang; public int[] SubFloor, SubResidue;
}

internal class VMode { public bool Long; public int Mapping; }

internal class VImdct
{
    private int m;          // number of coefficients (n/2)
    private float[] preC, preS, postC, postS, twC, twS;
    private int[] rev;
    private float[] re, im;

    public VImdct(int n)
    {
        m = n / 2;
        int h = m / 2;
        preC = new float[h]; preS = new float[h]; postC = new float[h]; postS = new float[h];
        for (int j = 0; j < h; j++)
        {
            preC[j] = (float)Math.Cos(-Math.PI * j / m); preS[j] = (float)Math.Sin(-Math.PI * j / m);
            postC[j] = (float)Math.Cos(-Math.PI * (j + 0.25) / m); postS[j] = (float)Math.Sin(-Math.PI * (j + 0.25) / m);
        }
        twC = new float[h / 2 + 1]; twS = new float[h / 2 + 1];
        for (int j = 0; j < twC.Length; j++)
        {
            twC[j] = (float)Math.Cos(-2 * Math.PI * j / h); twS[j] = (float)Math.Sin(-2 * Math.PI * j / h);
        }
        rev = new int[h];
        int bits = 0; while ((1 << bits) < h) bits++;
        for (int i = 0; i < h; i++)
        {
            int r = 0; for (int b = 0; b < bits; b++) if ((i & (1 << b)) != 0) r |= 1 << (bits - 1 - b);
            rev[i] = r;
        }
        re = new float[h]; im = new float[h];
    }

    private void Fft()
    {
        int h = re.Length;
        for (int i = 0; i < h; i++)
        {
            int j = rev[i];
            if (j > i) { float t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
        }
        for (int size = 2; size <= h; size <<= 1)
        {
            int half = size >> 1, step = h / size;
            for (int start = 0; start < h; start += size)
            {
                for (int k = 0; k < half; k++)
                {
                    float wr = twC[k * step], wi = twS[k * step];
                    int a = start + k, b = a + half;
                    float xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - xr; im[b] = im[a] - xi;
                    re[a] += xr; im[a] += xi;
                }
            }
        }
    }

    // spec[0..m) -> outp[0..2m)
    public void Inverse(float[] spec, float[] outp, float[] z)
    {
        int h = m / 2;
        for (int j = 0; j < h; j++)
        {
            float a = spec[2 * j], b = spec[m - 1 - 2 * j];
            re[j] = a * preC[j] - b * preS[j];
            im[j] = a * preS[j] + b * preC[j];
        }
        Fft();
        for (int p = 0; p < h; p++)
        {
            float ur = re[p] * postC[p] - im[p] * postS[p];
            float ui = re[p] * postS[p] + im[p] * postC[p];
            z[2 * p] = ur;
            z[m - 1 - 2 * p] = -ui;
        }
        int n = 2 * m, half = m / 2;
        for (int i = 0; i < n; i++)
        {
            int mm = i + half; float v;
            if (mm < m) v = z[mm];
            else if (mm < 2 * m) v = -z[2 * m - 1 - mm];
            else v = -z[mm - 2 * m];
            outp[i] = v;
        }
    }
}

internal static class VorbisDecoder
{
    private static int Ilog(int x) { int r = 0; while (x > 0) { r++; x >>= 1; } return r; }

    public static string Decode(string inPath, out byte[] pcm, out int outputChannels, out int outputRate)
    {
        pcm = null; outputChannels = 0; outputRate = 0;
        using (FileStream fin = new FileStream(inPath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536))
        using (MemoryStream fout = new MemoryStream())
        {
            OggPacketReader ogg = new OggPacketReader(new BufferedStream(fin, 65536));
            byte[] p = ogg.NextPacket();
            if (p == null) return "empty or invalid Ogg file";
            if (p.Length >= 8 && Encoding.ASCII.GetString(p, 0, 8) == "OpusHead") return "OPUS";
            if (p.Length < 30 || p[0] != 1 || Encoding.ASCII.GetString(p, 1, 6) != "vorbis")
                return "Ogg file does not contain Vorbis audio";

            int channels = p[11];
            int rate = p[12] | p[13] << 8 | p[14] << 16 | p[15] << 24;
            if (rate < 8000 || rate > 192000) return "unsupported Vorbis sample rate";
            int bs0 = 1 << (p[28] & 15), bs1 = 1 << (p[28] >> 4);
            if (channels < 1 || channels > 2) return "only mono/stereo Vorbis is supported (found " + channels + " channels)";
            if (bs0 < 64 || bs1 < bs0 || bs1 > 8192) return "bad Vorbis block sizes";

            p = ogg.NextPacket();                                  // comment header
            if (p == null || p[0] != 3) return "missing Vorbis comment header";
            p = ogg.NextPacket();                                  // setup header
            if (p == null || p[0] != 5) return "missing Vorbis setup header";

            VBitReader br = new VBitReader(p);
            br.Read(8); for (int i = 0; i < 6; i++) br.Read(8);   // packet type + "vorbis"
            int ncb = (int)br.Read(8) + 1;
            VCodebook[] books = new VCodebook[ncb];
            for (int i = 0; i < ncb; i++) books[i] = VCodebook.Read(br);
            int nt = (int)br.Read(6) + 1;
            for (int i = 0; i < nt; i++) br.Read(16);
            int nf = (int)br.Read(6) + 1;
            VFloor1[] floors = new VFloor1[nf];
            for (int i = 0; i < nf; i++)
            {
                int ft = (int)br.Read(16);
                if (ft != 1) return "this file uses Vorbis floor type " + ft + " (not supported)";
                floors[i] = VFloor1.Read(br);
            }
            int nr = (int)br.Read(6) + 1;
            VResidue[] res = new VResidue[nr];
            for (int i = 0; i < nr; i++)
            {
                int rt = (int)br.Read(16);
                if (rt > 2) return "bad residue type";
                res[i] = VResidue.Read(br, rt);
            }
            int nm = (int)br.Read(6) + 1;
            VMapping[] maps = new VMapping[nm];
            for (int i = 0; i < nm; i++)
            {
                if (br.Read(16) != 0) return "bad mapping type";
                VMapping mp = new VMapping();
                mp.Submaps = br.Read(1) != 0 ? (int)br.Read(4) + 1 : 1;
                int steps = br.Read(1) != 0 ? (int)br.Read(8) + 1 : 0;
                mp.Mag = new int[steps]; mp.Ang = new int[steps];
                for (int s = 0; s < steps; s++)
                {
                    mp.Mag[s] = (int)br.Read(Ilog(channels - 1));
                    mp.Ang[s] = (int)br.Read(Ilog(channels - 1));
                }
                br.Read(2);
                mp.Mux = new int[channels];
                if (mp.Submaps > 1) for (int c = 0; c < channels; c++) mp.Mux[c] = (int)br.Read(4);
                mp.SubFloor = new int[mp.Submaps]; mp.SubResidue = new int[mp.Submaps];
                for (int s = 0; s < mp.Submaps; s++)
                {
                    br.Read(8);
                    mp.SubFloor[s] = (int)br.Read(8); mp.SubResidue[s] = (int)br.Read(8);
                    if (mp.SubFloor[s] >= nf || mp.SubResidue[s] >= nr) return "bad mapping";
                }
                maps[i] = mp;
            }
            int nmodes = (int)br.Read(6) + 1;
            VMode[] modes = new VMode[nmodes];
            for (int i = 0; i < nmodes; i++)
            {
                modes[i] = new VMode();
                modes[i].Long = br.Read(1) != 0;
                br.Read(16); br.Read(16);
                modes[i].Mapping = (int)br.Read(8);
                if (modes[i].Mapping >= nm) return "bad mode";
            }
            if (br.Eop) return "truncated Vorbis setup header";

            // --- audio ---
            VImdct imdctS = new VImdct(bs0), imdctL = new VImdct(bs1);
            float[] winS = MakeSlope(bs0 / 2), winL = MakeSlope(bs1 / 2);
            float[][] prev = null; int prevN = 0;
            float[][] cur = new float[channels][];
            for (int c = 0; c < channels; c++) cur[c] = new float[bs1];
            float[] z = new float[bs1 / 2];
            float[][] spec = new float[channels][];
            float[][] floorCurve = new float[channels][];
            for (int c = 0; c < channels; c++) { spec[c] = new float[bs1 / 2]; floorCurve[c] = new float[bs1 / 2]; }
            bool[] hasFloor = new bool[channels], noRes = new bool[channels];

            long dataBytes = 0;
            byte[] ob = new byte[8192 * channels * 2 * 2];

            while ((p = ogg.NextPacket()) != null)
            {
                VBitReader pr = new VBitReader(p);
                if (pr.Read(1) != 0) continue;                    // not an audio packet
                int mi = (int)pr.Read(Ilog(nmodes - 1));
                if (mi >= nmodes || pr.Eop) continue;
                VMode mode = modes[mi];
                int n = mode.Long ? bs1 : bs0;
                bool prevLong = true, nextLong = true;
                if (mode.Long) { prevLong = pr.Read(1) != 0; nextLong = pr.Read(1) != 0; }
                int half = n / 2;
                VMapping mp = maps[mode.Mapping];

                for (int c = 0; c < channels; c++)
                {
                    Array.Clear(spec[c], 0, half);
                    VFloor1 fl = floors[mp.SubFloor[mp.Mux[c]]];
                    hasFloor[c] = fl.Decode(pr, books, floorCurve[c], half);
                    noRes[c] = !hasFloor[c];
                }
                for (int s = 0; s < mp.Mag.Length; s++)
                {
                    if (!noRes[mp.Mag[s]] || !noRes[mp.Ang[s]]) { noRes[mp.Mag[s]] = false; noRes[mp.Ang[s]] = false; }
                }
                for (int sm = 0; sm < mp.Submaps; sm++)
                {
                    List<int> chans = new List<int>();
                    for (int c = 0; c < channels; c++) if (mp.Mux[c] == sm) chans.Add(c);
                    VResidue rs = res[mp.SubResidue[sm]];
                    int cnt = chans.Count;
                    bool[] skip = new bool[cnt];
                    for (int i = 0; i < cnt; i++) skip[i] = noRes[chans[i]];
                    if (rs.Type == 2)
                    {
                        bool all = true; for (int i = 0; i < cnt; i++) if (!skip[i]) all = false;
                        if (all) continue;
                        float[][] one = new float[1][];
                        one[0] = new float[half * cnt];
                        rs.Decode(pr, books, one, new bool[1], half * cnt);
                        for (int i = 0; i < cnt; i++)
                            for (int k = 0; k < half; k++) spec[chans[i]][k] = one[0][k * cnt + i];
                    }
                    else
                    {
                        float[][] vv = new float[cnt][];
                        for (int i = 0; i < cnt; i++) vv[i] = spec[chans[i]];
                        rs.Decode(pr, books, vv, skip, half);
                    }
                }
                for (int s = mp.Mag.Length - 1; s >= 0; s--)
                {
                    float[] M = spec[mp.Mag[s]], A = spec[mp.Ang[s]];
                    for (int k = 0; k < half; k++)
                    {
                        float m = M[k], a = A[k], nm2, na;
                        if (m > 0) { if (a > 0) { nm2 = m; na = m - a; } else { na = m; nm2 = m + a; } }
                        else { if (a > 0) { nm2 = m; na = m + a; } else { na = m; nm2 = m - a; } }
                        M[k] = nm2; A[k] = na;
                    }
                }

                VImdct im = mode.Long ? imdctL : imdctS;
                // window boundaries
                int lStart, lEnd, rStart, rEnd;
                if (mode.Long && !prevLong) { lStart = n / 4 - bs0 / 4; lEnd = n / 4 + bs0 / 4; }
                else { lStart = 0; lEnd = n / 2; }
                if (mode.Long && !nextLong) { rStart = n * 3 / 4 - bs0 / 4; rEnd = n * 3 / 4 + bs0 / 4; }
                else { rStart = n / 2; rEnd = n; }
                float[] lw = (!mode.Long || !prevLong) ? winS : winL;
                float[] rw = (!mode.Long || !nextLong) ? winS : winL;

                for (int c = 0; c < channels; c++)
                {
                    if (noRes[c] && !hasFloor[c])
                    {
                        Array.Clear(cur[c], 0, n);
                        continue;
                    }
                    float[] sp = spec[c];
                    if (hasFloor[c]) for (int k = 0; k < half; k++) sp[k] *= floorCurve[c][k];
                    else Array.Clear(sp, 0, half);
                    im.Inverse(sp, cur[c], z);
                    float[] o = cur[c];
                    for (int i = 0; i < lStart; i++) o[i] = 0;
                    for (int i = lStart; i < lEnd; i++) o[i] *= lw[i - lStart];
                    for (int i = rStart; i < rEnd; i++) o[i] *= rw[rEnd - 1 - i];
                    for (int i = rEnd; i < n; i++) o[i] = 0;
                }

                if (prev != null)
                {
                    int L = prevN / 4 + n / 4;
                    int needed = L * channels * 2;
                    if (needed > ob.Length) ob = new byte[needed];
                    int w = 0;
                    for (int t = 0; t < L; t++)
                    {
                        for (int c = 0; c < channels; c++)
                        {
                            float v = 0;
                            int pi = prevN / 2 + t; if (pi < prevN) v += prev[c][pi];
                            int ci = n / 2 - L + t; if (ci >= 0) v += cur[c][ci];
                            int s16 = (int)Math.Round(v * 32768.0f);
                            if (s16 > 32767) s16 = 32767; else if (s16 < -32768) s16 = -32768;
                            ob[w++] = (byte)(s16 & 0xFF); ob[w++] = (byte)((s16 >> 8) & 0xFF);
                        }
                    }
                    fout.Write(ob, 0, w);
                    dataBytes += w;
                }
                // current becomes previous
                if (prev == null) { prev = new float[channels][]; for (int c = 0; c < channels; c++) prev[c] = new float[bs1]; }
                for (int c = 0; c < channels; c++) Array.Copy(cur[c], prev[c], n);
                prevN = n;
            }
            // trim padding from the final block using the granule position of the last page
            long frameBytes = channels * 2;
            if (ogg.EosGranule >= 0 && ogg.EosGranule * frameBytes < dataBytes) dataBytes = ogg.EosGranule * frameBytes;
            if (dataBytes == 0) return "no audio data decoded";
            if (dataBytes > Int32.MaxValue) return "decoded audio is too large for in-memory playback";
            fout.SetLength(dataBytes);
            pcm = fout.ToArray(); outputChannels = channels; outputRate = rate;
            return null;
        }
    }

    // rising half of the Vorbis power-sine window, length = half window
    private static float[] MakeSlope(int len)
    {
        float[] w = new float[len];
        for (int i = 0; i < len; i++)
        {
            double s = Math.Sin((i + 0.5) / (2.0 * len) * Math.PI);
            w[i] = (float)Math.Sin(Math.PI / 2 * s * s);
        }
        return w;
    }
}
'@

try {
    if (-not (Test-Path -LiteralPath "$env:WINDIR\System32\mfplay.dll")) {
        throw "Media Foundation MFPlay runtime not found."
    }
    Add-Type -TypeDefinition $mfSource -Language CSharp -ReferencedAssemblies @(
        "System.dll", "System.Drawing.dll", "System.Windows.Forms.dll"
    )
}
catch {
    Write-Host "[ERROR] Could not initialize Media Foundation: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Notifications (one reusable tray icon; never blocks playback)
# ---------------------------------------------------------------------------
$global:NotifyIcon = $null

function Show-Notification($title, $text) {
    try {
        if (-not $global:NotifyIcon) {
            $global:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
            $global:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
            $global:NotifyIcon.Visible = $true
        }
        $global:NotifyIcon.BalloonTipTitle = $title
        $global:NotifyIcon.BalloonTipText  = $text
        $global:NotifyIcon.ShowBalloonTip(3000)
    }
    catch { }
}

function Remove-NotifyIcon {
    if ($global:NotifyIcon) {
        try { $global:NotifyIcon.Visible = $false; $global:NotifyIcon.Dispose() } catch { }
        $global:NotifyIcon = $null
    }
}

# ---------------------------------------------------------------------------
# Codec hints and playback helpers
# ---------------------------------------------------------------------------
function Show-CodecHint {
    param([string]$Ext)
    if ($global:CodecHintShown) { return }
    $hint = switch ($Ext) {
        '.opus' { "Not currently supported" }
        default { $null }
    }
    if ($hint) {
        $global:CodecHintShown = $true
        Write-Host "  $hint" -ForegroundColor Yellow
    }
}

function Start-VideoPlayback {
    param([string]$Path)
    try {
        $playPath = $Path
        $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
        Show-CodecHint $ext
        [NativeMfPlayer]::Start($playPath)
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($global:VideoTempDir) -and
            (Test-Path -LiteralPath $global:VideoTempDir)) {
            Remove-Item -LiteralPath $global:VideoTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Video mode
# ---------------------------------------------------------------------------
function Get-MediaFiles {
    param([string[]]$Extensions)
    @(Get-ChildItem -LiteralPath $MusicDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() } |
        Select-Object -ExpandProperty FullName)
}

function Test-NameMatch {
    param([string]$Path, [string]$Query)
    return ([System.IO.Path]::GetFileName($Path).IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-MediaKind {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($AudioExt -contains $ext) { return 'audio' }
    return 'video'
}

function Resolve-MediaPath {
    param([string]$Text, [string[]]$Extensions)

    $Text = $Text.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $candidates = @($Text)
    try { $candidates += (Join-Path $MusicDir $Text) } catch { }
    foreach ($cand in $candidates) {
        try {
            if (Test-Path -LiteralPath $cand -PathType Leaf) { return (Resolve-Path -LiteralPath $cand).Path }
        }
        catch { }
    }

    
    $found = @(Get-MediaFiles $Extensions | Where-Object { Test-NameMatch $_ $Text })

    if ($found.Count -eq 0) { throw "No media found matching '$Text'." }
    if ($found.Count -eq 1) { return $found[0] }

    Write-Host ""
    Write-Host "  Looking for '$Text' - did you mean one of these?" -ForegroundColor Yellow
    Write-Host ""
    for ($i = 0; $i -lt $found.Count; $i++) {
        Write-Host "  $($i + 1). $([System.IO.Path]::GetFileName($found[$i]))"
    }
    Write-Host ""
    $choice = Read-Host "Enter number (or 0 to cancel)"
    $n = 0
    if (-not [int]::TryParse($choice, [ref]$n) -or $n -lt 1 -or $n -gt $found.Count) { return $null }
    return $found[$n - 1]
}

function Start-VideoMode {
    Write-Host ""
    $videoInput = Read-Host "Video (or audio) file path or name"
    if ([string]::IsNullOrWhiteSpace($videoInput)) { return }
    try {
        $resolved = Resolve-MediaPath $videoInput $AllExt
        if (-not $resolved) { Write-Host "  Cancelled." -ForegroundColor DarkGray; return }
        Start-VideoPlayback $resolved
    }
    catch { Write-Host "[VIDEO ERROR] $($_.Exception.Message)" -ForegroundColor Red }
}

# ---------------------------------------------------------------------------
# Audio mode
# ---------------------------------------------------------------------------
function Start-AudioMode {
$SongArg = $global:AudioSearchArg

# Load songs
$global:Songs = @(Get-MediaFiles $AudioExt)

if (-not $global:Songs -and -not $global:AudioDirectFile) {
    Write-Host "No audio files found under $MusicDir" -ForegroundColor Yellow
    return
}

$global:CliSongTarget = $null
if ($global:AudioDirectFile) { $global:CliSongTarget = $global:AudioDirectFile }


if (-not [string]::IsNullOrWhiteSpace($SongArg)) {
    $results = $global:Songs | Where-Object {
        (Test-NameMatch $_ $SongArg)
    }

    if (-not $results) {
        Write-Host "No songs found matching '$SongArg'." -ForegroundColor Red
        return
    }

    $list = @($results)

    if ($list.Count -eq 1) {
        $global:CliSongTarget = $list[0]
    } else {
        Write-Host ""
        Write-Host "  Looking for '$SongArg' - did you mean one of these?" -ForegroundColor Yellow
        Write-Host ""
        for ($i = 0; $i -lt $list.Count; $i++) {
            Write-Host "  $($i + 1). $([System.IO.Path]::GetFileName($list[$i]))"
        }
        Write-Host ""
        Write-Host "Enter number (or 0 to cancel): " -NoNewline -ForegroundColor Yellow
        $choice = Read-Host

        if ($choice -eq "0" -or $choice -eq "") {
            Write-Host "  Cancelled." -ForegroundColor DarkGray
            return
        }

        $choiceInt = 0
        if (-not [int]::TryParse($choice, [ref]$choiceInt) -or $choiceInt -lt 1 -or $choiceInt -gt $list.Count) {
            Write-Host "  Invalid selection." -ForegroundColor Red
            return
        }

        $global:CliSongTarget = $list[$choiceInt - 1]
    }
}

$global:TempAudioDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("play-ps1-" + $PID)
$global:TempAudioFile = $null

function Get-PlayablePath {
    param([string]$File)

    $ext = [System.IO.Path]::GetExtension($File).ToLowerInvariant()

    if ($ext -ne '.wav' -and $ext -ne '.mp3') { return $File }

    $prepared = Join-Path $global:TempAudioDir ([guid]::NewGuid().ToString('N') + $ext)
    try {
        [void][System.IO.Directory]::CreateDirectory($global:TempAudioDir)
        if ([WavFloatConverter]::TryPrepare($File, $prepared, ($ext -eq '.wav'))) {
            $global:TempAudioFile = $prepared
            return $prepared
        }
    }
    catch { }

    if (Test-Path -LiteralPath $prepared) {
        Remove-Item -LiteralPath $prepared -Force -ErrorAction SilentlyContinue
    }
    return $File
}

function Remove-TempAudio {
    if ($global:TempAudioFile -and (Test-Path -LiteralPath $global:TempAudioFile)) {
        Remove-Item -LiteralPath $global:TempAudioFile -Force -ErrorAction SilentlyContinue
    }
    $global:TempAudioFile = $null
}

function Shuffle-Queue {
    $currentFile = if ($global:PreSearchFile) {
        $global:PreSearchFile
    } elseif ($global:Queue -and $global:Queue.Count -gt 0) {
        $global:Queue[$global:Index]
    } else { $null }

    $global:PreSearchFile = $null

    $global:Queue       = @($global:Songs | Sort-Object { Get-Random })
    $global:Index       = 0
    $global:CursorIndex = 0

    if ($currentFile) {
        $foundAt = [array]::IndexOf($global:Queue, $currentFile)
        $global:LastPlayedIndex = if ($foundAt -ge 0) { $foundAt } else { 0 }
    } else {
        $global:LastPlayedIndex = 0
    }
}

function Show-Queue {
    Write-Host "`n--- QUEUE ---"
    for ($i = 0; $i -lt $global:Queue.Count; $i++) {
        $name = [System.IO.Path]::GetFileName($global:Queue[$i])
        if ($i -eq $global:Index -and $i -eq $global:LastPlayedIndex) {
            Write-Host ">> * $name" -ForegroundColor Cyan
        } elseif ($i -eq $global:Index) {
            Write-Host ">>   $name" -ForegroundColor Green
        } elseif ($i -eq $global:LastPlayedIndex) {
            Write-Host "  *  $name" -ForegroundColor Yellow
        } else {
            Write-Host "     $name"
        }
    }
    $loopStatus   = if ($global:LoopMode)   { "ON" } else { "OFF" }
    $repeatStatus = if ($global:RepeatOne)  { "ON" } else { "OFF" }
    $searchStatus = if ($global:SearchMode) { " [SEARCH MODE]" } else { "" }
    Write-Host "   [Loop: $loopStatus]  [Repeat: $repeatStatus]  [Vol: $global:Volume%]$searchStatus" -ForegroundColor DarkCyan
    Write-Host "--------------"
    Write-Host "  Q = View Queue/Navigate" -ForegroundColor DarkGray
}

function Open-Navigator {
    $global:CursorIndex = $global:Index

    while ($true) {
        [console]::Clear()
        Write-Host "`n--- NAVIGATOR ---"
        for ($i = 0; $i -lt $global:Queue.Count; $i++) {
            $name = [System.IO.Path]::GetFileName($global:Queue[$i])
            if ($i -eq $global:Index -and $i -eq $global:CursorIndex) {
                Write-Host ">> * $name" -ForegroundColor Cyan
            } elseif ($i -eq $global:Index) {
                Write-Host ">>   $name" -ForegroundColor Green
            } elseif ($i -eq $global:CursorIndex) {
                Write-Host "  *  $name" -ForegroundColor Yellow
            } else {
                Write-Host "     $name"
            }
        }
        $loopStatus   = if ($global:LoopMode)   { "ON" } else { "OFF" }
        $repeatStatus = if ($global:RepeatOne)  { "ON" } else { "OFF" }
        $searchStatus = if ($global:SearchMode) { " [SEARCH MODE]" } else { "" }
        Write-Host "   [Loop: $loopStatus]  [Repeat: $repeatStatus]  [Vol: $global:Volume%]$searchStatus" -ForegroundColor DarkCyan
        Write-Host "--------------"
        Write-Host "  Up/Down = Navigate | Enter = Play | F = Search | P = Pause | Q = Close" -ForegroundColor DarkGray
        Write-Host ""

        while (-not [console]::KeyAvailable) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 30
        }
        $k = [console]::ReadKey($true).Key
        switch ($k) {
            "UpArrow" {
                if ($global:CursorIndex -gt 0) {
                    $global:CursorIndex--
                } else {
                    $global:CursorIndex = $global:Queue.Count - 1
                }
            }
            "DownArrow" {
                if ($global:CursorIndex -lt ($global:Queue.Count - 1)) {
                    $global:CursorIndex++
                } else {
                    $global:CursorIndex = 0
                }
            }
            "Enter" {
                $global:LastPlayedIndex = $global:Index
                Stop-Current
                $global:Index = $global:CursorIndex
                [console]::Clear()
                Play-Current
                return
            }
            "P" { Toggle-Pause }
            "F" {
                [console]::Clear()
                Write-Host "Search: " -NoNewline -ForegroundColor Yellow
                $query = Read-Host

                if (-not $query) { break }

                $results = $global:Songs | Where-Object {
                    (Test-NameMatch $_ $query)
                }

                if (-not $results) {
                    Write-Host "  No match found for '$query'." -ForegroundColor Red
                    Start-Sleep -Milliseconds 800
                    break
                }

                $list = @($results)
                Write-Host ""
                for ($i = 0; $i -lt $list.Count; $i++) {
                    Write-Host "  $($i + 1). $([System.IO.Path]::GetFileName($list[$i]))"
                }
                Write-Host ""
                Write-Host "Enter number (append 'a' to add to queue only, 0 to cancel): " -NoNewline -ForegroundColor Yellow
                $choice = Read-Host

                if ($choice -eq "0" -or $choice -eq "") { break }

                $addOnly = $false
                if ($choice.Length -ge 2 -and $choice.ToUpper().EndsWith('A')) {
                    $addOnly = $true
                    $choice = $choice.Substring(0, $choice.Length - 1)
                }

                $choiceInt = 0
                if (-not [int]::TryParse($choice, [ref]$choiceInt) -or $choiceInt -lt 1 -or $choiceInt -gt $list.Count) {
                    Write-Host "  Invalid selection." -ForegroundColor Red
                    Start-Sleep -Milliseconds 800
                    break
                }

                $chosen = $list[$choiceInt - 1]

                if ($addOnly) {
                    if ($global:Queue -contains $chosen) {
                        Write-Host "  Song already in queue." -ForegroundColor Yellow
                        Start-Sleep -Milliseconds 800
                        break
                    }
                    $global:Queue = $global:Queue + $chosen
                    Write-Host "  Added to queue." -ForegroundColor Green
                    Start-Sleep -Milliseconds 800
                    break
                }

                $newIndex = [array]::IndexOf($global:Queue, $chosen)
                if ($newIndex -lt 0) {
                    $global:Queue = $global:Queue + $chosen
                    $newIndex     = $global:Queue.Count - 1
                }

                $global:LastPlayedIndex = $global:Index
                Stop-Current
                $global:Index       = $newIndex
                $global:CursorIndex = $newIndex
                [console]::Clear()
                Play-Current
                return
            }
            "Q" {
                [console]::Clear()
                Write-Host "Now playing: $(Split-Path $global:Queue[$global:Index] -Leaf)" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Controls:"
                Write-Host "  N = Next       | B = Previous  | P = Pause/Play"
                Write-Host "  S = Shuffle    | Q = View Queue | QQ = Navigate | F = Search"
                Write-Host "  L = Toggle Loop (queue) | R = Toggle Repeat (current song)"
                Write-Host "  < / > = Seek -/+ 5s | + = Volume Up  | - = Volume Down"
                Write-Host "  X = Exit"
                Write-Host ""
                return
            }
        }
    }
}

function Get-TrackDuration {
    if ($global:Alias -eq 'DirectPCM') { return [long][DirectPcmAudioEngine]::GetDurationMilliseconds() }
    return [long][NativeMfAudioEngine]::GetDurationMilliseconds()
}

function Get-TrackPosition {
    if ($global:Alias -eq 'DirectPCM') { return [long][DirectPcmAudioEngine]::GetPositionMilliseconds() }
    return [long][NativeMfAudioEngine]::GetPositionMilliseconds()
}

function Format-Time($ms) {
    $totalSec = [math]::Floor($ms / 1000)
    $min = [math]::Floor($totalSec / 60)
    $sec = $totalSec % 60
    return "{0}:{1:00}" -f $min, $sec
}

function Show-Progress {
    if (-not $global:Alias) { return }
    $pos = Get-TrackPosition
    $dur = Get-TrackDuration
    if ($dur -le 0) { return }
    $posStr = Format-Time $pos
    $durStr = Format-Time $dur
    $pct = [int][math]::Max(0, [math]::Min(30, [math]::Floor(($pos / $dur) * 30)))
    $bar = ("[" + "#" * $pct + "-" * (30 - $pct) + "]")
    $state = if ($global:Paused) { "PAUSED" } else { "PLAYING" }
    Write-Host "`r  $state  $bar  $posStr / $durStr   " -NoNewline
}

function Set-PlayerVolume($vol, $quiet = $false) {
    $global:Volume = [math]::Max(0, [math]::Min(100, $vol))
    if ($global:Alias -eq 'DirectPCM') { [void][DirectPcmAudioEngine]::SetVolume($global:Volume) }
    else { [void][NativeMfAudioEngine]::SetVolume($global:Volume) }
    if (-not $quiet) { Write-Host "`r  Volume: $global:Volume%   " -NoNewline }
}

function Play-Current {
    Stop-Current
    $file = $global:Queue[$global:Index]
    Write-Host "`nNow playing: $(Split-Path $file -Leaf)" -ForegroundColor Cyan
    Show-Notification "Now Playing" (Split-Path $file -Leaf)

    $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
    if ($ext -eq '.wav') {
        try {
            if ([DirectPcmAudioEngine]::OpenWavFloat($file)) {
                $global:Alias = 'DirectPCM'
                $global:Paused = $false
                $global:AudioHasPlayed = $true
                $global:PlayStartedAt = [DateTime]::UtcNow
                $global:ArrowSteps = 0
                Update-KeyBuffer
                $global:SeekEnabled = $true
                Set-PlayerVolume $global:Volume $true
                return
            }
        }
        catch {
            [DirectPcmAudioEngine]::Close()
            # Fall through to the existing PCM-temp-WAV/MFPlay path if direct
            # waveOut playback cannot be opened for this float WAV.
        }
    }

    if ($ext -eq '.ogg' -or $ext -eq '.aiff' -or $ext -eq '.aif' -or $ext -eq '.aifc') {
        try {
            if ($ext -eq '.ogg') {
                #Write-Host "  Decoding OGG Vorbis directly to memory..." -ForegroundColor DarkCyan
                [DirectPcmAudioEngine]::Open($file)
            } else {
                #Write-Host "  Decoding AIFF directly to memory..." -ForegroundColor DarkCyan
                [DirectPcmAudioEngine]::OpenAiff($file)
            }
            $global:Alias = 'DirectPCM'
            $global:Paused = $false
            $global:AudioHasPlayed = $true
            $global:PlayStartedAt = [DateTime]::UtcNow
            $global:ArrowSteps = 0
            Update-KeyBuffer
            $global:SeekEnabled = $true
            Set-PlayerVolume $global:Volume $true
        }
        catch {
            [DirectPcmAudioEngine]::Close()

            try {
                [NativeMfAudioEngine]::Open($file)
                $global:Alias = 'MFPlayAudio'
                $global:Paused = $false
                $global:AudioHasPlayed = $false
                $global:PlayStartedAt = [DateTime]::UtcNow
                $global:ArrowSteps = 0
                Update-KeyBuffer
                $global:SeekEnabled = $true
                Set-PlayerVolume $global:Volume $true
            }
            catch {
                $global:Alias = $null
                Write-Host "  Could not decode/play $ext`: $($_.Exception.Message)" -ForegroundColor Red
                if ($ext -eq '.ogg') { Show-CodecHint 'a supported OGG Vorbis file' }
            }
        }
        return
    }

    $playPath = Get-PlayablePath $file
    try {
        [NativeMfAudioEngine]::Open($playPath)
    }
    catch {
        $opened = $false
        if ($playPath -ne $file) {
            Remove-TempAudio
            try { [NativeMfAudioEngine]::Open($file); $opened = $true } catch { }
        }
        if (-not $opened) {
            Write-Host "  Could not open audio: $($_.Exception.Message)" -ForegroundColor Red
            $global:Alias = $null
            return
        }
    }

    $global:Alias = 'MFPlayAudio'
    [System.Windows.Forms.Application]::DoEvents()
    # Open() starts playback itself once MFPlay finishes its asynchronous load.
    Set-PlayerVolume $global:Volume $true

    $global:Paused = $false
    $global:AudioHasPlayed = $false
    $global:PlayStartedAt = [DateTime]::UtcNow
    $global:ArrowSteps = 0
    Update-KeyBuffer
    $global:SeekEnabled = $true
}

function Stop-Current {
    $global:SeekEnabled = $false
    if ($global:Alias -eq 'DirectPCM') {
        [DirectPcmAudioEngine]::Stop(); [DirectPcmAudioEngine]::Close(); $global:Alias = $null
    } elseif ($global:Alias) {
        try { [NativeMfAudioEngine]::Stop() } catch { }
        [NativeMfAudioEngine]::Close()
        $global:Alias = $null
    }
    Remove-TempAudio
}

function Toggle-Pause {
    if (-not $global:Alias) { return }
    try {
        if ($global:Alias -eq 'DirectPCM') {
            if ($global:Paused) { [DirectPcmAudioEngine]::Play(); $global:Paused = $false }
            else { [DirectPcmAudioEngine]::Pause(); $global:Paused = $true }
            return
        }
        if ($global:Paused) {
            [NativeMfAudioEngine]::Play()
            $global:Paused = $false
        }
        else {
            [NativeMfAudioEngine]::Pause()
            $global:Paused = $true
        }
    }
    catch { Write-Host "`n  Playback control error: $($_.Exception.Message)" -ForegroundColor Red }
}

# ---------------------------------------------------------------------------
# Key sorting and seeking
# ---------------------------------------------------------------------------

function Update-KeyBuffer {
    while ([console]::KeyAvailable) {
        $k = [console]::ReadKey($true).Key
        if ($k -eq "LeftArrow")       { if ($global:SeekEnabled) { $global:ArrowSteps-- } }
        elseif ($k -eq "RightArrow")  { if ($global:SeekEnabled) { $global:ArrowSteps++ } }
        elseif ($global:ValidKeys -contains $k) { $global:LetterQueue.Enqueue([string]$k) }
    }
}

function Get-PriorityKey {
    Update-KeyBuffer

    if ($global:LetterQueue.Count -gt 0) {
        $global:ArrowSteps = 0
        return $global:LetterQueue.Dequeue()
    }

    if ($global:SeekEnabled -and $global:ArrowSteps -ne 0) {
        $steps = [math]::Max(-3, [math]::Min(3, $global:ArrowSteps))
        $global:ArrowSteps    = 0
        $global:PendingSeekMs = $steps * 5000
        return "Seek"
    }

    $global:ArrowSteps = 0
    return $null
}

function Seek-Relative {
    param([int]$DeltaMs)
    if (-not $global:Alias -or -not $global:SeekEnabled) { return }
    $duration = Get-TrackDuration
    if ($duration -le 0) { return }
    $position = Get-TrackPosition
    $target = [long][math]::Max(0, [math]::Min($duration, $position + $DeltaMs))
    try {
        if ($global:Alias -eq 'DirectPCM') { [DirectPcmAudioEngine]::SetPositionMilliseconds($target) }
        else { [NativeMfAudioEngine]::SetPositionMilliseconds($target) }
        Show-Progress
    }
    catch { Write-Host "`n  Seek error: $($_.Exception.Message)" -ForegroundColor Red }
}

function Toggle-Loop {
    $global:LoopMode = -not $global:LoopMode
    $status = if ($global:LoopMode) { "ON" } else { "OFF" }
    Write-Host "`n  Loop mode: $status" -ForegroundColor DarkCyan
}

function Toggle-Repeat {
    $global:RepeatOne = -not $global:RepeatOne
    $status = if ($global:RepeatOne) { "ON" } else { "OFF" }
    Write-Host "`n  Repeat current song: $status" -ForegroundColor DarkCyan
}

function Next-Track {
    $global:LastPlayedIndex = $global:Index
    Stop-Current
    $global:Index++
    if ($global:Index -ge $global:Queue.Count) { $global:Index = 0 }
    Play-Current
}

function Prev-Track {
    $global:LastPlayedIndex = $global:Index
    Stop-Current
    $global:Index--
    if ($global:Index -lt 0) { $global:Index = $global:Queue.Count - 1 }
    Play-Current
}

function Resume-IfWasPlaying($wasPlaying) {
    if ($wasPlaying) {
        try {
            if ($global:Alias -eq 'DirectPCM') { [DirectPcmAudioEngine]::Play() }
            else { [NativeMfAudioEngine]::Play() }
        } catch { }
        $global:Paused = $false
    }
}

function Search-And-Play {
    Write-Host ""
    $wasPlaying = (-not $global:Paused) -and $global:Alias
    if ($wasPlaying) {
        try {
            if ($global:Alias -eq 'DirectPCM') { [DirectPcmAudioEngine]::Pause() }
            else { [NativeMfAudioEngine]::Pause() }
        } catch { }
        $global:Paused = $true
    }

    Write-Host "Search: " -NoNewline -ForegroundColor Yellow
    $query = Read-Host

    if (-not $query) {
        Resume-IfWasPlaying $wasPlaying
        Write-Host "  Search cancelled." -ForegroundColor DarkGray
        return
    }

    $results = $global:Songs | Where-Object {
        (Test-NameMatch $_ $query)
    }

    if (-not $results) {
        Resume-IfWasPlaying $wasPlaying
        Write-Host "  No matches found for '$query'." -ForegroundColor Red
        return
    }

    $list = @($results)
    Write-Host ""
    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host "  $($i + 1). $([System.IO.Path]::GetFileName($list[$i]))"
    }
    Write-Host ""
    Write-Host "Enter number (append 'a' to add to queue only, 0 to cancel): " -NoNewline -ForegroundColor Yellow
    $choice = (Read-Host).Trim()

    if ($choice -eq "0" -or $choice -eq "") {
        Resume-IfWasPlaying $wasPlaying
        Write-Host "  Cancelled." -ForegroundColor DarkGray
        return
    }

    # A suffix allows queue-only additions without interrupting the current track.
    $addOnly = $choice.EndsWith('a', [System.StringComparison]::OrdinalIgnoreCase)
    if ($addOnly) { $choice = $choice.Substring(0, $choice.Length - 1).Trim() }

    $choiceInt = 0
    if (-not [int]::TryParse($choice, [ref]$choiceInt) -or $choiceInt -lt 1 -or $choiceInt -gt $list.Count) {
        Resume-IfWasPlaying $wasPlaying
        Write-Host "  Invalid selection. Use a number or a number followed by 'a'." -ForegroundColor Red
        return
    }

    $chosen = $list[$choiceInt - 1]

    if ($addOnly) {
        if ($global:Queue -contains $chosen) {
            Write-Host "  Song already in queue." -ForegroundColor Yellow
        } else {
            # Append without replacing the queue or changing the current track.
            $global:Queue = @($global:Queue) + @($chosen)
            Write-Host "  Added to queue: $(Split-Path -Leaf $chosen)" -ForegroundColor Green
        }
        Resume-IfWasPlaying $wasPlaying
        return
    }

    $global:LastPlayedIndex = $global:Index
    Stop-Current

    if (-not $global:SearchMode) {
        $global:PreSearchQueue = $global:Queue
        $global:PreSearchIndex = $global:Index
    }
    $global:PreSearchFile = $chosen
    $global:SearchMode    = $true

    $global:Queue     = @($chosen)
    $global:Index     = 0
    $global:LoopMode  = $false
    $global:RepeatOne = $false

    Write-Host "  [Search mode: playing single song]" -ForegroundColor DarkYellow
    Play-Current
}

function Exit-SearchMode {
    $global:PreSearchFile   = $global:Queue[$global:Index]
    $global:Queue           = @($global:PreSearchQueue)
    $global:Index           = $global:PreSearchIndex
    $global:LoopMode        = $false
    $global:RepeatOne       = $false
    $global:SearchMode      = $false
}

function Start-EndOfQueueCountdown {
    $global:WaitingForLoop = $true

    if ($global:Queue.Count -eq 1) {
        $songName = [System.IO.Path]::GetFileName($global:Queue[0])
        Write-Host "`nFinished: $songName" -ForegroundColor DarkYellow
        Write-Host "Press L to replay this song, or exiting in..." -ForegroundColor Yellow
        Show-Notification "Song Finished" "Press L to replay, or player exits in 5 seconds."
    } else {
        Write-Host "`nQueue finished. Press L to loop, or exiting in..." -ForegroundColor Yellow
        Show-Notification "Queue Finished" "Press L to loop, or player exits in 5 seconds."
    }

    for ($i = 5; $i -ge 1; $i--) {
        Write-Host "$i..." -ForegroundColor Yellow -NoNewline
        for ($t = 0; $t -lt 4; $t++) {
            if ([console]::KeyAvailable) {
                $k = [console]::ReadKey($true).Key
                if ($k -eq "L") {
                    Write-Host ""
                    $global:LastPlayedIndex = $global:Index
                    $global:Index           = 0
                    $global:WaitingForLoop  = $false
                    if ($global:Queue.Count -eq 1) {
                        Write-Host "  Replaying song..." -ForegroundColor Green
                    } else {
                        Write-Host "  Looping queue from start!" -ForegroundColor Green
                    }
                    Play-Current
                    return
                }
                if ($k -eq "X") {
                    Write-Host ""
                    Stop-Current
                    $global:Running        = $false
                    $global:WaitingForLoop = $false
                    if ($global:SearchMode) { Exit-SearchMode }
                    return
                }
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 250
        }
    }

    Write-Host ""
    Write-Host "Exiting." -ForegroundColor Red
    Stop-Current
    if ($global:SearchMode) { Exit-SearchMode }
    $global:Running        = $false
    $global:WaitingForLoop = $false
}

# Initialize
$global:Alias           = $null
$global:LoopMode        = $false
$global:RepeatOne       = $false
$global:Paused          = $false
$global:Running         = $true
$global:WaitingForLoop  = $false
$global:Volume          = 100
$global:SearchMode      = $false
$global:PreSearchQueue  = $null
$global:PreSearchIndex  = 0
$global:CursorIndex     = 0
$global:LastPlayedIndex = 0
$global:QueueOpen       = $false
#$global:PreSearchFile   = $null
$global:AudioHasPlayed  = $false
$global:PlayStartedAt   = [DateTime]::UtcNow
$global:ValidKeys = @('N','B','P','S','Q','L','R','F','OemPlus','OemMinus','X')

# Seek state
$global:SeekEnabled   = $false
$global:ArrowSteps    = 0
$global:PendingSeekMs = 0
$global:LetterQueue   = New-Object System.Collections.Queue

[void][NativeMfAudioEngine]::SetVolume($global:Volume)
Shuffle-Queue

if ($global:CliSongTarget) {
    $global:PreSearchQueue = @($global:Queue)
    $global:PreSearchIndex = 0
    $global:SearchMode     = $true
    $global:Queue          = @($global:CliSongTarget)
    $global:Index          = 0
    $global:LoopMode       = $false
    $global:RepeatOne      = $false
    Write-Host "  [Search mode: playing single song]" -ForegroundColor DarkYellow
}

Show-Queue
Play-Current

Write-Host "Controls:"
Write-Host "  N = Next       | B = Previous  | P = Pause/Play"
Write-Host "  S = Shuffle    | Q = View Queue | QQ = Navigate | F = Search"
Write-Host "  L = Toggle Loop (queue) | R = Toggle Repeat (current song)"
Write-Host "  < / > = Seek -/+ 5s | + = Volume Up  | - = Volume Down"
Write-Host "  X = Exit"
Write-Host "  (Loop and Repeat are OFF by default.)"
Write-Host ""

# Main loop (try/finally so the temp audio copy is removed even on Ctrl+C)
try {
while ($global:Running) {

    if (-not $global:WaitingForLoop) { Show-Progress }

    $key = if (-not $global:WaitingForLoop) { Get-PriorityKey } else { $null }
    if ($key) {

        if ($global:QueueOpen) {
            switch ($key) {
                "Q" {
                    $global:QueueOpen = $false
                    Open-Navigator
                }
                default {
                    $global:QueueOpen = $false
                    Write-Host ""
                    switch ($key) {
                        "N"        { Next-Track }
                        "B"        { Prev-Track }
                        "P"        { Toggle-Pause }
                        "S"        {
                            if ($global:SearchMode) { Exit-SearchMode }
                            Write-Host "`n  Shuffling..." -ForegroundColor Yellow
                            Stop-Current
                            Shuffle-Queue
                            Show-Queue
                            Play-Current
                        }
                        "L"        { Toggle-Loop }
                        "R"        { Toggle-Repeat }
                        "F"        { Search-And-Play }
                        "OemPlus"  { Set-PlayerVolume ($global:Volume + 10) }
                        "OemMinus" { Set-PlayerVolume ($global:Volume - 10) }
                        "X"        {
                            Write-Host ""
                            Stop-Current
                            $global:Running = $false
                        }
                        "Seek"      { Seek-Relative $global:PendingSeekMs }
                        "UpArrow"   { }
                        "DownArrow" { }
                    }
                }
            }

        } else {
            switch ($key) {
                "N"        { Write-Host ""; Next-Track }
                "B"        { Write-Host ""; Prev-Track }
                "P"        { Toggle-Pause }
                "S"        {
                    if ($global:SearchMode) { Exit-SearchMode }
                    Write-Host "`n  Shuffling..." -ForegroundColor Yellow
                    Stop-Current
                    Shuffle-Queue
                    Show-Queue
                    Play-Current
                }
                "Q"        {
                    $global:QueueOpen   = $true
                    $global:CursorIndex = $global:Index
                    Write-Host ""
                    Show-Queue
                }
                "L"        { Toggle-Loop }
                "R"        { Toggle-Repeat }
                "F"        { Search-And-Play }
                "OemPlus"  { Set-PlayerVolume ($global:Volume + 10) }
                "OemMinus" { Set-PlayerVolume ($global:Volume - 10) }
                "X"        {
                    Write-Host ""
                    Stop-Current
                    $global:Running = $false
                }
                "Seek"      { Seek-Relative $global:PendingSeekMs }
                "UpArrow"   { }
                "DownArrow" { }
            }
        }
    }

    # Auto-next when song ends
    if (-not $global:WaitingForLoop -and $global:Alias) {
        $mediaState = 0
        try {
            if ($global:Alias -eq 'DirectPCM') { $mediaState = [DirectPcmAudioEngine]::GetState() }
            else { $mediaState = [NativeMfAudioEngine]::GetState() }
        } catch { }

        if ($mediaState -eq 2 -and -not $global:AudioHasPlayed) {
            $global:AudioHasPlayed = $true
            # Re-apply volume now that the media item is fully loaded.
            Set-PlayerVolume $global:Volume $true
        }

        $loadFailed = $false
        if (-not $global:AudioHasPlayed -and -not $global:Paused -and $mediaState -ne 2 -and
            ([DateTime]::UtcNow - $global:PlayStartedAt).TotalSeconds -gt 8) {
            $loadFailed = $true
            $failedFile = $global:Queue[$global:Index]
            Write-Host "`n  Could not play '$(Split-Path $failedFile -Leaf)'. Skipping." -ForegroundColor Red
            Show-CodecHint ([System.IO.Path]::GetExtension($failedFile).ToLowerInvariant())
        }

        if ($loadFailed -or ($mediaState -eq 1 -and $global:AudioHasPlayed -and -not $global:Paused)) {
            $global:SeekEnabled = $false

            if ($global:RepeatOne -and -not $loadFailed) {
                $global:LastPlayedIndex = $global:Index
                Stop-Current
                Play-Current
            } elseif ($global:Index + 1 -ge $global:Queue.Count) {
                if ($global:LoopMode) {
                    $global:LastPlayedIndex = $global:Index
                    Write-Host "`n  Restarting queue..." -ForegroundColor DarkCyan
                    $global:Index = 0
                    Play-Current
                } else {
                    Start-EndOfQueueCountdown
                }
            } else {
                $global:LastPlayedIndex = $global:Index
                $global:Index++
                Play-Current
            }
        }
    }

    # MFPlay completes its asynchronous media load through window messages on this
    # thread. Without a message pump the file never opens and nothing plays.
    for ($pump = 0; $pump -lt 4; $pump++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}
}
finally {
    Stop-Current
    Remove-NotifyIcon
    if (Test-Path -LiteralPath $global:TempAudioDir) {
        Remove-Item -LiteralPath $global:TempAudioDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
function Invoke-DirectPlay {
    param([string]$Text)
    try {
        $path = Resolve-MediaPath $Text $AllExt
        if (-not $path) { Write-Host "  Cancelled." -ForegroundColor DarkGray; return }

        if ((Get-MediaKind $path) -eq 'audio') {
            $global:AudioSearchArg  = $null
            $global:AudioDirectFile = $path
            Start-AudioMode
        }
        else {
            Start-VideoPlayback $path
        }
    }
    catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red }
}

if (-not [string]::IsNullOrWhiteSpace($Name)) {
    Invoke-DirectPlay $Name
    Remove-NotifyIcon
    exit
}

try {
    while ($true) {
        Clear-Host
        Write-Host "====================================" -ForegroundColor DarkCyan
        Write-Host "   WINDOWS PS1 MEDIA PLAYER CLI" -ForegroundColor Cyan
        Write-Host "====================================" -ForegroundColor DarkCyan
        Write-Host "  1. Audio  (MP3 / WAV / FLAC / M4A / AAC / WMA / OGG / AIFF / AIF / AIFC)"
        Write-Host "  2. Video  (GUI window; also opens any audio file)"
        Write-Host "  0. Exit"
        Write-Host ""
        $choice = Read-Host "Select a mode"
        switch ($choice) {
            '1' {
                $global:AudioSearchArg = Read-Host "Optional song-name search (Enter for full library)"
                if ([string]::IsNullOrWhiteSpace($global:AudioSearchArg)) { $global:AudioSearchArg = $null }
                Start-AudioMode
                $global:AudioSearchArg = $null
                Read-Host "Press Enter to return to the main menu" | Out-Null
            }
            '2' {
                Start-VideoMode
                Read-Host "Press Enter to return to the main menu" | Out-Null
            }
            '0' { break }
            default { Write-Host "Invalid selection." -ForegroundColor Red; Start-Sleep -Milliseconds 700 }
        }
        if ($choice -eq '0') { break }
    }
}
finally {
    Remove-NotifyIcon
}

