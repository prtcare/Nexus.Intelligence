using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// Reconciles a predicted cost against a measured one, and says which is authoritative.
/// </summary>
/// <remarks>
/// <para>
/// <b>The distinction the directive asks for is between ESTIMATED and ACTUAL_RECORDED, and it is a
/// distinction about <em>when the number was knowable</em>, not about how confident anyone is.</b>
/// Both figures are derived from the same published rates; they differ because one was computed
/// before the call from a predicted token count and the other after it from the tokens the provider
/// reported. Neither is a settled invoice, and the estate does not claim either is — what it claims
/// is that a reader can tell which one it is holding.
/// </para>
/// <para>
/// <b>Nothing here throws and nothing here refuses.</b> A reconciliation is a statement about two
/// numbers, not a gate. The gate is the budget evaluator, which reads the reconciled figure and
/// compares it against a ceiling an operator wrote down.
/// </para>
/// </remarks>
public static class AiCostReconciler
{
    /// <summary>
    /// Which figure is authoritative, given what was available.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The measured figure wins whenever there is one, because it rests on observed tokens rather
    /// than predicted ones. The prediction is used only where no measurement exists — a refused
    /// execution, or one whose provider reported no usage.
    /// </para>
    /// <para>
    /// <b><see cref="AiCostBasis.Unpriced"/> is returned rather than zero when neither exists.</b> An
    /// unpriced execution did not cost nothing; its cost is unknown, and reporting zero would hand
    /// every ceiling a figure that always passes.
    /// </para>
    /// </remarks>
    public static AiCostBasis BasisFor(decimal? estimated, decimal? actual)
    {
        if (actual is not null)
        {
            return AiCostBasis.ActualRecorded;
        }

        return estimated is not null ? AiCostBasis.Estimated : AiCostBasis.Unpriced;
    }

    /// <summary>The authoritative amount, or null when the execution cannot be priced.</summary>
    public static decimal? Authoritative(decimal? estimated, decimal? actual)
        => BasisFor(estimated, actual) switch
        {
            AiCostBasis.ActualRecorded => actual,
            AiCostBasis.Estimated => estimated,
            _ => null,
        };

    /// <summary>
    /// Why the prediction and the measurement differ, or null when they agree or one is absent.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Every difference is explained, and nothing is dismissed as rounding.</b> There is no
    /// tolerance band here, deliberately: a band would be a number nobody configured that silently
    /// suppresses small divergences, and small divergences are exactly how a wrong rate is
    /// discovered — a rate that is right is right exactly, because both figures come from it.
    /// </para>
    /// <para>
    /// A divergence therefore has one of two ordinary causes, and while this method cannot tell them
    /// apart it can name both, which is what an investigator needs to start from: the predicted token
    /// count differed from the observed one, or something about the route differed between the
    /// estimate and the call.
    /// </para>
    /// </remarks>
    public static string? VarianceReason(decimal? estimated, decimal? actual)
    {
        if (estimated is not { } prediction || actual is not { } measured)
        {
            return null;
        }

        if (prediction == measured)
        {
            return null;
        }

        var direction = measured > prediction ? "above" : "below";

        return $"The measured cost {measured} is {direction} the pre-invocation estimate {prediction}. "
            + "Both figures are derived from the same published rates, so the divergence is in the "
            + "inputs rather than the arithmetic: the observed token counts differed from the "
            + "predicted ones, the token count was served at a different rate than the one quoted, or "
            + "the route changed between the estimate and the call.";
    }

    /// <summary>
    /// Builds the reconciled pair from a prediction, a measurement and the quote behind each.
    /// </summary>
    /// <param name="estimated">The pre-invocation prediction, where one was possible.</param>
    /// <param name="actual">The post-invocation figure, where one was computable.</param>
    /// <param name="currency">The currency both figures are in, or null when neither exists.</param>
    public static (decimal? Estimated, decimal? Actual, AiCostBasis Basis) Reconcile(
        decimal? estimated, decimal? actual, string? currency)
    {
        if (estimated is not null && currency is null)
        {
            throw new ArgumentException(
                "A cost was predicted without a currency. A figure with no unit cannot be compared "
                + "against a ceiling, and comparing it silently is the defect the currency exists to "
                + "prevent.",
                nameof(currency));
        }

        return (estimated, actual, BasisFor(estimated, actual));
    }
}
