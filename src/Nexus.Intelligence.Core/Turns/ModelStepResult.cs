using Nexus.Intelligence.Contracts;
using Nexus.Platform.Contracts.Models;

namespace Nexus.Intelligence.Core.Turns;

public sealed record ModelStepResult(ModelInvocationResult Result, DecisionTrace Decision)
{
    /// <summary>
    /// Input tokens the provider reported, or <c>null</c> when it reported no usage at all.
    /// </summary>
    /// <remarks>
    /// <b>Carried beside <see cref="Result"/> rather than read out of it.</b> Platform's
    /// <see cref="ModelInvocationResult.Usage"/> is non-nullable and defaults to
    /// <see cref="ModelUsage.Zero"/>, so it cannot distinguish "the provider said nothing" from "the
    /// provider said zero". This member can, and it is what the cost ledger is written from.
    /// </remarks>
    public int? TokensIn { get; init; }

    /// <summary>Output tokens the provider reported, or <c>null</c> when it reported no usage at all.</summary>
    /// <remarks>See <see cref="TokensIn"/> — null together with it, or not at all.</remarks>
    public int? TokensOut { get; init; }
}
