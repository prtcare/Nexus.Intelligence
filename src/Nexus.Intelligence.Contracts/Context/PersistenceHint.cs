namespace Nexus.Intelligence.Contracts;

/// <summary>Intelligence proposes; the product decides whether to write it to its own store.</summary>
public sealed record PersistenceHint(PersistenceHintKind Kind, string Title, string Body, TrustLevel SuggestedTrust);
