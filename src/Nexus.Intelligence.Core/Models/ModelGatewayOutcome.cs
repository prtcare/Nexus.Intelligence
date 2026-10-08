using Nexus.Platform.Contracts.Models;

namespace Nexus.Platform.Core.Models;

/// <summary>
/// What a model-gateway call produced, <b>and whether the provider actually reported how much it
/// consumed.</b>
/// </summary>
/// <remarks>
/// <para>
/// <b>Why this type has to exist.</b> Platform's <see cref="ModelUsage"/> declares
/// <c>int TokensIn, int TokensOut</c> — non-nullable, with <see cref="ModelInvocationResult.Usage"/>
/// defaulting to <see cref="ModelUsage.Zero"/>. So the Platform contract <em>cannot say</em> that a
/// provider reported nothing: an unreported call and a reported zero leave the boundary byte-identical.
/// The AI Head cannot change that contract, and it must not pretend the two are the same, so the
/// distinction is carried out of band here.
/// </para>
/// <para>
/// <b>Null is not zero.</b> <see cref="TokensIn"/> is null when the provider returned no usage block at
/// all. That is a statement about what the estate was <em>told</em>, not about what the call consumed,
/// and the two must never be conflated: a cost computed from a fabricated zero would be labelled
/// <c>ActualRecorded</c> and would then be a <em>measured</em> cost of nothing, which every budget
/// ceiling passes.
/// </para>
/// <para>
/// <b>The two token members are null together or not at all.</b> A half-reported usage block would make
/// a total that looks measured and is not.
/// </para>
/// </remarks>
public sealed record ModelGatewayOutcome
{
    /// <summary>What the call produced, in the Platform shape every existing consumer already reads.</summary>
    public required ModelInvocationResult Result { get; init; }

    /// <summary>
    /// Input tokens the provider reported, or <c>null</c> when it reported no usage at all.
    /// </summary>
    /// <remarks>
    /// Null on every path where no measurement can exist: a refusal decided before the call, a provider
    /// failure, and a success whose response carried no usage block.
    /// </remarks>
    public int? TokensIn { get; init; }

    /// <summary>Output tokens the provider reported, or <c>null</c> when it reported no usage at all.</summary>
    /// <remarks>See <see cref="TokensIn"/>.</remarks>
    public int? TokensOut { get; init; }

    /// <summary>True when the provider reported both counts, so the outcome carries a measurement.</summary>
    public bool HasReportedUsage => TokensIn is not null && TokensOut is not null;

    /// <summary>An outcome with no measurement — every path that did not reach a provider, or did not hear back.</summary>
    public static ModelGatewayOutcome Unmeasured(ModelInvocationResult result) => new() { Result = result };
}

/// <summary>
/// A model gateway that can say whether the provider reported usage.
/// </summary>
/// <remarks>
/// <para>
/// <b>Separate from <see cref="IModelGateway"/> on purpose.</b> The Platform port must keep returning
/// <see cref="ModelInvocationResult"/>, whose usage cannot express absence; widening that port would be
/// a Platform change. This is the AI Head's own port for the same call, and it is the one the governed
/// path uses — so the fact the provider gave no measurement survives all the way to the cost ledger
/// instead of being flattened into a zero at the first boundary.
/// </para>
/// <para>
/// A gateway that does not implement this port is not a governed provider route; the routing layer
/// resolves vendors through <see cref="INamedModelGateway"/>, which requires it.
/// </para>
/// </remarks>
public interface IUsageReportingModelGateway
{
    /// <summary>
    /// Invokes the model, reporting whether the provider supplied a usage measurement.
    /// </summary>
    Task<ModelGatewayOutcome> InvokeReportingUsageAsync(
        ModelInvocation invocation,
        CancellationToken ct = default);
}
