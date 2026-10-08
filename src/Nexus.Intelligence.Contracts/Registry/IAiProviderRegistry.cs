namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The authoritative statement of which providers exist, how they are reached, and what they may receive.
/// </summary>
/// <remarks>
/// <para>
/// <b>Resolution only, with no enumeration at all.</b> The router never asks "what providers are
/// there?" — it asks "is the provider serving this model registered, and what are its terms?", once
/// per candidate, driven by models the capability mapping already produced. An enumeration would be a
/// question nothing needs answered and a list nothing should build.
/// </para>
/// <para>
/// This is also where a provider's <em>absence</em> becomes a refusal. A model whose
/// <see cref="AiModelRegistration.ProviderId"/> resolves to nothing is not a model with a missing
/// accessory; it is an execution whose destination is unknown, and the router refuses it rather than
/// assuming the provider is acceptable because nobody wrote down that it is not.
/// </para>
/// </remarks>
public interface IAiProviderRegistry
{
    /// <summary>Resolves one provider. False when nothing is registered under the identifier.</summary>
    bool TryGetProvider(string? providerId, out AiProviderRegistration? registration);

    /// <summary>How many providers the registry holds. A count, for diagnostics — not a capability.</summary>
    int Count { get; }
}
