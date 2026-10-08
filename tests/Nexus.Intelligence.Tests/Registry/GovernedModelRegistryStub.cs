using System;
using System.Collections.Generic;
using System.Linq;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Tests.Registry;

/// <summary>
/// W10.7A — <b>a minimal governed AI Model Registry for tests, so a test can express the difference
/// between "the provider supports this model" and "Nexus may route to it".</b>
///
/// <para>
/// <b>Why this exists rather than a real <c>ConfiguredAiRegistry</c>.</b> The tests that need this
/// double are about the AUTHORITY BOUNDARY, not about configuration parsing — <c>ConfiguredAiRegistryTests</c>
/// already owns that. What they must be able to state is exactly which model ids are registered, and
/// which are not, with nothing else in the way. A real registry loaded from a configuration object
/// would make every one of these tests a test of both the boundary and the parser.
/// </para>
///
/// <para>
/// <b>The registry is membership, and nothing else.</b> It does not consult the provider catalogue, it
/// does not infer support, and it does not add a model because a provider offers one. That is the whole
/// point: <c>PROVIDER_SUPPORTED</c> must never become <c>NEXUS_ROUTABLE</c> by implication, and a double
/// that inferred it would make the negative control untestable.
/// </para>
/// </summary>
internal sealed class GovernedModelRegistryStub : IAiModelRegistry
{
    private readonly Dictionary<string, AiModelRegistration> _models;

    /// <summary>Registers exactly the ids given — no more, no fewer.</summary>
    public GovernedModelRegistryStub(params string[] modelIds)
    {
        _models = modelIds.ToDictionary(
            id => id,
            id => new AiModelRegistration
            {
                ModelId = id,
                ProviderId = id.Contains(':') ? id[..id.IndexOf(':')] : "unknown",
                DisplayName = id,
                GovernanceRationale = "Registered by GovernedModelRegistryStub for a model-authority test.",
            },
            StringComparer.Ordinal);
    }

    /// <summary>An empty registry — the control for "removing a model removes eligibility".</summary>
    public static GovernedModelRegistryStub Empty() => new();

    public int Count => _models.Count;

    /// <summary>
    /// Membership by exact id. Absent means <b>not routable</b>, and there is deliberately no fallback:
    /// a registry that guessed would be a registry that authorizes.
    /// </summary>
    public bool TryGetModel(string? modelId, out AiModelRegistration? registration)
    {
        if (modelId is not null && _models.TryGetValue(modelId, out var found))
        {
            registration = found;
            return true;
        }

        registration = null;
        return false;
    }

    /// <summary>
    /// Capability listing. Deliberately NOT used by these tests to prove routability — role resolution
    /// goes through <see cref="TryGetModel"/>, which is the membership question.
    /// </summary>
    public IReadOnlyList<AiModelRegistration> ListForCapability(CapabilityId capability) =>
        _models.Values.Where(m => m.Declares(capability)).ToArray();
}
