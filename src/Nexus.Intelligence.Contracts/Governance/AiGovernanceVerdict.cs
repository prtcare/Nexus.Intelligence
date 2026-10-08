namespace Nexus.Intelligence.Contracts;

/// <summary>
/// What AI Governance decided about one proposed AI execution.
/// </summary>
/// <remarks>
/// <para>
/// The three-value vocabulary the W7B directive names: <c>ALLOW</c>, <c>BLOCK</c> and
/// <c>HUMAN_DECISION_REQUIRED</c>. It is a closed set for the same reason
/// <see cref="AiFailureCategory"/> is: a caller branches on these values, so adding one is a contract
/// change the consumers must be able to see, and a free-form outcome string would make that branch
/// unreviewable.
/// </para>
/// <para>
/// <b>The numbering is severity, and it is load-bearing.</b>
/// <see cref="Allow"/> is 0, <see cref="HumanDecisionRequired"/> is 1 and <see cref="Block"/> is 2, so
/// the most restrictive verdict of a set is its numeric maximum. That is what makes
/// <see cref="AiGovernanceDecision.Combine"/> — the only operator that composes two decisions —
/// incapable of weakening one. Every rule in the evaluator's table returns a verdict, and composition
/// takes the maximum; there is no code path that can lower a verdict, which is how "a human-required
/// decision cannot silently become ALLOW" is a structural property rather than a reviewed convention.
/// </para>
/// <para>
/// <b><see cref="HumanDecisionRequired"/> is ranked below <see cref="Block"/> deliberately.</b> A
/// block is a refusal no human can lift by deciding; a human-required decision is a pause that a
/// named person can resolve either way. If the ranking were reversed, a block combined with a
/// human-required decision would surface as "ask a human", which invites a person to grant what the
/// deterministic rule refused. The ordering makes the un-liftable refusal win.
/// </para>
/// </remarks>
public enum AiGovernanceVerdict
{
    /// <summary>AI participation is permitted. Nothing in policy refused it.</summary>
    /// <remarks>
    /// <b>Permission to proceed, never authority to act.</b> An allowed AI execution is advisory
    /// output; it does not merge, deploy, alter protected architecture, resolve a credential or decide
    /// anything Platform Governance owns. Those are refused upstream and by
    /// <see cref="AiProhibitedSurface"/>, not by this value.
    /// </remarks>
    Allow = 0,

    /// <summary>A named human must decide before this execution may proceed. Terminal until they act.</summary>
    HumanDecisionRequired = 1,

    /// <summary>AI participation is refused. Deterministic for the same inputs; no human can lift it here.</summary>
    Block = 2,
}

/// <summary>Classification and composition for <see cref="AiGovernanceVerdict"/>.</summary>
public static class AiGovernanceVerdictExtensions
{
    /// <summary>True when the verdict refuses the execution in any form.</summary>
    public static bool IsRefusal(this AiGovernanceVerdict verdict) => verdict is not AiGovernanceVerdict.Allow;

    /// <summary>True when the verdict is the strongest refusal: no human may lift it at this gate.</summary>
    public static bool IsHardBlock(this AiGovernanceVerdict verdict) => verdict is AiGovernanceVerdict.Block;

    /// <summary>
    /// The more restrictive of two verdicts.
    /// </summary>
    /// <remarks>
    /// The one composition rule, expressed once. It delegates to the numeric ordering rather than to a
    /// switch so that a future verdict cannot be added without the ordering being reconsidered — a
    /// switch with a default would silently map an unlisted value to one arm.
    /// </remarks>
    public static AiGovernanceVerdict MostRestrictive(this AiGovernanceVerdict left, AiGovernanceVerdict right)
        => (AiGovernanceVerdict)Math.Max((int)left, (int)right);

    /// <summary>
    /// The directive's own token: <c>ALLOW</c>, <c>HUMAN_DECISION_REQUIRED</c> or <c>BLOCK</c>.
    /// </summary>
    /// <remarks>
    /// Separate from <see cref="object.ToString"/> because the two answer different questions. The
    /// enum name is C# vocabulary for a developer; this is the wire token an audit record, a metric
    /// label or a control document uses, and the W7B directive names the outcomes in these exact
    /// words. Keeping one spelling in code and the other in the record would make a reviewer unable to
    /// grep a decision back to the rule that produced it.
    /// </remarks>
    public static string ToToken(this AiGovernanceVerdict verdict) => verdict switch
    {
        AiGovernanceVerdict.Allow => "ALLOW",
        AiGovernanceVerdict.HumanDecisionRequired => "HUMAN_DECISION_REQUIRED",
        AiGovernanceVerdict.Block => "BLOCK",
        _ => throw new ArgumentOutOfRangeException(
            nameof(verdict), verdict, "An undefined AI governance verdict has no directive token."),
    };

    /// <summary>
    /// The execution status this verdict produces on <see cref="AiExecutionResult"/>.
    /// </summary>
    /// <remarks>
    /// The mapping exists so that a governed execution reports through the status vocabulary that
    /// already crosses the boundary, rather than growing a second one. <see cref="AiExecutionStatus.
    /// Blocked"/> and <see cref="AiExecutionStatus.PendingHumanDecision"/> already carry exactly these
    /// two meanings, including the distinction that a pending human decision is terminal until a
    /// person acts.
    /// </remarks>
    public static AiExecutionStatus ToExecutionStatus(this AiGovernanceVerdict verdict) => verdict switch
    {
        AiGovernanceVerdict.Allow => AiExecutionStatus.Succeeded,
        AiGovernanceVerdict.HumanDecisionRequired => AiExecutionStatus.PendingHumanDecision,
        AiGovernanceVerdict.Block => AiExecutionStatus.Blocked,
        _ => throw new ArgumentOutOfRangeException(nameof(verdict), verdict, "Undefined governance verdict."),
    };
}
