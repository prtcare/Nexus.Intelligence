namespace Nexus.Intelligence.Contracts;

/// <summary>An opaque product coordinate. Intelligence stores and compares it, never parses it.</summary>
public sealed record ScopeRef(string Kind, string Key, IReadOnlyList<string> Path);
