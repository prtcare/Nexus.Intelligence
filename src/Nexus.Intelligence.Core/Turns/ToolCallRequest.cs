namespace Nexus.Intelligence.Core.Turns;

internal sealed record ToolCallRequest(string ToolId, string ArgumentsJson, IReadOnlyDictionary<string, string> Arguments);
