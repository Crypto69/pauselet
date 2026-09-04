using System.Security.Cryptography;
using System.Text;

namespace Pauselet.Core;

/// <summary>
/// Where a secret is kept. One method each way, so every platform can satisfy
/// it with whatever its OS provides. (Mirrors SecretStoring in
/// SecretStore.swift; the Mac and iOS satisfy it with the Keychain.)
/// </summary>
public interface ISecretStore
{
    /// <summary>The stored secret for <paramref name="account"/>, or <c>null</c>.</summary>
    string? Read(string account);

    /// <summary>
    /// Stores <paramref name="value"/>, replacing any existing secret.
    /// <c>null</c> removes it.
    /// </summary>
    void Write(string? value, string account);
}

/// <summary>Where the exercise importer's API key is stored.</summary>
public static class SecretAccounts
{
    public const string AIImportKey = "openai-api-key";
}

/// <summary>
/// Keeps secrets in a small file beside the data file, encrypted with DPAPI at
/// user scope — so the ciphertext is useless to any other Windows account, and
/// to anyone who copies the file off the machine.
///
/// Deliberately <em>not</em> in <c>data.json</c>. That file is plaintext at a
/// path the UI shows, and is copied verbatim to <c>data.corrupt.json</c> when
/// it cannot be decoded; a key there would leak into backups and support
/// bundles. This file is written with the same care and never copied.
/// </summary>
public sealed class DpapiSecretStore : ISecretStore
{
    private readonly string _path;
    /// <summary>
    /// Mixed into the encryption so a secrets file from another app — or
    /// another account name — cannot be decrypted as this one.
    /// </summary>
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("com.pauselet.ai-import");

    public DpapiSecretStore(string? path = null)
    {
        _path = path ?? DefaultPath();
    }

    /// <summary>Beside data.json, under the app's roaming application data.</summary>
    public static string DefaultPath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Pauselet",
        "secrets.dat");

    public string? Read(string account)
    {
        var all = ReadAll();
        return all.TryGetValue(account, out var value) ? value : null;
    }

    public void Write(string? value, string account)
    {
        var all = ReadAll();
        if (string.IsNullOrEmpty(value)) all.Remove(account);
        else all[account] = value;

        if (all.Count == 0)
        {
            // Nothing left to protect: remove the file rather than leave an
            // encrypted empty one behind.
            if (File.Exists(_path)) File.Delete(_path);
            return;
        }

        // One "account\nvalue" pair per record; accounts are our own constants,
        // so they carry no newlines to escape.
        var plain = string.Join("\n", all.Select(pair => $"{pair.Key}\t{pair.Value}"));
        var cipher = Protect(Encoding.UTF8.GetBytes(plain));
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllBytes(_path, cipher);
    }

    private Dictionary<string, string> ReadAll()
    {
        var all = new Dictionary<string, string>(StringComparer.Ordinal);
        if (!File.Exists(_path)) return all;
        byte[] plain;
        try
        {
            plain = Unprotect(File.ReadAllBytes(_path));
        }
        catch (Exception exception) when (
            exception is CryptographicException or IOException or UnauthorizedAccessException)
        {
            // An unreadable secrets file means "no key stored", not a crash:
            // the user re-enters the key and the file is rewritten. Losing an
            // API key is a nuisance; refusing to open Settings is worse.
            return all;
        }
        foreach (var line in Encoding.UTF8.GetString(plain).Split('\n'))
        {
            var split = line.IndexOf('\t');
            if (split <= 0) continue;
            all[line[..split]] = line[(split + 1)..];
        }
        return all;
    }

    /// <summary>
    /// DPAPI is Windows-only; the core builds and tests on any platform, so
    /// the call is made through the guard rather than at the type level.
    /// </summary>
    private static byte[] Protect(byte[] plain)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        return ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);
    }

    private static byte[] Unprotect(byte[] cipher)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        return ProtectedData.Unprotect(cipher, Entropy, DataProtectionScope.CurrentUser);
    }
}

/// <summary>
/// A secret store that keeps nothing on disk, for tests and for anything that
/// must not touch the real one.
/// </summary>
public sealed class InMemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _storage;
    private readonly object _lock = new();

    public InMemorySecretStore(IDictionary<string, string>? initial = null)
    {
        _storage = initial is null
            ? new Dictionary<string, string>(StringComparer.Ordinal)
            : new Dictionary<string, string>(initial, StringComparer.Ordinal);
    }

    public string? Read(string account)
    {
        lock (_lock)
        {
            return _storage.TryGetValue(account, out var value) ? value : null;
        }
    }

    public void Write(string? value, string account)
    {
        lock (_lock)
        {
            if (string.IsNullOrEmpty(value)) _storage.Remove(account);
            else _storage[account] = value;
        }
    }
}
