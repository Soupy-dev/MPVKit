using MPVKit.Windows;

namespace MPVKit.Demo;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new PlayerWindow(args.FirstOrDefault()));
    }
}

internal sealed class PlayerWindow : Form
{
    private readonly Panel video = new() { Dock = DockStyle.Fill, BackColor = Color.Black };
    private readonly TextBox source = new() { Width = 350, PlaceholderText = "Local file or HTTPS URL" };
    private readonly Label status = new() { Dock = DockStyle.Bottom, Height = 58, AutoEllipsis = true };
    private readonly ComboBox audio = new() { Width = 150, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox subtitles = new() { Width = 150, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TrackBar timeline = new() { Dock = DockStyle.Bottom, Height = 34, Maximum = 10000, TickStyle = TickStyle.None };
    private MpvVideoHost? host;
    private bool updating;
    private bool closed;
    private bool fullscreen;
    private Rectangle restoredBounds;

    public PlayerWindow(string? initialSource)
    {
        Text = "MPVKit Windows";
        ClientSize = new(1100, 720);
        MinimumSize = new(760, 420);
        BackColor = Color.FromArgb(24, 24, 28);
        ForeColor = Color.WhiteSmoke;
        KeyPreview = true;
        source.Text = initialSource ?? "";
        var controls = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true, Padding = new(8) };
        controls.Controls.Add(source);
        AddButton(controls, "Open file", async () => {
            using var dialog = new OpenFileDialog();
            if (dialog.ShowDialog(this) == DialogResult.OK) { source.Text = dialog.FileName; await LoadMedia(); }
        });
        AddButton(controls, "Load", LoadMedia);
        AddButton(controls, "Play / Pause", () => Player.Snapshot.Paused ? Player.PlayAsync() : Player.PauseAsync());
        AddButton(controls, "−10s", () => Player.SeekAsync(-10, true));
        AddButton(controls, "+10s", () => Player.SeekAsync(10, true));
        AddButton(controls, "Subtitle file", async () => {
            using var dialog = new OpenFileDialog { Filter = "Subtitles|*.srt;*.ass;*.ssa;*.vtt;*.sub|All files|*.*" };
            if (dialog.ShowDialog(this) == DialogResult.OK)
                await Player.LoadExternalSubtitlesAsync([new() { Source = dialog.FileName, Title = Path.GetFileNameWithoutExtension(dialog.FileName) }]);
        });
        AddButton(controls, "Compact overlay", () => {
            if (host!.IsCompactOverlay) host.RestoreInline(); else host.ShowCompactOverlay();
            return Task.CompletedTask;
        });
        AddButton(controls, "Fullscreen", () => { ToggleFullscreen(); return Task.CompletedTask; });
        controls.Controls.Add(audio);
        controls.Controls.Add(subtitles);
        audio.SelectedIndexChanged += async (_, _) => {
            if (!updating && audio.SelectedItem is TrackChoice choice) await Safely(() => Player.SelectTrackAsync(MpvTrackKind.Audio, choice.Id));
        };
        subtitles.SelectedIndexChanged += async (_, _) => {
            if (!updating && subtitles.SelectedItem is TrackChoice choice) await Safely(() => Player.SelectTrackAsync(MpvTrackKind.Subtitle, choice.Id));
        };
        timeline.MouseUp += async (_, _) => await Safely(() => Player.SeekAsync(Player.Snapshot.Duration * timeline.Value / 10000));
        Controls.Add(video);
        Controls.Add(timeline);
        Controls.Add(status);
        Controls.Add(controls);
        video.Resize += (_, _) => host?.Resize(0, 0, video.ClientSize.Width, video.ClientSize.Height);
        Shown += async (_, _) => {
            host = new(video.Handle, video.ClientSize.Width, video.ClientSize.Height);
            Player.SnapshotChanged += SnapshotChanged;
            await Safely(async () => { await Player.Ready; if (!string.IsNullOrWhiteSpace(source.Text)) await LoadMedia(); });
        };
        FormClosing += async (_, e) => {
            if (closed || host is null) return;
            e.Cancel = true;
            Enabled = false;
            await Player.DisposeAsync();
            host.Dispose();
            closed = true;
            Close();
        };
        KeyDown += async (_, e) => {
            if (source.Focused || host is null) return;
            if (e.KeyCode == Keys.F11) { ToggleFullscreen(); e.Handled = true; }
            if (e.KeyCode == Keys.Escape && fullscreen) { ToggleFullscreen(); e.Handled = true; }
            if (e.KeyCode == Keys.Space) { e.Handled = true; await Safely(() => Player.Snapshot.Paused ? Player.PlayAsync() : Player.PauseAsync()); }
        };
    }

    private MpvPlayer Player => host?.Player ?? throw new InvalidOperationException("The player window is still starting.");
    private Task LoadMedia() => Player.LoadAsync(new() { Source = source.Text });

    private async Task Safely(Func<Task> action)
    {
        try { await action(); }
        catch (Exception error) { status.Text = error.Message; }
    }

    private void AddButton(Control row, string text, Func<Task> action)
    {
        var button = new Button { Text = text, AutoSize = true, ForeColor = Color.Black };
        button.Click += async (_, _) => await Safely(action);
        row.Controls.Add(button);
    }

    private void SnapshotChanged(object? sender, MpvSnapshot value)
    {
        var detail = value.Diagnostics;
        status.Text = value.Error ?? $"{value.State} · {value.Position:F1} / {value.Duration:F1}s · {detail.Width}×{detail.Height} · {detail.HardwareDecoder} · {detail.VideoOutput} · {detail.SourceTransfer} → {detail.OutputTransfer} · {detail.AudioOutput} {detail.AudioChannels} · dropped {detail.DroppedFrames}";
        if (!timeline.Capture && value.Duration > 0) timeline.Value = (int)Math.Clamp(value.Position / value.Duration * 10000, 0, 10000);
        UpdateTracks(audio, value.Tracks.Where(track => track.Kind == MpvTrackKind.Audio).ToArray(), false);
        UpdateTracks(subtitles, value.Tracks.Where(track => track.Kind == MpvTrackKind.Subtitle).ToArray(), true);
    }

    private void UpdateTracks(ComboBox picker, MpvTrack[] tracks, bool allowOff)
    {
        var choices = tracks.Select(track => new TrackChoice(track.Id, string.IsNullOrEmpty(track.Title) ? $"{track.Id}: {track.Language} {track.Codec}" : track.Title)).ToList();
        if (allowOff) choices.Insert(0, new(null, "Subtitles off"));
        updating = true;
        try
        {
            if (!picker.Items.Cast<TrackChoice>().SequenceEqual(choices)) { picker.Items.Clear(); picker.Items.AddRange(choices.Cast<object>().ToArray()); }
            var selected = tracks.FirstOrDefault(track => track.Selected)?.Id;
            picker.SelectedIndex = choices.FindIndex(choice => choice.Id == selected);
        }
        finally { updating = false; }
    }

    private void ToggleFullscreen()
    {
        if (!fullscreen)
        {
            restoredBounds = Bounds;
            FormBorderStyle = FormBorderStyle.None;
            Bounds = Screen.FromControl(this).Bounds;
        }
        else { FormBorderStyle = FormBorderStyle.Sizable; Bounds = restoredBounds; }
        fullscreen = !fullscreen;
    }

    private sealed record TrackChoice(long? Id, string Label) { public override string ToString() => Label; }
}
