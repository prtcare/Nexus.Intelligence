namespace Nexus.Intelligence.Contracts;

/// <summary>
/// One feature's declared dependence on AI.
/// </summary>
/// <remarks>
/// <para>
/// A <b>feature</b> declaration, not a capability declaration. They answer different questions and
/// belong to different owners. <see cref="AiCapabilityRegistration"/> is the AI Head saying "I will
/// serve this capability, and here is what happens to <em>it</em> when a provider is down". This type
/// is a consuming Head or Product saying "this feature of <em>mine</em> depends on AI, and here is what
/// happens to <em>my feature</em> when the AI Head is gone". The second cannot be answered by the
/// first, which is why the classification is recorded on both sides rather than derived.
/// </para>
/// <para>
/// <see cref="FeatureId"/> is deliberately a plain string validated against the same stable-identifier
/// format as <see cref="CapabilityId"/> rather than a re-typed <c>AiFeatureId</c>. The format rule is
/// shared; the identity is not. A feature is not a capability and the compiler should not let one be
/// passed where the other is expected — which a distinct wrapper would also achieve, at the cost of a
/// second near-identical type to keep in step.
/// </para>
/// </remarks>
public sealed record AiDependencyDeclaration
{
    /// <summary>The feature's stable identifier, in <c>&lt;domain&gt;.&lt;object&gt;</c> form.</summary>
    public required string FeatureId { get; init; }

    /// <summary>The Head or Product that owns the feature and answers for this declaration.</summary>
    public required string Owner { get; init; }

    /// <summary>How the feature behaves when the AI Head is unavailable.</summary>
    public required AiDependencyClass DependencyClass { get; init; }

    /// <summary>Why the feature is in this class. Required, so the register is reviewable.</summary>
    public required string Rationale { get; init; }

    /// <summary>
    /// What the feature does instead when AI is unavailable. Required for
    /// <see cref="AiDependencyClass.AiOptional"/> and <see cref="AiDependencyClass.AiEnhanced"/>;
    /// an <see cref="AiDependencyClass.AiDependent"/> feature has none by definition and must leave
    /// this empty.
    /// </summary>
    public string? DeterministicFallback { get; init; }

    /// <summary>
    /// The accountable owner of the unmitigated risk, required for
    /// <see cref="AiDependencyClass.AiDependent"/> and refused for the other classes.
    /// </summary>
    /// <remarks>
    /// An AI-dependent feature is a liability. The class exists so that the liability is declared and
    /// owned rather than acquired by accident, and a declaration with nobody named against the risk has
    /// not been owned — it has only been labelled.
    /// </remarks>
    public string? AcceptedRiskOwner { get; init; }

    /// <summary>
    /// The prohibited surface this declaration names. Required for
    /// <see cref="AiDependencyClass.AiProhibited"/> and refused for every other class.
    /// </summary>
    /// <remarks>
    /// Required on exactly the class where the reason matters most. The other three classes describe
    /// an operational posture and their <see cref="Rationale"/> is enough to review them; this one
    /// overrides a decision by asserting that a deterministic authority has forbidden something, and
    /// an assertion of that weight without a stated basis is not reviewable at all.
    /// </remarks>
    public AiProhibitedSurface? ProhibitedSurface { get; init; }

    /// <summary>
    /// The capability this declaration concerns.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The field reads in two directions depending on the class, and the direction is the whole
    /// meaning, so it is stated rather than left to inference:
    /// </para>
    /// <list type="bullet">
    /// <item><description>
    /// For <see cref="AiDependencyClass.AiOptional"/>, <see cref="AiDependencyClass.AiEnhanced"/> and
    /// <see cref="AiDependencyClass.AiDependent"/>: the capability this feature <b>consumes</b>, when
    /// it consumes exactly one.
    /// </description></item>
    /// <item><description>
    /// For <see cref="AiDependencyClass.AiProhibited"/>: the capability AI <b>must not serve</b>, when
    /// the prohibition is capability-shaped. Optional even then — a prohibited surface is often a
    /// decision or a data operation rather than a capability.
    /// </description></item>
    /// </list>
    /// </remarks>
    public CapabilityId? Capability { get; init; }

    /// <summary>True when the feature is live. A disabled feature keeps its declaration.</summary>
    public bool Enabled { get; init; } = true;
}

/// <summary>
/// The control record of which features depend on AI, and how.
/// </summary>
/// <remarks>
/// <para>
/// This is a <b>governance</b> register, not a routing table. Nothing here selects a provider, a model
/// or an execution path, and nothing here is consulted when serving a request. Its consumers are the
/// people and systems that need to answer "what stops working when the AI Head is unavailable?" and
/// "who accepted that?" without reading every product's source.
/// </para>
/// <para>
/// <b>It also answers the inverse question</b>, added at W7A.1: "where is AI forbidden outright?" That
/// is a different axis from availability - see <see cref="AiDependencyClass.AiProhibited"/> - and it
/// lives in the same register because both answers are governance facts about the same set of features,
/// and splitting them across two structures would let the two drift apart for the same feature.
/// </para>
/// <para>
/// A prohibition register has one failure mode that an availability register does not: a prohibition
/// nobody wrote is indistinguishable from a permission. <see cref="AiProhibitionBaseline"/> and
/// <see cref="RequireProhibitionBaseline"/> exist for exactly that reason, and
/// <see cref="Governed"/> is the entry point for a register anyone will decide from.
/// </para>
/// <para>
/// Validation is total at construction: an invalid register cannot be built. A register that is only
/// validated when read is a register that is invalid in production and valid in the test that reads it.
/// </para>
/// </remarks>
public sealed class AiDependencyRegistry
{
    private readonly Dictionary<string, AiDependencyDeclaration> _declarations;

    /// <summary>Builds a registry from declarations, validating all of them.</summary>
    /// <exception cref="ArgumentException">A declaration is null, malformed, duplicated, or internally inconsistent.</exception>
    public AiDependencyRegistry(IEnumerable<AiDependencyDeclaration> declarations)
    {
        ArgumentNullException.ThrowIfNull(declarations);

        _declarations = new Dictionary<string, AiDependencyDeclaration>(StringComparer.Ordinal);

        foreach (var declaration in declarations)
        {
            Validate(declaration);

            if (!_declarations.TryAdd(declaration.FeatureId, declaration))
            {
                throw new ArgumentException(
                    $"The dependency registry declares feature '{declaration.FeatureId}' more than once. A " +
                    "duplicate declaration makes the effective dependency class depend on enumeration order.",
                    nameof(declarations));
            }
        }
    }

    /// <summary>An empty registry. The state before any consumer has declared anything.</summary>
    public static AiDependencyRegistry Empty { get; } = new([]);

    /// <summary>How many features are declared.</summary>
    public int Count => _declarations.Count;

    /// <summary>Every declaration, ordered by feature identifier.</summary>
    public IReadOnlyList<AiDependencyDeclaration> List()
        => _declarations.Values.OrderBy(d => d.FeatureId, StringComparer.Ordinal).ToArray();

    /// <summary>Every declaration in a given class.</summary>
    public IReadOnlyList<AiDependencyDeclaration> InClass(AiDependencyClass dependencyClass)
        => List().Where(d => d.DependencyClass == dependencyClass).ToArray();

    /// <summary>Resolves a feature's declaration.</summary>
    public bool TryResolve(string? featureId, out AiDependencyDeclaration? declaration)
    {
        declaration = null;

        if (string.IsNullOrWhiteSpace(featureId))
        {
            return false;
        }

        return _declarations.TryGetValue(featureId.Trim(), out declaration);
    }

    /// <summary>
    /// True when the named feature must remain usable with the AI Head absent.
    /// </summary>
    /// <remarks>
    /// An undeclared feature returns <see langword="false"/>. That is deliberately not the safe answer,
    /// and it is the correct one: a feature nobody has classified has no evidence behind a claim that
    /// it survives, and returning <see langword="true"/> would let an omission read as a clearance.
    /// </remarks>
    public bool MustSurviveAiOutage(string? featureId)
        => TryResolve(featureId, out var declaration)
           && declaration is not null
           && declaration.DependencyClass.MustSurviveAiOutage();

    /// <summary>Every declared feature that consumes a given capability.</summary>
    public IReadOnlyList<AiDependencyDeclaration> ConsumersOf(CapabilityId capability)
        => List().Where(d => d.Capability is not null && d.Capability == capability).ToArray();

    // ---------------------------------------------------------------------------------------------
    // Prohibition queries (W7A.1)
    //
    // Two directions, deliberately mirroring each other: a SURFACE is a protected area of the
    // platform ("secret custody", "deterministic security gates"), and a CAPABILITY is a named thing
    // the AI Head could be asked to serve. A prohibition may be declared in either shape - the
    // baseline surfaces are declared one way, a Product's own forbidden capability the other - and a
    // decision point only ever needs one of the two questions answered.
    //
    // None of these queries consults Enabled, and that is the conservative reading rather than an
    // oversight. A prohibition is a statement about the SURFACE, not about the traffic flowing
    // through it: disabling a feature does not un-protect the surface it touched. A prohibition is
    // lifted by withdrawing the declaration, which is a governance act with a name attached to it,
    // not by flipping a flag that reads like an operational toggle.
    // ---------------------------------------------------------------------------------------------

    /// <summary>Every declaration that prohibits AI on a surface.</summary>
    public IReadOnlyList<AiDependencyDeclaration> ProhibitedOn(AiProhibitedSurface surface)
        => List().Where(d => d.DependencyClass is AiDependencyClass.AiProhibited
                             && d.ProhibitedSurface == surface).ToArray();

    /// <summary>True when AI is prohibited on a surface by a declaration in this registry.</summary>
    public bool IsSurfaceProhibited(AiProhibitedSurface surface) => ProhibitedOn(surface).Count > 0;

    /// <summary>
    /// True when AI may participate in a protected surface.
    /// </summary>
    /// <remarks>
    /// The decision point for a caller that knows which surface it is about to touch and nothing
    /// else. <see langword="false"/> is an answer the caller must act on, not log and continue past.
    /// </remarks>
    public bool MayAiParticipate(AiProhibitedSurface surface) => !IsSurfaceProhibited(surface);

    /// <summary>True when AI is prohibited from serving a capability.</summary>
    public bool IsCapabilityProhibited(CapabilityId capability) => ProhibitedFor(capability).Count > 0;

    /// <summary>
    /// True when AI may serve a capability.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <see langword="true"/> is <b>not</b> a grant of authority, and the distinction is the one the
    /// register exists to keep clean. This method answers exactly one question - "has anything
    /// forbidden AI here?" - and it answers it from prohibitions alone. Serving a capability
    /// additionally requires the AI Head to have registered it (<see cref="AiCapabilityRegistration"/>)
    /// and requires the request to satisfy policy and classification.
    /// </para>
    /// <para>
    /// It is written this way on purpose. A query that conflated "not forbidden" with "permitted"
    /// would become the single place where an omission - nobody declared this capability either way -
    /// silently reads as a clearance.
    /// </para>
    /// </remarks>
    public bool MayAiServe(CapabilityId capability) => !IsCapabilityProhibited(capability);

    /// <summary>Every prohibition declaration naming a capability.</summary>
    public IReadOnlyList<AiDependencyDeclaration> ProhibitedFor(CapabilityId capability)
        => List().Where(d => d.DependencyClass is AiDependencyClass.AiProhibited
                             && d.Capability is not null
                             && d.Capability == capability).ToArray();

    /// <summary>
    /// The baseline surfaces this registry does not prohibit.
    /// </summary>
    /// <remarks>
    /// Empty means the registry covers the baseline. Non-empty means the register does not answer for
    /// those surfaces, and a consumer reading absence as permission will let AI into all of them.
    /// </remarks>
    public IReadOnlyList<AiProhibitedSurface> MissingProhibitedSurfaces()
        => AiProhibitionBaseline.RequiredSurfaces.Where(s => !IsSurfaceProhibited(s)).ToArray();

    /// <summary>True when every surface in the prohibition baseline is declared prohibited.</summary>
    public bool CoversProhibitionBaseline() => MissingProhibitedSurfaces().Count == 0;

    /// <summary>
    /// Throws unless every baseline surface is declared prohibited.
    /// </summary>
    /// <remarks>
    /// Separate from the constructor because an incomplete register is a legitimate intermediate
    /// state - a Head declaring its features one at a time - while an incomplete register <em>relied
    /// upon as authoritative</em> is not. The constructor permits the first; this refuses the second.
    /// </remarks>
    /// <exception cref="InvalidOperationException">A baseline surface is not prohibited.</exception>
    public void RequireProhibitionBaseline()
    {
        var missing = MissingProhibitedSurfaces();

        if (missing.Count > 0)
        {
            throw new InvalidOperationException(
                "This dependency registry does not prohibit AI on " + string.Join(", ", missing) +
                ". Absence of a prohibition is read by every consumer as permission, so an uncovered " +
                "baseline surface is not a gap in the register - it is a standing statement that AI may " +
                "participate there.");
        }
    }

    /// <summary>
    /// Builds a registry that is also required to cover the prohibition baseline.
    /// </summary>
    /// <remarks>
    /// The factory for a register anyone will consult for a decision. Use the constructor when
    /// assembling declarations incrementally and this one when handing the result to a consumer that
    /// will treat it as authoritative.
    /// </remarks>
    /// <exception cref="ArgumentException">A declaration is invalid.</exception>
    /// <exception cref="InvalidOperationException">A baseline surface is not prohibited.</exception>
    public static AiDependencyRegistry Governed(IEnumerable<AiDependencyDeclaration> declarations)
    {
        var registry = new AiDependencyRegistry(declarations);
        registry.RequireProhibitionBaseline();
        return registry;
    }

    private static void Validate(AiDependencyDeclaration declaration)
    {
        if (declaration is null)
        {
            throw new ArgumentException(
                "The dependency registry may not contain a null declaration.", nameof(declaration));
        }

        if (!CapabilityId.TryParse(declaration.FeatureId, out _, out var formatReason))
        {
            throw new ArgumentException(
                $"Feature identifier '{declaration.FeatureId}' is not a valid stable identifier: {formatReason}",
                nameof(declaration));
        }

        if (!Enum.IsDefined(declaration.DependencyClass))
        {
            throw new ArgumentException(
                $"Feature '{declaration.FeatureId}' declares an undefined dependency class " +
                $"'{declaration.DependencyClass}'.",
                nameof(declaration));
        }

        if (string.IsNullOrWhiteSpace(declaration.Owner))
        {
            throw new ArgumentException(
                $"Feature '{declaration.FeatureId}' has no owner. A dependency nobody owns is a dependency " +
                "nobody will revisit.",
                nameof(declaration));
        }

        if (string.IsNullOrWhiteSpace(declaration.Rationale))
        {
            throw new ArgumentException(
                $"Feature '{declaration.FeatureId}' has no rationale. The class is a conclusion; the register " +
                "needs the reasoning that produced it.",
                nameof(declaration));
        }

        var hasFallback = !string.IsNullOrWhiteSpace(declaration.DeterministicFallback);
        var hasRiskOwner = !string.IsNullOrWhiteSpace(declaration.AcceptedRiskOwner);

        if (declaration.DependencyClass is AiDependencyClass.AiProhibited)
        {
            // A prohibition must say which protection it exists to preserve, and must not be dressed
            // in the vocabulary of the availability classes. Both refusals below exist because the
            // fields they reject are how a prohibition gets quietly weakened into a preference.
            if (declaration.ProhibitedSurface is null)
            {
                throw new ArgumentException(
                    $"Feature '{declaration.FeatureId}' is declared AI-prohibited but names no prohibited " +
                    "surface. A prohibition without a stated basis is a label, and a label is not a control.",
                    nameof(declaration));
            }

            if (!Enum.IsDefined(declaration.ProhibitedSurface.Value))
            {
                throw new ArgumentException(
                    $"Feature '{declaration.FeatureId}' names an undefined prohibited surface " +
                    $"'{declaration.ProhibitedSurface}'.",
                    nameof(declaration));
            }

            if (hasFallback)
            {
                throw new ArgumentException(
                    $"Feature '{declaration.FeatureId}' is declared AI-prohibited but names a deterministic " +
                    $"fallback ('{declaration.DeterministicFallback}'). There is nothing to fall back FROM: on a " +
                    "prohibited surface the deterministic path is not the alternative to AI, it is the only path, " +
                    "and naming a fallback asserts an AI path that must not exist.",
                    nameof(declaration));
            }

            if (hasRiskOwner)
            {
                throw new ArgumentException(
                    $"Feature '{declaration.FeatureId}' is declared AI-prohibited but carries an accepted-risk " +
                    "owner. A prohibited surface has no unmitigated AI risk to own, because AI is not permitted " +
                    "in it - recording an owner against it asserts an exposure the class forbids.",
                    nameof(declaration));
            }

            return;
        }

        if (declaration.ProhibitedSurface is not null)
        {
            throw new ArgumentException(
                $"Feature '{declaration.FeatureId}' names prohibited surface " +
                $"'{declaration.ProhibitedSurface}' but is declared '{declaration.DependencyClass}'. Only an " +
                "AI-prohibited feature names a prohibited surface; carrying one on any other class says AI may " +
                "participate in a surface the declaration simultaneously protects.",
                nameof(declaration));
        }

        if (declaration.DependencyClass is AiDependencyClass.AiDependent)
        {
            // An AI-dependent feature cannot have a deterministic fallback - if it had one it would be
            // AI-enhanced - and it must name who accepted the risk of not having one.
            if (hasFallback)
            {
                throw new ArgumentException(
                    $"Feature '{declaration.FeatureId}' is declared AI-dependent but names a deterministic " +
                    $"fallback ('{declaration.DeterministicFallback}'). A feature with a working deterministic " +
                    "path is AI-enhanced, not AI-dependent.",
                    nameof(declaration));
            }

            if (!hasRiskOwner)
            {
                throw new ArgumentException(
                    $"Feature '{declaration.FeatureId}' is declared AI-dependent without an accepted-risk " +
                    "owner. A feature that cannot work without AI is a liability that must be owned, not " +
                    "merely labelled.",
                    nameof(declaration));
            }

            return;
        }

        if (!hasFallback)
        {
            throw new ArgumentException(
                $"Feature '{declaration.FeatureId}' is declared '{declaration.DependencyClass}' but names no " +
                "deterministic fallback. A feature that survives an AI outage must say what it does during " +
                "one.",
                nameof(declaration));
        }

        if (hasRiskOwner)
        {
            throw new ArgumentException(
                $"Feature '{declaration.FeatureId}' is declared '{declaration.DependencyClass}' but carries an " +
                "accepted-risk owner. Only an AI-dependent feature carries unmitigated risk, and recording one " +
                "against a class that has a fallback overstates the exposure.",
                nameof(declaration));
        }
    }
}
