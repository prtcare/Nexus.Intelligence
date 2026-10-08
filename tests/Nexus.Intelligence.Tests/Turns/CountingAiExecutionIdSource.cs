using Nexus.Intelligence.Core.Operations;

namespace Nexus.Intelligence.Tests.Turns;

/// <summary>
/// An execution-identity source that hands out a known sequence, so a test can name what the estate wrote.
/// </summary>
/// <remarks>
/// <para>
/// <b>It exists because <c>Guid.NewGuid()</c> cannot be asserted against.</b> A test that composed the
/// governed path over the shipped <see cref="GuidAiExecutionIdSource"/> and then asserted "two
/// executions produced two different identities" would be asserting a property of GUID generation, and
/// would pass just as well on a governed path that ignored the source entirely. Over this source the
/// same test can state the identities it expects, which means a path that stopped minting — or that
/// reverted to writing the request identifier — fails with the value it actually wrote in the message.
/// </para>
/// <para>
/// <b>It is deterministic, not random, and it must not be used to reason about unpredictability.</b>
/// Nothing in the estate depends on the execution identity being unguessable; see
/// <see cref="IAiExecutionIdSource"/>. The prefix is deliberately not GUID-shaped so that an identity
/// appearing in a failure message is recognisable as this harness's rather than the estate's.
/// </para>
/// </remarks>
internal sealed class CountingAiExecutionIdSource : IAiExecutionIdSource
{
    private int _issued;

    /// <inheritdoc />
    public string Next() => $"exec-{++_issued:D4}";

    /// <summary>How many identities this source has handed out.</summary>
    /// <remarks>
    /// Exposed so a test can assert that an execution the trace store suppressed minted none — the
    /// composition of the two idempotency controls, which is a claim about a count rather than about a
    /// value.
    /// </remarks>
    public int Issued => _issued;
}
