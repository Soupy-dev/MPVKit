using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace MPVKit.Windows;

public sealed partial class MpvPlayer
{
    private readonly MpvSubtitleCache subtitleCache = new();
    private readonly Dictionary<long, string> externalSubtitleSources = [];
    private readonly Dictionary<string, long> externalSubtitleKeys = [];

    public Task PrefetchSubtitlesAsync(IReadOnlyList<MpvExternalSubtitle> subtitles, CancellationToken cancellation = default) =>
        TrackSubtitleOperation(() => PrepareSubtitles(subtitles, false, false, cancellation));

    public Task LoadExternalSubtitlesAsync(IReadOnlyList<MpvExternalSubtitle> subtitles, bool selectFirst = true, CancellationToken cancellation = default) =>
        TrackSubtitleOperation(() => PrepareSubtitles(subtitles, true, selectFirst, cancellation));

    public Task<string?> GetCurrentExternalSubtitleAsync() => Invoke(() =>
        externalSubtitleSources.GetValueOrDefault(Get("sid").Integer()));

    private Task TrackSubtitleOperation(Func<Task> operation)
    {
        Task task;
        lock (subtitleOperations)
        {
            if (subtitleOperations.Count >= 16) return Task.FromException(new InvalidOperationException("The subtitle preparation queue is full."));
            task = operation();
            subtitleOperations.Add(task);
        }
        _ = task.ContinueWith(completed => { lock (subtitleOperations) subtitleOperations.Remove(completed); },
            CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        return task;
    }

    private async Task PrepareSubtitles(IReadOnlyList<MpvExternalSubtitle> subtitles, bool attach, bool selectFirst, CancellationToken cancellation)
    {
        if (subtitles.Count is < 1 or > 16) throw new ArgumentException("Supply 1–16 subtitles per batch.");
        var requests = subtitles.Select(subtitle => {
            ValidateSource(subtitle.Source);
            ValidateText(subtitle.Title);
            ValidateText(subtitle.Language);
            ValidateHeaders(subtitle.Headers);
            return subtitle with { Headers = new Dictionary<string, string>(subtitle.Headers) };
        }).ToArray();
        var identity = await Invoke(() => {
            if (targetEntry < 0) throw new InvalidOperationException("Load media before preparing its subtitles.");
            if (attach && selectFirst) subtitleSelectionEpoch++;
            return (Generation: generation, Selection: subtitleSelectionEpoch, Token: mediaCancellation.Token, Load: loading!.Task);
        }, cancellation).ConfigureAwait(false);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, identity.Token);
        var prepared = await Task.WhenAll(requests.Select(request => subtitleCache.PrepareAsync(request, linked.Token))).ConfigureAwait(false);
        if (!attach) return;
        await identity.Load.WaitAsync(linked.Token).ConfigureAwait(false);
        await Invoke(() => {
            linked.Token.ThrowIfCancellationRequested();
            if (identity.Generation != generation || !loaded) throw new OperationCanceledException("The subtitle load was superseded.");
            var select = selectFirst && identity.Selection == subtitleSelectionEpoch;
            for (var index = 0; index < prepared.Length; index++)
            {
                var key = MpvSubtitleCache.Fingerprint(requests[index]);
                if (externalSubtitleKeys.TryGetValue(key, out var existingId))
                {
                    if (index == 0 && select) Set("sid", existingId);
                    continue;
                }
                if (externalSubtitleKeys.Count >= 32) throw new InvalidOperationException("At most 32 external subtitle tracks can be attached to one media load.");
                var path = prepared[index].LocalPath;
                var temporary = prepared[index].Data is not null;
                if (prepared[index].Data is { } data)
                {
                    if (subtitleFiles.Count >= 32) throw new InvalidOperationException("The per-load subtitle file limit was reached.");
                    var directory = Path.Combine(Path.GetTempPath(), "MPVKit", Environment.ProcessId.ToString());
                    Directory.CreateDirectory(directory);
                    path = Path.Combine(directory, Guid.NewGuid().ToString("N") + prepared[index].Extension);
                    File.WriteAllBytes(path, data);
                    subtitleFiles.Add(path);
                }
                try
                {
                    var before = (Get("track-list") as System.Text.Json.Nodes.JsonArray ?? []).Where(item => item?["type"].Text() == "sub").Select(item => item?["id"].Integer() ?? -1).ToHashSet();
                    Execute(new object[] { "sub-add", path!, "auto", requests[index].Title, requests[index].Language });
                    var added = (Get("track-list") as System.Text.Json.Nodes.JsonArray ?? [])
                        .FirstOrDefault(item => item?["type"].Text() == "sub" && !before.Contains(item["id"].Integer()));
                    if (added is null) throw new InvalidDataException("libmpv did not accept the external subtitle.");
                    var id = added["id"].Integer();
                    externalSubtitleSources[id] = requests[index].Source;
                    externalSubtitleKeys[key] = id;
                    if (index == 0 && select) Set("sid", id);
                }
                catch
                {
                    if (temporary)
                        try { File.Delete(path!); subtitleFiles.Remove(path!); }
                        catch (IOException) { }
                        catch (UnauthorizedAccessException) { }
                    throw;
                }
            }
        }, linked.Token).ConfigureAwait(false);
    }
}

internal sealed class MpvSubtitleCache : IDisposable
{
    internal static string Fingerprint(MpvExternalSubtitle subtitle) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
        MpvPlayer.NormalizeSource(subtitle.Source) + "\n" + string.Join('\n', subtitle.Headers.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
            .Select(pair => pair.Key.ToLowerInvariant() + ":" + pair.Value)))));
    internal sealed record Prepared(string? LocalPath, byte[]? Data, string Extension);
    private readonly HttpClient client = new(new SocketsHttpHandler {
        AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.All,
        ConnectTimeout = TimeSpan.FromSeconds(10), MaxConnectionsPerServer = 2,
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30), UseCookies = false
    }) { Timeout = TimeSpan.FromSeconds(20), MaxResponseContentBufferSize = 2 * 1024 * 1024 };
    private readonly SemaphoreSlim concurrency = new(2);
    private readonly object gate = new();
    private readonly Dictionary<string, Prepared> entries = [];
    private readonly Queue<string> order = new();

    public async Task<Prepared> PrepareAsync(MpvExternalSubtitle subtitle, CancellationToken cancellation)
    {
        var source = MpvPlayer.NormalizeSource(subtitle.Source);
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri) || uri.IsFile)
        {
            var path = uri?.LocalPath ?? source;
            if (!File.Exists(path)) throw new FileNotFoundException("Subtitle file is missing.", path);
            return new(path, null, Path.GetExtension(path));
        }
        var fingerprint = Fingerprint(subtitle);
        lock (gate) if (entries.TryGetValue(fingerprint, out var cached)) return cached;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(20));
        cancellation = deadline.Token;
        await concurrency.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            lock (gate) if (entries.TryGetValue(fingerprint, out var cached)) return cached;
            var original = uri;
            for (var redirects = 0; redirects <= 5; redirects++)
            {
                using var message = new HttpRequestMessage(HttpMethod.Get, uri);
                if (uri.Scheme == original.Scheme && uri.IdnHost == original.IdnHost && uri.Port == original.Port)
                    foreach (var pair in subtitle.Headers)
                        if (!message.Headers.TryAddWithoutValidation(pair.Key, pair.Value))
                            throw new ArgumentException("The subtitle request header is not supported.");
                using var response = await client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
                if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
                {
                    if (redirects == 5 || response.Headers.Location is null) throw new HttpRequestException("Subtitle redirect limit exceeded.");
                    var next = new Uri(uri, response.Headers.Location);
                    if (next.Scheme is not ("https" or "http") || uri.Scheme == "https" && next.Scheme != "https")
                        throw new HttpRequestException("Unsupported subtitle redirect.");
                    uri = next;
                    continue;
                }
                response.EnsureSuccessStatusCode();
                if (response.Content.Headers.ContentLength > 2 * 1024 * 1024) throw new InvalidDataException("Subtitle exceeds 2 MiB.");
                await using var stream = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
                using var memory = new MemoryStream();
                var buffer = new byte[16384];
                int count;
                while ((count = await stream.ReadAsync(buffer, cancellation).ConfigureAwait(false)) != 0)
                {
                    if (memory.Length + count > 2 * 1024 * 1024) throw new InvalidDataException("Subtitle exceeds 2 MiB.");
                    memory.Write(buffer, 0, count);
                }
                var extension = Path.GetExtension(uri.AbsolutePath).ToLowerInvariant();
                if (extension is not (".srt" or ".ass" or ".ssa" or ".vtt" or ".sub" or ".txt")) extension = ".srt";
                var prepared = new Prepared(null, memory.ToArray(), extension);
                lock (gate)
                {
                    if (entries.TryGetValue(fingerprint, out var existing)) return existing;
                    while (entries.Count >= 16 && order.TryDequeue(out var oldest)) entries.Remove(oldest);
                    entries[fingerprint] = prepared;
                    order.Enqueue(fingerprint);
                }
                return prepared;
            }
            throw new HttpRequestException("Subtitle redirect limit exceeded.");
        }
        finally { concurrency.Release(); }
    }

    public void Dispose() { client.Dispose(); concurrency.Dispose(); lock (gate) { entries.Clear(); order.Clear(); } }
}
