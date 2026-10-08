namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What the exposure policy decided for one request. The output of stage two of the exposure path.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="DeclaredClassification"/> is the gate; <see cref="ContextCeiling"/> is information. They
/// are separate on purpose, and the reason is worth stating because it is the one design decision in
/// this file that a reviewer should challenge.
/// </para>
/// <para>
/// The alternative is to gate on the aggregate — block the whole request when any attached source is
/// more sensitive than the request's declared classification. That is simpler, and it is wrong twice
/// over. It lets one attachment deny an entire request, so a caller who is denied learns to stop
/// attaching the sensitive document rather than to stop sending it, and the control drives the
/// behaviour it exists to prevent. And it removes the filtering stage the exposure model requires by
/// making it unreachable: if the aggregate always gates, the builder is never asked to exclude
/// anything.
/// </para>
/// <para>
/// So the declared classification — the caller's assertion about the request as a whole — is what
/// policy is evaluated against, and an individual source more sensitive than the request is excluded
/// by the builder and reported. An excluded source never reaches execution, and the caller is told the
/// answer was built without it.
/// </para>
/// </remarks>
public sealed record DataExposureDecision
{
    /// <summary>True when the request may proceed to execution.</summary>
    public required bool Allowed { get; init; }

    /// <summary>The destination class the request was evaluated against.</summary>
    public required AiDestinationClass Destination { get; init; }

    /// <summary>The classification the caller declared for the request. This is what was gated on.</summary>
    public required DataClassification DeclaredClassification { get; init; }

    /// <summary>
    /// The most sensitive classification among the supplied context. Informational, and recorded — not
    /// the value the gate used.
    /// </summary>
    public required DataClassification ContextCeiling { get; init; }

    /// <summary>True when content must pass through a redactor before egress.</summary>
    public bool RequiresRedaction { get; init; }

    /// <summary>Why, in caller-safe terms.</summary>
    public string? Reason { get; init; }

    /// <summary>The rules that produced the decision, for the audit record.</summary>
    public IReadOnlyList<string> RulesApplied { get; init; } = [];

    /// <summary>
    /// The typed failure to return when <see cref="Allowed"/> is false.
    /// </summary>
    /// <remarks>
    /// The category is <see cref="AiFailureCategory.DataExposureBlocked"/> and not
    /// <see cref="AiFailureCategory.PolicyBlocked"/>. A caller must be able to distinguish "this data
    /// may not go there" from "this action is not permitted": the first is often answered by
    /// re-classifying or by accepting a local destination, the second is not, and a caller given one
    /// category for both will apply the wrong remedy and escalate the wrong thing.
    /// </remarks>
    public AiFailure ToFailure(string correlationId) => AiFailure.From(
        AiFailureCategory.DataExposureBlocked,
        "data_exposure_blocked",
        Reason ?? "The request's data classification forbids the exposure it asked for.",
        correlationId);
}

/// <summary>
/// Evaluates a request's exposure against the policy table. Stage two of the exposure path.
/// </summary>
/// <remarks>
/// <c>caller → exposure policy → context builder → redaction/filtering → AI execution</c>
/// </remarks>
public interface IDataExposurePolicyEvaluator
{
    /// <summary>Evaluates a request for a destination class.</summary>
    DataExposureDecision Evaluate(
        DataClassification declared,
        IReadOnlyList<DataClassification> contextClassifications,
        AiDestinationClass destination);
}

/// <summary>What the builder admitted and what it excluded.</summary>
public sealed record ContextBuildResult
{
    /// <summary>The context that may proceed to execution.</summary>
    public required ContextBundle Bundle { get; init; }

    /// <summary>
    /// The excluded items, by reference. The item bodies are dropped rather than carried alongside, so
    /// an excluded secret is not still in memory in the object that reports its exclusion.
    /// </summary>
    public IReadOnlyList<AiContextReference> Excluded { get; init; } = [];

    /// <summary>True when anything was excluded, and therefore when the result is built on partial context.</summary>
    public bool IsPartial => Excluded.Count > 0;
}

/// <summary>
/// Builds the context an execution will actually receive. Stage three of the exposure path.
/// </summary>
/// <remarks>
/// Separated from the evaluator because the two answer different questions. The evaluator decides
/// <em>whether the request</em> may go; the builder decides <em>which of its sources</em> go once it
/// may. Collapsing them into one type is the usual way a redaction or filtering step becomes
/// optional — it stops being a stage with its own decision and becomes a branch inside someone else's.
/// </remarks>
public interface IContextBuilder
{
    /// <summary>Builds the context an execution may receive, excluding sources the destination does not admit.</summary>
    ContextBuildResult Build(ContextBundle supplied, DataExposureDecision decision, DataExposurePolicy policy);
}

/// <summary>Removes or masks content that must not reach an execution. Stage four of the exposure path.</summary>
/// <remarks>
/// <b>Provider-agnostic by directive.</b> A redactor answers what may be sent, never which provider
/// receives it. Filtering tuned to one provider's handling would place provider knowledge above the
/// boundary whose purpose is to keep it below — and would leave the estate with a redaction posture
/// that silently changes when routing changes provider.
/// </remarks>
public interface IContextRedactor
{
    /// <summary>Redacts a context bundle.</summary>
    ContextBundle Redact(ContextBundle bundle);
}

/// <summary>
/// The default evaluator: gates the request on its declared classification and reports the context
/// ceiling.
/// </summary>
/// <remarks>
/// Deterministic and total. It consults only the policy table, which is configuration — there is no
/// provider, no model and no network in this path, and there is nothing here for a caller to influence
/// other than by declaring its classification honestly.
/// </remarks>
public sealed class DeclaredClassificationExposureEvaluator : IDataExposurePolicyEvaluator
{
    private readonly DataExposurePolicy _policy;

    /// <summary>Builds an evaluator over a policy table.</summary>
    public DeclaredClassificationExposureEvaluator(DataExposurePolicy policy)
        => _policy = policy ?? throw new ArgumentNullException(nameof(policy));

    /// <inheritdoc />
    public DataExposureDecision Evaluate(
        DataClassification declared,
        IReadOnlyList<DataClassification> contextClassifications,
        AiDestinationClass destination)
    {
        ArgumentNullException.ThrowIfNull(contextClassifications);

        var rule = _policy.RuleFor(declared);
        var ceiling = DataClassificationExtensions.Aggregate(contextClassifications);
        var allowed = rule.AllowedDestinations.Contains(destination);

        return new DataExposureDecision
        {
            Allowed = allowed,
            Destination = destination,
            DeclaredClassification = declared,
            ContextCeiling = ceiling,
            RequiresRedaction = allowed && rule.RequiresRedaction,
            Reason = allowed
                ? null
                : $"Content classified '{declared}' may not be sent to a '{destination}' destination.",
            RulesApplied = [$"{declared}->{destination}={(allowed ? "allowed" : "denied")}",
                            $"context-ceiling={ceiling}"],
        };
    }
}

/// <summary>
/// The default context builder: excludes sources the destination does not admit.
/// </summary>
/// <remarks>
/// <para>
/// Excludes whole items and never truncates one. A truncated item is a partially disclosed item, and a
/// caller handed half a record cannot tell that it was half a record — it reads as a short document,
/// not as a withheld one.
/// </para>
/// <para>
/// An item with no declared classification inherits the request's declared classification. This is not
/// a fail-open: the request's classification is a required field the caller asserted, and inheriting it
/// means an undeclared source can only ever be treated as sensitive as the request already is — never
/// as harmless.
/// </para>
/// </remarks>
public sealed class FilteringContextBuilder : IContextBuilder
{
    /// <inheritdoc />
    public ContextBuildResult Build(
        ContextBundle supplied,
        DataExposureDecision decision,
        DataExposurePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(supplied);
        ArgumentNullException.ThrowIfNull(decision);
        ArgumentNullException.ThrowIfNull(policy);

        var admitted = new List<ContextItem>(supplied.Items.Count);
        var excluded = new List<AiContextReference>();

        foreach (var item in supplied.Items)
        {
            var itemClassification = item.Classification ?? decision.DeclaredClassification;

            if (policy.RuleFor(itemClassification).AllowedDestinations.Contains(decision.Destination))
            {
                admitted.Add(item);
                continue;
            }

            excluded.Add(new AiContextReference
            {
                ContextItemId = item.Id,
                Classification = itemClassification,

                // Excluded content is referenced without a digest. A hash of content that was withheld
                // is still a durable artefact derived from it, and the reference exists to show that
                // something was left out, not to let a later reader confirm what it was.
                ContentHash = null,
            });
        }

        return new ContextBuildResult
        {
            Bundle = new ContextBundle(admitted),
            Excluded = excluded,
        };
    }
}

/// <summary>
/// The default redactor: applies <see cref="AiRedaction"/> to the free text of every item.
/// </summary>
/// <remarks>
/// <para>
/// A deterministic, provider-agnostic backstop — not a data-loss-prevention system. It removes known
/// credential shapes and nothing else. It cannot detect personal data, financial identifiers or
/// customer records in prose, and it does not claim to. It exists so that stage four is present, typed
/// and testable, and so the stage a later lane replaces already has a shape and a caller.
/// </para>
/// <para>
/// It never rewrites <see cref="ContextItem.Id"/>. The identifier is what a
/// <see cref="Citation"/> points at; redacting it would break the link between an answer and its
/// source, which is the evidence a reviewer needs when they dispute the answer.
/// </para>
/// </remarks>
public sealed class RedactingContextRedactor : IContextRedactor
{
    /// <inheritdoc />
    public ContextBundle Redact(ContextBundle bundle)
    {
        ArgumentNullException.ThrowIfNull(bundle);

        var redacted = bundle.Items
            .Select(item => item with
            {
                Body = AiRedaction.Redact(item.Body) ?? string.Empty,
                Title = AiRedaction.Redact(item.Title),
                Tags = item.Tags.ToDictionary(
                    tag => AiRedaction.Redact(tag.Key) ?? string.Empty,
                    tag => AiRedaction.Redact(tag.Value) ?? string.Empty,
                    StringComparer.Ordinal),
            })
            .ToArray();

        return new ContextBundle(redacted);
    }
}
