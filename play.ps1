param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$MediaArgs
)
$Name = ($MediaArgs -join ' ').Trim()

$ErrorActionPreference = 'Stop'
$MusicDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MusicDir)) { $MusicDir = (Get-Location).Path }

$AudioExt = @('.mp3', '.wav', '.flac', '.m4a', '.aac', '.wma')
$VideoExt = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.m4v')
$AllExt   = $AudioExt + $VideoExt
$global:AudioDirectFile = $null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mfSource = @'
using System;
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
        window.Text = "Native Windows Video Player - " + Path.GetFileName(path);
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

// Converts standard or extensible IEEE-float WAV audio to temporary PCM16 WAV.
// Returns false for non-float WAV files or unsupported/invalid float layouts.
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
                if (TryConvertFile(inputPath, outputPath)) return true;
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
    public static bool TryConvertFile(string inputPath, string outputPath) {
        try {
            long length = new FileInfo(inputPath).Length;
            if (length < 12) return false;

            using (FileStream fs = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                byte[] head = new byte[12];
                int got = 0;
                while (got < 12) {
                    int c = fs.Read(head, got, 12 - got);
                    if (c <= 0) break;
                    got += c;
                }
                if (got == 12 &&
                    head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46 &&
                    head[8] == 0x57 && head[9] == 0x41 && head[10] == 0x56 && head[11] == 0x45) {
                    return TryConvert(inputPath, 0, outputPath);
                }

                // Leading non-audio bytes: search for an embedded RIFF/WAVE header.
                const int ChunkSize = 65536;
                byte[] buf = new byte[ChunkSize];
                long pos = 0;
                while (pos < length) {
                    fs.Position = pos;
                    int read = 0;
                    while (read < ChunkSize) {
                        int c = fs.Read(buf, read, ChunkSize - read);
                        if (c <= 0) break;
                        read += c;
                    }
                    if (read < 12) break;

                    for (int i = 0; i + 12 <= read; i++) {
                        if (buf[i] == 0x52 && buf[i + 1] == 0x49 && buf[i + 2] == 0x46 && buf[i + 3] == 0x46 &&
                            buf[i + 8] == 0x57 && buf[i + 9] == 0x41 && buf[i + 10] == 0x56 && buf[i + 11] == 0x45) {
                            if (TryConvert(inputPath, pos + i, outputPath)) return true;
                        }
                    }

                    if (pos + read >= length) break;
                    pos += read - 11;   // overlap so a header on a chunk boundary is not missed
                }
            }
            return false;
        } catch {
            return false;
        }
    }

    public static bool TryConvert(string inputPath, long startOffset, string outputPath) {
        bool outputCreated = false;
        try {
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
                long dataOffset = -1;
                long dataSize = -1;
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
                int channels = BitConverter.ToUInt16(format, 2);
                uint sampleRate = BitConverter.ToUInt32(format, 4);
                uint byteRate = BitConverter.ToUInt32(format, 8);
                ushort blockAlign = BitConverter.ToUInt16(format, 12);
                ushort bitsPerSample = BitConverter.ToUInt16(format, 14);
                bool isFloat = formatTag == 3;

                if (formatTag == 0xFFFE) {
                    if (format.Length < 40 || BitConverter.ToUInt16(format, 16) < 22) return false;
                    if (BitConverter.ToUInt16(format, 18) != bitsPerSample) return false;
                    isFloat = true;
                    for (int i = 0; i < 16; i++) {
                        if (format[24 + i] != IeeeFloatSubFormat[i]) { isFloat = false; break; }
                    }
                }
                if (!isFloat) return false;
                if (channels < 1 || channels > 32 || sampleRate < 1 || sampleRate > 768000) return false;
                if (bitsPerSample != 32 && bitsPerSample != 64) return false;

                int bytesPerSample = bitsPerSample / 8;
                int expectedBlockAlign = channels * bytesPerSample;
                if (blockAlign != expectedBlockAlign || dataSize % blockAlign != 0 ||
                    byteRate != (long)sampleRate * blockAlign) return false;
                long outputDataSize = (dataSize / bytesPerSample) * 2L;
                long outputByteRate = (long)sampleRate * channels * 2L;
                int outputBlockAlign = channels * 2;
                if (outputDataSize > UInt32.MaxValue - 36L || outputByteRate > UInt32.MaxValue || outputBlockAlign > UInt16.MaxValue) return false;

                using (FileStream output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (BinaryWriter writer = new BinaryWriter(output)) {
                    outputCreated = true;
                    writer.Write(Encoding.ASCII.GetBytes("RIFF"));
                    writer.Write((uint)(36L + outputDataSize));
                    writer.Write(Encoding.ASCII.GetBytes("WAVE"));
                    writer.Write(Encoding.ASCII.GetBytes("fmt "));
                    writer.Write((uint)16);
                    writer.Write((ushort)1); // WAVE_FORMAT_PCM
                    writer.Write((ushort)channels);
                    writer.Write(sampleRate);
                    writer.Write((uint)outputByteRate);
                    writer.Write((ushort)outputBlockAlign);
                    writer.Write((ushort)16);
                    writer.Write(Encoding.ASCII.GetBytes("data"));
                    writer.Write((uint)outputDataSize);

                    input.Position = dataOffset;
                    byte[] buffer = new byte[65536 - (65536 % bytesPerSample)];
                    long remaining = dataSize;
                    while (remaining > 0) {
                        int wanted = (int)Math.Min(buffer.Length, remaining);
                        wanted -= wanted % bytesPerSample;
                        if (wanted <= 0) throw new IOException("Invalid IEEE-float WAV data length.");
                        int read = 0;
                        while (read < wanted) {
                            int count = input.Read(buffer, read, wanted - read);
                            if (count <= 0) throw new IOException("Unexpected end of IEEE-float WAV data.");
                            read += count;
                        }
                        for (int i = 0; i < read; i += bytesPerSample) {
                            double sample = bitsPerSample == 32
                                ? (double)BitConverter.ToSingle(buffer, i)
                                : BitConverter.ToDouble(buffer, i);
                            short pcmSample;
                            if (Double.IsNaN(sample) || Double.IsInfinity(sample)) pcmSample = 0;
                            else if (sample >= 1.0) pcmSample = Int16.MaxValue;
                            else if (sample <= -1.0) pcmSample = Int16.MinValue;
                            else pcmSample = (short)Math.Round(sample < 0 ? sample * 32768.0 : sample * 32767.0);
                            writer.Write(pcmSample);
                        }
                        remaining -= read;
                    }
                    writer.Flush();
                }
            }
            return true;
        } catch {
            if (outputCreated) {
                try { if (File.Exists(outputPath)) File.Delete(outputPath); } catch { }
            }
            return false;
        }
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
        [NativeMfPlayer]::Start($resolved)
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
    return [long][NativeMfAudioEngine]::GetDurationMilliseconds()
}

function Get-TrackPosition {
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
    [void][NativeMfAudioEngine]::SetVolume($global:Volume)
    if (-not $quiet) { Write-Host "`r  Volume: $global:Volume%   " -NoNewline }
}

function Play-Current {
    Stop-Current
    $file = $global:Queue[$global:Index]
    Write-Host "`nNow playing: $(Split-Path $file -Leaf)" -ForegroundColor Cyan
    Show-Notification "Now Playing" (Split-Path $file -Leaf)

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
    $global:ArrowSteps = 0
    Update-KeyBuffer
    $global:SeekEnabled = $true
}

function Stop-Current {
    $global:SeekEnabled = $false
    if ($global:Alias) {
        try { [NativeMfAudioEngine]::Stop() } catch { }
        [NativeMfAudioEngine]::Close()
        $global:Alias = $null
    }
    Remove-TempAudio
}

function Toggle-Pause {
    if (-not $global:Alias) { return }
    try {
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
        [NativeMfAudioEngine]::SetPositionMilliseconds($target)
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
        try { [NativeMfAudioEngine]::Play() } catch { }
        $global:Paused = $false
    }
}

function Search-And-Play {
    Write-Host ""
    $wasPlaying = (-not $global:Paused) -and $global:Alias
    if ($wasPlaying) {
        try { [NativeMfAudioEngine]::Pause() } catch { }
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
$global:PreSearchFile   = $null
$global:AudioHasPlayed  = $false
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
        try { $mediaState = [NativeMfAudioEngine]::GetState() } catch { }

        if ($mediaState -eq 2 -and -not $global:AudioHasPlayed) {
            $global:AudioHasPlayed = $true
            # Re-apply volume now that the media item is fully loaded.
            Set-PlayerVolume $global:Volume $true
        }

        if ($mediaState -eq 1 -and $global:AudioHasPlayed -and -not $global:Paused) {
            $global:SeekEnabled = $false

            if ($global:RepeatOne) {
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
            [NativeMfPlayer]::Start($path)
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
        Write-Host "  1. Audio  (MP3 / WAV / FLAC / M4A / AAC / WMA)"
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
