using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Logging;
using Microsoft.Data.Sqlite;

namespace AudioRecorder.Services.Storage;

/// <summary>
/// Persists recording sessions to a local SQLite database.
/// Supports full-text search (FTS5) across titles and transcript previews.
/// DB location: %LOCALAPPDATA%\Contora\contora.db
/// </summary>
public sealed class SqliteSessionStore : ISessionStore
{
    private readonly string _dbPath;
    private bool _initialized;
    private readonly SemaphoreSlim _initLock = new(1, 1);

    public SqliteSessionStore()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Contora");
        Directory.CreateDirectory(dir);
        _dbPath = Path.Combine(dir, "contora.db");
    }

    // ── Initialization ──────────────────────────────────────────────────────

    public async Task InitializeAsync()
    {
        await _initLock.WaitAsync();
        try
        {
            if (_initialized) return;
            await using var conn = OpenConnection();
            await conn.OpenAsync();
            await CreateSchemaAsync(conn);
            _initialized = true;
            AppLogger.LogInfo($"SqliteSessionStore initialized: {_dbPath}");
        }
        catch (Exception ex)
        {
            AppLogger.LogError($"SqliteSessionStore.InitializeAsync failed: {ex.Message}");
            throw;
        }
        finally
        {
            _initLock.Release();
        }
    }

    private static async Task CreateSchemaAsync(SqliteConnection conn)
    {
        // Main sessions table
        await ExecAsync(conn, """
            CREATE TABLE IF NOT EXISTS sessions (
                id              TEXT    PRIMARY KEY,
                title           TEXT    NOT NULL DEFAULT '',
                recorded_at     TEXT    NOT NULL,
                duration_sec    REAL    NOT NULL DEFAULT 0,
                audio_path      TEXT,
                transcript_path TEXT,
                state           TEXT    NOT NULL DEFAULT 'Recorded',
                speaker_names   TEXT,
                outline_doc_id  TEXT,
                preview_text    TEXT,
                created_at      TEXT    NOT NULL
            );
            """);

        // FTS5 virtual table for full-text search
        await ExecAsync(conn, """
            CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
                title,
                preview_text,
                content='sessions',
                content_rowid='rowid'
            );
            """);

        // Triggers to keep FTS index in sync
        await ExecAsync(conn, """
            CREATE TRIGGER IF NOT EXISTS sessions_ai AFTER INSERT ON sessions BEGIN
                INSERT INTO sessions_fts(rowid, title, preview_text)
                VALUES (new.rowid, new.title, new.preview_text);
            END;
            """);

        await ExecAsync(conn, """
            CREATE TRIGGER IF NOT EXISTS sessions_ad AFTER DELETE ON sessions BEGIN
                INSERT INTO sessions_fts(sessions_fts, rowid, title, preview_text)
                VALUES ('delete', old.rowid, old.title, old.preview_text);
            END;
            """);

        await ExecAsync(conn, """
            CREATE TRIGGER IF NOT EXISTS sessions_au AFTER UPDATE ON sessions BEGIN
                INSERT INTO sessions_fts(sessions_fts, rowid, title, preview_text)
                VALUES ('delete', old.rowid, old.title, old.preview_text);
                INSERT INTO sessions_fts(rowid, title, preview_text)
                VALUES (new.rowid, new.title, new.preview_text);
            END;
            """);
    }

    // ── CRUD ────────────────────────────────────────────────────────────────

    public async Task<Session> CreateAsync(Session session)
    {
        await EnsureInitializedAsync();
        await using var conn = OpenConnection();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO sessions
                (id, title, recorded_at, duration_sec, audio_path, transcript_path,
                 state, speaker_names, outline_doc_id, preview_text, created_at)
            VALUES
                ($id, $title, $recorded_at, $dur, $audio, $transcript,
                 $state, $speakers, $outline, $preview, $created);
            """;
        BindSession(cmd, session);
        await cmd.ExecuteNonQueryAsync();

        AppLogger.LogInfo($"Session created: {session.Id} — {session.Title}");
        return session;
    }

    public async Task UpdateAsync(Session session)
    {
        await EnsureInitializedAsync();
        await using var conn = OpenConnection();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            UPDATE sessions SET
                title           = $title,
                recorded_at     = $recorded_at,
                duration_sec    = $dur,
                audio_path      = $audio,
                transcript_path = $transcript,
                state           = $state,
                speaker_names   = $speakers,
                outline_doc_id  = $outline,
                preview_text    = $preview
            WHERE id = $id;
            """;
        BindSession(cmd, session);
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task<Session?> GetAsync(Guid id)
    {
        await EnsureInitializedAsync();
        await using var conn = OpenConnection();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT * FROM sessions WHERE id = $id;";
        cmd.Parameters.AddWithValue("$id", id.ToString());

        await using var reader = await cmd.ExecuteReaderAsync();
        return await reader.ReadAsync() ? MapRow(reader) : null;
    }

    public async Task<IReadOnlyList<Session>> GetAllAsync(int limit = 200, int offset = 0)
    {
        await EnsureInitializedAsync();
        await using var conn = OpenConnection();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT * FROM sessions
            ORDER BY recorded_at DESC
            LIMIT $limit OFFSET $offset;
            """;
        cmd.Parameters.AddWithValue("$limit", limit);
        cmd.Parameters.AddWithValue("$offset", offset);

        return await ReadSessionsAsync(cmd);
    }

    public async Task<IReadOnlyList<Session>> SearchAsync(string query, int limit = 50)
    {
        if (string.IsNullOrWhiteSpace(query))
            return await GetAllAsync(limit);

        await EnsureInitializedAsync();
        await using var conn = OpenConnection();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        // FTS5 MATCH with rank ordering; fall back to LIKE if query has special chars
        cmd.CommandText = """
            SELECT s.* FROM sessions s
            JOIN sessions_fts f ON s.rowid = f.rowid
            WHERE sessions_fts MATCH $query
            ORDER BY rank, s.recorded_at DESC
            LIMIT $limit;
            """;
        cmd.Parameters.AddWithValue("$query", SanitizeFtsQuery(query));
        cmd.Parameters.AddWithValue("$limit", limit);

        try
        {
            return await ReadSessionsAsync(cmd);
        }
        catch (SqliteException)
        {
            // If FTS query is malformed, fall back to simple LIKE search
            return await SearchFallbackAsync(conn, query, limit);
        }
    }

    public async Task DeleteAsync(Guid id)
    {
        await EnsureInitializedAsync();
        await using var conn = OpenConnection();
        await conn.OpenAsync();

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "DELETE FROM sessions WHERE id = $id;";
        cmd.Parameters.AddWithValue("$id", id.ToString());
        await cmd.ExecuteNonQueryAsync();
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private SqliteConnection OpenConnection()
        => new($"Data Source={_dbPath}");

    private async Task EnsureInitializedAsync()
    {
        if (!_initialized) await InitializeAsync();
    }

    private static void BindSession(SqliteCommand cmd, Session s)
    {
        cmd.Parameters.AddWithValue("$id", s.Id.ToString());
        cmd.Parameters.AddWithValue("$title", s.Title);
        cmd.Parameters.AddWithValue("$recorded_at", s.RecordedAt.ToString("O"));
        cmd.Parameters.AddWithValue("$dur", s.DurationSeconds);
        cmd.Parameters.AddWithValue("$audio", (object?)s.AudioPath ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$transcript", (object?)s.TranscriptPath ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$state", s.State.ToString());
        cmd.Parameters.AddWithValue("$speakers", (object?)s.SpeakerNamesJson ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$outline", (object?)s.OutlineDocumentId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$preview", (object?)s.PreviewText ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$created", s.CreatedAt.ToString("O"));
    }

    private static Session MapRow(SqliteDataReader r) => new()
    {
        Id = Guid.Parse(r.GetString(r.GetOrdinal("id"))),
        Title = r.GetString(r.GetOrdinal("title")),
        RecordedAt = DateTime.Parse(r.GetString(r.GetOrdinal("recorded_at"))),
        DurationSeconds = r.GetDouble(r.GetOrdinal("duration_sec")),
        AudioPath = r.IsDBNull(r.GetOrdinal("audio_path")) ? null : r.GetString(r.GetOrdinal("audio_path")),
        TranscriptPath = r.IsDBNull(r.GetOrdinal("transcript_path")) ? null : r.GetString(r.GetOrdinal("transcript_path")),
        State = Enum.TryParse<SessionState>(r.GetString(r.GetOrdinal("state")), out var st) ? st : SessionState.Recorded,
        SpeakerNamesJson = r.IsDBNull(r.GetOrdinal("speaker_names")) ? null : r.GetString(r.GetOrdinal("speaker_names")),
        OutlineDocumentId = r.IsDBNull(r.GetOrdinal("outline_doc_id")) ? null : r.GetString(r.GetOrdinal("outline_doc_id")),
        PreviewText = r.IsDBNull(r.GetOrdinal("preview_text")) ? null : r.GetString(r.GetOrdinal("preview_text")),
        CreatedAt = DateTime.Parse(r.GetString(r.GetOrdinal("created_at"))),
    };

    private static async Task<IReadOnlyList<Session>> ReadSessionsAsync(SqliteCommand cmd)
    {
        var result = new List<Session>();
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            result.Add(MapRow(reader));
        return result;
    }

    private static async Task<IReadOnlyList<Session>> SearchFallbackAsync(SqliteConnection conn, string query, int limit)
    {
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT * FROM sessions
            WHERE title LIKE $q OR preview_text LIKE $q
            ORDER BY recorded_at DESC
            LIMIT $limit;
            """;
        cmd.Parameters.AddWithValue("$q", $"%{query}%");
        cmd.Parameters.AddWithValue("$limit", limit);
        return await ReadSessionsAsync(cmd);
    }

    private static async Task ExecAsync(SqliteConnection conn, string sql)
    {
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        await cmd.ExecuteNonQueryAsync();
    }

    /// <summary>
    /// Escapes special FTS5 characters to prevent query parse errors.
    /// </summary>
    private static string SanitizeFtsQuery(string query)
    {
        // FTS5 special chars: " * ^ ( ) -
        // Simplest safe approach: wrap each word in quotes
        var words = query.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        return string.Join(" ", words.Select(w => $"\"{w.Replace("\"", "")}\""));
    }
}
