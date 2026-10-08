namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The set of capabilities this AI Head serves, with each one's governance facts.
/// </summary>
/// <remarks>
/// <para>
/// Holds <see cref="AiCapabilityRegistration"/> records and answers "is this capability known, and
/// what does it mean?". It is a <b>schema in code and membership in data</b>: the constructor accepts
/// any set of registrations, and <see cref="Bootstrap"/> is the default set the W7A directive names.
/// A later lane supplies the same records from configuration without changing this type.
/// </para>
/// <para>
/// Construction validates the whole register, so a malformed register fails at startup rather than on
/// the first request that happens to use the broken entry. The checks are: identifiers well-formed,
/// no duplicates, every entry owned, and every entry carrying a rationale for its dependency class.
/// </para>
/// </remarks>
public sealed class AiCapabilityRegister
{
    private readonly Dictionary<string, AiCapabilityRegistration> _byId;

    /// <summary>Builds a register, validating it as a whole.</summary>
    /// <exception cref="ArgumentException">
    /// The register contains a duplicate identifier, a missing owner or rationale, or a malformed
    /// identifier. Thrown at construction: a register that is wrong is wrong for every request, and
    /// discovering that per-request would turn a startup failure into a production one.
    /// </exception>
    public AiCapabilityRegister(IEnumerable<AiCapabilityRegistration> registrations)
    {
        ArgumentNullException.ThrowIfNull(registrations);

        _byId = new Dictionary<string, AiCapabilityRegistration>(StringComparer.Ordinal);

        foreach (var registration in registrations)
        {
            if (registration is null)
            {
                throw new ArgumentException("The capability register may not contain a null entry.", nameof(registrations));
            }

            if (!Enum.IsDefined(registration.DependencyClass))
            {
                throw new ArgumentException(
                    $"Capability '{registration.Capability}' declares an undefined dependency class. " +
                    "Every capability must declare one of AI_OPTIONAL, AI_ENHANCED or AI_DEPENDENT.",
                    nameof(registrations));
            }

            if (string.IsNullOrWhiteSpace(registration.Owner))
            {
                throw new ArgumentException(
                    $"Capability '{registration.Capability}' has no owner. An unowned capability cannot be " +
                    "reclassified, quality-gated or retired, so the register refuses it.",
                    nameof(registrations));
            }

            if (string.IsNullOrWhiteSpace(registration.DependencyRationale))
            {
                throw new ArgumentException(
                    $"Capability '{registration.Capability}' declares a dependency class with no rationale. " +
                    "The rationale is what makes the classification reviewable rather than asserted.",
                    nameof(registrations));
            }

            if (!_byId.TryAdd(registration.Capability.Value, registration))
            {
                throw new ArgumentException(
                    $"Capability '{registration.Capability}' is registered more than once. Two entries for one " +
                    "identifier would make the audit record unable to say which governed the execution.",
                    nameof(registrations));
            }
        }
    }

    /// <summary>How many capabilities are registered, enabled or not.</summary>
    public int Count => _byId.Count;

    /// <summary>Every registration, ordered by identifier so the listing is deterministic.</summary>
    public IReadOnlyList<AiCapabilityRegistration> List()
        => _byId.Values.OrderBy(r => r.Capability.Value, StringComparer.Ordinal).ToArray();

    /// <summary>Every enabled registration, ordered by identifier.</summary>
    public IReadOnlyList<AiCapabilityRegistration> ListEnabled()
        => List().Where(r => r.Enabled).ToArray();

    /// <summary>True when the identifier is registered and enabled.</summary>
    public bool IsServable(CapabilityId capability)
    {
        ArgumentNullException.ThrowIfNull(capability);
        return _byId.TryGetValue(capability.Value, out var registration) && registration.Enabled;
    }

    /// <summary>Resolves a registration, or returns <see langword="false"/> if it is unknown or disabled.</summary>
    public bool TryResolve(CapabilityId capability, out AiCapabilityRegistration? registration)
    {
        ArgumentNullException.ThrowIfNull(capability);

        if (_byId.TryGetValue(capability.Value, out var found) && found.Enabled)
        {
            registration = found;
            return true;
        }

        // A disabled capability reports as unresolvable rather than as a distinct "disabled" outcome.
        // The caller's remedy is the same in both cases - it cannot use this capability now - and a
        // distinct code would invite a caller to branch on an operational state it does not own.
        registration = null;
        return false;
    }

    /// <summary>
    /// The default register: the nine capabilities the W7A directive names, each with its dependency
    /// class, owner and rationale.
    /// </summary>
    /// <remarks>
    /// The rationales are the substance here. A class without a reason is an assertion, and the reason
    /// is what a reviewer checks when the class is challenged.
    /// </remarks>
    public static AiCapabilityRegister Bootstrap() => new(
    [
        new AiCapabilityRegistration
        {
            Capability = CapabilityId.Parse(AiCapabilities.ArchitectureReview),
            Description = "Evaluate a design or change against architecture standards.",
            DependencyClass = AiDependencyClass.AiEnhanced,
            Owner = "AI-03 AI Governance",
            DependencyRationale =
                "A human architect can reach the same judgement from the same documents. Losing the review " +
                "degrades the speed and consistency of the assessment, not its availability.",
        },
        new AiCapabilityRegistration
        {
            Capability = CapabilityId.Parse(AiCapabilities.CodeReview),
            Description = "Review a code change against criteria.",
            DependencyClass = AiDependencyClass.AiEnhanced,
            Owner = "AI-03 AI Governance",
            DependencyRationale =
                "Deterministic review gates already decide whether a change may land. The AI review adds " +
                "coverage and explanation; its absence degrades the review, it does not stop the merge.",
        },
        new AiCapabilityRegistration
        {
            Capability = CapabilityId.Parse(AiCapabilities.CodeGenerate),
            Description = "Produce a code change.",
            DependencyClass = AiDependencyClass.AiOptional,
            Owner = "AI-03 AI Governance",
            DependencyRationale =
                "Nothing in Nexus requires generated code. A developer writes the change instead; the " +
                "deterministic development path is complete without it.",
        },
        new AiCapabilityRegistration
        {
            Capability = CapabilityId.Parse(AiCapabilities.TestDiagnose),
            Description = "Explain a failing test or build.",
            DependencyClass = AiDependencyClass.AiEnhanced,
            Owner = "AI-03 AI Governance",
            DependencyRationale =
                "The failure, its output and its location are deterministic facts that remain available. " +
                "The explanation is what is lost, so the diagnosis degrades visibly rather than failing.",
        },
        new AiCapabilityRegistration
        {
            Capability = CapabilityId.Parse(AiCapabilities.DocumentSummarize),
            Description = "Condense a document.",
            DependencyClass = AiDependencyClass.AiOptional,
            Owner = "AI-03 AI Governance",
            DependencyRationale =
                "The document is readable without a summary. The operation completes normally and silently " +
                "when the summary is unavailable.",
        },
        new AiCapabilityRegistration
        {
            Capability = CapabilityId.Parse(AiCapabilities.BusinessAnalyze),
            Description = "Analyse business data.",
            DependencyClass = AiDependencyClass.AiOptional,
            Owner = "AI-03 AI Governance",
            DependencyRationale =
                "Analysis is advisory. The underlying figures are produced deterministically and are not " +
                "affected by whether the narrative exists.",
        },
        new AiCapabilityRegistration
        {
            Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
            Description = "Produce a conversational turn.",
            DependencyClass = AiDependencyClass.AiDependent,
            Owner = "AI-03 AI Governance",
            DependencyRationale =
                "A conversation product with no model is not a conversation product, so no deterministic " +
                "fallback exists. Declared rather than inherited: the consumer is a Product, so the failure " +
                "is contained to that surface and cannot reach a Platform path. See D-W7A-02.",
        },
        new AiCapabilityRegistration
        {
            Capability = CapabilityId.Parse(AiCapabilities.EmbeddingGenerate),
            Description = "Produce a vector embedding.",
            DependencyClass = AiDependencyClass.AiOptional,
            Owner = "AI-03 AI Governance",
            DependencyRationale =
                "Embeddings improve retrieval. Where they are unavailable, retrieval falls back to the " +
                "deterministic ranker, which is the path that already exists.",
        },
        new AiCapabilityRegistration
        {
            Capability = CapabilityId.Parse(AiCapabilities.ImageGenerate),
            Description = "Produce an image.",
            DependencyClass = AiDependencyClass.AiOptional,
            Owner = "AI-03 AI Governance",
            DependencyRationale =
                "No Nexus operation depends on generated imagery. It is a convenience in the experience " +
                "layer and nothing else consumes its output.",
        },
    ]);
}
