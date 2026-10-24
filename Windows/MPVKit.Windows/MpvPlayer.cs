using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace MPVKit.Windows;

public sealed partial class MpvPlayer : IAsyncDisposable
{
    private static readonly string[] Observed = [
        "time-pos", "duration", "pause", "paused-for-cache", "speed", "volume", "mute", "seekable", "seeking",
        "demuxer-cache-duration", "track-list", "chapter-list", "hwdec-current", "video-params", "video-target-params",
        "video-codec", "container-fps", "frame-drop-count", "decoder-frame-drop-count", "vo-delayed-frame-count",
        "avsync", "current-vo", "current-ao", "audio-codec-name", "audio-params", "audio-out-params", "vid", "aid", "sid"
    ];
    private static readonly HashSet<string> Protected = new(StringComparer.OrdinalIgnoreCase) {
        "wid", "vo", "gpu-api", "gpu-context", "hwdec", "hwdec-codecs", "hwdec-software-fallback", "ao",
        "config", "input-ipc-server", "input-ipc-client", "idle", "keep-open", "load-scripts", "script",
        "scripts", "playlist", "playlist-pos", "playlist-pos-1", "d3d11-warp", "load-unsafe-playlists",
        "access-references", "target-trc", "target-prim", "target-colorspace-hint", "audio-exclusive", "audio-spdif",
        "profile", "include", "config-dir", "d3d11-output-csp", "file-local-options", "vid"
    };
    private static readonly HashSet<string> SupportedCommands = new(StringComparer.Ordinal) {
        "stop", "seek", "frame-step", "frame-back-step", "set", "cycle", "cycle-values", "add", "multiply", "change-list",
        "screenshot", "screenshot-to-file", "show-text", "expand-text", "sub-step", "sub-seek",
        "ab-loop", "revert-seek", "af", "vf", "print-text"
    };
    private readonly object gate = new();
    private readonly Queue<Action> work = new();
    private readonly AutoResetEvent wake = new(false);
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Dictionary<string, JsonNode?> properties = new(StringComparer.Ordinal);
    private readonly MpvPlayerOptions options;
    private readonly nint window;
    private readonly MpvNative.WakeCallback wakeCallback;
    private MpvNative? native;
    private nint handle;
    private bool closing;
    private bool loaded;
    private bool restarted;
    private bool desiredPause;
    private bool videoDisabledByUser;
    private double? pendingSeek;
    private long activeEntry = -1;
    private long targetEntry = -1;
    private long generation;
    private long staleEvents;
    private long subtitleSelectionEpoch;
    private TaskCompletionSource<MpvDiagnostics>? recovery;
    private bool recoveryReconfigured;
    private int recoveryStage;
    private JsonNode? recoveryTrack;
    private CancellationTokenSource? transitionDeadline;
    private MpvDisplayInfo displayInfo = new(false, false, 0, 0, 0, 0, 0);
    private TaskCompletionSource<long>? loading;
    private CancellationTokenSource mediaCancellation = new();
    private readonly List<string> subtitleFiles = [];
    private readonly HashSet<Task> subtitleOperations = [];
    private MpvSnapshot snapshot = new();
    private int notificationQueued;
    private int resourcesDisposed;
    private long notificationVersion;
    private string mpvVersion = "";
    private string ffmpegVersion = "";
    private readonly ConcurrentQueue<Exception> callbackErrors = new();

    public event EventHandler<MpvSnapshot>? SnapshotChanged;
    public MpvSnapshot Snapshot => Volatile.Read(ref snapshot);
    public Task Ready => ready.Task;
    public IReadOnlyCollection<Exception> CallbackErrors => callbackErrors.ToArray();

    public MpvPlayer(nint videoWindow, MpvPlayerOptions? options = null)
    {
        if (videoWindow == 0) throw new ArgumentException("A live host HWND is required.", nameof(videoWindow));
        window = videoWindow;
        var requested = options ?? new();
        this.options = requested with {
            AdditionalOptions = new System.Collections.ObjectModel.ReadOnlyDictionary<string, string>(new Dictionary<string, string>(requested.AdditionalOptions)),
            PassthroughCodecs = Array.AsReadOnly(requested.PassthroughCodecs.ToArray())
        };
        ValidateOptions(this.options);
        videoDisabledByUser = !this.options.VideoEnabled;
        wakeCallback = _ => wake.Set();
        _ = Task.Factory.StartNew(Run, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }

    private static void ValidateOptions(MpvPlayerOptions value)
    {
        if (!Enum.IsDefined(value.HardwareDecoding) || !Enum.IsDefined(value.HdrMode) || !Enum.IsDefined(value.Scaling))
            throw new ArgumentException("Invalid playback policy.");
        if (value.NetworkTimeout.TotalSeconds is < 1 or > 300 || value.MaximumCacheBytes is < 1048576 or > 1073741824)
            throw new ArgumentOutOfRangeException(nameof(value), "Network timeout must be 1–300 seconds and cache size 1–1024 MiB.");
        if (value.LoadTimeout.TotalSeconds is < 1 or > 300) throw new ArgumentOutOfRangeException(nameof(value.LoadTimeout));
        if (value.PassthroughCodecs.Any(c => c is not ("ac3" or "eac3" or "dts" or "dts-hd" or "truehd")))
            throw new ArgumentException("Unsupported WASAPI passthrough codec.");
        foreach (var pair in value.AdditionalOptions)
        {
            if (IsProtected(pair.Key)) throw new ArgumentException($"Use the typed playback policy for {pair.Key}.");
            ValidateText(pair.Key);
            ValidateText(pair.Value);
        }
    }

    private static string NormalizeProperty(string name) => name switch {
        "sub" => "sid", "video" => "vid", "audio" => "aid",
        "vd-lavc-software-fallback" => "hwdec-software-fallback", _ => name
    };

    private static bool IsProtected(string name)
    {
        name = NormalizeProperty(name);
        if (name.StartsWith("no-", StringComparison.OrdinalIgnoreCase)) name = name[3..];
        if (Protected.Contains(name) || name.StartsWith("options/", StringComparison.OrdinalIgnoreCase) || name.StartsWith("file-local-options/", StringComparison.OrdinalIgnoreCase)) return true;
        foreach (var suffix in new[] { "-add", "-append", "-clr", "-del", "-remove", "-set", "-pre", "-toggle" })
            if (name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) && Protected.Contains(name[..^suffix.Length])) return true;
        return false;
    }

    internal static void ValidateText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (text.Length > 32768 || text.Contains('\0')) throw new ArgumentException("Text contains NUL or exceeds 32 KiB.");
    }

    private static void Finite(double value, double min, double max, string name)
    {
        if (!double.IsFinite(value) || value < min || value > max) throw new ArgumentOutOfRangeException(name);
    }

    private void Run()
    {
        try
        {
            native = new(options.RuntimeDirectory);
            handle = native.Create();
            if (handle == 0) throw new InvalidOperationException("mpv_create failed.");
            Configure();
            native.Check(native.Initialize(handle), "Initialize libmpv");
            native.SetWake(handle, wakeCallback, 0);
            mpvVersion = Get("mpv-version").Text();
            ffmpegVersion = Get("ffmpeg-version").Text();
            Publish(new() { State = MpvPlaybackState.Idle, Diagnostics = EngineDiagnostics() });
            ready.TrySetResult();
            while (true)
            {
                DrainEvents();
                Action? action;
                lock (gate)
                {
                    if (closing) break;
                    action = work.Count == 0 ? null : work.Dequeue();
                }
                if (action is not null) action();
                else wake.WaitOne();
            }
        }
        catch (Exception error)
        {
            ready.TrySetException(error);
            loading?.TrySetException(error);
            Publish(Snapshot with { State = MpvPlaybackState.Failed, Error = error.Message });
        }
        finally
        {
            lock (gate) closing = true;
            mediaCancellation.Cancel();
            transitionDeadline?.Cancel();
            transitionDeadline?.Dispose();
            loading?.TrySetException(new ObjectDisposedException(nameof(MpvPlayer)));
            recovery?.TrySetException(new ObjectDisposedException(nameof(MpvPlayer)));
            if (native is not null && handle != 0)
            {
                native.SetWake(handle, null, 0);
                native.Destroy(handle);
                handle = 0;
            }
            native?.Dispose();
            Action[] abandoned;
            lock (gate) { abandoned = work.ToArray(); work.Clear(); }
            foreach (var action in abandoned) action();
            DeleteSubtitleFiles();
            Publish(Snapshot with { State = MpvPlaybackState.Disposed });
            stopped.TrySetResult();
        }
    }

    private void Configure()
    {
        var settings = new Dictionary<string, string> {
            ["config"] = "no", ["load-scripts"] = "no", ["osc"] = "no", ["input-default-bindings"] = "no",
            ["input-vo-keyboard"] = "no", ["input-cursor"] = "no", ["terminal"] = "no", ["msg-level"] = "all=no",
            ["idle"] = "yes", ["keep-open"] = "no", ["vo"] = "gpu-next", ["gpu-api"] = "d3d11",
            ["gpu-context"] = "d3d11", ["d3d11-warp"] = "no", ["wid"] = window.ToInt64().ToString(CultureInfo.InvariantCulture),
            ["hwdec"] = options.HardwareDecoding == MpvHardwareDecoding.Software ? "no" : "d3d11va",
            ["hwdec-codecs"] = "all", ["hwdec-software-fallback"] = options.HardwareDecoding == MpvHardwareDecoding.Required ? "no" : "yes",
            ["vid"] = options.VideoEnabled ? "auto" : "no",
            ["ao"] = "wasapi", ["audio-device"] = options.AudioDevice, ["audio-exclusive"] = options.ExclusiveAudio ? "yes" : "no",
            ["audio-channels"] = options.AudioChannels,
            ["audio-spdif"] = string.Join(',', options.PassthroughCodecs), ["video-sync"] = "audio",
            ["target-colorspace-hint"] = "auto", ["network-timeout"] = options.NetworkTimeout.TotalSeconds.ToString(CultureInfo.InvariantCulture),
            ["demuxer-max-bytes"] = options.MaximumCacheBytes.ToString(CultureInfo.InvariantCulture),
            ["demuxer-max-back-bytes"] = (options.MaximumCacheBytes / 4).ToString(CultureInfo.InvariantCulture),
            ["cache"] = "auto", ["save-position-on-quit"] = "no", ["resume-playback"] = "no", ["sub-auto"] = "no",
            ["audio-file-auto"] = "no", ["ytdl"] = "no", ["access-references"] = "yes", ["load-unsafe-playlists"] = "no", ["tls-verify"] = "yes"
        };
        if (options.Scaling == MpvScaling.Fast) settings["profile"] = "fast";
        if (options.Scaling == MpvScaling.HighQuality) settings["profile"] = "high-quality";
        if (options.HdrMode == MpvHdrMode.ToneMapToSdr)
        {
            settings["target-trc"] = "srgb";
            settings["target-prim"] = "bt.709";
            settings["d3d11-output-csp"] = "srgb";
        }
        foreach (var pair in options.AdditionalOptions) settings[pair.Key] = pair.Value;
        foreach (var pair in settings) native!.Check(native!.SetOption(handle, pair.Key, pair.Value), $"Set {pair.Key}");
    }

    private Task<T> Invoke<T>(Func<T> function, CancellationToken cancellation = default)
    {
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate)
        {
            if (closing) return Task.FromException<T>(new ObjectDisposedException(nameof(MpvPlayer)));
            if (work.Count >= 128) return Task.FromException<T>(new InvalidOperationException("The bounded player command queue is full."));
            work.Enqueue(() => {
                if (closing) completion.TrySetException(new ObjectDisposedException(nameof(MpvPlayer)));
                else if (cancellation.IsCancellationRequested) completion.TrySetCanceled(cancellation);
                else
                {
                    try { completion.TrySetResult(function()); }
                    catch (Exception error) { completion.TrySetException(error); }
                }
            });
        }
        wake.Set();
        return completion.Task;
    }

    private Task Invoke(Action function, CancellationToken cancellation = default) => Invoke(() => { function(); return true; }, cancellation);

    public async Task<long> LoadAsync(MpvMedia media, CancellationToken cancellation = default)
    {
        ArgumentNullException.ThrowIfNull(media);
        ValidateSource(media.Source);
        Finite(media.StartSeconds, 0, double.MaxValue, nameof(media.StartSeconds));
        var headers = ValidateHeaders(media.Headers);
        var load = await Invoke(() => {
            CancelRecovery(true);
            loading?.TrySetException(new OperationCanceledException("Superseded by a new media load."));
            recovery?.TrySetException(new OperationCanceledException("Decoder recovery was superseded by a new media load."));
            recovery = null;
            recoveryStage = 0;
            mediaCancellation.Cancel();
            mediaCancellation.Dispose();
            mediaCancellation = new();
            Unobserve();
            properties.Clear();
            externalSubtitleSources.Clear();
            externalSubtitleKeys.Clear();
            loaded = restarted = false;
            desiredPause = media.StartPaused;
            pendingSeek = null;
            targetEntry = -1;
            generation++;
            subtitleSelectionEpoch++;
            loading = new(TaskCreationOptions.RunContinuationsAsynchronously);
            Publish(new() { Generation = generation, State = MpvPlaybackState.Loading, Paused = media.StartPaused,
                Diagnostics = EngineDiagnostics() });
            try
            {
                var perFile = new Dictionary<string, object?> {
                    ["http-header-fields-clr"] = "",
                    ["pause"] = media.StartPaused ? "yes" : "no",
                    ["start"] = media.StartSeconds == 0 ? "none" : media.StartSeconds.ToString(CultureInfo.InvariantCulture)
                };
                if (headers.Length > 0) perFile["http-header-fields-append"] = string.Join("\r\n", headers);
                var result = Execute(new object?[] { "loadfile", NormalizeSource(media.Source), "replace", -1, perFile });
                targetEntry = result?["playlist_entry_id"].Integer() ?? -1;
                if (targetEntry < 0) throw new InvalidDataException("libmpv did not return a load identity.");
                Publish(Snapshot with { PlaylistEntryId = targetEntry });
            }
            catch (Exception error) { Fail(error); }
            return (Task: loading.Task, Generation: generation);
        }, cancellation).ConfigureAwait(false);
        try { return await load.Task.WaitAsync(options.LoadTimeout, cancellation).ConfigureAwait(false); }
        catch (Exception error) when (error is TimeoutException || error is OperationCanceledException && cancellation.IsCancellationRequested)
        {
            await Invoke(() => { if (generation == load.Generation) StopCore(); }).ConfigureAwait(false);
            throw;
        }
    }

    internal static string NormalizeSource(string source) => Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.IsFile
        ? uri.LocalPath : Uri.TryCreate(source, UriKind.Absolute, out uri) && uri.Scheme is "https" or "http" ? source : Path.GetFullPath(source);

    internal static void ValidateSource(string source)
    {
        ValidateText(source);
        if (string.IsNullOrWhiteSpace(source)) throw new ArgumentException("A media source is required.");
        if (Uri.TryCreate(source, UriKind.Absolute, out var uri) && !uri.IsFile && uri.Scheme is not ("http" or "https"))
            throw new NotSupportedException("Use a local file, HTTP, or HTTPS source.");
    }

    internal static string[] ValidateHeaders(IReadOnlyDictionary<string, string> headers)
    {
        if (headers.Count > 64) throw new ArgumentException("At most 64 request headers are supported.");
        return headers.Select(pair => {
            if (string.IsNullOrEmpty(pair.Key) || pair.Key.Any(c => !char.IsAsciiLetterOrDigit(c) && !"!#$%&'*+-.^_`|~".Contains(c)) ||
                pair.Value.Any(c => c < 32 && c != '\t' || c == 127) || pair.Value.Length > 16384)
                throw new ArgumentException("Invalid request header.");
            return pair.Key + ": " + pair.Value;
        }).ToArray();
    }

    public Task PlayAsync() => Invoke(() => { desiredPause = false; Set("pause", false); });
    public Task PauseAsync() => Invoke(() => { desiredPause = true; Set("pause", true); });
    public Task StopAsync() => Invoke(StopCore);
    private void StopCore()
    {
        CancelRecovery(true);
        mediaCancellation.Cancel();
        loading?.TrySetCanceled();
        recovery?.TrySetCanceled();
        recoveryStage = 0;
        loaded = restarted = false;
        targetEntry = -1;
        Unobserve();
        Execute(new object[] { "stop" });
        properties.Clear();
        Publish(new() { Generation = generation, State = MpvPlaybackState.Idle, Diagnostics = EngineDiagnostics() });
    }

    public Task SeekAsync(double seconds, bool relative = false)
    {
        Finite(seconds, relative ? -double.MaxValue : 0, double.MaxValue, nameof(seconds));
        return Invoke(() => {
            CancelRecovery();
            if (!loaded)
            {
                pendingSeek = relative ? Math.Max(0, (pendingSeek ?? Snapshot.Position) + seconds) : seconds;
                return;
            }
            Execute(new[] { "seek", seconds.ToString(CultureInfo.InvariantCulture), relative ? "relative+exact" : "absolute+exact" });
        });
    }
    public Task SetSpeedAsync(double speed) { Finite(speed, 0.01, 100, nameof(speed)); return SetPropertyAsync("speed", speed); }
    public Task SetVolumeAsync(double volume) { Finite(volume, 0, 100, nameof(volume)); return SetPropertyAsync("volume", volume); }
    public Task SetMutedAsync(bool muted) => SetPropertyAsync("mute", muted);
    public Task SetAudioDelayAsync(double seconds) { Finite(seconds, -100, 100, nameof(seconds)); return SetPropertyAsync("audio-delay", seconds); }
    public Task SetAudioFilterAsync(string chain) => SetPropertyAsync("af", chain);
    public Task SetVideoFilterAsync(string chain) => SetPropertyAsync("vf", chain);
    public Task SetAudioDeviceAsync(string device) => SetPropertyAsync("audio-device", device);
    public Task<MpvDisplayInfo> RefreshDisplayAsync() => Invoke(() => {
        displayInfo = native!.GetDisplay(window);
        UpdateSnapshot();
        ValidatePipeline();
        return displayInfo;
    });

    public async Task<MpvDiagnostics> RecoverVideoAfterResumeAsync(CancellationToken cancellation = default)
    {
        var pending = await Invoke(() => {
            if (!loaded || !restarted || Snapshot.Diagnostics.Width == 0)
                throw new InvalidOperationException("Decoder recovery requires a loaded video.");
            if (recovery is not null && !recovery.Task.IsCompleted) return recovery.Task;
            return BeginVideoTransition(Get("vid")!);
        }, cancellation).ConfigureAwait(false);
        return await AwaitVideoTransition(pending, cancellation).ConfigureAwait(false);
    }

    private Task<MpvDiagnostics> BeginVideoTransition(object selection)
    {
        CancelRecovery(true);
        recovery = new(TaskCreationOptions.RunContinuationsAsynchronously);
        recoveryReconfigured = false;
        recoveryStage = 1;
        recoveryTrack = System.Text.Json.JsonSerializer.SerializeToNode(selection);
        restarted = false;
        native!.Check(native.ObserveProperty(handle, ((ulong)generation << 8) | 250, "video-frame-info", 6), "Observe video transition");
        Set("vid", "no");
        if (Get("video-params") is null && Get("video-frame-info") is null)
        {
            recoveryStage = 2;
            Set("vid", recoveryTrack);
        }
        transitionDeadline = new();
        _ = WatchVideoTransition(generation, recovery.Task, transitionDeadline.Token);
        return recovery.Task;
    }

    private async Task WatchVideoTransition(long identity, Task<MpvDiagnostics> transition, CancellationToken cancellation)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(10), cancellation).ConfigureAwait(false);
            await Invoke(() => {
                if (identity == generation && ReferenceEquals(recovery?.Task, transition) && recoveryStage != 0)
                    Fail(new TimeoutException("The requested video output did not produce a current hardware frame within ten seconds."));
            }, cancellation).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
    }

    private async Task<MpvDiagnostics> AwaitVideoTransition(Task<MpvDiagnostics> pending, CancellationToken cancellation)
    {
        try { return await pending.WaitAsync(TimeSpan.FromSeconds(10), cancellation).ConfigureAwait(false); }
        catch (Exception error) when (error is TimeoutException || error is OperationCanceledException && cancellation.IsCancellationRequested)
        {
            await Invoke(() => { if (ReferenceEquals(recovery?.Task, pending)) CancelRecovery(); }).ConfigureAwait(false);
            throw;
        }
    }

    private void CancelRecovery(bool abandoningLoad = false)
    {
        if (recoveryStage == 0) return;
        if (recoveryStage == 1) Set("vid", recoveryTrack);
        recovery?.TrySetException(new OperationCanceledException("Decoder reconstruction was superseded."));
        if (abandoningLoad)
        {
            native!.UnobserveProperty(handle, ((ulong)generation << 8) | 250);
            recoveryStage = 0;
            transitionDeadline?.Cancel();
            transitionDeadline?.Dispose();
            transitionDeadline = null;
        }
        else
        {
            recoveryStage = 2;
            restarted = false;
            TryCompleteRecovery();
        }
    }

    public Task SelectTrackAsync(MpvTrackKind kind, long? id, bool automatic = false)
    {
        if (!Enum.IsDefined(kind) || id < 0) throw new ArgumentOutOfRangeException(nameof(id));
        var property = kind switch { MpvTrackKind.Video => "vid", MpvTrackKind.Audio => "aid", _ => "sid" };
        if (kind == MpvTrackKind.Video && (automatic || id is not null))
            return SelectVideoAsync(automatic ? "auto" : id!.Value);
        return Invoke(() => {
            if (kind == MpvTrackKind.Subtitle) subtitleSelectionEpoch++;
            if (kind == MpvTrackKind.Video) { CancelRecovery(true); restarted = loaded; }
            if (kind == MpvTrackKind.Video) videoDisabledByUser = !automatic && id is null;
            Set(property, automatic ? "auto" : id is { } number ? (object)number : "no");
        });
    }

    private async Task SelectVideoAsync(object selection)
    {
        var pending = await Invoke(() => {
            if (!loaded) throw new InvalidOperationException("Load media before choosing a video track.");
            videoDisabledByUser = false;
            return BeginVideoTransition(selection);
        }).ConfigureAwait(false);
        await AwaitVideoTransition(pending, CancellationToken.None).ConfigureAwait(false);
    }

    public Task<JsonNode?> GetPropertyAsync(string name)
    {
        ValidateText(name);
        return Invoke(() => Get(name));
    }

    public Task SetPropertyAsync(string name, object value)
    {
        name = NormalizeProperty(name);
        ValidateText(name);
        if (IsProtected(name)) throw new ArgumentException($"The playback policy owns {name}.");
        var copy = System.Text.Json.JsonSerializer.SerializeToNode(value);
        using (var arena = new MpvArena()) arena.Create(copy);
        return Invoke(() => {
            if (name is "sid" or "secondary-sid") subtitleSelectionEpoch++;
            if (name == "vid") CancelRecovery();
            Set(name, copy);
            if (name == "vid") videoDisabledByUser = Get("vid").Text() == "no";
            if (name == "pause") desiredPause = Get("pause").Flag();
        });
    }

    public Task CommandAsync(params string[] arguments)
    {
        if (arguments.Length is < 1 or > 128) throw new ArgumentException("Supply 1–128 command arguments.");
        foreach (var argument in arguments) ValidateText(argument);
        arguments = arguments.ToArray();
        if (arguments.Length > 1 && arguments[0] is "set" or "cycle" or "cycle-values" or "add" or "multiply" or "change-list") arguments[1] = NormalizeProperty(arguments[1]);
        if (!SupportedCommands.Contains(arguments[0]))
            throw new ArgumentException("This command is not exposed by the managed playback contract. Use the typed load, track, subtitle, or lifetime APIs.");
        if (arguments[0] is "set" or "cycle" or "cycle-values" or "add" or "multiply" or "change-list" && arguments.Length > 1 && IsProtected(arguments[1]))
            throw new ArgumentException("The command would replace the typed playback policy.");
        if (arguments[0] == "stop") return StopAsync();
        var copy = arguments.ToArray();
        return Invoke(() => {
            if (copy[0] is "seek" or "frame-step" or "frame-back-step" or "revert-seek" or "sub-seek" || copy.Length > 1 && copy[1] == "vid") CancelRecovery();
            if (copy[0] is "sub-remove" or "sub-reload" || copy.Length > 1 && copy[1] is "sid" or "secondary-sid") subtitleSelectionEpoch++;
            Execute(copy);
            if (copy.Length > 1 && copy[1] == "vid") videoDisabledByUser = Get("vid").Text() == "no";
            if (copy.Length > 1 && copy[1] == "pause") desiredPause = Get("pause").Flag();
        });
    }

    public Task ApplySubtitleStyleAsync(MpvSubtitleStyle style)
    {
        ArgumentNullException.ThrowIfNull(style);
        Finite(style.FontSize, 1, 500, nameof(style.FontSize));
        Finite(style.BorderSize, 0, 20, nameof(style.BorderSize));
        Finite(style.ShadowOffset, 0, 20, nameof(style.ShadowOffset));
        Finite(style.DelaySeconds, -86400, 86400, nameof(style.DelaySeconds));
        if (style.Position is < 0 or > 150 || style.MarginY is < 0 or > 1000) throw new ArgumentOutOfRangeException(nameof(style));
        return Invoke(() => {
            Set("sub-font", style.Font); Set("sub-font-size", style.FontSize); Set("sub-color", style.Color);
            Set("sub-border-color", style.BorderColor); Set("sub-back-color", style.BackgroundColor);
            Set("sub-border-size", style.BorderSize); Set("sub-shadow-offset", style.ShadowOffset);
            Set("sub-pos", style.Position); Set("sub-margin-y", style.MarginY);
            Set("sub-ass-override", style.OverrideAss ? "force" : "yes");
            Set("sub-visibility", style.Visible); Set("sub-delay", style.DelaySeconds);
        });
    }

    public Task<IReadOnlyList<MpvAudioDevice>> GetAudioDevicesAsync() => Invoke<IReadOnlyList<MpvAudioDevice>>(() =>
        Array.AsReadOnly((Get("audio-device-list") as JsonArray ?? []).Select(item =>
            new MpvAudioDevice(item?["name"].Text() ?? "", item?["description"].Text() ?? "")).ToArray()));

    private JsonNode? Execute(object arguments)
    {
        using var arena = new MpvArena();
        var node = arena.Create(arguments);
        native!.Check(native.Execute(handle, ref node, out var result), "mpv command");
        try { return MpvArena.Read(result); }
        finally { native.Free(ref result); }
    }

    private JsonNode? Get(string name)
    {
        var status = native!.GetProperty(handle, name, 6, out var node);
        if (status is -10 or -8) return null;
        native.Check(status, $"Read {name}");
        try { return MpvArena.Read(node); }
        finally { native.Free(ref node); }
    }

    private void Set(string name, object? value)
    {
        using var arena = new MpvArena();
        var node = arena.Create(value);
        native!.Check(native.SetProperty(handle, name, 6, ref node), $"Set {name}");
    }

    private void Unobserve()
    {
        for (var index = 0; index < Observed.Length; index++)
            native!.UnobserveProperty(handle, ((ulong)generation << 8) | (uint)(index + 1));
        native!.UnobserveProperty(handle, ((ulong)generation << 8) | 250);
    }

    private void DrainEvents()
    {
        for (var count = 0; count < 256; count++)
        {
            var value = Marshal.PtrToStructure<MpvEvent>(native!.Wait(handle, 0));
            if (value.Id == 0) return;
            if (value.Id == 24) throw new InvalidOperationException("The libmpv event queue overflowed; playback identity is no longer reliable.");
            if (value.Id == 1) { lock (gate) closing = true; return; }
            if (value.Id == 6)
            {
                activeEntry = Marshal.ReadInt64(value.Data);
                if (activeEntry != targetEntry) staleEvents++;
            }
            else if (value.Id == 7) HandleEnd(Marshal.PtrToStructure<MpvEndEvent>(value.Data));
            else if (activeEntry != targetEntry || targetEntry < 0) { staleEvents++; }
            else if (value.Id == 8)
            {
                loaded = true;
                displayInfo = native.GetDisplay(window);
                DeleteSubtitleFiles();
                Set("pause", desiredPause);
                if (pendingSeek is { } seconds)
                {
                    Execute(new[] { "seek", seconds.ToString(CultureInfo.InvariantCulture), "absolute+exact" });
                    pendingSeek = null;
                }
                for (var index = 0; index < Observed.Length; index++)
                {
                    native.Check(native.ObserveProperty(handle, ((ulong)generation << 8) | (uint)(index + 1), Observed[index], 6), "Observe playback");
                    properties[Observed[index]] = Get(Observed[index]);
                }
                UpdateSnapshot();
            }
            else if (value.Id == 22 && loaded)
            {
                if ((long)(value.UserData >> 8) != generation) { staleEvents++; continue; }
                if ((value.UserData & 0xff) == 250) { TryCompleteRecovery(); continue; }
                var property = Marshal.PtrToStructure<MpvPropertyEvent>(value.Data);
                var index = (int)(value.UserData & 0xff) - 1;
                if (index < 0 || index >= Observed.Length) continue;
                properties[Observed[index]] = property.Format == 6 && property.Data != 0
                    ? MpvArena.Read(Marshal.PtrToStructure<MpvNode>(property.Data)) : null;
                if (Observed[index] == "video-target-params") displayInfo = native.GetDisplay(window);
                UpdateSnapshot();
                ValidatePipeline();
                TryCompleteLoad();
            }
            else if (value.Id == 21 && loaded)
            {
                restarted = true;
                foreach (var name in Observed) properties[name] = Get(name);
                UpdateSnapshot();
                ValidatePipeline();
                TryCompleteLoad();
                TryCompleteRecovery();
            }
            else if (value.Id == 17 && loaded && recoveryStage != 0)
            {
                var width = Get("video-params")?["w"].Integer() ?? 0;
                if (recoveryStage == 1 && width == 0 && Get("video-frame-info") is null)
                {
                    recoveryStage = 2;
                    Set("vid", recoveryTrack);
                }
                else if (recoveryStage == 2 && width > 0) { recoveryReconfigured = true; TryCompleteRecovery(); }
            }
        }
        wake.Set();
    }

    private void TryCompleteRecovery()
    {
        if (recoveryStage != 2 || !recoveryReconfigured || Get("video-frame-info") is null) return;
        foreach (var name in Observed) properties[name] = Get(name);
        restarted = true;
        UpdateSnapshot();
        recoveryStage = 0;
        transitionDeadline?.Cancel();
        transitionDeadline?.Dispose();
        transitionDeadline = null;
        native!.UnobserveProperty(handle, ((ulong)generation << 8) | 250);
        ValidatePipeline();
        if (Snapshot.State != MpvPlaybackState.Failed) recovery?.TrySetResult(Snapshot.Diagnostics);
    }

    private void TryCompleteLoad()
    {
        if (!loaded || !restarted || Snapshot.State == MpvPlaybackState.Failed) return;
        if (!Snapshot.Tracks.Any(track => track.Kind is MpvTrackKind.Video or MpvTrackKind.Audio)) return;
        var expectsVideo = !videoDisabledByUser && Snapshot.Tracks.Any(track => track.Kind == MpvTrackKind.Video && !track.AlbumArt);
        if (expectsVideo && Snapshot.Diagnostics.Width == 0) return;
        loading?.TrySetResult(generation);
    }

    private MpvDiagnostics EngineDiagnostics() => new() { MpvVersion = mpvVersion, FfmpegVersion = ffmpegVersion, Display = displayInfo };

    private void HandleEnd(MpvEndEvent end)
    {
        if (end.EntryId != targetEntry || targetEntry < 0) { staleEvents++; return; }
        if (Snapshot.State == MpvPlaybackState.Failed) return;
        if (end.Reason == 5)
        {
            if (end.InsertCount == 1) { targetEntry = end.InsertId; Publish(Snapshot with { PlaylistEntryId = targetEntry }); return; }
            Fail(new NotSupportedException("A media source expanded into a multi-entry playlist. Load individual items explicitly."));
            return;
        }
        if (end.Reason == 4) Fail(new MpvException("Load media", end.Error, "libmpv rejected the source or its selected playback pipeline"));
        else
        {
            loading?.TrySetException(new InvalidOperationException("Media ended before playback was ready."));
            loaded = restarted = false;
            Publish(Snapshot with { State = end.Reason == 0 ? MpvPlaybackState.Ended : MpvPlaybackState.Idle, EndReason = end.Reason });
        }
    }

    private void ValidatePipeline()
    {
        if (!restarted || !loaded || recoveryStage != 0 || Snapshot.State == MpvPlaybackState.Failed) return;
        var diagnostics = Snapshot.Diagnostics;
        var expectsVideo = !videoDisabledByUser && Snapshot.Tracks.Any(track => track.Kind == MpvTrackKind.Video && !track.AlbumArt);
        if (expectsVideo && options.HardwareDecoding == MpvHardwareDecoding.Required && diagnostics.HardwareDecoder != "d3d11va")
        {
            Fail(new NotSupportedException("This video did not activate D3D11 hardware decoding. Software fallback is disabled."));
            return;
        }
        if (diagnostics.Width > 0 && options.HdrMode == MpvHdrMode.RequireHdrDisplay && diagnostics.SourceIsHdr &&
            (!diagnostics.Display.HdrActive || !diagnostics.OutputIsHdr))
            Fail(new NotSupportedException("HDR output was required but the active output is SDR. Enable Windows HDR on a capable display or choose tone mapping."));
        var audioCodec = diagnostics.AudioCodec == "dca" ? "dts" : diagnostics.AudioCodec;
        var passthroughRequested = options.PassthroughCodecs.Contains(audioCodec) || audioCodec == "dts" && options.PassthroughCodecs.Contains("dts-hd");
        if (passthroughRequested && !diagnostics.AudioFormat.StartsWith("spdif-", StringComparison.Ordinal))
            Fail(new NotSupportedException("The selected WASAPI endpoint did not activate the requested encoded audio passthrough."));
    }

    private void Fail(Exception error)
    {
        loading?.TrySetException(error);
        recovery?.TrySetException(error);
        recoveryStage = 0;
        native!.UnobserveProperty(handle, ((ulong)generation << 8) | 250);
        transitionDeadline?.Cancel();
        transitionDeadline?.Dispose();
        transitionDeadline = null;
        restarted = false;
        Publish(Snapshot with { State = MpvPlaybackState.Failed, Error = error.Message });
        Execute(new object[] { "stop" });
    }

    private JsonNode? Property(string key) => properties.GetValueOrDefault(key);

    private void UpdateSnapshot()
    {
        if (Snapshot.State == MpvPlaybackState.Failed) return;
        var video = Property("video-params");
        var output = Property("video-target-params");
        var audio = Property("audio-out-params");
        var tracks = (Property("track-list") as JsonArray ?? []).Take(1024).Where(item => item?["type"].Text() is "video" or "audio" or "sub")
            .Select(item => new MpvTrack(item!["id"].Integer(), item["type"].Text() switch { "video" => MpvTrackKind.Video, "audio" => MpvTrackKind.Audio, _ => MpvTrackKind.Subtitle },
                item["title"].Text(), item["lang"].Text(), item["codec"].Text(), item["selected"].Flag(), item["default"].Flag(),
                item["forced"].Flag(), item["external"].Flag(), item["external-filename"].Text(), (int)item["audio-channels"].Integer(), item["albumart"].Flag())).ToArray();
        var chapters = (Property("chapter-list") as JsonArray ?? []).Take(4096)
            .Select((item, index) => new MpvChapter(index, item?["title"].Text() ?? "", item?["time"].Number() ?? 0)).ToArray();
        var paused = Property("pause").Flag();
        Publish(Snapshot with {
            State = !restarted ? MpvPlaybackState.Loading : Property("paused-for-cache").Flag() ? MpvPlaybackState.Buffering : paused ? MpvPlaybackState.Paused : MpvPlaybackState.Playing,
            Position = Property("time-pos") is { } position ? position.Number() : Snapshot.Position, Duration = Property("duration").Number(), Paused = paused,
            Speed = Property("speed").Number(), Volume = Property("volume").Number(), Muted = Property("mute").Flag(),
            Seekable = Property("seekable").Flag(), Seeking = Property("seeking").Flag(), CacheSeconds = Property("demuxer-cache-duration").Number(),
            Tracks = Array.AsReadOnly(tracks), Chapters = Array.AsReadOnly(chapters),
            Diagnostics = Snapshot.Diagnostics with {
                Display = displayInfo,
                MpvVersion = mpvVersion, FfmpegVersion = ffmpegVersion,
                VideoOutput = Property("current-vo").Text(), HardwareDecoder = Property("hwdec-current").Text(),
                VideoCodec = Property("video-codec").Text(), PixelFormat = video?["pixelformat"].Text() ?? "",
                Width = (int)(video?["w"].Integer() ?? 0), Height = (int)(video?["h"].Integer() ?? 0), FramesPerSecond = Property("container-fps").Number(),
                SourceTransfer = video?["gamma"].Text() ?? "", SourcePrimaries = video?["primaries"].Text() ?? "",
                OutputTransfer = output?["gamma"].Text() ?? "", OutputPrimaries = output?["primaries"].Text() ?? "",
                AudioOutput = Property("current-ao").Text(), AudioCodec = Property("audio-codec-name").Text(),
                AudioFormat = audio?["format"].Text() ?? "", AudioChannels = audio?["channels"].Text() ?? "",
                DroppedFrames = Property("frame-drop-count").Integer(), DecoderDroppedFrames = Property("decoder-frame-drop-count").Integer(),
                DelayedFrames = Property("vo-delayed-frame-count").Integer(), AvSyncSeconds = Property("avsync").Number(), StaleEventsDropped = staleEvents
            }
        });
    }

    private void Publish(MpvSnapshot value)
    {
        Volatile.Write(ref snapshot, value);
        if (SnapshotChanged is null) return;
        Interlocked.Increment(ref notificationVersion);
        if (Interlocked.Exchange(ref notificationQueued, 1) != 0) return;
        DispatchNotification();
    }

    private void DispatchNotification()
    {
        void Deliver(object? _)
        {
            var version = Interlocked.Read(ref notificationVersion);
            var current = Snapshot;
            if (current.State != MpvPlaybackState.Disposed)
                foreach (EventHandler<MpvSnapshot> subscriber in SnapshotChanged?.GetInvocationList() ?? [])
                    try { subscriber(this, current); }
                    catch (Exception error) { callbackErrors.Enqueue(error); while (callbackErrors.Count > 16) callbackErrors.TryDequeue(out var ignored); }
            Interlocked.Exchange(ref notificationQueued, 0);
            if (version != Interlocked.Read(ref notificationVersion) && Interlocked.Exchange(ref notificationQueued, 1) == 0) DispatchNotification();
        }
        try
        {
            if (options.CallbackContext is { } context) context.Post(Deliver, null);
            else ThreadPool.QueueUserWorkItem(Deliver);
        }
        catch (Exception error)
        {
            callbackErrors.Enqueue(error);
            while (callbackErrors.Count > 16) callbackErrors.TryDequeue(out var ignored);
            Interlocked.Exchange(ref notificationQueued, 0);
        }
    }

    private void DeleteSubtitleFiles()
    {
        foreach (var path in subtitleFiles.ToArray())
            try { File.Delete(path); subtitleFiles.Remove(path); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
    }

    public async ValueTask DisposeAsync()
    {
        lock (gate)
        {
            if (!closing) { closing = true; wake.Set(); }
        }
        await stopped.Task.ConfigureAwait(false);
        Task[] pending;
        lock (subtitleOperations) pending = subtitleOperations.ToArray();
        await Task.WhenAll(pending.Select(async task => { try { await task.ConfigureAwait(false); } catch (Exception) { } })).ConfigureAwait(false);
        if (Interlocked.Exchange(ref resourcesDisposed, 1) == 0)
        {
            subtitleCache.Dispose();
            mediaCancellation.Dispose();
            wake.Dispose();
        }
        GC.KeepAlive(wakeCallback);
    }
}
