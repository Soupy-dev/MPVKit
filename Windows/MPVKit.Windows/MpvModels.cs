using System.Collections.ObjectModel;
using System.Text.Json.Nodes;

namespace MPVKit.Windows;

public enum MpvPlaybackState { Starting, Idle, Loading, Playing, Paused, Buffering, Ended, Failed, Stopping, Disposed }
public enum MpvHardwareDecoding { Required, Preferred, Software }
public enum MpvHdrMode { Automatic, ToneMapToSdr, RequireHdrDisplay }
public enum MpvScaling { Fast, Balanced, HighQuality }
public enum MpvTrackKind { Video, Audio, Subtitle }

public sealed record MpvPlayerOptions
{
    public string RuntimeDirectory { get; init; } = Path.Combine(AppContext.BaseDirectory, "runtimes", "win-x64", "native");
    public MpvHardwareDecoding HardwareDecoding { get; init; } = MpvHardwareDecoding.Required;
    public MpvHdrMode HdrMode { get; init; } = MpvHdrMode.Automatic;
    public MpvScaling Scaling { get; init; } = MpvScaling.Balanced;
    public bool ExclusiveAudio { get; init; }
    public bool VideoEnabled { get; init; } = true;
    public string AudioDevice { get; init; } = "auto";
    public string AudioChannels { get; init; } = "auto-safe";
    public IReadOnlyList<string> PassthroughCodecs { get; init; } = [];
    public TimeSpan NetworkTimeout { get; init; } = TimeSpan.FromSeconds(20);
    public TimeSpan LoadTimeout { get; init; } = TimeSpan.FromSeconds(45);
    public long MaximumCacheBytes { get; init; } = 128 * 1024 * 1024;
    public SynchronizationContext? CallbackContext { get; init; } = SynchronizationContext.Current;
    public IReadOnlyDictionary<string, string> AdditionalOptions { get; init; } = new ReadOnlyDictionary<string, string>(new Dictionary<string, string>());
}

public sealed record MpvMedia
{
    public required string Source { get; init; }
    public IReadOnlyDictionary<string, string> Headers { get; init; } = new ReadOnlyDictionary<string, string>(new Dictionary<string, string>());
    public bool StartPaused { get; init; }
    public double StartSeconds { get; init; }
}

public sealed record MpvTrack(long Id, MpvTrackKind Kind, string Title, string Language, string Codec,
    bool Selected, bool Default, bool Forced, bool External, string? ExternalFile, int AudioChannels, bool AlbumArt = false);
public sealed record MpvChapter(int Index, string Title, double Seconds);
public sealed record MpvAudioDevice(string Id, string Description);
public sealed record MpvDisplayInfo(bool Verified, bool HdrActive, int BitsPerColor, int ColorSpace,
    float MinimumLuminance, float MaximumLuminance, float MaximumFullFrameLuminance);

public sealed record MpvDiagnostics
{
    public string MpvVersion { get; init; } = "";
    public string FfmpegVersion { get; init; } = "";
    public string VideoOutput { get; init; } = "";
    public string HardwareDecoder { get; init; } = "";
    public string VideoCodec { get; init; } = "";
    public string PixelFormat { get; init; } = "";
    public int Width { get; init; }
    public int Height { get; init; }
    public double FramesPerSecond { get; init; }
    public string SourceTransfer { get; init; } = "";
    public string SourcePrimaries { get; init; } = "";
    public string OutputTransfer { get; init; } = "";
    public string OutputPrimaries { get; init; } = "";
    public MpvDisplayInfo Display { get; init; } = new(false, false, 0, 0, 0, 0, 0);
    public string AudioOutput { get; init; } = "";
    public string AudioCodec { get; init; } = "";
    public string AudioFormat { get; init; } = "";
    public string AudioChannels { get; init; } = "";
    public long DroppedFrames { get; init; }
    public long DecoderDroppedFrames { get; init; }
    public long DelayedFrames { get; init; }
    public double AvSyncSeconds { get; init; }
    public bool SourceIsHdr => SourceTransfer is "pq" or "hlg";
    public bool OutputIsHdr => OutputTransfer is "pq" or "hlg";
    public bool HardwareDecodingActive => HardwareDecoder is not ("" or "no");
    public long StaleEventsDropped { get; init; }
}

public sealed record MpvSnapshot
{
    public long Generation { get; init; }
    public long PlaylistEntryId { get; init; } = -1;
    public MpvPlaybackState State { get; init; } = MpvPlaybackState.Starting;
    public double Position { get; init; }
    public double Duration { get; init; }
    public double Speed { get; init; } = 1;
    public double Volume { get; init; } = 100;
    public bool Muted { get; init; }
    public bool Paused { get; init; }
    public bool Seekable { get; init; }
    public bool Seeking { get; init; }
    public double CacheSeconds { get; init; }
    public int? EndReason { get; init; }
    public string? Error { get; init; }
    public IReadOnlyList<MpvTrack> Tracks { get; init; } = [];
    public IReadOnlyList<MpvChapter> Chapters { get; init; } = [];
    public MpvDiagnostics Diagnostics { get; init; } = new();
}

public sealed record MpvSubtitleStyle
{
    public string Font { get; init; } = "sans-serif";
    public double FontSize { get; init; } = 55;
    public string Color { get; init; } = "#FFFFFFFF";
    public string BorderColor { get; init; } = "#FF000000";
    public string BackgroundColor { get; init; } = "#00000000";
    public double BorderSize { get; init; } = 3;
    public double ShadowOffset { get; init; } = 0;
    public int Position { get; init; } = 100;
    public int MarginY { get; init; } = 22;
    public bool OverrideAss { get; init; }
    public bool Visible { get; init; } = true;
    public double DelaySeconds { get; init; }
}

public sealed record MpvExternalSubtitle
{
    public required string Source { get; init; }
    public string Title { get; init; } = "";
    public string Language { get; init; } = "";
    public IReadOnlyDictionary<string, string> Headers { get; init; } = new ReadOnlyDictionary<string, string>(new Dictionary<string, string>());
}

internal static class MpvJson
{
    public static string Text(this JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : "";
    public static double Number(this JsonNode? node) => node is JsonValue value && value.TryGetValue<double>(out var number) ? number : 0;
    public static long Integer(this JsonNode? node) => node is JsonValue value && value.TryGetValue<long>(out var number) ? number : (long)node.Number();
    public static bool Flag(this JsonNode? node) => node is JsonValue value && value.TryGetValue<bool>(out var flag) && flag;
}
